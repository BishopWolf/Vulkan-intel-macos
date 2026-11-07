#!/usr/bin/env bash
# Regression test for the vulkaninfo defect this repository patches.
#
# Unpatched vulkaninfo resizes VkPhysicalDeviceLayeredApiPropertiesListKHR::pLayeredApis
# but never sets the sType of the array elements it hands to
# vkGetPhysicalDeviceProperties2. With the validation layer enabled the loader reports,
# once per physical device:
#
#   vkGetPhysicalDeviceProperties2KHR(): pProperties->pNext
#       <VkPhysicalDeviceLayeredApiPropertiesListKHR>.pLayeredApis[0].sType
#       must be VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LAYERED_API_PROPERTIES_KHR
#
# The patch makes vulkaninfo a correct caller, so the message must be absent.

set -uo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }

VULKANINFO="${VULKANINFO:-$(command -v vulkaninfo || true)}"
[ -n "$VULKANINFO" ] || skip "vulkaninfo not installed (port install vulkan-tools)"
[ -x "$VULKANINFO" ] || fail "VULKANINFO=$VULKANINFO is not executable"

if ! "$VULKANINFO" --summary 2>&1 | grep -q VK_LAYER_KHRONOS_validation; then
  skip "VK_LAYER_KHRONOS_validation is not installed"
fi

# The bug is in the pNext chain handed to vkGetPhysicalDeviceProperties2, which is
# only reached once a physical device exists.
if [ "$(VK_INSTANCE_LAYERS= "$VULKANINFO" --summary 2>&1 | grep -cE '^[[:space:]]*GPU[0-9]+:' || true)" -lt 1 ]; then
  skip "no physical device enumerated, so the properties chain is never queried"
fi

output="$(VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation "$VULKANINFO" --summary 2>&1)"
status=$?

echo "$output" | grep -E 'deviceName|Khronos Validation Layer' | sed 's/^[[:space:]]*/      /'

if grep -q 'pLayeredApis\[0\]\.sType must be VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LAYERED_API_PROPERTIES_KHR' <<<"$output"; then
  fail "vulkaninfo is the unpatched build: it passes VkPhysicalDeviceLayeredApiPropertiesKHR elements without sType (VUID-VkPhysicalDeviceLayeredApiPropertiesKHR-sType-sType). Install the overlay's vulkan-tools port."
fi

if grep -q 'VUID-VkPhysicalDeviceLayeredApiPropertiesKHR-sType-sType' <<<"$output"; then
  fail "validation reported VUID-VkPhysicalDeviceLayeredApiPropertiesKHR-sType-sType"
fi

if grep -qE 'ERROR: \[Validation\]' <<<"$output"; then
  echo "$output" | grep -E 'ERROR: \[Validation\]' | head -5 | sed 's/^/      /'
  fail "unexpected validation errors while running vulkaninfo"
fi

echo "PASS: patched vulkaninfo runs clean under VK_LAYER_KHRONOS_validation (exit $status)"
