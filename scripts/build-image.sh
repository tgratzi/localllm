#!/usr/bin/env bash
# Builds the Gemma server image (llama-server + baked-in GGUF weights).
#
#   scripts/build-image.sh                 # local build, loads gemma-e2b-server:local
#   scripts/build-image.sh --push [TAG]    # build linux/amd64, push to Artifact Registry
#                                          # with SBOM + provenance, print the digest
#
# --push reads gcp/env.sh for PROJECT_ID / REGION / AR_REPO / IMAGE_NAME.
# The build downloads ~5 GB from Hugging Face; allow 15+ GB of free Docker disk.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

mode="local"
tag=""
case "${1:-}" in
    "")       ;;
    --push)   mode="push"; tag="${2:-}" ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *)        echo "ERROR: unknown argument '$1' (use --push [TAG])" >&2; exit 1 ;;
esac

command -v docker >/dev/null || { echo "ERROR: docker is required." >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "ERROR: docker buildx is required." >&2; exit 1; }

echo "==> Checking model pins against Hugging Face"
scripts/verify-model-file.sh

# Optional HF token for gated models, passed as a BuildKit secret, never a build arg.
secret_args=()
if [[ -n "${HF_TOKEN_FILE:-}" ]]; then
    [[ -r "$HF_TOKEN_FILE" ]] || { echo "ERROR: HF_TOKEN_FILE '$HF_TOKEN_FILE' is not readable." >&2; exit 1; }
    secret_args=(--secret "id=hf_token,src=${HF_TOKEN_FILE}")
fi

if [[ "$mode" == "local" ]]; then
    image="${LOCAL_IMAGE:-gemma-e2b-server:local}"
    echo "==> Building ${image}"
    docker buildx build --load --platform linux/amd64 ${secret_args[@]+"${secret_args[@]}"} -t "$image" .
    echo
    echo "Built ${image}. Next: scripts/test-local.sh ${image}"
    if command -v trivy >/dev/null; then
        echo "==> Scanning with trivy (HIGH,CRITICAL)"
        trivy image --scanners vuln --severity HIGH,CRITICAL "$image" || true
    fi
    exit 0
fi

# --- push mode ------------------------------------------------------------------------
# shellcheck source=../gcp/common.sh
source "${repo_root}/gcp/common.sh"
require_vars AR_REPO IMAGE_NAME

if [[ -z "$tag" ]]; then
    sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)"
    tag="$(date -u +%Y%m%d)-${sha}"
    [[ -z "$(git status --porcelain 2>/dev/null)" ]] || tag="${tag}-dirty"
fi
[[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || { echo "ERROR: invalid tag '$tag'." >&2; exit 1; }

image="${IMAGE_PATH}:${tag}"
"${GCLOUD[@]}" artifacts repositories describe "$AR_REPO" --location="$REGION" >/dev/null \
    || { echo "ERROR: Artifact Registry repo '$AR_REPO' not found. Run gcp/setup-network.sh first." >&2; exit 1; }
gcloud auth configure-docker "$AR_HOST" --quiet >/dev/null

metadata="$(mktemp)"
trap 'rm -f "$metadata"' EXIT

echo "==> Building and pushing ${image}"
# --sbom / --provenance attach an SPDX SBOM and SLSA provenance to the pushed image.
docker buildx build --platform linux/amd64 ${secret_args[@]+"${secret_args[@]}"} \
    --sbom=true --provenance=mode=max \
    --metadata-file "$metadata" \
    -t "$image" --push .

digest="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["containerimage.digest"])' "$metadata")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: could not read pushed digest." >&2; exit 1; }

echo
echo "Pushed: ${image}"
echo "Digest: ${IMAGE_PATH}@${digest}"
echo
echo "Deploy this exact digest:"
echo "  scripts/deploy-vm.sh ${IMAGE_PATH}@${digest}"
if [[ "${ENABLE_AR_SCANNING:-true}" == "true" ]]; then
    echo
    echo "Vulnerability results (ready a few minutes after push):"
    echo "  gcloud artifacts docker images describe ${IMAGE_PATH}@${digest} --show-package-vulnerability --project=${PROJECT_ID}"
fi
