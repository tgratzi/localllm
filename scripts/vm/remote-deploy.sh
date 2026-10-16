#!/usr/bin/env bash
# Runs ON THE VM as root. Driven by scripts/deploy-vm.sh; not meant to be run by hand
# except for `status`.
#
#   remote-deploy.sh prepare <staging-dir>   install Docker + Compose, copy files to /opt/gemma
#   remote-deploy.sh up <IMAGE@sha256:...>   pull that digest and (re)start the container
#   remote-deploy.sh rollback                go back to the previously deployed digest
#   remote-deploy.sh status                  container, health and resource summary
set -euo pipefail

app_dir=/opt/gemma
key_file=/etc/gemma/api_key
metadata=http://metadata.google.internal/computeMetadata/v1

[[ "$(id -u)" == "0" ]] || { echo "ERROR: run as root (sudo)." >&2; exit 1; }

md() { curl -fsS -H 'Metadata-Flavor: Google' "${metadata}/$1"; }
internal_ip() { md instance/network-interfaces/0/ip; }

compose() { docker compose --project-directory "$app_dir" "$@"; }

wait_healthy() {
    local ip deadline code
    ip="$(internal_ip)"
    deadline=$((SECONDS + ${1:-300}))
    while (( SECONDS < deadline )); do
        code="$(curl -s -o /dev/null -w '%{http_code}' "http://${ip}:8080/health" || true)"
        if [[ "$code" == "200" ]]; then
            echo "Healthy at http://${ip}:8080"
            return 0
        fi
        sleep 5
    done
    echo "ERROR: not healthy after ${1:-300}s. Recent logs:" >&2
    compose logs --tail 50 >&2 || true
    return 1
}

prepare() {
    local staging="$1"
    [[ -f "${staging}/compose.yaml" && -f "${staging}/settings.env" ]] || { echo "ERROR: ${staging} is incomplete." >&2; exit 1; }

    if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
        echo "Installing Docker Engine and Compose from the Ubuntu archive..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q
        apt-get install -y -q docker.io docker-compose-v2 curl python3
    fi
    systemctl enable --now docker   # starts at boot, so the container comes back after a reboot

    install -d -m 0755 "$app_dir" "${app_dir}/bin"
    install -m 0644 "${staging}/compose.yaml" "${app_dir}/compose.yaml"
    install -m 0600 "${staging}/settings.env" "${app_dir}/settings.env"
    install -m 0755 "${staging}/remote-deploy.sh" "${app_dir}/bin/remote-deploy.sh"
    install -m 0755 "${staging}/write-api-key.sh" "${app_dir}/bin/write-api-key.sh"
    rm -rf "$staging"
    echo "Prepared ${app_dir}. Docker: $(docker --version)"
}

up() {
    local image="$1" registry token previous=""
    [[ "$image" =~ ^[a-z0-9.-]+-docker\.pkg\.dev/[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] \
        || { echo "ERROR: '$image' is not an Artifact Registry image pinned by digest." >&2; exit 1; }
    [[ -s "$key_file" ]] || { echo "ERROR: ${key_file} missing. Run gcp/manage-api-key.sh push-to-vm first." >&2; exit 1; }

    # Short-lived token from the VM's attached service account; nothing stored on disk
    # beyond the pull, and no service-account key file exists anywhere.
    registry="${image%%/*}"
    token="$(md instance/service-accounts/default/token | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
    printf '%s' "$token" | docker login -u oauth2accesstoken --password-stdin "https://${registry}" >/dev/null
    unset token
    echo "Pulling ${image}"
    if ! docker pull -q "$image"; then
        docker logout "https://${registry}" >/dev/null || true
        exit 1
    fi
    docker logout "https://${registry}" >/dev/null

    if [[ -f "${app_dir}/.env" ]]; then
        previous="$(sed -n 's/^GEMMA_IMAGE=//p' "${app_dir}/.env")"
    fi

    # .env = non-secret settings + this host's values. Compose reads it automatically.
    {
        cat "${app_dir}/settings.env"
        echo "GEMMA_IMAGE=${image}"
        echo "GEMMA_BIND_ADDRESS=$(internal_ip)"
        echo "GEMMA_API_KEY_FILE=${key_file}"
    } > "${app_dir}/.env.new"
    chmod 0600 "${app_dir}/.env.new"
    mv -f "${app_dir}/.env.new" "${app_dir}/.env"

    compose up -d --remove-orphans
    if ! wait_healthy 300; then
        if [[ -n "$previous" && "$previous" != "$image" ]]; then
            echo "New image is unhealthy. Roll back with: scripts/deploy-vm.sh --rollback" >&2
        fi
        exit 1
    fi
    if [[ -n "$previous" && "$previous" != "$image" ]]; then
        echo "$previous" > "${app_dir}/previous-image"
        echo "Previous image recorded for rollback: ${previous}"
    fi
    # No automatic pruning: images pulled by digest are untagged, so `docker image prune`
    # would delete the rollback image too. See docs/operations.md for cleaning old images.
}

rollback() {
    [[ -s "${app_dir}/previous-image" ]] || { echo "ERROR: no previous image recorded." >&2; exit 1; }
    local target
    target="$(cat "${app_dir}/previous-image")"
    echo "Rolling back to ${target}"
    up "$target"
}

status() {
    compose ps
    echo
    docker stats --no-stream --format 'cpu={{.CPUPerc}} mem={{.MemUsage}} ({{.MemPerc}})' gemma-gemma-1 || true
    docker inspect -f 'health={{.State.Health.Status}} restarts={{.RestartCount}} started={{.State.StartedAt}}' gemma-gemma-1 || true
    echo "image: $(sed -n 's/^GEMMA_IMAGE=//p' "${app_dir}/.env" 2>/dev/null)"
    free -h
}

case "${1:-}" in
    prepare)  prepare "${2:?staging dir required}" ;;
    up)       up "${2:?image digest required}" ;;
    rollback) rollback ;;
    status)   status ;;
    *)        sed -n '2,9p' "$0"; exit 1 ;;
esac
