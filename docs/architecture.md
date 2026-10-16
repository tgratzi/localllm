# Architecture

**One sentence:** a private Cloud Run application calls a Gemma 4 E2B model that runs in a
Docker container on a Compute Engine VM with no public IP, over the VPC, with an API key.

## Picture

```text
 Callers (IAM-authenticated, inside the project / VPC)
    │  HTTPS, Google identity token
    ▼
 ┌────────────────────────────┐
 │ Cloud Run: your app        │  ingress=internal, no unauthenticated access
 │  GEMMA_BASE_URL            │  runtime SA: secretAccessor on ONE secret
 │  GEMMA_API_KEY ◄── Secret Manager (gemma-api-key)
 └─────────────┬──────────────┘
               │ Direct VPC egress (private-ranges-only), source IP from RUN_SUBNET
               │ HTTP, "Authorization: Bearer <key>"      ← NOT encrypted on this hop
               ▼
 ┌─────────────────────────────── VPC gemma-vpc ──────────────────────────────┐
 │ firewall: tcp:8080 only from RUN_SUBNET_RANGE → tag gemma-llm              │
 │                                                                            │
 │  VM gemma-e2b-vm (e2-standard-4, Ubuntu 24.04, no external IP)             │
 │   Docker ─ container gemma (UID 10001, read-only FS, no capabilities)      │
 │             llama-server  :8080  /v1/chat/completions                      │
 │             /models/gemma-4-e2b.gguf  (baked into the image)               │
 │   /etc/gemma/api_key (root:10001, 0440)                                    │
 │                                                                            │
 │  outbound only: Private Google Access → Artifact Registry (image pulls)    │
 │                 Cloud NAT → Ubuntu archive (Docker install / updates)      │
 └────────────────────────────────────────────────────────────────────────────┘
```

## Pieces and why each exists

| Piece | Choice | Reason |
| --- | --- | --- |
| Model | `ggml-org/gemma-4-E2B-it-GGUF`, file `gemma-4-E2B-it-Q8_0.gguf` (4.97 GB) | The instruction-tuned ("-it") variant answers chat requests. The sibling repo `ggml-org/gemma-4-E2B-GGUF` is the *base* model, which only continues text; it is the wrong choice for a chat API even though its name is shorter. |
| Model pin | Repo commit `b4243c156154b6dca9324415f8c7ccc098b4aed1` + SHA-256 `996d0877…aa63a` | A branch name like `main` can change; a commit can't. The build checks the downloaded bytes against Hugging Face's published SHA-256. |
| Server | `ghcr.io/ggml-org/llama.cpp:server-b11277@sha256:6d60…de14` | Official CPU build of `llama-server`, Ubuntu 24.04 base, includes the `gemma4` architecture. Pinned by digest so a rebuild gets the same binary. |
| Weights location | Inside the image | The container starts with no network access to Hugging Face, and the deployed artifact is a single immutable digest. Cost: every model or llama.cpp change means a new ~5 GB image. |
| Auth at the model | `--api-key-file` | The key is read from a mounted file, not an environment variable, so it does not appear in `docker inspect`. The entrypoint refuses to start without it, because `llama-server` otherwise runs with no auth at all. |
| Web UI | Disabled (`--no-webui`) | llama-server serves its UI without auth. This is an API-only service. |
| Host | `e2-standard-4` (4 vCPU, 16 GB) | Q8_0 weights are ~5 GB (memory-mapped), plus the KV cache. 16 GB leaves room. Resize after measuring. |
| Network path | Cloud Run Direct VPC egress into a dedicated subnet | The firewall can then name one source range. No Serverless VPC Access connector VMs to run. |
| Admin access | SSH through IAP, OS Login | No public IP and no SSH keys in project metadata. |

## Settings

The container reads `llama-server`'s own environment variables. `compose.yaml` maps short
`GEMMA_*` names onto them; the VM gets its values from `gcp/env.sh`.

| `GEMMA_*` (compose / env.sh) | llama-server variable | Default | Notes |
| --- | --- | --- | --- |
| `GEMMA_CTX_SIZE` | `LLAMA_ARG_CTX_SIZE` | 8192 | Total context, split across parallel slots. More context = more RAM. |
| `GEMMA_THREADS` | `LLAMA_ARG_THREADS` | 4 | Start with the vCPU count; on E2, 4 vCPUs are 2 physical cores, so also try 2. |
| `GEMMA_PARALLEL` | `LLAMA_ARG_N_PARALLEL` | 1 | Requests generated at once. Others queue. |
| `GEMMA_MAX_TOKENS` | `LLAMA_ARG_N_PREDICT` | 1024 | Server-side cap on output tokens per request, whatever the client asks for. |
| `GEMMA_TIMEOUT_SECONDS` | `LLAMA_ARG_TIMEOUT` | 300 | HTTP read/write timeout. |
| `GEMMA_REASONING` | `LLAMA_ARG_REASONING` | off | Gemma's "thinking" output. `on` makes replies slower and spends tokens on reasoning. |
| `GEMMA_MEM_LIMIT` | Docker `mem_limit` | 12g | The container is killed instead of the whole VM if memory runs away. |

Fixed in the image: model path, port 8080, alias `gemma` (the `model` field clients send),
key file path `/run/secrets/llama_api_key`.

## Security decisions and their limits

- **The Cloud Run → VM hop is plain HTTP.** It stays inside Google's network and the VPC,
  but it is not encrypted end to end, and the API key travels in that HTTP header. If your
  security policy requires encryption on this hop, changing `http://` to `https://` is
  *not* enough. You need: an internal Application Load Balancer (or TLS on llama-server via
  `--ssl-key-file` / `--ssl-cert-file`), an internal DNS name, a certificate the app trusts
  (Certificate Manager or a private CA), HTTPS as the backend protocol, and certificate
  validation turned on in the app's HTTP client. That design is not implemented here.
- **The API key is a shared secret.** Anyone who has it and can reach the VM's IP on 8080
  can use the model. The firewall limits "reach" to the Cloud Run egress subnet. Never send
  the key to a browser or mobile app; the Cloud Run app must authenticate its own callers.
- **Least privilege.** The VM's service account can read one Artifact Registry repo and
  nothing else. The Cloud Run service account can read one secret. No service-account keys
  exist anywhere.
- **Logs.** llama-server at default verbosity does not log prompts or headers. Don't add
  `-v`/`--verbose` in production. Make sure your app doesn't log the `Authorization` header
  or full prompts if they may hold sensitive data.
- **Limits.** Output tokens are capped server-side (`GEMMA_MAX_TOKENS`), requests time out
  (`GEMMA_TIMEOUT_SECONDS`), and Cloud Run concurrency/instances are capped
  (`RUN_CONCURRENCY`, `RUN_MAX_INSTANCES`). llama-server has no request-body size limit of
  its own; enforce one in your app before forwarding prompts.

## What the scripts can't decide for you

- Your organization's policy on unencrypted internal HTTP (see above).
- Peered VPCs or on-prem ranges that might overlap the default `10.80.0.0/24` and
  `10.80.16.0/26`: the scripts check only subnets inside the Gemma VPC.
- Which identities should be allowed to call the Cloud Run app (`RUN_INVOKERS`).
- The application itself: `RUN_IMAGE` is your code; `GEMMA_BASE_URL` and `GEMMA_API_KEY`
  are example variable names you should match to what your code reads.
