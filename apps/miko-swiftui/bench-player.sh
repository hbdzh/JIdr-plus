#!/bin/bash
# Native player measurement. Only the harness observes counters; app behavior is unchanged.
# Live mode requires an already running disposable device in an explicit MIKO_HOME.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
source "$root/apps/miko-swiftui/swift-target.sh"
export MIKO_BENCH_PROFILE="${MIKO_BENCH_PROFILE:-release}"
case "$MIKO_BENCH_PROFILE" in
  release) cargo_profile=(--release); swift_profile=(-O) ;;
  debug) cargo_profile=(--profile dev); swift_profile=(-Onone) ;;
  *) echo 'MIKO_BENCH_PROFILE must be release or debug' >&2; exit 2 ;;
esac
out="$root/target/swiftui-bench/$MIKO_BENCH_PROFILE"
mkdir -p "$out/module-cache"
if [[ "${1:-}" != "--self-test" && "${1:-}" != "--help" && "${1:-}" != "-h" ]]; then
  cargo build "${cargo_profile[@]}" -p miko-swiftui-bridge --bin miko-swiftui-bridge
fi
center_sources=()
for file in "$root"/apps/miko-swiftui/Center/*.swift; do
  [[ "$(basename "$file")" == main.swift ]] && continue
  center_sources+=("$file")
done
# Reuse only an exact source/flags/compiler match, never a stale test executable.
export MIKO_BENCH_FONTS="$root/apps/miko-swiftui/Resources/fonts"
fingerprint="$(python3 - "$root" "$MIKO_BENCH_PROFILE" <<'PYHASH'
import hashlib,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]); digest=hashlib.sha256(sys.argv[2].encode())
files=[*root.glob('apps/miko-swiftui/Sources/*.swift'),*root.glob('apps/miko-swiftui/Center/*.swift'),
       *root.glob('apps/miko-swiftui/Resources/fonts/*')]
files += [root/name for name in ['apps/miko-swiftui/Tests/Bench/main.swift','apps/miko-swiftui/bench-player.sh',
          'apps/miko-swiftui/swift-target.sh','packaging/swiftui/Miko-Info.plist.in','Cargo.toml','Cargo.lock']]
for file in sorted(files):
 digest.update(str(file.relative_to(root)).encode()); digest.update(file.read_bytes())
digest.update(subprocess.check_output(['swiftc','--version']))
print(digest.hexdigest())
PYHASH
)"
if [[ ! -x "$out/miko-swiftui-bench" || ! -f "$out/inputs.sha256" || "$(cat "$out/inputs.sha256")" != "$fingerprint" ]]; then
  swiftc "${swift_profile[@]}" -target "$miko_swift_target" -module-cache-path "$out/module-cache" \
    apps/miko-swiftui/Sources/*.swift "${center_sources[@]}" \
    apps/miko-swiftui/Tests/Bench/main.swift -o "$out/miko-swiftui-bench"
  printf '%s\n' "$fingerprint" > "$out/inputs.sha256"
fi
export MIKO_BENCH_INPUTS_SHA256="$fingerprint"
export MIKO_BENCH_REVISION="$(git rev-parse HEAD)"
if git diff --quiet HEAD --; then
  export MIKO_BENCH_DIRTY=false
else
  export MIKO_BENCH_DIRTY=true
fi
export MIKO_BENCH_BINARY_SHA256="$(shasum -a 256 "$out/miko-swiftui-bench" | awk '{print $1}')"
bridge="$root/target/$MIKO_BENCH_PROFILE/miko-swiftui-bridge"
if [[ -f "$bridge" ]]; then
  export MIKO_BENCH_BRIDGE_SHA256="$(shasum -a 256 "$bridge" | awk '{print $1}')"
else
  export MIKO_BENCH_BRIDGE_SHA256=unavailable
fi
exec "$out/miko-swiftui-bench" --production-player --bridge "$bridge" "$@"
