#!/usr/bin/env bash
# Install the fixed Vulkan stack (vulkaninfo + validation layers) from this overlay.
#
# Usage: ./scripts/install.sh [--add-source]
#   --add-source   append this repository to sources.conf if it is missing (sudo)
#
# Without --add-source the script checks sources.conf and prints the exact line to
# add, so nothing under /opt/local/etc is modified without being asked.
#
# Exit status: 0 installed, 1 prerequisite missing, 2 usage, 3 install failed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORTS="$ROOT/ports"
MP_PREFIX="${MP_PREFIX:-/opt/local}"
SOURCES_CONF_SYSTEM="/opt/local/etc/macports/sources.conf"
REPO_URL="file://$PORTS"

ADD_SOURCE=0
case "${1:-}" in
  --add-source) ADD_SOURCE=1 ;;
  "") ;;
  -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

fail() { echo "FAIL  $*" >&2; exit "${FAIL_CODE:-1}"; }
ok() { echo "OK    $*"; }

[ "$(uname -s)" = "Darwin" ] || fail "this overlay is macOS only"

# Abort on Apple Silicon: none of the three fixes applies there, and silently
# installing revision-bumped, patched ports into a working arm64 stack would only
# risk disturbing it.
if [ "$(uname -m)" != "x86_64" ]; then
  cat >&2 <<'EOF'
FAIL  this repository is Intel (x86_64) macOS only; refusing to touch this system.

      On Apple Silicon the MacPorts stack is already correct: the
      vulkan-utility-libraries archives match the host architecture, the validation
      layer manifest loads through dyld's default search paths, and vulkaninfo is a
      universal binary that does not hit the pLayeredApis sType bug.
EOF
  exit 1
fi

command -v port >/dev/null 2>&1 || fail "MacPorts 'port' not found; install MacPorts 2.12 or newer"
command -v portindex >/dev/null 2>&1 || fail "portindex not found (comes with MacPorts base)"
[ -d "$PORTS" ] || fail "no ports directory at $PORTS"

# Locate sources.conf: honour a non-default prefix when MacPorts is installed there.
SOURCES_CONF="$SOURCES_CONF_SYSTEM"
if [ ! -f "$SOURCES_CONF" ]; then
  SOURCES_CONF="$MP_PREFIX/etc/macports/sources.conf"
fi
[ -f "$SOURCES_CONF" ] || fail "cannot find sources.conf (looked in /opt/local/etc/macports)"

echo "Indexing $PORTS"
portindex "$PORTS" || fail "portindex rejected the Portfiles in $PORTS"
[ -f "$PORTS/PortIndex" ] || fail "portindex did not produce $PORTS/PortIndex"
ok "PortIndex built ($(grep -c '^vulkan-' "$PORTS/PortIndex" || true) vulkan entries)"

# A plain file:// entry outranks the [default] macports-ports entry, which is what
# makes the revision-bumped overlays win for the same port names.
if grep -qF "$REPO_URL" "$SOURCES_CONF"; then
  ok "overlay already registered in $SOURCES_CONF"
elif [ "$ADD_SOURCE" = "1" ]; then
  echo "$REPO_URL" | sudo tee -a "$SOURCES_CONF" >/dev/null
  ok "registered overlay in $SOURCES_CONF"
else
  cat <<EOF
FAIL  the overlay is not registered, so 'port install vulkan-tools' would build the
      unpatched macports-ports version.

      Add this line to $SOURCES_CONF:

          $REPO_URL

      then re-run, or let the script do it:  ./scripts/install.sh --add-source
EOF
  exit 1
fi

echo
echo "Installing vulkan-tools and vulkan-validationlayers"
# No -s on purpose: the overlays are revision 1, for which no binary archive exists,
# so MacPorts has to build exactly these from source. -s would also rebuild every
# dependency (python314, cmake, glslang, spirv-tools) from source for no benefit.
FAIL_CODE=3
sudo port -N -v install vulkan-tools vulkan-validationlayers || fail "port install failed"

echo
for portname in vulkan-tools vulkan-validationlayers vulkan-utility-libraries; do
  # 'port -q installed' indents each line, hence the [active] match rather than ^name.
  if port -q installed "$portname" 2>/dev/null | grep -q 'active'; then
    ok "$(port -q installed "$portname" | grep active | sed 's/^ *//')"
  else
    fail "$portname is not installed/active"
  fi
done

cat <<'EOF'

Installed. Next:
  ./tests/run_tests.sh              # loader, manifest, layer load, vulkaninfo regression
  ./scripts/loader-symlinks.sh      # only if something dlopen()s "libvulkan.dylib"
EOF
