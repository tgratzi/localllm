#!/usr/bin/env bash
# Creates the CPU-only Gemma VM and its service account.
#
#   - Ubuntu 24.04 LTS (image family ubuntu-2404-lts-amd64), Shielded VM, OS Login.
#   - NO external IP. Admin access is SSH through IAP only.
#   - Attached service account with exactly one grant: Artifact Registry reader on the
#     Gemma repository (not project-wide). No service-account keys are created.
#     INSTALL_OPS_AGENT=true additionally grants log/metric writer roles for the Ops Agent.
#
# Run after gcp/setup-network.sh: gcp/create-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_vars VM_NAME VM_MACHINE_TYPE VM_DISK_SIZE_GB VM_DISK_TYPE VM_SA_NAME VM_TAG VM_SUBNET AR_REPO
if ! [[ "$VM_DISK_SIZE_GB" =~ ^[0-9]+$ ]] || (( VM_DISK_SIZE_GB < 30 )); then
    die "VM_DISK_SIZE_GB must be a number >= 30."
fi

log "Service account ${VM_SA_EMAIL}"
if exists "${GCLOUD[@]}" iam service-accounts describe "$VM_SA_EMAIL"; then
    info "exists"
else
    "${GCLOUD[@]}" iam service-accounts create "$VM_SA_NAME" \
        --display-name="Gemma VM (pulls the Gemma image only)"
    info "created"
fi

log "Grant: Artifact Registry reader on repository ${AR_REPO} only"
"${GCLOUD[@]}" artifacts repositories add-iam-policy-binding "$AR_REPO" --location="$REGION" \
    --member="serviceAccount:${VM_SA_EMAIL}" --role="roles/artifactregistry.reader" >/dev/null
info "done"

if [[ "${INSTALL_OPS_AGENT:-false}" == "true" ]]; then
    log "Grant: logging.logWriter + monitoring.metricWriter (for the Ops Agent)"
    for role in roles/logging.logWriter roles/monitoring.metricWriter; do
        "${GCLOUD[@]}" projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:${VM_SA_EMAIL}" --role="$role" --condition=None >/dev/null
    done
    info "done"
fi

log "VM ${VM_NAME} (${VM_MACHINE_TYPE}, ${ZONE})"
if exists "${GCLOUD[@]}" compute instances describe "$VM_NAME" --zone="$ZONE"; then
    info "exists; not modifying it"
else
    # --scopes=cloud-platform is Google's recommended pairing with IAM: the service
    # account's roles above are what actually limit access.
    "${GCLOUD[@]}" compute instances create "$VM_NAME" \
        --zone="$ZONE" \
        --machine-type="$VM_MACHINE_TYPE" \
        --subnet="$VM_SUBNET" \
        --no-address \
        --tags="$VM_TAG" \
        --service-account="$VM_SA_EMAIL" \
        --scopes=cloud-platform \
        --image-family=ubuntu-2404-lts-amd64 \
        --image-project=ubuntu-os-cloud \
        --boot-disk-size="${VM_DISK_SIZE_GB}GB" \
        --boot-disk-type="$VM_DISK_TYPE" \
        --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
        --metadata=enable-oslogin=TRUE,block-project-ssh-keys=TRUE \
        --labels=app=gemma-e2b
    info "created"
fi

# Prove the "no external IP" requirement instead of assuming it.
access_configs="$("${GCLOUD[@]}" compute instances describe "$VM_NAME" --zone="$ZONE" \
    --format='value(networkInterfaces[].accessConfigs[].natIP.list())')"
[[ -z "$access_configs" ]] || die "VM has an external IP (${access_configs}). Remove it: it must not be public."

info "internal IP: $(vm_internal_ip)"
info "external IP: none"
log "Done. Next: scripts/deploy-vm.sh <IMAGE@sha256:DIGEST>"
info "Your user needs roles/iap.tunnelResourceAccessor and OS Login (roles/compute.osAdminLogin) to SSH."
