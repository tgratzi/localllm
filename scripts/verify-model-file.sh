#!/usr/bin/env bash
# Checks the model pins in the Dockerfile against Hugging Face BEFORE a 5 GB build:
#   - the repository and revision exist,
#   - the GGUF file exists at that revision,
#   - Hugging Face's published SHA-256 matches MODEL_SHA256.
# Also lists the GGUF files available at that revision, to help pick a different one.
#
# Usage: scripts/verify-model-file.sh
# Override any pin with env vars: MODEL_REPO, MODEL_REVISION, MODEL_FILE, MODEL_SHA256.
# Requires: curl, python3.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${repo_root}/Dockerfile"

# Read a default `ARG NAME=value` from the Dockerfile so there is one source of truth.
dockerfile_arg() {
    sed -n "s/^ARG $1=\(.*\)$/\1/p" "$dockerfile" | head -n 1
}

MODEL_REPO="${MODEL_REPO:-$(dockerfile_arg MODEL_REPO)}"
MODEL_REVISION="${MODEL_REVISION:-$(dockerfile_arg MODEL_REVISION)}"
MODEL_FILE="${MODEL_FILE:-$(dockerfile_arg MODEL_FILE)}"
MODEL_SHA256="${MODEL_SHA256:-$(dockerfile_arg MODEL_SHA256)}"

for v in MODEL_REPO MODEL_REVISION MODEL_FILE MODEL_SHA256; do
    [[ -n "${!v}" ]] || { echo "ERROR: ${v} is empty (not set and not found in Dockerfile)." >&2; exit 1; }
done
[[ "$MODEL_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "ERROR: MODEL_REPO '$MODEL_REPO' is not owner/name." >&2; exit 1; }
[[ "$MODEL_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "ERROR: MODEL_SHA256 is not a 64-char lowercase hex string." >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 is required." >&2; exit 1; }

echo "Repository: ${MODEL_REPO}"
echo "Revision:   ${MODEL_REVISION}"
echo "File:       ${MODEL_FILE}"
echo

tree_json="$(curl -fsS --proto '=https' "https://huggingface.co/api/models/${MODEL_REPO}/tree/${MODEL_REVISION}")" || {
    echo "ERROR: could not list ${MODEL_REPO} at revision ${MODEL_REVISION}. Check the repo name and revision." >&2
    exit 1
}

TREE_JSON="$tree_json" python3 - "$MODEL_FILE" "$MODEL_SHA256" <<'PY'
import json, os, sys

wanted, expected_sha = sys.argv[1], sys.argv[2]
entries = json.loads(os.environ["TREE_JSON"])
ggufs = [e for e in entries if e.get("path", "").endswith(".gguf")]

print("GGUF files at this revision:")
for e in ggufs:
    size_gb = e.get("size", 0) / 1e9
    sha = (e.get("lfs") or {}).get("oid", "?")
    mark = "  <== selected" if e["path"] == wanted else ""
    print(f"  {e['path']:<40} {size_gb:6.2f} GB  sha256={sha}{mark}")
print()

match = next((e for e in ggufs if e["path"] == wanted), None)
if match is None:
    sys.exit(f"ERROR: '{wanted}' does not exist at this revision. Pick one of the files above.")

actual_sha = (match.get("lfs") or {}).get("oid")
if actual_sha != expected_sha:
    sys.exit(f"ERROR: published SHA-256 is {actual_sha}, Dockerfile expects {expected_sha}.")

if wanted.startswith(("mmproj-", "mtp-")):
    sys.exit("ERROR: that is a projector/draft file, not a standalone language model.")

print(f"OK: {wanted} exists, {match['size'] / 1e9:.2f} GB, SHA-256 matches the Dockerfile.")
PY

# The resolve URL is what the Docker build downloads; confirm it answers too.
status="$(curl -sS -o /dev/null -w '%{http_code}' --proto '=https' -I \
    "https://huggingface.co/${MODEL_REPO}/resolve/${MODEL_REVISION}/${MODEL_FILE}")"
if [[ "$status" != "302" && "$status" != "200" ]]; then
    echo "ERROR: download URL returned HTTP ${status}." >&2
    exit 1
fi
echo "OK: download URL responds (HTTP ${status})."
