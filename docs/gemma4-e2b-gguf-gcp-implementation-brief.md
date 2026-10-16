from pathlib import Path

content = r"""# Gemma 4 E2B GGUF Docker Deployment on Google Cloud

## Repository name

Recommended repository name: **`gemma4-e2b-gguf-gcp`**

Why:
- `gemma4`: identifies the model family.
- `e2b`: identifies the E2B model variant.
- `gguf`: identifies the model format.
- `gcp`: identifies the deployment target.

Use this repository name for the source-code repository. Use a separate Artifact Registry image name such as `gemma-e2b-server`.

## Project goal

Build a reproducible Docker image containing both:
1. `llama.cpp` inference server.
2. The Gemma 4 E2B instruction-tuned GGUF model weights.

Deploy the container on a Google Compute Engine CPU VM. The model API must be private and callable by a private Google Cloud Run application over a VPC network.

The model weights must be inside the Docker image, not downloaded at container startup and not mounted from a host directory. The Docker build may download the model from the official Hugging Face repository.

## Architecture

- **Inference host:** Google Compute Engine, Ubuntu 24.04 LTS, CPU-only.
- **Suggested starting machine:** `e2-standard-4` (4 vCPU, 16 GB RAM). Validate RAM and performance with the selected quantization and context length; resize if necessary.
- **Container runtime:** Docker Engine and Docker Compose on the VM.
- **Inference server:** `llama.cpp` `llama-server`.
- **Model repository:** `ggml-org/gemma-4-E2B-GGUF` on Hugging Face.
- **Quantization:** Start with a published Q8_0 variant if the exact file is available and memory testing succeeds. Consider a smaller supported quantization if needed.
- **API protocol:** OpenAI-compatible `/v1/chat/completions`.
- **Application host:** Google Cloud Run.
- **Networking:** Cloud Run Direct VPC egress to a dedicated subnet; VM has no external IP; firewall allows TCP 8080 only from that subnet.
- **Authentication:** Require an API key at `llama-server`; keep it in Secret Manager for Cloud Run and securely provision the same value to the VM.
- **Client-to-Cloud Run security:** Cloud Run internal ingress and IAM authentication.
- **Cloud Run-to-VM transport:** Internal VPC HTTP can be used only if accepted by the organization's security policy. If encryption on this hop is required, implement internal HTTPS with a properly configured internal load balancer and certificates.

## Important implementation requirements

1. **Verify the model file name before building.** Do not assume a Hugging Face filename. Inspect the repository's current file listing and choose an actual compatible GGUF file.
2. **Verify the model architecture is supported by the selected `llama.cpp` image/version.** Pin a known-good release or image digest for reproducibility; avoid relying on an unpinned `latest` image in production.
3. **Bundle the GGUF weights in the final Docker image.** The running container must not need to download model weights or access Hugging Face.
4. Use a multi-stage Docker build if useful, but the final image must contain the server binary and model weights.
5. Do not bake API keys, access tokens, or other secrets into the image or build arguments.
6. Keep the container running as a non-root user where feasible. Ensure that the model file is readable by that user.
7. Use a health check or external readiness check and configure restart behavior.
8. Set appropriate CPU thread count and context length through environment variables or a clear configuration file.
9. Handle SIGTERM correctly so the server shuts down gracefully.
10. Document that updating model weights requires building and publishing a new image.
11. Add `.dockerignore` and `.gitignore`. Never commit model weights, credentials, `.env` files, or local caches to the source repository.
12. Add an SBOM/image scanning step if supported by the chosen build pipeline.

## Required repository layout

Generate a maintainable project with at least:

```text
gemma4-e2b-gguf-gcp/
├── README.md
├── Dockerfile
├── .dockerignore
├── .gitignore
├── compose.yaml
├── .env.example
├── scripts/
│   ├── verify-model-file.sh
│   ├── build-image.sh
│   ├── test-local.sh
│   └── deploy-vm.sh
├── gcp/
│   ├── setup-network.sh
│   ├── create-vm.sh
│   ├── configure-cloud-run.sh
│   └── firewall.md
└── docs/
    ├── architecture.md
    ├── operations.md
    └── troubleshooting.md
```

You may adjust this structure if there is a strong reason, but keep build, local test, GCP infrastructure, and operations instructions separate.

## Docker build requirements

Create a Dockerfile that:
- Uses a compatible `llama.cpp` server base image or builds `llama.cpp` from source.
- Downloads the verified GGUF file at build time.
- Checks the download succeeded and preferably verifies a published checksum when one is available.
- Copies the model into a stable path such as `/models/gemma-4-e2b.gguf`.
- Does not require a Hugging Face token for a public model; if access is required, use a secure build secret rather than a literal token.
- Starts `llama-server` with the local model path, not a runtime Hugging Face download.
- Binds to the container interface so VPC clients can connect.
- Requires API-key authentication.
- Exposes port 8080.
- Supports configuration of context size and CPU threads.
- Includes no GPU dependencies for the CPU target.

Do not copy an example filename from an old guide without checking the repository. The build should fail with a clear error if the selected file does not exist.

## Local run and test requirements

Provide documented commands to:
1. Build the image.
2. Generate a random API key.
3. Run the container with port 8080 bound to loopback for local-only testing.
4. Send a sample OpenAI-compatible chat-completions request.
5. Check logs, health, memory, and CPU use.
6. Stop and remove the container.

Never publish port 8080 to all host interfaces for a public deployment unless an explicit, reviewed network design requires it.

## Google Cloud deployment requirements

Write scripts and instructions to:

1. Select a GCP project and region.
2. Enable required APIs (Compute Engine, Artifact Registry, Cloud Run, Secret Manager, and IAP where required).
3. Create or verify the VPC and a dedicated subnet for Cloud Run Direct VPC egress. Check for CIDR overlap before creating the subnet.
4. Create a CPU-only Compute Engine VM with an appropriate persistent boot disk and **no external IP**.
5. Configure administrative SSH through IAP if desired, with a narrowly scoped firewall rule for TCP 22 from the IAP range.
6. Create a firewall rule allowing TCP 8080 only from the Cloud Run egress subnet and targeting the Gemma VM tag. Do not allow `0.0.0.0/0` to port 8080.
7. Build and push the image to a private Artifact Registry repository.
8. Give the VM's attached service account only the permissions required to pull the image from Artifact Registry. Do not place service-account keys on disk.
9. Install Docker on the VM and deploy the pinned image tag or digest.
10. Provision the API key securely. The Cloud Run runtime service account must have access only to the required Secret Manager secret. Avoid writing secret values to shell history or logs.
11. Configure Cloud Run Direct VPC egress to the correct VPC and subnet. Use `private-ranges-only` if only private destinations need VPC routing.
12. Deploy the Cloud Run application with internal ingress and unauthenticated invocation disabled. Grant `roles/run.invoker` only to the actual calling identities.
13. Configure the application to call `http://<VM_INTERNAL_IP>:8080/v1` with the API key in the `Authorization: Bearer ...` header.
14. Explain that `GEMMA_BASE_URL` and `GEMMA_API_KEY` are application configuration examples; adapt them to the application's actual code.
15. Verify connectivity from a diagnostic workload using the same VPC path, rather than from an unrelated local machine.
16. Provide rollback and cleanup commands, with warnings before destructive operations.

Do not create public IPs or public ingress rules as a shortcut.

## Application integration contract

The Cloud Run application should be able to configure:

- `GEMMA_BASE_URL=http://<VM_INTERNAL_IP>:8080/v1`
- `GEMMA_API_KEY` sourced from Secret Manager.

Example request:

```bash
curl "${GEMMA_BASE_URL}/chat/completions" \
  -H "Authorization: Bearer ${GEMMA_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma",
    "messages": [
      {"role": "user", "content": "Reply with: private connection works"}
    ],
    "max_tokens": 64
  }'
```

The API key must never be exposed to a browser, mobile client, or other untrusted caller. The Cloud Run application should authenticate its own callers using IAM or the chosen application authentication layer.

## HTTPS and security notes

- Cloud Run's HTTPS endpoint protects the client-to-application hop.
- Private VPC HTTP from Cloud Run to the VM is not encrypted end-to-end. State this clearly.
- If policy requires encryption on the backend hop, propose and document an internal HTTPS load balancer, internal DNS name, certificate management, backend protocol, and certificate validation. Do not simply change `http://` to `https://`.
- Use least-privilege IAM, Secret Manager, private ingress, firewall restrictions, and log redaction.
- Do not log Authorization headers, API keys, or prompts if they may contain sensitive data.
- Set sensible request size, token, timeout, and concurrency limits.

## Operations and observability

Document commands for:
- `docker ps`, `docker logs`, `docker inspect`, and `docker stats`.
- Checking VM and Cloud Run logs.
- Restarting and upgrading the container.
- Rotating the API key on both VM and Cloud Run.
- Testing the model after deployment.
- Monitoring memory pressure, CPU utilization, latency, errors, and restarts.
- Estimating Compute Engine, disk, Artifact Registry, networking, and Cloud NAT costs.
- Configuring a GCP budget alert.
- Rebuilding and redeploying when model weights or `llama.cpp` are updated.

## Acceptance criteria

The implementation is complete only when:

- [ ] A clean build produces a Docker image containing the inference server and GGUF weights.
- [ ] The container starts without downloading model weights at runtime.
- [ ] A local authenticated chat-completions request returns generated text.
- [ ] The container restarts after a VM reboot.
- [ ] The VM has no external IP.
- [ ] TCP 8080 is not publicly reachable.
- [ ] The Cloud Run workload can reach the model over the private VPC.
- [ ] Unauthorized Cloud Run callers cannot invoke the application.
- [ ] Secrets are not in Git, image layers, image build arguments, or logs.
- [ ] Documentation contains reproducible build, deploy, test, rollback, and cleanup steps.

## Expected deliverables from the AI coding agent

1. All files in the repository layout above.
2. A verified Dockerfile and Compose configuration.
3. Working scripts with safe defaults and input validation.
4. Exact commands to build, test, push, and deploy.
5. A README that clearly separates commands run locally, in Cloud Shell, on the VM, and in the Cloud Run application.
6. Explicit notes for any assumptions or GCP configuration that cannot be automated safely.
7. No fabricated model filenames, image tags, CLI flags, resource IDs, or prices. Verify current names and options against official documentation before finalizing.
"""

path = Path("/mnt/data/gemma4-e2b-gguf-gcp-implementation-brief.md")
path.write_text(content, encoding="utf-8")
print(f"Created: {path}")
