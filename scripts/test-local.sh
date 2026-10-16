#!/usr/bin/env bash
# Local end-to-end test of the image, bound to loopback only.
#
#   scripts/test-local.sh [IMAGE] [--keep] [--skip-offline]
#
# 1. Generates a throwaway API key (never printed).
# 2. Starts the container with compose.yaml on 127.0.0.1:${GEMMA_HOST_PORT:-8080}.
# 3. Waits for /health, checks that a request WITHOUT the key is rejected (401),
#    then sends an authenticated chat-completions request and prints the reply.
# 4. Shows health, memory and CPU use, and the last log lines.
# 5. Offline check: starts the image again with NO network at all and waits for it to
#    become healthy, proving the weights are inside the image.
# 6. Stops and removes everything (unless --keep).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

image="gemma-e2b-server:local"
keep=0
offline=1
for arg in "$@"; do
    case "$arg" in
        --keep)         keep=1 ;;
        --skip-offline) offline=0 ;;
        -h|--help)      sed -n '2,14p' "$0"; exit 0 ;;
        -*)             echo "ERROR: unknown option $arg" >&2; exit 1 ;;
        *)              image="$arg" ;;
    esac
done

port="${GEMMA_HOST_PORT:-8080}"
base="http://127.0.0.1:${port}"
project="gemma-local"
offline_name="gemma-offline-check"
health_timeout="${HEALTH_TIMEOUT:-300}"

# Git Bash on Windows: give Docker Windows-style host paths, and stop MSYS from
# rewriting container paths (only on the docker run that needs it).
host_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

for c in docker curl python3; do
    command -v "$c" >/dev/null || { echo "ERROR: $c is required." >&2; exit 1; }
done
docker image inspect "$image" >/dev/null 2>&1 || { echo "ERROR: image $image not found. Run scripts/build-image.sh first." >&2; exit 1; }

workdir="$(mktemp -d)"
chmod 700 "$workdir"
key_file="${workdir}/api_key"
header_file="${workdir}/auth_header"
env_file="${workdir}/compose.env"

compose() { docker compose -p "$project" --env-file "$(host_path "$env_file")" -f compose.yaml "$@"; }

cleanup() {
    if [[ "$keep" == "1" ]]; then
        echo
        echo "Left running (--keep). The API key file is ${key_file}"
        echo "Stop with: docker compose -p ${project} --env-file ${env_file} -f compose.yaml down && rm -rf ${workdir}"
        return
    fi
    docker rm -f "$offline_name" >/dev/null 2>&1 || true
    compose down --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$workdir"
}
trap cleanup EXIT

# --- 1. Throwaway key ---------------------------------------------------------------
# The container runs as UID 10001, so the key file must be world-readable; the 0700
# directory around it keeps other host users out.
# end="": on Windows, print() would end the line with CRLF and the CR becomes part of the key.
python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")' > "$key_file"
chmod 0644 "$key_file"
# curl reads the header from a file, so the key never appears in the process list.
printf 'Authorization: Bearer %s\n' "$(cat "$key_file")" > "$header_file"
chmod 0600 "$header_file"

cat > "$env_file" <<EOF
GEMMA_IMAGE=${image}
GEMMA_BIND_ADDRESS=127.0.0.1
GEMMA_HOST_PORT=${port}
GEMMA_API_KEY_FILE=$(host_path "$key_file")
GEMMA_CTX_SIZE=${GEMMA_CTX_SIZE:-4096}
GEMMA_THREADS=${GEMMA_THREADS:-4}
GEMMA_MEM_LIMIT=${GEMMA_MEM_LIMIT:-12g}
EOF

wait_healthy() {
    local deadline=$((SECONDS + health_timeout)) code
    while (( SECONDS < deadline )); do
        code="$(curl -s -o "${workdir}/body" -w '%{http_code}' "${base}/health" || true)"
        [[ "$code" == "200" ]] && return 0
        if [[ -z "$(compose ps --status running -q)" ]]; then
            echo "ERROR: container exited. Logs:" >&2
            compose logs --tail 50 >&2
            return 1
        fi
        sleep 3
    done
    echo "ERROR: /health not ready after ${health_timeout}s. Logs:" >&2
    compose logs --tail 50 >&2
    return 1
}

# --- 2. Start ----------------------------------------------------------------------
echo "==> Starting ${image} on ${base} (loopback only)"
compose up -d
echo "==> Waiting for the model to load (up to ${health_timeout}s)"
wait_healthy
echo "    healthy"

# --- 3. Auth and inference -------------------------------------------------------
echo "==> Request without API key (expect 401)"
code="$(curl -s -o "${workdir}/body" -w '%{http_code}' "${base}/v1/models")"
[[ "$code" == "401" ]] || { echo "FAIL: unauthenticated request returned HTTP ${code}, expected 401." >&2; exit 1; }
echo "    401 as expected"

echo "==> Authenticated chat completion"
start=$SECONDS
response="$(curl -sS --fail-with-body -H @"$(host_path "$header_file")" -H 'Content-Type: application/json' \
    "${base}/v1/chat/completions" \
    -d '{"model":"gemma","messages":[{"role":"user","content":"Reply with: private connection works"}],"max_tokens":64}')"
elapsed=$((SECONDS - start))
RESPONSE="$response" python3 - "$elapsed" <<'PY'
import json, os, sys
r = json.loads(os.environ["RESPONSE"])
text = (r["choices"][0]["message"].get("content") or "").strip()
if not text:
    sys.exit("FAIL: empty completion: " + os.environ["RESPONSE"][:500])
u = r.get("usage", {})
print(f"    reply: {text!r}")
print(f"    tokens: prompt={u.get('prompt_tokens')} completion={u.get('completion_tokens')}  wall={sys.argv[1]}s")
PY

# --- 4. Observability --------------------------------------------------------------
cid="$(compose ps -q gemma)"
echo "==> Health / resources"
docker inspect -f '    health={{.State.Health.Status}} restarts={{.RestartCount}} user={{.Config.User}}' "$cid"
docker stats --no-stream --format '    cpu={{.CPUPerc}} mem={{.MemUsage}} ({{.MemPerc}})' "$cid"
echo "==> Last log lines"
compose logs --tail 10 | sed 's/^/    /'

# --- 5. Offline check --------------------------------------------------------------
if [[ "$offline" == "1" ]]; then
    echo "==> Offline check: starting a second copy with --network none"
    compose down >/dev/null   # free the memory first
    MSYS_NO_PATHCONV=1 docker run -d --name "$offline_name" --network none --read-only --tmpfs /tmp \
        -v "$(host_path "$key_file"):/run/secrets/llama_api_key:ro" \
        -e LLAMA_ARG_CTX_SIZE=2048 "$image" >/dev/null
    deadline=$((SECONDS + health_timeout))
    status=""
    while (( SECONDS < deadline )); do
        status="$(docker inspect -f '{{.State.Health.Status}}' "$offline_name" 2>/dev/null || echo gone)"
        [[ "$status" == "healthy" || "$status" == "unhealthy" || "$status" == "gone" ]] && break
        sleep 5
    done
    if [[ "$status" != "healthy" ]]; then
        echo "FAIL: offline container status '${status}'. Logs:" >&2
        docker logs --tail 50 "$offline_name" >&2 || true
        exit 1
    fi
    echo "    healthy with no network: weights are in the image"
fi

echo
echo "PASS: local tests succeeded."
