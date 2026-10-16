# gemma4-e2b-gguf-gcp

A private Gemma 4 E2B chat model for a Cloud Run application, on one CPU-only Compute Engine VM.

**The problem:** an app on Cloud Run needs an LLM it can call without sending data to a
third-party API, and without exposing the model to the internet.

**The solution:** a Docker image that contains both the `llama.cpp` server and the model
weights, running on a VM that has no public IP. Cloud Run reaches it over the VPC, and the
server requires an API key.

- Model: [`ggml-org/gemma-4-E2B-it-GGUF`](https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF),
  file `gemma-4-E2B-it-Q8_0.gguf` (instruction-tuned, 8-bit, 4.97 GB), pinned to a commit and
  checked against its SHA-256.
- Server: `llama-server` from `ghcr.io/ggml-org/llama.cpp:server-b11277`, pinned by digest.
  API: OpenAI-compatible `/v1/chat/completions`.
- Design, security decisions and their limits: [docs/architecture.md](docs/architecture.md).
  The original brief is in [docs/gemma4-e2b-gguf-gcp-implementation-brief.md](docs/gemma4-e2b-gguf-gcp-implementation-brief.md).

> **Read this before production:** the Cloud Run → VM hop is plain HTTP inside the VPC.
> It is private but not encrypted. If your policy requires encryption on that hop, see the
> HTTPS section in [docs/architecture.md](docs/architecture.md); it is not implemented here.

## Layout

```text
Dockerfile, compose.yaml, .env.example   the image and how to run it
docker/entrypoint.sh                     refuses to start without an API key, then execs llama-server
scripts/                                 build, local test, deploy (run locally / Cloud Shell)
scripts/vm/                              helpers copied to and run on the VM
gcp/                                     network, VM, secret, Cloud Run, verification, cleanup
charts/localllm/                         Helm chart for Kubernetes / TOS
scripts/build-tupack.sh                  packages chart + image as a TOS app .tar (tupack)
.github/workflows/release-tupack.yml     builds that .tar on each v* tag, publishes a GitHub Release
docs/                                    architecture, operations, troubleshooting, kubernetes
```

## Run on Kubernetes (TOS)

The same image also ships as a TOS app: one `.tar` built by `tupack` that holds the Helm chart
and the image. Push a `v*` tag and the workflow attaches it to a GitHub Release, split into
parts under GitHub's 2 GiB file limit. On the TOS node:

```bash
cat localllm-1.0.0.tar.part-* > localllm-1.0.0.tar && sha256sum -c localllm-1.0.0.tar.sha256
tos apps install localllm-1.0.0.tar
```

Other pods then call `http://localllm:8080/v1` with the key from Secret `localllm-api-key`.
Nothing is exposed outside the cluster. Details, caller example and limits:
[docs/kubernetes.md](docs/kubernetes.md). Step-by-step manual build:
[docs/build-tos-package.html](docs/build-tos-package.html).

## Where commands run

| Marker | Where | Needs |
| --- | --- | --- |
| **[Local]** | Your workstation | Docker with buildx, curl, python3, ~15 GB free disk |
| **[Cloud Shell]** | Cloud Shell, or a Linux/macOS/WSL workstation | `gcloud` logged in, this repo checked out |
| **[VM]** | The Gemma VM via `gcloud compute ssh gemma-e2b-vm --zone=ZONE --tunnel-through-iap` | IAP + OS Login permissions |
| **[App]** | Your Cloud Run application's code | — |

## 1. Build and test locally [Local]

```bash
scripts/verify-model-file.sh       # checks the pinned file exists and its SHA-256 matches
scripts/build-image.sh             # builds gemma-e2b-server:local (~5 GB download)
scripts/test-local.sh              # loopback-only run, 401 check, chat request, offline check
```

`test-local.sh` generates a random key, starts the container on `127.0.0.1:8080`, checks
that a request without the key is refused, sends a chat request, shows CPU and memory, and
then starts the image again with **no network** to prove the weights are inside it. It
cleans up afterwards; add `--keep` to leave it running.

To run it by hand instead:

```bash
mkdir -p secrets && chmod 700 secrets
python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")' > secrets/api_key   # never echo it
chmod 644 secrets/api_key                       # container runs as UID 10001
cp .env.example .env                            # GEMMA_BIND_ADDRESS=127.0.0.1 stays loopback
docker compose up -d
docker compose ps                               # wait for "(healthy)"
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer $(cat secrets/api_key)" -H 'Content-Type: application/json' \
  -d '{"model":"gemma","messages":[{"role":"user","content":"Reply with: private connection works"}],"max_tokens":64}'
docker compose logs --tail 50
docker stats --no-stream
docker compose down
```

(The `$(cat ...)` puts the key in your shell's process list for a moment; fine on a laptop,
which is why the scripts use header files instead.)

## 2. Deploy to Google Cloud [Cloud Shell]

```bash
cp gcp/env.sh.example gcp/env.sh       # set PROJECT_ID, REGION, ZONE, RUN_IMAGE, RUN_INVOKERS
gcp/setup-network.sh                   # APIs, VPC, 2 subnets (overlap-checked), firewall, NAT, Artifact Registry
gcp/manage-api-key.sh create           # random key straight into Secret Manager
scripts/build-image.sh --push          # push with SBOM + provenance; prints IMAGE@sha256:DIGEST
gcp/create-vm.sh                       # VM with no external IP; SA can only pull from the repo
scripts/deploy-vm.sh IMAGE@sha256:DIGEST   # install Docker, copy the key over IAP, start, wait healthy
gcp/configure-cloud-run.sh             # your app: Direct VPC egress, internal ingress, IAM-only
gcp/verify-private-path.sh             # checks from inside the VPC + negative checks
```

Building on a laptop uploads ~5 GB. To build inside Google Cloud instead:
`gcloud builds submit --config gcp/cloudbuild.yaml --substitutions=_REGION=...,_TAG=... .`
then deploy the digest it prints.

What each script creates, and why, is in the comment block at the top of the script.
Firewall rules are explained in [gcp/firewall.md](gcp/firewall.md).

## 3. Call the model from your app [App]

`gcp/configure-cloud-run.sh` sets two environment variables on the service. The names are
examples: change them in the script to whatever your code reads.

- `GEMMA_BASE_URL=http://<VM_INTERNAL_IP>:8080/v1`
- `GEMMA_API_KEY` from Secret Manager secret `gemma-api-key`

```bash
curl "${GEMMA_BASE_URL}/chat/completions" \
  -H "Authorization: Bearer ${GEMMA_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma","messages":[{"role":"user","content":"Reply with: private connection works"}],"max_tokens":64}'
```

Any OpenAI-compatible client works, for example in Python:

```python
from openai import OpenAI
client = OpenAI(base_url=os.environ["GEMMA_BASE_URL"], api_key=os.environ["GEMMA_API_KEY"])
reply = client.chat.completions.create(model="gemma", messages=[{"role": "user", "content": "Hi"}], max_tokens=64)
```

Rules for the app:

- Never send `GEMMA_API_KEY` to a browser or mobile client.
- Authenticate your own callers (Cloud Run IAM is on; `roles/run.invoker` only for `RUN_INVOKERS`).
- Don't log the `Authorization` header or sensitive prompts.
- Limit request body size and prompt length before forwarding.

## 4. Operate

[docs/operations.md](docs/operations.md): status, logs, restart, upgrade, rollback, key
rotation, monitoring, costs, budget alerts. [docs/troubleshooting.md](docs/troubleshooting.md):
common failures.

**Changing the model or llama.cpp version means building and publishing a new image.**
The VM never downloads weights.

## Rollback and cleanup [Cloud Shell]

```bash
scripts/deploy-vm.sh --rollback   # previous image digest on the VM
gcp/cleanup.sh                    # VM, Cloud Run, firewall, NAT (asks before each group)
gcp/cleanup.sh --all              # also secret, registry + images, subnets, VPC, service accounts
```

Both cleanup modes are destructive and irreversible; the script asks you to type the
project ID first.

## Assumptions and manual steps

- Org policy accepts unencrypted HTTP inside the VPC (see the warning above).
- The default ranges `10.80.0.0/24` and `10.80.16.0/26` don't clash with peered or on-prem
  networks. The scripts check only subnets in the Gemma VPC.
- Ubuntu's `docker.io` and `docker-compose-v2` packages are used on the VM (simpler than
  adding Docker's apt repo). They lag upstream Docker slightly.
- Cloud NAT is created so the VM can reach the Ubuntu archive. It is outbound only. If you
  delete it after setup, apt updates stop working.
- Your user needs IAM to run the scripts (roughly: Compute Admin, Network Admin, Security
  Admin, Artifact Registry Admin, Secret Manager Admin, Cloud Run Admin, Service Account
  Admin/User, IAP-secured Tunnel User). Granting these is not automated.
- Performance is not measured here. Check tokens/second and memory on the real VM before
  sizing for production.
- Monitoring the container's memory and logs from Cloud Monitoring needs the Ops Agent,
  which needs extra roles (`INSTALL_OPS_AGENT=true`). Off by default.

## Acceptance checklist

| Requirement | How it is checked |
| --- | --- |
| Clean build has server + weights | `scripts/build-image.sh` (SHA-256 checked inside the build) |
| No runtime download | `scripts/test-local.sh` offline step (`--network none`); entrypoint passes `--offline` |
| Local authenticated chat works | `scripts/test-local.sh` |
| Restarts after VM reboot | Docker enabled at boot + `restart: unless-stopped`; `sudo reboot` then `scripts/deploy-vm.sh --status` |
| VM has no external IP | `gcp/create-vm.sh` and `gcp/verify-private-path.sh` step 1 |
| 8080 not public | No external IP + `gcp/verify-private-path.sh` step 2 |
| Cloud Run reaches the model privately | `gcp/verify-private-path.sh` step 3 |
| Unauthorized callers rejected | `gcp/verify-private-path.sh` step 4 |
| No secrets in Git / image / build args / logs | `.gitignore`, `.dockerignore` (only the entrypoint is in the build context), key passed only by file and stdin |
| Reproducible docs | This README + `docs/` |
