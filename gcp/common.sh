#!/usr/bin/env bash
# Shared helpers for the GCP scripts. Sourced, not executed.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${GEMMA_GCP_ENV:-${REPO_ROOT}/gcp/env.sh}"

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "'$c' is required but not installed."
    done
}

require_vars() {
    local v
    for v in "$@"; do
        [[ -n "${!v:-}" ]] || die "$v is empty. Set it in ${ENV_FILE}."
    done
}

# Ask before anything destructive. ASSUME_YES=1 skips the prompt (for CI only).
confirm() {
    local prompt="$1" answer
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then return 0; fi
    read -r -p "${prompt} [y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# True if a gcloud describe command finds the resource.
exists() { "$@" >/dev/null 2>&1; }

[[ -f "$ENV_FILE" ]] || die "Missing ${ENV_FILE}. Copy gcp/env.sh.example to gcp/env.sh and edit it."
# shellcheck source=/dev/null
source "$ENV_FILE"

require_cmd gcloud
require_vars PROJECT_ID REGION ZONE
[[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "PROJECT_ID '$PROJECT_ID' is not a valid project ID."

# Every gcloud call names the project explicitly instead of trusting the active config.
GCLOUD=(gcloud --project="$PROJECT_ID" --quiet)

AR_HOST="${REGION}-docker.pkg.dev"
IMAGE_PATH="${AR_HOST}/${PROJECT_ID}/${AR_REPO:-gemma}/${IMAGE_NAME:-gemma-e2b-server}"
VM_SA_EMAIL="${VM_SA_NAME:-gemma-vm}@${PROJECT_ID}.iam.gserviceaccount.com"
RUN_SA_EMAIL="${RUN_SA_NAME:-gemma-app-run}@${PROJECT_ID}.iam.gserviceaccount.com"
FW_ALLOW_8080="${NETWORK:-gemma-vpc}-allow-gemma-8080-from-run"
FW_ALLOW_IAP_SSH="${NETWORK:-gemma-vpc}-allow-iap-ssh-gemma"
ROUTER_NAME="${NETWORK:-gemma-vpc}-router"
NAT_NAME="${NETWORK:-gemma-vpc}-nat"
# Google's documented source range for IAP TCP forwarding.
IAP_RANGE="35.235.240.0/20"

vm_internal_ip() {
    "${GCLOUD[@]}" compute instances describe "$VM_NAME" --zone="$ZONE" \
        --format='value(networkInterfaces[0].networkIP)'
}

# SSH / SCP to the VM through IAP; the VM has no external IP.
vm_ssh() { "${GCLOUD[@]}" compute ssh "$VM_NAME" --zone="$ZONE" --tunnel-through-iap "$@"; }
vm_scp() { "${GCLOUD[@]}" compute scp --zone="$ZONE" --tunnel-through-iap "$@"; }
