#!/usr/bin/env bash
# Proves the deployment matches the security design, from the places that matter:
#
#   1. The VM has no external IP.
#   2. No enabled firewall rule in the VPC lets 0.0.0.0/0 reach TCP 8080.
#   3. From INSIDE the VPC path Cloud Run uses (a Cloud Run job on the same subnet, with
#      the same service account and secret as the app):
#        /health answers, a request without the key gets 401, and an authenticated
#        chat completion returns text.
#   4. The Cloud Run service rejects a caller with no identity token.
#
# Testing from a laptop proves nothing about the VPC path, which is why step 3 runs as
# a Cloud Run job. The job is created on first run and reused afterwards.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd python3 curl
require_vars VM_NAME NETWORK RUN_SUBNET SECRET_NAME RUN_SERVICE

# Small public image with curl, pinned by digest (curl 8.22.0).
CHECK_IMAGE="docker.io/curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"
CHECK_JOB="${RUN_SERVICE}-vpc-check"
failures=0
pass() { info "PASS  $*"; }
fail() { info "FAIL  $*"; failures=$((failures + 1)); }

log "1. VM external IP"
nat_ip="$("${GCLOUD[@]}" compute instances describe "$VM_NAME" --zone="$ZONE" \
    --format='value(networkInterfaces[].accessConfigs[].natIP.list())')"
if [[ -z "$nat_ip" ]]; then pass "no external IP"; else fail "external IP ${nat_ip}"; fi

log "2. Firewall: TCP 8080 not open to 0.0.0.0/0"
"${GCLOUD[@]}" compute firewall-rules list --filter="network~/networks/${NETWORK}\$ AND direction=INGRESS AND disabled=false" \
    --format=json > "${TMPDIR:-/tmp}/gemma-fw.json"
if python3 - "${TMPDIR:-/tmp}/gemma-fw.json" <<'PY'
import json, sys
bad = []
for r in json.load(open(sys.argv[1])):
    if "0.0.0.0/0" not in r.get("sourceRanges", []):
        continue
    for a in r.get("allowed", []):
        proto = a.get("IPProtocol")
        if proto not in ("tcp", "all"):
            continue
        ports = a.get("ports")
        if proto == "all" or not ports:
            bad.append(r["name"]); continue
        for p in ports:
            lo, _, hi = p.partition("-")
            if int(lo) <= 8080 <= int(hi or lo):
                bad.append(r["name"])
if bad:
    print("    rules opening 8080 to the internet: " + ", ".join(sorted(set(bad))))
    sys.exit(1)
PY
then pass "no rule opens 8080 to 0.0.0.0/0"; else fail "see rules above"; fi
rm -f "${TMPDIR:-/tmp}/gemma-fw.json"

log "3. Private path from a Cloud Run job on ${RUN_SUBNET}"
vm_ip="$(vm_internal_ip)"
# Runs inside the job, so its variables must NOT expand here.
# No '@' in the script: it is the list delimiter for --args below.
# shellcheck disable=SC2016
check_script='set -eu
base="http://${GEMMA_VM_IP}:8080"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$base/health")
echo "health: HTTP $code"; [ "$code" = 200 ]
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$base/v1/models")
echo "no key: HTTP $code"; [ "$code" = 401 ]
out=$(curl -sS --fail-with-body --max-time 120 "$base/v1/chat/completions" -H "Authorization: Bearer $GEMMA_API_KEY" -H "Content-Type: application/json" -d "{\"model\":\"gemma\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with: private connection works\"}],\"max_tokens\":32}")
echo "$out" | grep -q "\"content\"" && echo "chat: OK" '
"${GCLOUD[@]}" run jobs deploy "$CHECK_JOB" \
    --region="$REGION" \
    --image="$CHECK_IMAGE" \
    --service-account="$RUN_SA_EMAIL" \
    --network="$NETWORK" --subnet="$RUN_SUBNET" --vpc-egress=private-ranges-only \
    --set-env-vars="GEMMA_VM_IP=${vm_ip}" \
    --set-secrets="GEMMA_API_KEY=${SECRET_NAME}:latest" \
    --command=sh --args="^@^-c@${check_script}" \
    --max-retries=0 --task-timeout=300s >/dev/null
if "${GCLOUD[@]}" run jobs execute "$CHECK_JOB" --region="$REGION" --wait >/dev/null; then
    pass "health 200, no-key 401, chat completion OK over the VPC"
else
    fail "job failed; read its output with:"
    info "  gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name=${CHECK_JOB}' --project=${PROJECT_ID} --limit=20 --format='value(textPayload)'"
fi

log "4. Cloud Run service rejects anonymous callers"
url="$("${GCLOUD[@]}" run services describe "$RUN_SERVICE" --region="$REGION" --format='value(status.url)' 2>/dev/null || true)"
if [[ -z "$url" ]]; then
    fail "service ${RUN_SERVICE} not found (run gcp/configure-cloud-run.sh)"
else
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" || true)"
    if [[ "$code" =~ ^(401|403|404)$ ]]; then
        pass "anonymous request from here: HTTP ${code} (internal ingress + IAM)"
    else
        fail "anonymous request returned HTTP ${code}"
    fi
fi

echo
if (( failures == 0 )); then
    echo "All checks passed."
else
    echo "${failures} check(s) failed."
    exit 1
fi
