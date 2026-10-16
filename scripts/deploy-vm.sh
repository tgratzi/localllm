#!/usr/bin/env bash
# Deploys (or rolls back) the Gemma container on the VM, over SSH through IAP.
# Run from Cloud Shell or a Linux/macOS workstation with gcloud.
#
#   scripts/deploy-vm.sh <REGION-docker.pkg.dev/PROJECT/REPO/IMAGE@sha256:DIGEST>
#   scripts/deploy-vm.sh --rollback     # previous digest on the VM
#   scripts/deploy-vm.sh --status
#
# Steps for a deploy:
#   1. Check the digest exists in Artifact Registry.
#   2. Copy compose.yaml, the VM helper scripts and the non-secret settings to the VM.
#   3. On the VM: install Docker + Compose if missing, enable Docker at boot.
#   4. If the VM has no API key yet, pipe the latest Secret Manager version to it.
#   5. On the VM: pull the digest with the VM's own service account, start, wait healthy.
source "$(dirname "${BASH_SOURCE[0]}")/../gcp/common.sh"
require_vars VM_NAME SECRET_NAME

case "${1:-}" in
    --status)
        vm_ssh --command='sudo /opt/gemma/bin/remote-deploy.sh status'
        exit 0 ;;
    --rollback)
        confirm "Roll ${VM_NAME} back to its previously deployed image?" || exit 1
        vm_ssh --command='sudo /opt/gemma/bin/remote-deploy.sh rollback'
        exit 0 ;;
    ""|-h|--help)
        sed -n '2,15p' "$0"; exit 1 ;;
esac

image="$1"
[[ "$image" == "${IMAGE_PATH}@sha256:"* && "$image" =~ @sha256:[0-9a-f]{64}$ ]] \
    || die "Expected ${IMAGE_PATH}@sha256:<64 hex>. Deploy digests, not tags (scripts/build-image.sh --push prints it)."

log "Checking ${image} exists in Artifact Registry"
"${GCLOUD[@]}" artifacts docker images describe "$image" >/dev/null \
    || die "Image digest not found in ${IMAGE_PATH}."

staging_local="$(mktemp -d)"
trap 'rm -rf "$staging_local"' EXIT
cp "${REPO_ROOT}/compose.yaml" "${REPO_ROOT}/scripts/vm/remote-deploy.sh" \
   "${REPO_ROOT}/scripts/vm/write-api-key.sh" "$staging_local/"
cat > "${staging_local}/settings.env" <<EOF
GEMMA_CTX_SIZE=${GEMMA_CTX_SIZE:-8192}
GEMMA_THREADS=${GEMMA_THREADS:-4}
GEMMA_PARALLEL=${GEMMA_PARALLEL:-1}
GEMMA_MAX_TOKENS=${GEMMA_MAX_TOKENS:-1024}
GEMMA_TIMEOUT_SECONDS=${GEMMA_TIMEOUT_SECONDS:-300}
GEMMA_REASONING=${GEMMA_REASONING:-off}
GEMMA_MEM_LIMIT=${GEMMA_MEM_LIMIT:-12g}
EOF

staging_remote="gemma-deploy-$(date +%s)"
log "Copying files to ${VM_NAME}:~/${staging_remote}"
vm_ssh --command="mkdir -p ~/${staging_remote}"
vm_scp "${staging_local}"/* "${VM_NAME}:~/${staging_remote}/"

log "Preparing the VM (Docker, Compose, /opt/gemma)"
vm_ssh --command="sudo bash ~/${staging_remote}/remote-deploy.sh prepare \$HOME/${staging_remote}"

if ! vm_ssh --command='sudo test -s /etc/gemma/api_key' 2>/dev/null; then
    log "No API key on the VM yet; copying the latest ${SECRET_NAME} version"
    "${GCLOUD[@]}" secrets versions access latest --secret="$SECRET_NAME" \
        | vm_ssh --command='sudo /opt/gemma/bin/write-api-key.sh'
fi

log "Starting ${image}"
vm_ssh --command="sudo /opt/gemma/bin/remote-deploy.sh up '${image}'"

log "Deployed. Internal endpoint: http://$(vm_internal_ip):8080/v1"
info "Next: gcp/configure-cloud-run.sh, then gcp/verify-private-path.sh"
