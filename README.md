# Vulkan-intel-macos

A MacPorts local port overlay that installs a **working Vulkan development stack on
Intel Macs**, plus the tests and GitHub Actions that prove it.

Apple stopped shipping Intel Macs and GitHub is retiring its x86_64 runners in
August 2027, so the Intel + MacPorts combination is increasingly untested upstream.
Three concrete defects show up on that combination, and this repository fixes all
three at install time:

| # | Defect | Symptom | Fix here |
| --- | --- | --- | --- |
| 1 | `vulkan-utility-libraries` ships `arm64`-only static archives in the MacPorts binary archive (it is a `noarch` port, so nothing flags the mismatch) | `vulkan-validationlayers` fails to link: `ignoring file 'libVulkanSafeStruct.a' ... found architecture 'arm64', required architecture 'x86_64'` | local `Portfile` with a revision bump, so the x86_64 build happens from source |
| 2 | Validation layer manifest uses a bare `library_path` (`libVkLayer_khronos_validation.dylib`) | loader fails to `dlopen` the layer on macOS: `dlopen(libVkLayer_khronos_validation.dylib, 0x0005): no such file`, and a `/usr/local/lib` symlink does **not** help | `post-destroot` rewrites the manifest to an absolute path |
| 3 | `vulkaninfo` never initialises `pLayeredApis[i].sType` | with `VK_LAYER_KHRONOS_validation` enabled every run reports `vkGetPhysicalDeviceProperties2KHR(): pProperties->pNext<VkPhysicalDeviceLayeredApiPropertiesListKHR>.pLayeredApis[0].sType must be VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LAYERED_API_PROPERTIES_KHR` for each device | patch to `vulkaninfo/generated/vulkaninfo.hpp` in the port |

All three are reproducible on the pinned versions in this repository
(Vulkan 1.4.363, MoltenVK 1.4.2, MacPorts 2.12.x) and none of them are caused by
local configuration.

## Why a port and not install scripts

Defects 1 and 2 live in the *installed files* of two ports, so the durable place to
fix them is the ports themselves. MacPorts also matches prebuilt binary archives on
name + version + **revision** + variant: a plain copy of the upstream `Portfile` with
a `patchfiles-append` would still be satisfied by the official archive and silently
skip the patch. Every port here therefore carries `revision 1`. Because no archive
exists for that revision, MacPorts builds it from source.

`sources.conf` gives `[default]` entries the *lowest* priority, so adding this repo
as a plain `file://` entry is enough for it to override `macports-ports` for the
three port names it provides.

## Requirements

- **Intel (`x86_64`) Mac.** `scripts/install.sh` and `tests/run_tests.sh` abort with a
  non-zero status on Apple Silicon: none of the three defects exists there, so
  installing patched, revision-bumped ports would only disturb a working arm64 stack.
- macOS 13 or newer. Verified on macOS 15.
- MacPorts 2.12.x (`port version`), with a ports tree (`sudo port sync`).
- Xcode command line tools (`xcode-select --install`).

MacPorts only. There is no Homebrew path, because Homebrew no longer supports Intel
macOS.

## Install

```bash
git clone https://github.com/<you>/Vulkan-intel-macos
cd Vulkan-intel-macos

./scripts/install.sh            # shows the one-line sources.conf change if missing
./scripts/install.sh --add-source   # adds it for you (needs sudo), then installs
```

`install.sh` indexes the local repo, installs `vulkan-tools` and
`vulkan-validationlayers` **from source** (`port -s`), and prints the resulting
revision so the overlay is visibly in effect.

Optional, only for applications that `dlopen("libvulkan.dylib")` by name instead of
linking with an rpath (Python `ctypes`, some Go/Rust bindings, `vulkaninfo` builds
from other prefixes):

```bash
./scripts/loader-symlinks.sh    # /usr/local/lib/libvulkan*.dylib -> /opt/local/lib, no sudo
```

## Test

```bash
./tests/run_tests.sh
```

| Test | Asserts |
| --- | --- |
| `test_loader.sh` | `ctypes.util.find_library("vulkan")` resolves, the loader can be loaded, and `vulkaninfo` enumerates at least one device |
| `test_layer_manifest.sh` | `VkLayer_khronos_validation.json` exists, has a **absolute** `library_path`, and the file it names exists |
| `test_layer_loads.sh` | with `VK_LOADER_DEBUG=layer`, the loader logs `Loading layer library ...` and never logs a `dlopen` failure |
| `test_vulkaninfo_clean.sh` | with the validation layer enabled, `vulkaninfo --summary` emits no `pLayeredApis[0].sType` / `VUID-VkPhysicalDeviceLayeredApiPropertiesKHR-sType-sType` error — the regression test for defect 3 |

Exit codes are `0` pass, `1` fail, `77` skip (missing `vulkaninfo`, or no physical
device because no ICD such as MoltenVK is installed). `run_tests.sh` exits non-zero
if anything failed and reports skips separately rather than counting them as passes.

## GitHub Actions

`.github/workflows/ci.yml`, on `macos-15-intel` (the last x86_64 runner image,
available until August 2027):

- **`portfiles`** — every push/PR: installs MacPorts base from the latest official
  `.pkg`, indexes this overlay with `portindex`, and asserts that each overridden port
  is parsed with the expected `revision` and that no checksum/patch entry is missing.
  This catches Portfile syntax errors without a 30-minute build.
- **`install`** — `workflow_dispatch` and weekly: does the real thing, a source build
  of `vulkan-tools`, `vulkan-validationlayers` and `MoltenVK` through the local
  overlay, then runs `tests/run_tests.sh` against the freshly installed stack.

The full build job is deliberately not on every push: building MoltenVK plus the
validation layers from source takes around half an hour.

Two CI details that cost a run each to learn:

- the actions must be `checkout@v6` / `upload-artifact@v7`. GitHub removed the Node 20
  runtime from hosted runners on 2026-09-23, so `@v4` fails with `Node 20 is not
  supported`, and `upload-artifact@v5` is still Node 20 — its first Node 24 major is v6;
- `PATH` is set at job level. The MacPorts installer adds `/opt/local/bin` through
  `/etc/paths.d`, which only applies to shells started afterwards; without the explicit
  `PATH`, the first `port` call after installing exits 127.

## Verified results

On a real Intel Mac (macOS 15, MacPorts 2.12.7, Vulkan 1.4.363, MoltenVK 1.4.2,
AMD Radeon Pro 560X + Intel UHD 630), before and after:

```
# before
dlopen(libVkLayer_khronos_validation.dylib, 0x0005): no such file
ERROR: [Validation] ... pLayeredApis[0].sType must be VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LAYERED_API_PROPERTIES_KHR

# after
[Vulkan Loader] DEBUG | LAYER:  Loading layer library /opt/local/lib/libVkLayer_khronos_validation.dylib
VK_LAYER_KHRONOS_validation Khronos Validation Layer 1.4.363  version 1
deviceName = AMD Radeon Pro 560X
deviceName = Intel(R) UHD Graphics 630
```

## Limitations

- The `vulkaninfo` patch is pinned to Vulkan 1.4.363.0. Upstream still has the bug on
  `main`, so re-check the anchor when bumping the port; the patch fails loudly instead
  of applying to the wrong place (`patch.pre_args -p1` against the generated header).
- Validation layers are optional for running Vulkan; they only add API debugging.
  TorchVulkan/Slicer (the original motivation for this) do not depend on them.
- MoltenVK, the ICD on macOS, is installed by MacPorts as a dependency of the loader;
  this repository does not fork it.
- GitHub removes the last x86_64 runner image in August 2027; after that point the CI
  has to move to a self-hosted Intel Mac or the repo becomes local-only.

## License

MIT for the scripts, tests and Portfiles. The patched `vulkaninfo` source and the
port metadata are Apache-2.0, from KhronosGroup/Vulkan-Tools and macports-ports.
