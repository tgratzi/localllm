#!/usr/bin/env bash
# Deploys YOUR application (RUN_IMAGE) to Cloud Run so it can call the Gemma VM privately.
#
#   - Runtime service account RUN_SA_NAME with one grant: secretAccessor on SECRET_NAME only.
#   - Direct VPC egress into RUN_SUBNET, private-ranges-only: traffic to 10.x (the VM)
#     goes through the VPC; traffic to the internet and Google APIs does not.
#   - Ingress "internal": only callers inside the VPC / same project perimeter can reach it.
#   - No unauthenticated invocation; roles/run.invoker only for RUN_INVOKERS.
#   - Injects GEMMA_BASE_URL and GEMMA_API_KEY (from Secret Manager). These names are
#     examples: rename them to whatever your application code reads.
#
# Re-running deploys a new revision, which also picks up the latest secret version.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_vars RUN_SERVICE RUN_IMAGE RUN_SA_NAME SECRET_NAME NETWORK RUN_SUBNET VM_NAME

log "Runtime service account ${RUN_SA_EMAIL}"
if exists "${GCLOUD[@]}" iam service-accounts describe "$RUN_SA_EMAIL"; then
    info "exists"
else
    "${GCLOUD[@]}" iam service-accounts create "$RUN_SA_NAME" --display-name="Gemma app on Cloud Run"
    info "created"
fi

log "Grant: secretAccessor on secret ${SECRET_NAME} only"
"${GCLOUD[@]}" secrets add-iam-policy-binding "$SECRET_NAME" \
    --member="serviceAccount:${RUN_SA_EMAIL}" --role="roles/secretmanager.secretAccessor" >/dev/null
info "done"

vm_ip="$(vm_internal_ip)"
[[ -n "$vm_ip" ]] || die "Could not read the internal IP of ${VM_NAME}."
base_url="http://${vm_ip}:8080/v1"

log "Deploying ${RUN_SERVICE} (${RUN_IMAGE})"
info "GEMMA_BASE_URL=${base_url}"
"${GCLOUD[@]}" run deploy "$RUN_SERVICE" \
    --region="$REGION" \
    --image="$RUN_IMAGE" \
    --service-account="$RUN_SA_EMAIL" \
    --network="$NETWORK" \
    --subnet="$RUN_SUBNET" \
    --vpc-egress=private-ranges-only \
    --ingress=internal \
    --no-allow-unauthenticated \
    --set-env-vars="GEMMA_BASE_URL=${base_url}" \
    --set-secrets="GEMMA_API_KEY=${SECRET_NAME}:latest" \
    --concurrency="${RUN_CONCURRENCY:-4}" \
    --max-instances="${RUN_MAX_INSTANCES:-3}" \
    --timeout="${RUN_TIMEOUT:-300s}"

log "Invokers"
if [[ -z "${RUN_INVOKERS:-}" ]]; then
    warn "RUN_INVOKERS is empty: nobody except project owners/editors can invoke ${RUN_SERVICE}."
else
    IFS=',' read -r -a members <<< "$RUN_INVOKERS"
    for m in "${members[@]}"; do
        m="${m// /}"
        [[ "$m" != "allUsers" && "$m" != "allAuthenticatedUsers" ]] || die "Public invokers are not allowed."
        [[ "$m" =~ ^(user|serviceAccount|group|domain): ]] || die "Invalid member '$m'."
        "${GCLOUD[@]}" run services add-iam-policy-binding "$RUN_SERVICE" --region="$REGION" \
            --member="$m" --role="roles/run.invoker" >/dev/null
        info "roles/run.invoker -> ${m}"
    done
fi

# Fail loudly if anything public slipped in (for example from an earlier manual deploy).
public="$("${GCLOUD[@]}" run services get-iam-policy "$RUN_SERVICE" --region="$REGION" \
    --flatten='bindings[].members' --filter='bindings.members:allUsers OR bindings.members:allAuthenticatedUsers' \
    --format='value(bindings.role)')"
[[ -z "$public" ]] || die "${RUN_SERVICE} has a public binding (${public}). Remove it: gcloud run services remove-iam-policy-binding ..."

log "Done. Verify the private path with: gcp/verify-private-path.sh"
