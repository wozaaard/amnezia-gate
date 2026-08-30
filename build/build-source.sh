#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
version=${1:?usage: build-source.sh VERSION OUTPUT}
output=${2:?usage: build-source.sh VERSION OUTPUT}
project_name=${project_dir##*/}
source_name="amnezia-gate-${version}"

[[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || {
    printf 'build-source: invalid version: %s\n' "$version" >&2
    exit 1
}

install -d "${output%/*}"
temporary=$(mktemp "${output}.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT

tar \
    --sort=name \
    --mtime=@0 \
    --numeric-owner \
    --owner=0 \
    --group=0 \
    --exclude="${project_name}/.git" \
    --exclude="${project_name}/_build" \
    --exclude="${project_name}/dist" \
    --transform="s,^${project_name},${source_name}," \
    -C "${project_dir%/*}" \
    -cf - "$project_name" |
    zstd -T0 -19 -f -o "$temporary"

mv -f -- "$temporary" "$output"
trap - EXIT
printf '%s\n' "$output"
