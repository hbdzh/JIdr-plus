#!/bin/bash
# Exercise the composite action with local, pre-verified fixture archives.
set -euo pipefail
if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo 'usage: test-ci-runtime-action.sh EMULATOR_ZIP PLATFORM_TOOLS_ZIP CORE [DMG]' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
export MOCK_EMULATOR="$1" MOCK_PLATFORM="$2" MOCK_CORE="$3" MOCK_DMG="${4:-}"
for file in "$MOCK_EMULATOR" "$MOCK_PLATFORM" "$MOCK_CORE"; do [ -f "$file" ] || { echo "missing fixture: $file" >&2; exit 1; }; done
work="$(mktemp -d "${TMPDIR:-/tmp}/miko-ci-action-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/runner"
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
  https://ci.invalid/core) source="$MOCK_CORE" ;;
  https://github.com/hbdzh/miko-simulator/releases/download/v0.10.0/miko-simulator-0.10.0-arm64.dmg) source="$MOCK_DMG" ;;
  https://ci.invalid/bad) printf wrong > "$dest"; exit 0 ;;
  https://redirector.gvt1.com/edgedl/android/repository/emulator-darwin_aarch64-16970787.zip) source="$MOCK_EMULATOR" ;;
  https://redirector.gvt1.com/edgedl/android/repository/platform-tools_r37.0.3-darwin.zip) source="$MOCK_PLATFORM" ;;
  *) exit 1 ;;
esac
cp "$source" "$dest"
MOCK
chmod +x "$work/bin/curl"
ruby -e 'require "yaml"; puts YAML.load_file(ARGV[0])["runs"]["steps"][0]["run"]' \
  "$root/.github/actions/prepare-miko-runtime/action.yml" > "$work/action.sh"
export PATH="$work/bin:$PATH" GITHUB_WORKSPACE="$root" RUNNER_TEMP="$work/runner" GITHUB_ENV="$work/github-env"
touch "$GITHUB_ENV"
if MIKO_CORE_URL=http://example.invalid/core bash "$work/action.sh" >"$work/http.log" 2>&1; then echo 'HTTP should fail' >&2; exit 1; fi
grep -q 'HTTPS URL' "$work/http.log"
if MIKO_CORE_URL=https://ci.invalid/bad bash "$work/action.sh" >"$work/hash.log" 2>&1; then echo 'bad hash should fail' >&2; exit 1; fi
grep -q 'does not match' "$work/hash.log"
MIKO_CORE_URL=https://ci.invalid/core bash "$work/action.sh"
grep -q '^MIKO_BUNDLED_SDK=' "$GITHUB_ENV"
echo 'CI runtime preparation: valid, HTTP rejected, bad core rejected'
if [ -n "$MOCK_DMG" ]; then
  [ -f "$MOCK_DMG" ] || { echo "missing DMG fixture: $MOCK_DMG" >&2; exit 1; }
  printf 'not the pinned dmg' > "$work/bad.dmg"
  if MOCK_DMG="$work/bad.dmg" MIKO_CORE_URL='' bash "$work/action.sh" >"$work/dmg-hash.log" 2>&1; then echo 'bad DMG hash should fail' >&2; exit 1; fi
  grep -q 'FAILED' "$work/dmg-hash.log"
  MIKO_CORE_URL='' bash "$work/action.sh"
  echo 'CI runtime preparation: pinned DMG extraction verified'
fi
