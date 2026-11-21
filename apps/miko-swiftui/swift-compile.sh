#!/bin/bash
# Source after setting root; the caller supplies the output path and mode.
source "$root/apps/miko-swiftui/swift-target.sh"
miko_compile_swift() {
  local binary="$1" cache="$2" mode="$3"
  local -a flags=(-Onone)
  if [ "$mode" = release ]; then flags=(-O); fi
  mkdir -p "$cache"
  CLANG_MODULE_CACHE_PATH="$cache" swiftc "${flags[@]}" -target "$miko_swift_target" \
    -module-cache-path "$cache" \
    "$root"/apps/miko-swiftui/Sources/*.swift \
    "$root"/apps/miko-swiftui/Center/*.swift -o "$binary"
}
