#!/bin/bash
# Register this checkout's ports/ overlay ahead of macports-ports on a CI runner.
#
# Ordering matters: MacPorts resolves a duplicate port name to the FIRST source listed
# in sources.conf (the file's own header says so), so the overlay is prepended.
# Appending it - the form the MacPorts guide shows for a throwaway local test - leaves
# macports-ports winning and every port resolving to revision 0.
#
# Usage: register-overlay.sh [macports-pkg-url]
# The URL is only used if 'port sync' cannot fetch the ports tree, to rebuild a base
# that may have been restored from the Actions cache in a broken state.
#
# MACPORTS_ROOT exists so this script can be exercised against a scratch tree.
set -euo pipefail

root="${MACPORTS_ROOT:-/opt/local}"
sources="$root/etc/macports/sources.conf"
ports_tree="$root/var/macports/sources/github.com/macports/macports-ports"
repo="$(cd "$(dirname "$0")/.." && pwd)"
overlay="file://$repo/ports [nosync]"
pkg_url="${1:-}"
tmp_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

# Annotations are the only channel this step has: raw Actions logs need auth, and a
# bare "Process completed with exit code 1" does not say which command died.
trap 'rc=$?; echo "::error::failed at line $LINENO (exit $rc): $BASH_COMMAND"' ERR

report() {
  # Collapse a captured multi-line error into one annotation; Actions only shows a
  # handful per step, and "%" would otherwise be read as an escape.
  printf '::warning::%s\n' "$(printf '%s' "$1" | tail -5 | sed 's/%/%25/g' | tr '\n' '~')"
}

sync_ports() {
  local out
  if out="$(sudo port sync 2>&1)"; then return 0; fi
  report "$1: $out"
  return 1
}

synced=0
for attempt in 1 2 3; do
  if sync_ports "port sync attempt $attempt failed"; then synced=1; break; fi
  sleep $((attempt * 15))
done

# A base restored from the cache is the one thing that differs from a run that worked,
# so rebuild it from the package before blaming the network.
if [ "$synced" != 1 ] && [ -n "$pkg_url" ]; then
  echo "::warning::sync keeps failing, reinstalling the MacPorts base from the package"
  curl -fsSL -o "$tmp_dir/macports.pkg" "$pkg_url"
  sudo installer -pkg "$tmp_dir/macports.pkg" -target /
  if sync_ports "port sync failed on a freshly installed base"; then synced=1; fi
fi

if [ "$synced" != 1 ]; then
  # Last resort: fetch the ports tree over HTTPS. macports-ports is a git repository
  # whose root doubles as a valid file:// source, so a shallow clone can stand in for
  # the rsync tree when port 873 is unreachable from the runner.
  echo "::warning::falling back to a shallow clone of macports-ports over HTTPS"
  sudo mkdir -p "$(dirname "$ports_tree")"
  sudo rm -rf "$ports_tree"
  sudo git clone --depth 1 --quiet https://github.com/macports/macports-ports.git "$ports_tree"
  if [ ! -f "$ports_tree/PortIndex" ]; then
    sudo portindex "$ports_tree" \
      || { echo "::error::cannot build a PortIndex for the cloned ports tree"; exit 1; }
  fi
  sudo sed -i '' "s|^rsync://[^[:space:]]*|file://$ports_tree|" "$sources"
fi

# Prepend the overlay, idempotently, leaving every other source untouched.
tmp="$(mktemp)"
{
  printf '%s\n' "$overlay"
  grep -vF "file://$repo/ports" "$sources" || true
} > "$tmp"
sudo tee "$sources" < "$tmp" >/dev/null
rm -f "$tmp"

grep -qF "$overlay" "$sources" \
  || { echo "::error::overlay entry missing from $sources after writing it"; exit 1; }
echo "--- sources.conf ---"
grep -nE '^file://|\[default\]' "$sources"

portindex -f "$repo/ports" \
  || { echo "::error::portindex rejected the overlay Portfiles"; exit 1; }
echo "overlay registered ahead of macports-ports"
