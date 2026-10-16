# Firewall rules

The Gemma VM has no external IP, so nothing on the internet can route to it. The firewall
rules below decide which **internal** sources may reach it. `gcp/setup-network.sh` creates
them; this page explains them so a reviewer can check them by hand.

| Rule (default name) | Direction | Source | Target | Ports | Why |
| --- | --- | --- | --- | --- | --- |
| `gemma-vpc-allow-gemma-8080-from-run` | Ingress | `RUN_SUBNET_RANGE` (default `10.80.16.0/26`) | network tag `gemma-llm` | `tcp:8080` | Only Cloud Run instances using Direct VPC egress get addresses in this subnet, so only they can call the model API. |
| `gemma-vpc-allow-iap-ssh-gemma` (optional) | Ingress | `35.235.240.0/20` (Google IAP TCP forwarding) | network tag `gemma-llm` | `tcp:22` | Admin SSH through `gcloud compute ssh --tunnel-through-iap`. Who may tunnel is controlled by IAM (`roles/iap.tunnelResourceAccessor`), not by IP. |

Everything else inbound is denied by the VPC's implied deny-ingress rule.

## What is deliberately absent

- **No rule with source `0.0.0.0/0`** for port 8080, or for anything targeting `gemma-llm`.
  `gcp/verify-private-path.sh` fails if one appears.
- **No rule from the VM subnet to itself on 8080.** Other VMs in the VM subnet cannot call
  the model. If a diagnostic VM must, add a temporary, narrowly scoped rule and delete it after.
- **No egress restrictions.** The VM needs outbound HTTPS to Artifact Registry (through
  Private Google Access) and to the Ubuntu archive (through Cloud NAT) for installs.
  If policy requires, add egress deny rules with allow-listed destinations, and install
  Docker from a custom image so Cloud NAT can be removed.

## Checking by hand

```bash
gcloud compute firewall-rules list --project=PROJECT_ID \
  --filter="network~/networks/gemma-vpc$" \
  --format="table(name,direction,sourceRanges.list(),targetTags.list(),allowed.list(),disabled)"
```

## Things that bypass these rules

- **Shared VPC / VPC peering:** peered networks can reach the VM if their ranges are added to
  a rule. The 8080 rule names one source range only, so peering alone does not open it.
- **Cloud Run with `all-traffic` egress** still uses the same subnet and is still covered.
- **Docker and the host firewall:** Docker's published ports bypass `ufw`. That does not
  matter here because the GCP firewall is the control, but don't rely on `ufw` on this VM.
