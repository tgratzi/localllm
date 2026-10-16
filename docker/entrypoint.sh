#!/bin/sh
# Container entrypoint: refuse to start in an unsafe configuration, then hand PID over to
# llama-server with `exec` so it receives SIGTERM directly and shuts down gracefully.
set -eu

die() {
    echo "gemma-entrypoint: ERROR: $*" >&2
    exit 64
}

# Authentication is mandatory. llama-server silently runs WITHOUT auth when no key is
# configured, so check for the key file here instead of trusting the defaults.
key_file="${LLAMA_ARG_API_KEY_FILE:-}"
[ -n "$key_file" ] || die "LLAMA_ARG_API_KEY_FILE is not set; refusing to start without API-key auth."
[ -f "$key_file" ] || die "API key file '$key_file' does not exist (mount it as a secret)."
[ -r "$key_file" ] || die "API key file '$key_file' is not readable by UID $(id -u). Make it readable by GID 10001."
[ -s "$key_file" ] || die "API key file '$key_file' is empty."

# Keys passed as environment variables show up in `docker inspect`; only the file is allowed.
[ -z "${LLAMA_API_KEY:-}" ] || die "LLAMA_API_KEY is set. Pass the key only through the key file."

# The weights are baked into the image; any runtime download setting is a misconfiguration.
for v in LLAMA_ARG_HF_REPO LLAMA_ARG_HF_FILE LLAMA_ARG_MODEL_URL LLAMA_ARG_MMPROJ_URL; do
    eval "val=\${$v:-}"
    [ -z "$val" ] || die "$v is set; this image must not download models at runtime."
done

model="${LLAMA_ARG_MODEL:-}"
[ -r "$model" ] || die "Model file '$model' is missing or unreadable."

# --offline: never touch the network for model files.
# --no-webui: the bundled web UI is served without auth; this is an API-only service.
exec /app/llama-server --offline --no-webui "$@"
