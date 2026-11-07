#!/usr/bin/env bash
# The installed validation layer manifest must point at the layer library by absolute
# path, and that file must exist. This is the defect the vulkan-validationlayers
# overlay fixes in post-destroot.

set -uo pipefail

MP_PREFIX="${MP_PREFIX:-/opt/local}"
host_arch="$(uname -m)"
fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }

manifest=""
for candidate in "$MP_PREFIX/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json" \
                 "$HOME/.local/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json" \
                 /usr/local/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json; do
  if [ -f "$candidate" ]; then manifest="$candidate"; break; fi
done
[ -n "$manifest" ] || skip "VK_LAYER_KHRONOS_validation is not installed"

echo "manifest: $manifest"
library="$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest")"
[ -n "$library" ] || fail "no library_path in $manifest"
echo "library_path: $library"

case "$library" in
  /*) ;;
  *)  fail "library_path is relative. macOS does not dyld-search a bare name for dlopen(), so the loader cannot load the layer. Reinstall with the vulkan-validationlayers overlay (its post-destroot rewrites this to an absolute path)." ;;
esac

[ -f "$library" ] || fail "library_path names a file that does not exist: $library"

if command -v lipo >/dev/null 2>&1; then
  archs="$(lipo -archs "$library" 2>/dev/null || true)"
  echo "architectures: $archs"
  case " $archs " in
    *" $host_arch "*) ;;
    *) fail "layer library has no $host_arch slice (found: $archs), so the loader could not dlopen it" ;;
  esac
fi

echo "PASS: manifest uses an absolute, existing library_path with a $host_arch slice"
