#!/usr/bin/env bash
# Runs ON THE VM as root. Reads one or more API keys (one per line) from stdin and
# installs them as /etc/gemma/api_key, readable only by root and GID 10001 (the
# container user). If the Gemma container is running it is recreated so the server
# re-reads the key file. Keys are never echoed.
#
# Called by gcp/manage-api-key.sh and scripts/deploy-vm.sh:
#   gcloud secrets versions access latest --secret=... | gcloud compute ssh ... --command='sudo /opt/gemma/bin/write-api-key.sh'
set -euo pipefail
umask 077

[[ "$(id -u)" == "0" ]] || { echo "ERROR: run as root." >&2; exit 1; }

key_dir=/etc/gemma
key_file="${key_dir}/api_key"
install -d -m 0750 -o root -g 10001 "$key_dir"

tmp="$(mktemp "${key_dir}/.api_key.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# Keep non-empty lines only; reject anything that does not look like a strong key.
count=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[A-Za-z0-9._~+/=-]{32,}$ ]] || { echo "ERROR: key line $((count + 1)) is shorter than 32 chars or has invalid characters." >&2; exit 1; }
    printf '%s\n' "$line" >> "$tmp"
    count=$((count + 1))
done
(( count > 0 )) || { echo "ERROR: no key received on stdin." >&2; exit 1; }

chown root:10001 "$tmp"
chmod 0440 "$tmp"
mv -f "$tmp" "$key_file"
trap - EXIT
echo "Installed ${count} key(s) in ${key_file} (root:10001, 0440)."

# A file bind mount pins the old inode, so the container must be recreated, not just
# signalled, to see the new file.
if [[ -f /opt/gemma/compose.yaml ]] && docker compose --project-directory /opt/gemma ps -q --status running 2>/dev/null | grep -q .; then
    echo "Recreating the Gemma container to load the new key(s)..."
    docker compose --project-directory /opt/gemma up -d --force-recreate --wait --wait-timeout 300
    echo "Container healthy."
fi
