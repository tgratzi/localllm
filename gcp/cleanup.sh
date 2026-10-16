#!/usr/bin/env bash
# Deletes what the other scripts created. DESTRUCTIVE and not reversible.
#
#   gcp/cleanup.sh            # VM, Cloud Run service + check job, firewall rules, NAT, router
#   gcp/cleanup.sh --all      # ...and the secret, the Artifact Registry repo (all images),
#                             #    subnets, VPC and both service accounts
#
# Every group asks for confirmation; the first prompt requires typing the project ID.
# The VPC is only deleted with --all and only if nothing else uses it.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

all=0
[[ "${1:-}" == "--all" ]] && all=1

echo "This deletes Gemma resources in project ${PROJECT_ID}."
read -r -p "Type the project ID to continue: " typed
[[ "$typed" == "$PROJECT_ID" ]] || die "Project ID did not match; nothing deleted."

try() { "$@" || warn "failed (may already be gone): $*"; }

if confirm "Delete Cloud Run service ${RUN_SERVICE} and job ${RUN_SERVICE}-vpc-check?"; then
    try "${GCLOUD[@]}" run services delete "$RUN_SERVICE" --region="$REGION"
    try "${GCLOUD[@]}" run jobs delete "${RUN_SERVICE}-vpc-check" --region="$REGION"
fi

if confirm "Delete VM ${VM_NAME} and its boot disk?"; then
    try "${GCLOUD[@]}" compute instances delete "$VM_NAME" --zone="$ZONE" --delete-disks=all
fi

if confirm "Delete firewall rules ${FW_ALLOW_8080} and ${FW_ALLOW_IAP_SSH}?"; then
    try "${GCLOUD[@]}" compute firewall-rules delete "$FW_ALLOW_8080"
    try "${GCLOUD[@]}" compute firewall-rules delete "$FW_ALLOW_IAP_SSH"
fi

if confirm "Delete Cloud NAT ${NAT_NAME} and router ${ROUTER_NAME}?"; then
    try "${GCLOUD[@]}" compute routers nats delete "$NAT_NAME" --router="$ROUTER_NAME" --region="$REGION"
    try "${GCLOUD[@]}" compute routers delete "$ROUTER_NAME" --region="$REGION"
fi

if (( all )); then
    if confirm "Delete secret ${SECRET_NAME} (ALL versions; the key cannot be recovered)?"; then
        try "${GCLOUD[@]}" secrets delete "$SECRET_NAME"
    fi
    if confirm "Delete Artifact Registry repo ${AR_REPO} and EVERY image in it?"; then
        try "${GCLOUD[@]}" artifacts repositories delete "$AR_REPO" --location="$REGION"
    fi
    if confirm "Delete subnets ${VM_SUBNET} and ${RUN_SUBNET}? (Cloud Run may hold IPs for a while after deletion)"; then
        try "${GCLOUD[@]}" compute networks subnets delete "$RUN_SUBNET" --region="$REGION"
        try "${GCLOUD[@]}" compute networks subnets delete "$VM_SUBNET" --region="$REGION"
    fi
    if confirm "Delete VPC ${NETWORK}? (fails if anything else still uses it)"; then
        try "${GCLOUD[@]}" compute networks delete "$NETWORK"
    fi
    if confirm "Delete service accounts ${VM_SA_EMAIL} and ${RUN_SA_EMAIL}?"; then
        try "${GCLOUD[@]}" iam service-accounts delete "$VM_SA_EMAIL"
        try "${GCLOUD[@]}" iam service-accounts delete "$RUN_SA_EMAIL"
    fi
fi

log "Cleanup finished. Project-level role bindings (Ops Agent roles, if enabled) are removed with the service account."
