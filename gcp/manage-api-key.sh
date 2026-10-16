#!/usr/bin/env bash
# The API key that llama-server requires, kept in Secret Manager.
#
#   gcp/manage-api-key.sh create          # create the secret with a random first version
#   gcp/manage-api-key.sh push-to-vm      # copy the LATEST version to the VM
#   gcp/manage-api-key.sh rotate          # zero-downtime rotation, step 1 (see below)
#   gcp/manage-api-key.sh finish-rotation # rotation step 3
#
# Rotation without downtime works because llama-server accepts several keys (one per
# line in the key file):
#   1. rotate          - adds a new secret version; the VM accepts OLD and NEW keys.
#   2. gcp/configure-cloud-run.sh - new Cloud Run revision picks up the NEW key.
#   3. finish-rotation - the VM accepts only the NEW key; the old version is disabled.
#
# Key values never appear on a command line, in shell history or in logs: they are
# generated in Python and piped through stdin, including over the IAP SSH session.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd python3
require_vars SECRET_NAME VM_NAME

new_key() { python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")'; }

access() { "${GCLOUD[@]}" secrets versions access "$1" --secret="$SECRET_NAME"; }

latest_version() {
    "${GCLOUD[@]}" secrets versions list "$SECRET_NAME" --filter='state=ENABLED' \
        --sort-by='~createTime' --limit=1 --format='value(name.basename())'
}

# Send key lines on stdin to the VM helper, which installs them atomically and restarts
# the container if it is running.
send_to_vm() {
    vm_ssh --command='sudo /opt/gemma/bin/write-api-key.sh'
}

cmd="${1:-}"
case "$cmd" in
create)
    if exists "${GCLOUD[@]}" secrets describe "$SECRET_NAME"; then
        info "Secret ${SECRET_NAME} already exists; nothing to do."
        exit 0
    fi
    log "Creating secret ${SECRET_NAME} (replicated in ${REGION} only)"
    new_key | "${GCLOUD[@]}" secrets create "$SECRET_NAME" \
        --replication-policy=user-managed --locations="$REGION" \
        --labels=app=gemma-e2b --data-file=-
    info "created with version 1 (value not shown)"
    ;;
push-to-vm)
    log "Copying latest ${SECRET_NAME} to ${VM_NAME}"
    access latest | send_to_vm
    ;;
rotate)
    old="$(latest_version)"
    [[ -n "$old" ]] || die "No enabled version of ${SECRET_NAME}."
    log "Adding a new version of ${SECRET_NAME} (current: ${old})"
    new_key | "${GCLOUD[@]}" secrets versions add "$SECRET_NAME" --data-file=-
    new="$(latest_version)"
    log "VM now accepts versions ${old} and ${new}"
    { access "$new"; printf '\n'; access "$old"; printf '\n'; } | send_to_vm
    echo "${old}" > "${REPO_ROOT}/gcp/.rotation-old-version"
    log "Next: gcp/configure-cloud-run.sh (picks up version ${new}), then: gcp/manage-api-key.sh finish-rotation"
    ;;
finish-rotation)
    old_file="${REPO_ROOT}/gcp/.rotation-old-version"
    [[ -f "$old_file" ]] || die "No rotation in progress (${old_file} missing)."
    old="$(cat "$old_file")"
    log "VM accepts only the latest version from now on"
    access latest | send_to_vm
    if confirm "Disable old secret version ${old}? (Cloud Run must already run a revision using the new key)"; then
        "${GCLOUD[@]}" secrets versions disable "$old" --secret="$SECRET_NAME"
        info "version ${old} disabled (destroy it later with: gcloud secrets versions destroy ${old} --secret=${SECRET_NAME})"
    fi
    rm -f "$old_file"
    ;;
*)
    sed -n '2,17p' "$0"
    exit 1
    ;;
esac
