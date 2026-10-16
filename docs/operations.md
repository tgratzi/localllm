# Operations

Where each command runs is marked: **[VM]** = on the VM after
`gcloud compute ssh gemma-e2b-vm --zone=ZONE --tunnel-through-iap`;
**[Cloud Shell]** = Cloud Shell or any workstation with `gcloud` and this repo.

## Day-to-day checks

```bash
# [Cloud Shell] one-shot summary: container, health, CPU/memory, image digest, free RAM
scripts/deploy-vm.sh --status

# [VM]
sudo docker ps                                    # running? "(healthy)"?
sudo docker logs --tail 100 -f gemma-gemma-1      # server log (no prompts at default verbosity)
sudo docker inspect -f '{{.State.Health.Status}} restarts={{.RestartCount}}' gemma-gemma-1
sudo docker inspect -f '{{json .State.Health.Log}}' gemma-gemma-1   # last health-check results
sudo docker stats gemma-gemma-1                   # live CPU / memory
free -h; vmstat 5                                 # host memory pressure (watch si/so = swap)
```

The container log uses Docker's `json-file` driver, capped at 5 × 10 MB.

## Testing the model after a deploy

Always test along the real path, from inside the VPC:

```bash
# [Cloud Shell] runs a Cloud Run job on the Cloud Run egress subnet
gcp/verify-private-path.sh
```

Quick check on the VM itself (the key stays out of the command line):

```bash
# [VM]
IP=$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
curl -s "http://$IP:8080/health"
(umask 077; sudo sh -c 'printf "Authorization: Bearer %s\n" "$(head -n1 /etc/gemma/api_key)"' > /tmp/h)
curl -s "http://$IP:8080/v1/chat/completions" -H @/tmp/h -H 'Content-Type: application/json' \
  -d '{"model":"gemma","messages":[{"role":"user","content":"Say hi"}],"max_tokens":32}'
rm -f /tmp/h
```

## Restarting

```bash
# [VM]
sudo docker compose --project-directory /opt/gemma restart          # same container
sudo docker compose --project-directory /opt/gemma up -d --force-recreate --wait   # fresh container
```

After a VM reboot Docker starts at boot and `restart: unless-stopped` brings the
container back. To prove it: `sudo reboot`, wait a minute, then `scripts/deploy-vm.sh --status`.

## Upgrading the model or llama.cpp

The weights are inside the image, so **every change to the model or to llama.cpp is a new
image**. Nothing on the VM downloads models.

1. Edit the pins in `Dockerfile`:
   - llama.cpp: `LLAMA_CPP_IMAGE` (tag **and** digest; see `docs/troubleshooting.md` for how
     to read a digest).
   - model: `MODEL_REPO`, `MODEL_REVISION` (a commit hash), `MODEL_FILE`, `MODEL_SHA256`.
2. `scripts/verify-model-file.sh` must print `OK`.
3. Build and test locally: `scripts/build-image.sh && scripts/test-local.sh`.
4. Push: `scripts/build-image.sh --push` → prints `...@sha256:<digest>`.
5. Check vulnerabilities on that digest (command printed by step 4).
6. Deploy: `scripts/deploy-vm.sh <digest>`. The previous digest is recorded on the VM.
7. Verify: `gcp/verify-private-path.sh`.

The Cloud Run app does not need redeploying for a model upgrade: the URL and key stay the same.
There is a short outage (the time to load the new model, roughly 10–60 s) while the
container is recreated. With one VM there is no way around that; for zero-downtime upgrades
you would need two VMs behind an internal load balancer.

## Rollback

```bash
# [Cloud Shell] back to the digest that ran before the last successful deploy
scripts/deploy-vm.sh --rollback

# or any specific older digest
gcloud artifacts docker images list REGION-docker.pkg.dev/PROJECT/gemma/gemma-e2b-server --include-tags
scripts/deploy-vm.sh REGION-docker.pkg.dev/PROJECT/gemma/gemma-e2b-server@sha256:...
```

## Rotating the API key (no downtime)

`llama-server` accepts several keys at once, so the VM can accept the old and new key while
Cloud Run switches over.

```bash
# [Cloud Shell]
gcp/manage-api-key.sh rotate            # new secret version; VM accepts old + new
gcp/configure-cloud-run.sh              # new revision reads the new version
gcp/verify-private-path.sh              # confirm the new key works
gcp/manage-api-key.sh finish-rotation   # VM accepts only the new key; old version disabled
```

Each VM-side key change recreates the container, a brief pause while the model loads.
If the key leaked, skip the overlap: `gcloud secrets versions add` a new value, run
`gcp/manage-api-key.sh push-to-vm`, then `gcp/configure-cloud-run.sh` immediately.

## Logs in Cloud Logging

```bash
# Cloud Run service
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="gemma-app"' \
  --project=PROJECT --limit=50 --freshness=1h

# VM serial console (boot problems)
gcloud compute instances get-serial-port-output gemma-e2b-vm --zone=ZONE --project=PROJECT | tail -50
```

Container logs reach Cloud Logging only if the Ops Agent is installed. That needs extra
roles, so it is off by default: set `INSTALL_OPS_AGENT=true` in `gcp/env.sh`, re-run
`gcp/create-vm.sh`, then on the VM follow Google's Ops Agent install instructions and
enable its Docker/journald log receiver.

## Monitoring

| Signal | Where | Alert when |
| --- | --- | --- |
| VM CPU utilization | Cloud Monitoring, `compute.googleapis.com/instance/cpu/utilization` (no agent needed) | Sustained > 90% (requests are queuing) |
| VM memory used | Ops Agent `agent.googleapis.com/memory/percent_used` (needs agent) | > 90% |
| Container restarts | `docker inspect ... RestartCount`; with Ops Agent, a log-based metric on "gemma-entrypoint: ERROR" | Any increase |
| Health | Uptime checks can't reach a private IP; run `gcp/verify-private-path.sh` on a schedule (Cloud Scheduler → Cloud Run job) | Job failure |
| Latency / errors | Cloud Run request metrics for your app (`run.googleapis.com/request_latencies`, 5xx count) | p95 above your SLO |
| Server internals | `GET /metrics` (Prometheus format) needs the API key; enable with `LLAMA_ARG_ENDPOINT_METRICS=1` if you scrape it | — |

## Costs

No prices are listed here because they change by region and over time. Estimate with the
[Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator) using:

| Item | What to enter |
| --- | --- |
| Compute Engine | `e2-standard-4`, 730 h/month, your region (sustained-use or committed-use discounts may apply) |
| Persistent disk | `pd-balanced`, 50 GB |
| Artifact Registry | ~5 GB per stored image version × versions kept (delete old ones) |
| Artifact Analysis | per image scanned on push (if `ENABLE_AR_SCANNING=true`) |
| Cloud NAT | 1 gateway-hour × 730 + GB processed (small: apt traffic only). Delete NAT after setup if you can live without apt updates. |
| Networking | Cloud Run → VM in the same region on internal IPs; check current intra-region pricing |
| Cloud Run | your app's vCPU-seconds, memory, requests |
| Secret Manager | active versions + access operations (tiny) |

Set a budget alert so surprises are caught early:

```bash
gcloud billing budgets create --billing-account=BILLING_ACCOUNT_ID \
  --display-name="gemma-e2b monthly" --budget-amount=200USD \
  --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0
```

(The amount is a placeholder; pick yours. Budgets alert, they don't stop spending.)

## Cleaning old images

On the VM, images pulled by digest have no tag. The deploy keeps the current and previous
ones for rollback. To reclaim disk when it fills:

```bash
# [VM] remove everything not used by a container (also removes the rollback image)
sudo docker image prune -a
```

In Artifact Registry, delete old digests with `gcloud artifacts docker images delete`, or
configure a cleanup policy on the repository.
