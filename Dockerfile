# Gemma 4 E2B (instruction-tuned, Q8_0 GGUF) served by llama.cpp `llama-server`, CPU only.
#
# The model weights are downloaded at BUILD time and baked into the final image.
# The running container never contacts Hugging Face. Changing the model file or the
# llama.cpp version means building and publishing a new image.
#
# Build:  scripts/build-image.sh            (wraps `docker buildx build`)
# Verify the model pins first: scripts/verify-model-file.sh

# llama.cpp CPU server image, pinned by tag and by multi-arch index digest.
# server-b11277 = llama.cpp commit eae11d2217fe9225d1aaba48773b6cca45ae4de9 (2026-09-30),
# Ubuntu 24.04 base, ships the `gemma4` architecture. CPU build: no CUDA/Vulkan libraries.
ARG LLAMA_CPP_IMAGE=ghcr.io/ggml-org/llama.cpp:server-b11277@sha256:6d607629e3dd5e85f45c43d1494648126cb3f93f2122c9cd53f43242c94cde14

# Model pins. All four values were checked against the Hugging Face API; the revision is
# a commit hash so the file cannot change underneath us. MODEL_SHA256 is the LFS SHA-256
# published by Hugging Face for this exact file.
ARG MODEL_REPO=ggml-org/gemma-4-E2B-it-GGUF
ARG MODEL_REVISION=b4243c156154b6dca9324415f8c7ccc098b4aed1
ARG MODEL_FILE=gemma-4-E2B-it-Q8_0.gguf
ARG MODEL_SHA256=996d08777aadc6bfd3c7375ef70ba25a0f55240075860754fdb18d6d860aa63a

# ---------------------------------------------------------------------------------------
# Stage 1: download and verify the GGUF file. Reuses the pinned base (it has curl and
# sha256sum) so the build pulls no extra images.
# ---------------------------------------------------------------------------------------
FROM ${LLAMA_CPP_IMAGE} AS model

ARG MODEL_REPO
ARG MODEL_REVISION
ARG MODEL_FILE
ARG MODEL_SHA256

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The model is public, so no token is needed. If a gated model is ever used, pass the
# token as a BuildKit secret (never a build arg):
#   docker buildx build --secret id=hf_token,src=$HOME/.hf_token ...
# The token is read through process substitution, so it is never written to a layer.
RUN --mount=type=secret,id=hf_token,required=false \
    set -eu; \
    for v in MODEL_REPO MODEL_REVISION MODEL_FILE MODEL_SHA256; do \
        if [ -z "${!v}" ]; then echo "ERROR: build arg ${v} is empty" >&2; exit 1; fi; \
    done; \
    url="https://huggingface.co/${MODEL_REPO}/resolve/${MODEL_REVISION}/${MODEL_FILE}"; \
    mkdir -p /models; \
    echo "Downloading ${MODEL_REPO}@${MODEL_REVISION}/${MODEL_FILE}"; \
    if [ -s /run/secrets/hf_token ]; then \
        dl() { curl -fSL --proto '=https' --tlsv1.2 --retry 5 --retry-delay 10 \
                    -H @<(printf 'Authorization: Bearer %s\n' "$(cat /run/secrets/hf_token)") "$@"; }; \
    else \
        dl() { curl -fSL --proto '=https' --tlsv1.2 --retry 5 --retry-delay 10 "$@"; }; \
    fi; \
    if ! dl -o /models/gemma-4-e2b.gguf "${url}"; then \
        echo "ERROR: could not download ${MODEL_FILE} from ${MODEL_REPO} at revision ${MODEL_REVISION}." >&2; \
        echo "       The file name or revision may be wrong. Run scripts/verify-model-file.sh." >&2; \
        exit 1; \
    fi; \
    if ! echo "${MODEL_SHA256}  /models/gemma-4-e2b.gguf" | sha256sum -c -; then \
        echo "ERROR: SHA-256 mismatch for ${MODEL_FILE}. Refusing to bake an unverified model." >&2; \
        exit 1; \
    fi; \
    if [ "$(head -c 4 /models/gemma-4-e2b.gguf)" != "GGUF" ]; then \
        echo "ERROR: ${MODEL_FILE} is not a GGUF file (bad magic bytes)." >&2; \
        exit 1; \
    fi

# ---------------------------------------------------------------------------------------
# Stage 2: runtime image = pinned llama-server + verified weights + small entrypoint.
# ---------------------------------------------------------------------------------------
FROM ${LLAMA_CPP_IMAGE}

ARG MODEL_REPO
ARG MODEL_REVISION
ARG MODEL_FILE
ARG MODEL_SHA256

LABEL org.opencontainers.image.title="gemma-e2b-server" \
      org.opencontainers.image.description="llama.cpp llama-server with Gemma 4 E2B-it Q8_0 GGUF weights baked in (CPU only)" \
      org.opencontainers.image.licenses="Apache-2.0" \
      io.gemma.model.repo="${MODEL_REPO}" \
      io.gemma.model.revision="${MODEL_REVISION}" \
      io.gemma.model.file="${MODEL_FILE}" \
      io.gemma.model.sha256="${MODEL_SHA256}"

# Dedicated non-root user. The fixed UID/GID (10001) matters: the API key file on the VM
# is made readable by this GID only (see scripts/vm/write-api-key.sh).
RUN groupadd --system --gid 10001 llama \
 && useradd --system --uid 10001 --gid 10001 --no-create-home \
            --home-dir /nonexistent --shell /usr/sbin/nologin llama \
 && install -d -m 0755 -o root -g root /models

# Root-owned and read-only for everyone: the server can read the weights but not change them.
# /models must exist first: COPY --chmod would otherwise create it as 0444 (not traversable).
COPY --from=model --chmod=0444 /models/gemma-4-e2b.gguf /models/gemma-4-e2b.gguf
COPY --chmod=0555 docker/entrypoint.sh /usr/local/bin/gemma-entrypoint

# Defaults only; override at run time (compose.yaml maps GEMMA_* variables onto these).
# LLAMA_ARG_THREADS is left unset so llama.cpp picks its own default unless told otherwise.
ENV LLAMA_ARG_MODEL=/models/gemma-4-e2b.gguf \
    LLAMA_ARG_HOST=0.0.0.0 \
    LLAMA_ARG_PORT=8080 \
    LLAMA_ARG_ALIAS=gemma \
    LLAMA_ARG_API_KEY_FILE=/run/secrets/llama_api_key \
    LLAMA_ARG_CTX_SIZE=8192 \
    LLAMA_ARG_N_PARALLEL=1 \
    LLAMA_ARG_N_PREDICT=1024 \
    LLAMA_ARG_TIMEOUT=300 \
    LLAMA_ARG_REASONING=off

USER 10001:10001
EXPOSE 8080

# /health is the only unauthenticated API route in llama-server: 503 while loading, 200 when ready.
HEALTHCHECK --interval=15s --timeout=5s --start-period=180s --retries=3 \
  CMD ["curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8080/health"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/gemma-entrypoint"]
CMD []
