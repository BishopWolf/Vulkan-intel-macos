# Vulkan-intel-macos

A MacPorts local port overlay that installs a **working Vulkan development stack on
Intel Macs**, plus the tests and GitHub Actions that prove it.

Apple stopped shipping Intel Macs and GitHub is retiring its x86_64 runners in
August 2027, so the Intel + MacPorts combination is increasingly untested upstream.
Three concrete defects show up on that combination, and this repository fixes all
three at install time:

| # | Defect | Symptom | Fix here |
| --- | --- | --- | --- |
| 1 | `vulkan-utility-libraries` ships `arm64`-only static archives in the MacPorts binary archive (it is a `noarch` port, so nothing flags the mismatch) | `vulkan-validationlayers` fails to link: `ignoring file 'libVulkanSafeStruct.a' ... found architecture 'arm64', required architecture 'x86_64'` | `supported_archs noarch` dropped in the port, so the archive is built and cached per architecture |
| 2 | Validation layer manifest uses a bare `library_path` (`libVkLayer_khronos_validation.dylib`) | loader fails to `dlopen` the layer on macOS: `dlopen(libVkLayer_khronos_validation.dylib, 0x0005): no such file`, and a `/usr/local/lib` symlink does **not** help | `layers/CMakeLists.txt` patched so the install manifest is generated with an absolute `library_path` |
| 3 | `vulkaninfo` never initialises `pLayeredApis[i].sType` | with `VK_LAYER_KHRONOS_validation` enabled every run reports `vkGetPhysicalDeviceProperties2KHR(): pProperties->pNext<VkPhysicalDeviceLayeredApiPropertiesListKHR>.pLayeredApis[0].sType must be VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LAYERED_API_PROPERTIES_KHR` for each device | patch to `vulkaninfo/generated/vulkaninfo.hpp`, the generated source the build compiles |

All three are reproducible on the pinned versions in this repository
(Vulkan 1.4.363, MoltenVK 1.4.2, MacPorts 2.12.x) and none of them are caused by
local configuration.

## Why Portfile changes, and how they are published

All three defects live in files that a port installs, so the durable fix is in the ports
— and all three target ports already exist in `macports-ports`. This repository is
therefore both a local overlay and the patch set for an upstream pull request:
`ports/graphics/<port>` is the upstream `Portfile` with only the change under review
added, nothing else reformatted. `port lint --nitpick` reports 0 errors and 0 warnings on
all three.

`revision 1` is part of the change, not a local trick. It is what MacPorts asks for when
a port's installed files change, and it has a useful side effect: binary archives are
matched on name + version + revision + variant, so no existing archive can satisfy the
patched ports and both CI and a local `port install` build them from source.

Two of the three need a patch file. Both are `-p0` diffs against the release tarball,
which is what MacPorts applies by default:

| Port | Patch | Why there |
| --- | --- | --- |
| `vulkan-tools` | `vulkaninfo/generated/vulkaninfo.hpp` | the build compiles this checked-in generated source; the `TOOLS_CODEGEN` target is off by default and not part of the default build |
| `vulkan-validationlayers` | `layers/CMakeLists.txt` | the install-time manifest is produced by `configure_file`, so fixing the template input fixes every install rather than one destroot |

The overlay still has to be the **first** source in `sources.conf`: MacPorts resolves a
duplicated port name to the first source (the header shipped in that file states it, and
the guide's "just append a `file://` line" recipe is for throwaway local testing).
`install.sh --add-source` writes it that way, idempotently, and refuses to continue if
the overlay is registered but not first.

## Publishing to MacPorts

```bash
# 1. fork https://github.com/macports/macports-ports and clone your fork at master
git clone https://github.com/<you>/macports-ports
# 2. stage this repository's ports over it: copies each port, lints it, one commit per port
./scripts/prepare-macports-pr.sh ../macports-ports
# 3. push the branch and open the pull request
git -C ../macports-ports push --set-upstream origin vulkan-intel-fixes
```

The script creates one commit per port, in the subject format `macports-ports` asks for:

```
graphics/vulkan-tools: fix uninitialised pLayeredApis sType in vulkaninfo
graphics/vulkan-validationlayers: install an absolute library_path in the layer manifest
graphics/vulkan-utility-libraries: build per architecture instead of noarch
```

They are independent, so a reviewer can take one and ask for changes on another. Each
claim needs its evidence in the pull request: the `vulkaninfo` VUID before and after, the
loader's `dlopen` failure for the bare manifest name on an Intel Mac, and the
`ld: found architecture 'arm64', required architecture 'x86_64'` failure a noarch archive
causes. All three are in *Verified results* below and in `tests/run_tests.sh`.

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
  use — but it caches the official `.pkg` **download**, not an installed `/opt/local`,
  keyed on runner OS, architecture, macOS major and MacPorts version (exact match, no
  `restore-keys`). Caching a snapshot of the installed base was tried first and is wrong:
  the installer also creates the `macports` system user (uid 502, group 501, home
  `/opt/local/var/macports/home`), so a restored snapshot contains files owned by a user
  that does not exist on a fresh runner, and the first privilege drop dies with
  `port sync failed: Unknown user given`. Installing from the cached package takes about
  half a minute and always produces a complete base, which `port version` then confirms.
  Nothing above the base is cached, so the ports tree and the built ports are never stale;
- every push lints the three Portfiles with `port lint --nitpick` and dry-runs both
  patches against the pinned release tarballs, so a submission cannot rot between
  releases: a stale patch fails the job instead of surfacing in review;
- `port sync` is the only network step left. Registration retries it with backoff and, if
  it still fails, falls back to a shallow HTTPS clone of `macports-ports` indexed with
  `portindex` — that repository ships no `PortIndex`, and port 873 may simply be
  unreachable from the runner;
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
  `main`, so re-check the anchor when bumping the port; `patch` applies it with the
  default `-p0` and fails loudly on a context mismatch instead of patching something
  else. `scripts/generators/vulkaninfo_generator.py` has the same omission, so a fix
  there would let the patch be dropped.
- Validation layers are optional for running Vulkan; they only add API debugging.
  TorchVulkan/Slicer (the original motivation for this) do not depend on them.
- MoltenVK, the ICD on macOS, is installed by MacPorts as a dependency of the loader;
  this repository does not fork it.
- GitHub removes the last x86_64 runner image in August 2027; after that point the CI
  has to move to a self-hosted Intel Mac or the repo becomes local-only.

## License

MIT for the scripts, tests and Portfiles. The patched `vulkaninfo` source and the
port metadata are Apache-2.0, from KhronosGroup/Vulkan-Tools and macports-ports.
