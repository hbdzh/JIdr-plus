#!/bin/bash
# Prepare the existing, explicitly incomplete 0.10.0 source-review materials
# for a release using exactly the same pinned runtime and QEMU patch.
set -euo pipefail
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
  echo 'usage: prepare-runtime-sources.sh EXISTING_OUTPUT_DIRECTORY' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(cd "$1" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/miko-source-prep.XXXXXX")"
trap 'rm -rf "$work"' EXIT
base='https://github.com/hbdzh/miko-simulator/releases/download/v0.10.0'
review='miko-runtime-source-review-0.10.0.tar.gz'
projects='miko-runtime-source-projects-0.10.0.tar'
for file in "$review" "$projects"; do
  [ ! -e "$out/$file" ] || { echo "output already exists: $out/$file" >&2; exit 1; }
done
curl --fail --silent --show-error --location --retry 3 --proto '=https' --proto-redir '=https' "$base/$review" --output "$work/$review"
echo "2c97d0aa0be2833243c36f414e92ce55d05bea4605c03d068353164353f8299a  $work/$review" | shasum -a 256 -c -
tar -xOf "$work/$review" miko-runtime-source/runtime-sha256.txt | cmp - "$root/packaging/runtime-source/runtime-sha256.txt"
tar -xOf "$work/$review" miko-runtime-source/qemu-local.patch | cmp - "$root/packaging/runtime-source/qemu-local.patch"
curl --fail --silent --show-error --location --retry 3 --proto '=https' --proto-redir '=https' "$base/$projects" --output "$work/$projects"
echo "7ac094b68991d5fa8bf7074a4bbfe695ecc33c73acc32ad6fb49011adc80d13c  $work/$projects" | shasum -a 256 -c -
mv "$work/$review" "$work/$projects" "$out/"
printf '%s\n' 'Prepared incomplete source-review materials; the separate release review gate still applies.'
