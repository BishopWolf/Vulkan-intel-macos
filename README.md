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

Source order matters, and appending is not enough: MacPorts resolves a duplicated port
name to the **first** source in `sources.conf` (the header shipped in that file states
it, and the guide's "just append a `file://` line" recipe is for throwaway local
testing). The overlay therefore has to be the first line, with `[nosync]` so that
`port sync` does not try to git-pull the checkout:

```
file:///path/to/Vulkan-intel-macos/ports [nosync]
rsync://rsync.macports.org/macports/release/tarballs/ports.tar.gz [default]
```

`install.sh --add-source` rewrites the file that way, idempotently, and refuses to
continue if the overlay is registered but not first.

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
`vulkan-validationlayers`, and prints the resulting revision so the overlay is visibly
in effect. No `-s` is needed: `revision 1` has no binary archive, so MacPorts builds
exactly the three overlaid ports from source and still uses archives for their
dependencies.

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
- **`install`** — every push, pull request, `workflow_dispatch` and the weekly cron:
  does the real thing, a source build of `vulkan-tools`, `vulkan-validationlayers` and
  `MoltenVK` through the local overlay, then runs `tests/run_tests.sh` against the
  freshly installed stack.

It was originally restricted to `workflow_dispatch`/`schedule`, which is why pushes
reported it as **skipped** without running a step. A failing `portfiles` job skips it
too, through `needs`. The cost is real — MoltenVK plus the validation layers from
source is roughly half an hour — but a green `portfiles` never proved the ports build.

Details that each cost a CI run to learn:

- the actions must be `checkout@v6` / `upload-artifact@v7`. GitHub removed the Node 20
  runtime from hosted runners on 2026-09-23, so `@v4` fails with `Node 20 is not
  supported`, and `upload-artifact@v5` is still Node 20 — its first Node 24 major is v6;
- `PATH` is set at job level. The MacPorts installer adds `/opt/local/bin` through
  `/etc/paths.d`, which only applies to shells started afterwards; without the explicit
  `PATH`, the first `port` call after installing exits 127;
- the `file://` source is written as the **first** line of `sources.conf`, removing any
  previous copy of the entry, so a re-run cannot duplicate it either. Ordering, indexing
  and the sync fallbacks live in `scripts/register-overlay.sh`, which both jobs call;
- MacPorts base is cached by `.github/actions/macports-base`, a composite action both jobs
  use. It stores `/opt/local` as a tarball taken immediately after the base install —
  before `port sync` and before any port exists — keyed on runner OS, architecture, macOS
  major and MacPorts version, exact match only: a partial hit would leave an older base
  in place and re-save it under the newer version's key, so a MacPorts release instead
  rebuilds the cache once. The archive is `gzip -t`-checked before extracting and the
  restored base is smoke-tested with `port version`; either failure discards it and
  installs the `.pkg` instead. Nothing above the base is cached, so the ports tree and
  the built ports are never stale;
- `port sync` is the only network step, and the only thing that has failed for real: on
  the first cache-hit run it failed three attempts in a row. Registration retries it with
  backoff, then reinstalls the base from the `.pkg` (the restored base is what differs
  from a run that worked), then falls back to a shallow HTTPS clone of `macports-ports`
  indexed with `portindex` — that repository ships no `PortIndex`, and port 873 may
  simply be unreachable from the runner;
- every step traps `ERR` and annotates the failing command and its line. Actions logs are
  not readable without authentication, and the default annotation, `Process completed
  with exit code 1`, does not say what broke.

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
