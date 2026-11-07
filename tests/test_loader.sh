#!/usr/bin/env bash
# The loader must be discoverable the way applications look for it, and must be able
# to enumerate at least one physical device.

set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }

command -v python3 >/dev/null 2>&1 || skip "python3 not available for the find_library probe"

python3 - <<'PY' || fail "ctypes could not load the Vulkan loader"
import ctypes, ctypes.util, sys

name = ctypes.util.find_library("vulkan")
if not name:
    print("FAIL: ctypes.util.find_library('vulkan') returned nothing", file=sys.stderr)
    sys.exit(1)
ctypes.CDLL(name)
print(f"PASS: find_library('vulkan') = {name}")
PY

command -v vulkaninfo >/dev/null 2>&1 || skip "vulkaninfo not installed (port install vulkan-tools)"

output="$(vulkaninfo --summary 2>&1)" || fail "vulkaninfo failed to initialise the loader:
$output"
devices="$(grep -cE '^[[:space:]]*GPU[0-9]+:' <<<"$output" || true)"
[ "$devices" -ge 1 ] || skip "no physical device enumerated (is an ICD such as MoltenVK installed?)"

echo "PASS: $devices device(s) enumerated"
grep -E "deviceName|driverName" <<<"$output" | sed 's/^[[:space:]]*/      /'
