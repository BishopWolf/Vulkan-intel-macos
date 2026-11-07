#!/usr/bin/env bash
# Expose the MacPorts Vulkan loader to code that dlopen()s "libvulkan.dylib" by name.
#
# MacPorts installs the loader in /opt/local/lib, which is not a dyld default search
# path. Programs that link libvulkan explicitly are fine (the port bakes in an rpath),
# but ctypes.util.find_library("vulkan"), many Python/Go/Rust bindings, and Vulkan
# builds from other prefixes all resolve by name and fail without this.
#
# /usr/local/lib is a dyld default path, is usually user-writable, and the LunarG
# installer uses the same place for its "system global" option. Symlinks target the
# stable libvulkan*.dylib names, so they survive loader upgrades.
#
# Idempotent. Usage: ./scripts/loader-symlinks.sh [--check]

set -euo pipefail

MP_PREFIX="${MP_PREFIX:-/opt/local}"
SYS_LIB_DIR="${SYS_LIB_DIR:-/usr/local/lib}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

fail() { echo "FAIL  $*" >&2; exit 1; }
ok() { echo "OK    $*"; }

VERSIONED="$(ls -1 "$MP_PREFIX"/lib/libvulkan.1.*.dylib 2>/dev/null | head -1 || true)"
[ -n "$VERSIONED" ] || fail "no libvulkan.1.*.dylib in $MP_PREFIX/lib (port install vulkan-loader)"

for name in libvulkan.dylib libvulkan.1.dylib "$(basename "$VERSIONED")"; do
  source="$(readlink "$MP_PREFIX/lib/$name" 2>/dev/null || echo "$MP_PREFIX/lib/$name")"
  target="$SYS_LIB_DIR/$name"
  if [ "$CHECK_ONLY" = "1" ]; then
    [ -e "$target" ] || fail "missing $target"
    ok "$target present"
  else
    mkdir -p "$SYS_LIB_DIR"
    ln -sfn "$source" "$target"
    ok "linked $target -> $source"
  fi
done

finder="$(command -v python3 || true)"
if [ -n "$finder" ]; then
  got="$("$finder" -c 'import ctypes.util; print(ctypes.util.find_library("vulkan") or "")')"
  [ -n "$got" ] || fail "find_library('vulkan') is still empty after linking"
  ok "find_library('vulkan') = $got"
fi
