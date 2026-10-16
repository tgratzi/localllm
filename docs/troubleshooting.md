# Troubleshooting

## Build

**`ERROR: could not download ... The file name or revision may be wrong`**
Hugging Face returned an error for the pinned URL. Run `scripts/verify-model-file.sh`; it
lists every GGUF file at the pinned revision. If the repo moved, look up the new commit hash
on the repo's "Files and versions" page and update `MODEL_REVISION` and `MODEL_SHA256`.

**`SHA-256 mismatch`**
The download is corrupt or the pin is wrong. Don't remove the check. Re-run the build; if it
persists, compare `MODEL_SHA256` with the value `scripts/verify-model-file.sh` prints.

**Build runs out of disk.** The model stage holds ~5 GB and the final image another ~5 GB.
Free Docker space (`docker system df`, `docker builder prune`) or use `gcp/cloudbuild.yaml`.

**Finding a llama.cpp image digest for an upgrade.**

```bash
docker buildx imagetools inspect ghcr.io/ggml-org/llama.cpp:server-bNNNNN | head -3
```

Not every release `bNNNNN` has a `server-bNNNNN` image; pick one that exists. Prefer a
release at least two weeks old, and check its source supports `gemma4`
(`src/llama-arch.cpp` lists `LLM_ARCH_GEMMA4`).

**`/bin/sh^M: bad interpreter` or `exec format error` from the entrypoint.**
The script was checked out with Windows line endings. `.gitattributes` forces LF; after
cloning on Windows run `git add --renormalize .` and rebuild.

## Container start

**`gemma-entrypoint: ERROR: API key file ... is not readable by UID 10001`**
The key file must be readable by GID 10001 (VM) or world-readable (local test). On the VM
re-run `gcp/manage-api-key.sh push-to-vm`, which sets `root:10001 0440`.

**`unknown model architecture: 'gemma4'`** The llama.cpp image is too old for Gemma 4. Use
a newer pinned `LLAMA_CPP_IMAGE`.

**Exits with code 137 / `OOMKilled: true` in `docker inspect`.**
Out of memory. Lower `GEMMA_CTX_SIZE` or `GEMMA_PARALLEL`, raise `GEMMA_MEM_LIMIT` (keep it
below VM RAM), use the smaller `gemma-4-E2B-it-Q4_0.gguf` (2.84 GB), or a bigger machine
type.

**Health stays `starting` for minutes.** The model is memory-mapped from the image layer;
the first read after a fresh pull is slow on small disks. `pd-balanced` or `pd-ssd` helps.
The health check allows 180 s before counting failures.

**Port bind error on the VM (`cannot assign requested address`).** Docker started before the
VM's internal IP was configured. Restart with
`sudo docker compose --project-directory /opt/gemma up -d`. If it happens on every boot, add
a systemd drop-in so `docker.service` waits for `network-online.target`.

## Requests

**`401 Unauthorized`** Missing or wrong `Authorization: Bearer <key>`. Cloud Run reads the
secret when an instance starts, so after a rotation redeploy (`gcp/configure-cloud-run.sh`).

**Empty `content` but tokens used.** Reasoning is on and the token budget went into the
`reasoning_content` field. Keep `GEMMA_REASONING=off` or raise `max_tokens`.

**Slow responses.** CPU inference is much slower than GPU, and long prompts slow it further
because the whole prompt is processed before the first token. Try `GEMMA_THREADS=2` (E2 vCPUs are hyperthreads), keep
`GEMMA_PARALLEL=1`, keep prompts short, or move to a compute-optimized machine type (C3/C4).
Measure: `"timings"` in each llama-server response shows prompt and generation speed.

**Requests queue / time out under load.** One slot means one request at a time. Raise
`GEMMA_PARALLEL` (each slot gets `GEMMA_CTX_SIZE / GEMMA_PARALLEL` tokens), lower Cloud Run
`RUN_CONCURRENCY`, and keep client timeouts above `GEMMA_TIMEOUT_SECONDS`.

## Networking

**Cloud Run → VM times out.** Check in order:

1. Cloud Run uses Direct VPC egress on the right subnet:
   `gcloud run services describe gemma-app --region=REGION --format='yaml(spec.template.metadata.annotations)'`
   should show `run.googleapis.com/network-interfaces` with `gemma-vpc` / `gemma-run-egress-subnet`.
2. Firewall source range equals the Cloud Run subnet range and the VM has tag `gemma-llm`
   (`gcloud compute instances describe gemma-e2b-vm --format='value(tags.items)'`).
3. The container listens on the VM's internal IP:
   `[VM] sudo ss -ltnp | grep 8080`.
4. `GEMMA_BASE_URL` points to the current VM IP. A recreated VM may get a new IP; reserve a
   static internal IP if that matters
   (`gcloud compute addresses create ... --subnet=gemma-vm-subnet`).

**`gcloud compute ssh` hangs or is refused.** The IAP SSH firewall rule must exist, and your
user needs `roles/iap.tunnelResourceAccessor` plus `roles/compute.osAdminLogin` (or
`osLogin`). On Windows, run the scripts from Cloud Shell or WSL; Git Bash works for local
Docker tests but not reliably for `gcloud compute ssh` with piped input.

**`apt-get` fails on the VM.** No internet path: Cloud NAT is missing (`CREATE_NAT=false`) or
was deleted. Re-run `gcp/setup-network.sh` with `CREATE_NAT=true`.

**`docker pull` fails with `denied` on the VM.** The VM's service account lacks
`roles/artifactregistry.reader` on the repo, or the VM was created with a different
service account. Re-run `gcp/create-vm.sh` (it re-applies the binding).

**Anonymous call to the Cloud Run URL returns 200.** Ingress or IAM is wrong. Re-run
`gcp/configure-cloud-run.sh`; it fails if a public binding exists.
