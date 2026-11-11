#!/bin/bash
# Native player measurement. Only the harness observes counters; app behavior is unchanged.
# Live mode requires an already running disposable device in an explicit JIDR_HOME.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/jidr-swiftui/swift-target.sh"
export JIDR_BENCH_PROFILE="${JIDR_BENCH_PROFILE:-release}"
case "$JIDR_BENCH_PROFILE" in
  release) cargo_profile=(--release); swift_profile=(-O) ;;
  debug) cargo_profile=(--profile dev); swift_profile=(-Onone) ;;
  *) echo 'JIDR_BENCH_PROFILE must be release or debug' >&2; exit 2 ;;
esac
out="$root/target/swiftui-bench/$JIDR_BENCH_PROFILE"
mkdir -p "$out/module-cache"
if [[ "${1:-}" != "--self-test" && "${1:-}" != "--help" && "${1:-}" != "-h" ]]; then
  cargo build "${cargo_profile[@]}" -p jidr-swiftui-bridge --bin jidr-swiftui-bridge
fi
center_sources=()
for file in "$root"/apps/jidr-swiftui/Center/*.swift; do
  [[ "$(basename "$file")" == main.swift ]] && continue
  center_sources+=("$file")
done
# Reuse only an exact source/flags/compiler match, never a stale test executable.
export JIDR_BENCH_FONTS="$root/apps/jidr-swiftui/Resources/fonts"
fingerprint="$(python3 - "$root" "$JIDR_BENCH_PROFILE" <<'PYHASH'
import hashlib,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]); digest=hashlib.sha256(sys.argv[2].encode())
files=[*root.glob('apps/jidr-swiftui/Sources/*.swift'),*root.glob('apps/jidr-swiftui/Center/*.swift'),
       *root.glob('apps/jidr-swiftui/Resources/fonts/*')]
files += [root/name for name in ['apps/jidr-swiftui/Tests/Bench/main.swift','apps/jidr-swiftui/bench-player.sh',
          'apps/jidr-swiftui/swift-target.sh','packaging/swiftui/Jidr-Info.plist.in','Cargo.toml','Cargo.lock']]
for file in sorted(files):
 digest.update(str(file.relative_to(root)).encode()); digest.update(file.read_bytes())
digest.update(subprocess.check_output(['swiftc','--version']))
print(digest.hexdigest())
PYHASH
)"
if [[ ! -x "$out/jidr-swiftui-bench" || ! -f "$out/inputs.sha256" || "$(cat "$out/inputs.sha256")" != "$fingerprint" ]]; then
  swiftc "${swift_profile[@]}" -target "$jidr_swift_target" -module-cache-path "$out/module-cache" \
    apps/jidr-swiftui/Sources/*.swift "${center_sources[@]}" \
    apps/jidr-swiftui/Tests/Bench/main.swift -o "$out/jidr-swiftui-bench"
  printf '%s\n' "$fingerprint" > "$out/inputs.sha256"
fi
export JIDR_BENCH_INPUTS_SHA256="$fingerprint"
export JIDR_BENCH_REVISION="$(git rev-parse HEAD)"
if git diff --quiet HEAD --; then
  export JIDR_BENCH_DIRTY=false
else
  export JIDR_BENCH_DIRTY=true
fi
export JIDR_BENCH_BINARY_SHA256="$(shasum -a 256 "$out/jidr-swiftui-bench" | awk '{print $1}')"
bridge="$root/target/$JIDR_BENCH_PROFILE/jidr-swiftui-bridge"
if [[ -f "$bridge" ]]; then
  export JIDR_BENCH_BRIDGE_SHA256="$(shasum -a 256 "$bridge" | awk '{print $1}')"
else
  export JIDR_BENCH_BRIDGE_SHA256=unavailable
fi
exec "$out/jidr-swiftui-bench" --production-player --bridge "$bridge" "$@"
