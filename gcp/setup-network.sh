#!/usr/bin/env bash
# One-time foundation for the deployment. Safe to re-run: existing resources are checked,
# not recreated.
#
#   1. Enables the required APIs.
#   2. Creates (or verifies) a custom-mode VPC and two subnets:
#        VM_SUBNET   - the Gemma VM
#        RUN_SUBNET  - Cloud Run Direct VPC egress (source of all Cloud Run -> VM traffic)
#      New ranges are checked for overlap with every existing subnet in the VPC first.
#   3. Firewall: TCP 8080 only from RUN_SUBNET_RANGE to VMs tagged VM_TAG; optional
#      SSH only from Google's IAP range. Never 0.0.0.0/0.
#   4. Optional Cloud Router + Cloud NAT for the VM subnet only (outbound apt traffic
#      from a VM with no external IP). Nothing inbound is opened by NAT.
#   5. A private Docker repository in Artifact Registry.
#
# Run from Cloud Shell or a workstation with gcloud: gcp/setup-network.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd python3
require_vars NETWORK VM_SUBNET VM_SUBNET_RANGE RUN_SUBNET RUN_SUBNET_RANGE AR_REPO VM_TAG

log "Project ${PROJECT_ID}, region ${REGION}"

# --- 1. APIs ------------------------------------------------------------------------
apis=(compute.googleapis.com artifactregistry.googleapis.com run.googleapis.com
      secretmanager.googleapis.com iam.googleapis.com iap.googleapis.com)
[[ "${ENABLE_AR_SCANNING:-true}" == "true" ]] && apis+=(containerscanning.googleapis.com)
log "Enabling APIs: ${apis[*]}"
"${GCLOUD[@]}" services enable "${apis[@]}"

# --- 2. VPC and subnets -------------------------------------------------------------
log "VPC ${NETWORK}"
if exists "${GCLOUD[@]}" compute networks describe "$NETWORK"; then
    mode="$("${GCLOUD[@]}" compute networks describe "$NETWORK" --format='value(x_gcloud_subnet_mode)')"
    info "exists (subnet mode: ${mode})"
else
    "${GCLOUD[@]}" compute networks create "$NETWORK" --subnet-mode=custom
    info "created (custom mode)"
fi

# Every primary and secondary range already in the VPC, any region.
existing_ranges() {
    "${GCLOUD[@]}" compute networks subnets list \
        --filter="network~/networks/${NETWORK}\$" \
        --format='value[delimiter=" "](name,region.basename(),ipCidrRange,secondaryIpRanges[].ipCidrRange.list())' \
    | tr ',;' '  '
}

ensure_subnet() {
    local name="$1" range="$2" current
    if exists "${GCLOUD[@]}" compute networks subnets describe "$name" --region="$REGION"; then
        current="$("${GCLOUD[@]}" compute networks subnets describe "$name" --region="$REGION" --format='value(ipCidrRange)')"
        [[ "$current" == "$range" ]] || die "Subnet ${name} exists with range ${current}, env.sh says ${range}. Fix env.sh."
        info "${name} exists (${current})"
        return
    fi
    # Refuse to create a subnet that overlaps anything already in the VPC.
    existing_ranges | python3 -c '
import ipaddress, sys
new = ipaddress.ip_network(sys.argv[1])
clashes = []
for line in sys.stdin:
    parts = line.split()
    if len(parts) < 3:
        continue
    name, region, *ranges = parts
    for r in ranges:
        if new.overlaps(ipaddress.ip_network(r)):
            clashes.append(f"{name} ({region}) {r}")
if clashes:
    sys.exit("ERROR: " + sys.argv[1] + " overlaps: " + ", ".join(clashes))
' "$range"
    "${GCLOUD[@]}" compute networks subnets create "$name" --network="$NETWORK" \
        --region="$REGION" --range="$range" --enable-private-ip-google-access
    info "${name} created (${range}, Private Google Access on)"
}

[[ "$VM_SUBNET_RANGE" != "$RUN_SUBNET_RANGE" ]] || die "VM_SUBNET_RANGE and RUN_SUBNET_RANGE must differ."
python3 -c 'import ipaddress,sys; a,b=map(ipaddress.ip_network,sys.argv[1:]); sys.exit("ERROR: VM and Run subnet ranges overlap" if a.overlaps(b) else 0)' \
    "$VM_SUBNET_RANGE" "$RUN_SUBNET_RANGE"
log "Subnets"
ensure_subnet "$VM_SUBNET" "$VM_SUBNET_RANGE"
ensure_subnet "$RUN_SUBNET" "$RUN_SUBNET_RANGE"
info "Peered networks and on-prem routes are NOT checked; confirm those ranges by hand."

# --- 3. Firewall --------------------------------------------------------------------
log "Firewall"
if exists "${GCLOUD[@]}" compute firewall-rules describe "$FW_ALLOW_8080"; then
    src="$("${GCLOUD[@]}" compute firewall-rules describe "$FW_ALLOW_8080" --format='value(sourceRanges.list())')"
    [[ "$src" == "$RUN_SUBNET_RANGE" ]] || die "Rule ${FW_ALLOW_8080} has source ranges '${src}', expected '${RUN_SUBNET_RANGE}'. Fix or delete it."
    info "${FW_ALLOW_8080} exists (from ${src})"
else
    "${GCLOUD[@]}" compute firewall-rules create "$FW_ALLOW_8080" --network="$NETWORK" \
        --direction=INGRESS --action=ALLOW --rules=tcp:8080 \
        --source-ranges="$RUN_SUBNET_RANGE" --target-tags="$VM_TAG" --priority=1000 \
        --description="Gemma llama-server: only Cloud Run Direct VPC egress subnet may reach TCP 8080"
    info "${FW_ALLOW_8080} created (tcp:8080 from ${RUN_SUBNET_RANGE} to tag ${VM_TAG})"
fi

if [[ "${ENABLE_IAP_SSH:-true}" == "true" ]]; then
    if exists "${GCLOUD[@]}" compute firewall-rules describe "$FW_ALLOW_IAP_SSH"; then
        info "${FW_ALLOW_IAP_SSH} exists"
    else
        "${GCLOUD[@]}" compute firewall-rules create "$FW_ALLOW_IAP_SSH" --network="$NETWORK" \
            --direction=INGRESS --action=ALLOW --rules=tcp:22 \
            --source-ranges="$IAP_RANGE" --target-tags="$VM_TAG" --priority=1000 \
            --description="Admin SSH to the Gemma VM through IAP TCP forwarding only"
        info "${FW_ALLOW_IAP_SSH} created (tcp:22 from IAP ${IAP_RANGE})"
    fi
fi

# Warn about any OTHER rule in this VPC that opens ingress to the world.
open_rules="$("${GCLOUD[@]}" compute firewall-rules list \
    --filter="network~/networks/${NETWORK}\$ AND direction=INGRESS AND sourceRanges:0.0.0.0/0 AND disabled=false" \
    --format='value(name)')"
[[ -z "$open_rules" ]] || warn "These rules allow ingress from 0.0.0.0/0 in ${NETWORK}; review them: ${open_rules//$'\n'/, }"

# --- 4. Cloud NAT (VM subnet only) ------------------------------------------------------
if [[ "${CREATE_NAT:-true}" == "true" ]]; then
    log "Cloud NAT for ${VM_SUBNET}"
    exists "${GCLOUD[@]}" compute routers describe "$ROUTER_NAME" --region="$REGION" \
        || "${GCLOUD[@]}" compute routers create "$ROUTER_NAME" --network="$NETWORK" --region="$REGION"
    if exists "${GCLOUD[@]}" compute routers nats describe "$NAT_NAME" --router="$ROUTER_NAME" --region="$REGION"; then
        info "${NAT_NAME} exists"
    else
        "${GCLOUD[@]}" compute routers nats create "$NAT_NAME" --router="$ROUTER_NAME" --region="$REGION" \
            --nat-custom-subnet-ip-ranges="$VM_SUBNET" --auto-allocate-nat-external-ips
        info "${NAT_NAME} created (outbound only, ${VM_SUBNET} only)"
    fi
else
    info "CREATE_NAT=false: the VM cannot reach apt mirrors. Docker must be installed from a custom image."
fi

# --- 5. Artifact Registry -------------------------------------------------------------
log "Artifact Registry ${AR_REPO} (${REGION})"
if exists "${GCLOUD[@]}" artifacts repositories describe "$AR_REPO" --location="$REGION"; then
    info "exists"
else
    "${GCLOUD[@]}" artifacts repositories create "$AR_REPO" --repository-format=docker \
        --location="$REGION" --description="Private images for the Gemma inference server"
    info "created (private by default)"
fi

log "Done. Next: gcp/manage-api-key.sh create, then scripts/build-image.sh --push"
