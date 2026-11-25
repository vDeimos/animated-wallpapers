#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
base=https://github.com/vDeimos/animated-wallpapers/releases/download/v2.3.9
work=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/AnimatedWallpapers.XXXXXX")
parts="$work/parts"
/bin/mkdir "$parts"
trap '/bin/rm -rf -- "$parts"' EXIT

if [[ $# == 2 && $1 == --extract-only ]]; then
    package="$2"
elif [[ $# == 0 ]]; then
    package="$work/Animated Wallpapers.pkg"
else
    printf 'Usage: %s [--extract-only output.pkg]\n' "$0" >&2
    exit 64
fi
if [[ -e "$package" ]]; then
    printf 'The output installer already exists.\n' >&2
    exit 73
fi

printf 'Preparing Animated Wallpapers 2.3.9. Download size is about 5.5 GB.\n'
verified=()
for suffix in aa ab ac; do
    part="Animated-Wallpapers.aea.part-$suffix"
    if [[ -f "$here/$part" ]]; then
        file="$here/$part"
    else
        printf 'Downloading %s\n' "$part"
        file="$parts/$part"
        /usr/bin/curl --fail --location --retry 3 --progress-bar "$base/$part" --output "$file"
    fi
    expected=$(/usr/bin/awk -v part="$part" '$2 == part {print $1}' "$here/SHA256SUMS")
    actual=$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        printf 'The checksum for %s did not match. Download a fresh copy.\n' "$part" >&2
        exit 65
    fi
    verified+=("$file")
done

printf 'Verifying and decrypting the macOS installer…\n'
/bin/cat "${verified[@]}" | /usr/bin/aea decrypt -key "$here/Animated-Wallpapers.key" -o "$package"
if [[ $# == 0 ]]; then
    /usr/bin/open "$package"
else
    printf 'Installer extracted to %s\n' "$package"
fi
