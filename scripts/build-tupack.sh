#!/usr/bin/env bash
# Packages the Gemma server as a TOS app with tupack: one .tar holding the Helm chart and
# the image, which `tos apps install` takes as-is (no registry access needed on the TOS side).
#
#   scripts/build-tupack.sh VERSION [IMAGE]
#
#   VERSION  release version, with or without a leading v (v1.2.0 or 1.2.0)
#   IMAGE    local image to package (default gemma-e2b-server:local; build it first with
#            scripts/build-image.sh)
#
# Environment:
#   TUPACK         path to the tupack binary (required). It ships in the private repo
#                  tufin-ext-resources/baseimage7 at src/scripts/tupack.
#   TUPACK_SHA256  optional: refuse to run a tupack binary with a different SHA-256
#   OUT_DIR        output directory (default dist)
#   REGISTRY_PORT  host port for the temporary registry (default 5000)
#
# Output: OUT_DIR/localllm-VERSION.tar and OUT_DIR/localllm-VERSION.tar.sha256
#
# How it works: tupack downloads images from a registry, not from the local Docker store.
# The script starts a throwaway registry on 127.0.0.1, pushes IMAGE to it, and runs tupack
# in a container that shares the registry container's network, so "localhost:5000" means the
# registry on every host OS. Needs ~2x the image size (~11 GB) of free Docker disk.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

APP_NAME=localllm
APP_TITLE="Local LLM (Gemma 4 E2B)"
IMAGE_REPOSITORY=localllm/gemma-e2b-server
# Pinned helper images. registry:2 holds the image while tupack reads it; ubuntu runs tupack.
REGISTRY_IMAGE=registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373
RUNNER_IMAGE=ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
    ""|-h|--help) sed -n '2,24p' "$0"; [[ -n "${1:-}" ]] && exit 0 || exit 1 ;;
esac

version="${1#v}"
image="${2:-gemma-e2b-server:local}"
out_dir="${OUT_DIR:-dist}"
registry_port="${REGISTRY_PORT:-5000}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
    || die "'$1' is not a semantic version such as v1.2.0 or 1.2.0-rc.1."
command -v docker >/dev/null || die "docker is required."
docker image inspect "$image" >/dev/null 2>&1 \
    || die "image '$image' not found. Build it first: scripts/build-image.sh"

tupack="${TUPACK:-}"
[[ -n "$tupack" ]] || die "set TUPACK to the tupack binary (tufin-ext-resources/baseimage7: src/scripts/tupack)."
[[ -f "$tupack" ]] || die "TUPACK '$tupack' does not exist."
if [[ -n "${TUPACK_SHA256:-}" ]]; then
    actual="$(sha256sum "$tupack" | awk '{print $1}')"
    [[ "$actual" == "$TUPACK_SHA256" ]] || die "tupack SHA-256 is $actual, expected $TUPACK_SHA256."
fi

# Git Bash on Windows: hand Docker Windows paths and stop MSYS from rewriting /w-style
# container paths. No effect on Linux or macOS.
host_path() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
export MSYS_NO_PATHCONV=1

sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo nogit)"
[[ -z "$(git status --porcelain 2>/dev/null)" ]] || sha="${sha}-dirty"

mkdir -p "$out_dir"
work="${out_dir}/.tupack-work"
rm -rf "$work"
mkdir -p "$work/chart"
registry="localllm-pkg-registry-$$"

cleanup() {
    docker rm -f "$registry" >/dev/null 2>&1 || true
    rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Starting temporary registry on 127.0.0.1:${registry_port}"
docker run -d --rm --name "$registry" -p "127.0.0.1:${registry_port}:5000" "$REGISTRY_IMAGE" >/dev/null
for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:${registry_port}/v2/" >/dev/null 2>&1 && break
    sleep 1
done
curl -fsS "http://127.0.0.1:${registry_port}/v2/" >/dev/null || die "temporary registry did not start."

echo "==> Pushing ${image} to the temporary registry"
local_ref="localhost:${registry_port}/${IMAGE_REPOSITORY}:${version}"
docker tag "$image" "$local_ref"
docker push -q "$local_ref" >/dev/null
docker rmi "$local_ref" >/dev/null   # drops only the extra tag, not the image

echo "==> Preparing chart ${APP_NAME} ${version}"
cp -R "charts/${APP_NAME}" "$work/chart/"
chart="$work/chart/${APP_NAME}"
sed -i.bak -E "s/^version:.*/version: ${version}/; s/^appVersion:.*/appVersion: \"${version}\"/" "$chart/Chart.yaml"
sed -i.bak -E "s/^(    version:).*/\1 \"${version}\"/" "$chart/values.yaml"
rm -f "$chart"/*.bak
grep -q "^    version: \"${version}\"" "$chart/values.yaml" || die "could not set image.version in values.yaml."

# Build-time only: tupack reads the image from the temporary registry. The packaged
# values.yaml keeps tos-registry.local, which TOS rewrites at install time anyway.
# Inside the shared network namespace the registry always listens on 5000.
printf 'image:\n    registry: localhost:5000/\n' > "$work/build-values.yaml"
cp "$tupack" "$work/tupack"
chmod +x "$work/tupack"

user_args=()
[[ "$(uname -s)" == "Linux" ]] && user_args=(--user "$(id -u):$(id -g)")

echo "==> Running tupack (archives ~5 GB, takes a few minutes)"
docker run --rm "${user_args[@]}" \
    --network "container:${registry}" \
    -e HOME=/tmp \
    -v "$(host_path "$repo_root/$work"):/w" -w /w \
    "$RUNNER_IMAGE" \
    /w/tupack build \
        --name "$APP_NAME" --version "$version" --type marketplace --title "$APP_TITLE" \
        --sha "$sha" --no-progress \
        --cache-path /w/image-cache \
        --build-values /w/build-values.yaml \
        "chart/${APP_NAME}/"

[[ -s "$work/${APP_NAME}.tar" ]] || die "tupack did not produce ${APP_NAME}.tar."
tar_name="${APP_NAME}-${version}.tar"
mv -f "$work/${APP_NAME}.tar" "$out_dir/$tar_name"
(cd "$out_dir" && sha256sum "$tar_name" > "${tar_name}.sha256")

echo
echo "Built:  ${out_dir}/${tar_name} ($(du -h "$out_dir/$tar_name" | awk '{print $1}'))"
echo "SHA256: $(awk '{print $1}' "$out_dir/${tar_name}.sha256")"
echo
echo "Install on the TOS node:  tos apps install ${tar_name}"
echo "Upgrade:                  tos apps upgrade ${tar_name}"
