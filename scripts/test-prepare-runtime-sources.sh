#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then echo 'usage: test-prepare-runtime-sources.sh REVIEW_TAR_GZ PROJECTS_TAR' >&2; exit 2; fi
root="$(cd "$(dirname "$0")/.." && pwd)"
export MOCK_REVIEW="$1" MOCK_PROJECTS="$2"
for file in "$MOCK_REVIEW" "$MOCK_PROJECTS"; do [ -f "$file" ] || { echo "missing fixture: $file" >&2; exit 1; }; done
work="$(mktemp -d "${TMPDIR:-/tmp}/miko-source-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/out" "$work/bad" "$work/repo/scripts" "$work/repo/packaging/runtime-source"
cat > "$work/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
url=''; dest=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) dest="$2"; shift 2 ;;
    --retry|--proto|--proto-redir) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */miko-runtime-source-review-0.10.0.tar.gz) cp "$MOCK_REVIEW" "$dest" ;;
  */miko-runtime-source-projects-0.10.0.tar) cp "$MOCK_PROJECTS" "$dest" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
"$root/scripts/prepare-runtime-sources.sh" "$work/out"
test -f "$work/out/miko-runtime-source-review-0.10.0.tar.gz"
test -f "$work/out/miko-runtime-source-projects-0.10.0.tar"
cp "$root/scripts/prepare-runtime-sources.sh" "$work/repo/scripts/"
cp "$root/packaging/runtime-source/runtime-sha256.txt" "$work/repo/packaging/runtime-source/"
cp "$root/packaging/runtime-source/qemu-local.patch" "$work/repo/packaging/runtime-source/"
printf 'tampered\n' >> "$work/repo/packaging/runtime-source/runtime-sha256.txt"
if "$work/repo/scripts/prepare-runtime-sources.sh" "$work/bad" >/dev/null 2>&1; then
  echo 'changed runtime manifest should fail' >&2; exit 1
fi
printf 'Source preparation: pinned inputs accepted and changed runtime rejected\n'
