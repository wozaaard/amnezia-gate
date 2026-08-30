#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
output=${1:-$project_dir/_build/amnezia-gate-rootfs.squashfs}
repo_oss=${KIWI_REPO_OSS:-https://download.opensuse.org/tumbleweed/repo/oss/}
repo_amneziawg=${KIWI_REPO_AMNEZIAWG:-https://download.opensuse.org/repositories/home:/teksource:/amneziawg/openSUSE_Tumbleweed/}

[[ $EUID -eq 0 ]] || {
    printf 'build-rootfs: run as root (KIWI requires mount namespaces)\n' >&2
    exit 1
}
command -v kiwi-ng >/dev/null || {
    printf 'build-rootfs: kiwi-ng is not installed\n' >&2
    exit 1
}

build_dir=$(mktemp -d /tmp/amnezia-gate-kiwi.XXXXXX)
cleanup() {
    rm -rf -- "$build_dir"
}
trap cleanup EXIT

mkdir -p "$build_dir/result" "$build_dir/tmp"
kiwi-ng --temp-dir="$build_dir/tmp" system build \
    --description "$project_dir/kiwi" \
    --target-dir "$build_dir/result" \
    --ignore-repos \
    --add-repo="$repo_oss,rpm-md,repo-oss,99,false,true" \
    --add-repo="$repo_amneziawg,rpm-md,amneziawg,1,false,true"

mapfile -t images < <(find "$build_dir/result" -maxdepth 1 -type f -name '*.squashfs' -print)
(( ${#images[@]} == 1 )) || {
    printf 'build-rootfs: expected one squashfs result, found %d\n' "${#images[@]}" >&2
    exit 1
}

mkdir -p "${output%/*}"
install -m 0644 "${images[0]}" "$output"

artifacts=("$output")
for suffix in packages verified; do
    mapfile -t metadata < <(find "$build_dir/result" -maxdepth 1 -type f -name "*.$suffix" -print)
    (( ${#metadata[@]} == 1 )) || {
        printf 'build-rootfs: expected one %s result, found %d\n' \
            "$suffix" "${#metadata[@]}" >&2
        exit 1
    }
    install -m 0644 "${metadata[0]}" "$output.$suffix"
    artifacts+=("$output.$suffix")
done

if [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]]; then
    chown "$SUDO_UID:$SUDO_GID" "${artifacts[@]}"
fi
printf '%s\n' "$output"
