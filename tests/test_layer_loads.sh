#!/usr/bin/env bash
# The loader must actually load the validation layer, not merely list it in
# vulkaninfo --summary. This catches dlopen-level problems such as a manifest that
# names the library without a path, or a layer built for the wrong architecture.

set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }

command -v vulkaninfo >/dev/null 2>&1 || skip "vulkaninfo not installed (port install vulkan-tools)"

if ! vulkaninfo --summary 2>&1 | grep -q VK_LAYER_KHRONOS_validation; then
  skip "VK_LAYER_KHRONOS_validation is not installed"
fi

probe="$(mktemp "${TMPDIR:-/tmp}/vk_layer_loads.XXXXXX")"
trap 'rm -f "$probe"' EXIT

VK_LOADER_DEBUG=layer VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
  vulkaninfo --summary >"$probe" 2>&1
status=$?

if grep -qiE 'dlopen\(.*(no such file|image not found|not valid for use in process)' "$probe"; then
  grep -iE 'dlopen' "$probe" | head -3 | sed 's/^/      /'
  fail "the loader could not load the validation layer (see above)"
fi

grep -qE 'Loading layer library .*libVkLayer_khronos_validation\.dylib' "$probe" || {
  tail -20 "$probe" | sed 's/^/      /'
  fail "the loader never logged 'Loading layer library ... libVkLayer_khronos_validation.dylib'"
}

echo "PASS: loader loaded the validation layer (vulkaninfo exit $status)"
grep -E 'Loading layer library' "$probe" | tail -1 | sed 's/^[[:space:]]*/      /'
