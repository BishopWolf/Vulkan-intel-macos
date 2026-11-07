#!/usr/bin/env bash
# Stage ports/graphics/* into a checkout of macports/macports-ports as reviewable commits.
#
# Usage: ./scripts/prepare-macports-pr.sh /path/to/macports-ports [branch]
#
# macports-ports wants one commit per port, with a subject of the form
# "graphics/<port>: <what changed>", so this script copies each port directory over the
# checkout, lints it and commits it on its own. Nothing is pushed and no existing commit
# is amended; the branch is created from wherever the checkout currently is.
#
# Exit status: 0 staged, 1 lint or copy failed, 2 usage or unusable checkout.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-}"
branch="${2:-vulkan-intel-fixes}"

[ -n "$target" ] || { echo "usage: $0 /path/to/macports-ports [branch]" >&2; exit 2; }
[ -d "$target/graphics" ] || { echo "error: $target is not a macports-ports checkout (no graphics/)" >&2; exit 2; }
git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "error: $target is not a git checkout" >&2; exit 2; }
command -v port >/dev/null 2>&1 || { echo "error: 'port' not found; install MacPorts" >&2; exit 2; }
if [ -n "$(git -C "$target" status --porcelain)" ]; then
  echo "error: $target has local changes; commit or stash them first" >&2
  exit 2
fi

if git -C "$target" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
  git -C "$target" switch --quiet "$branch"
else
  git -C "$target" switch --quiet --create "$branch"
fi

subjects="vulkan-tools=fix uninitialised pLayeredApis sType in vulkaninfo
vulkan-validationlayers=install an absolute library_path in the layer manifest
vulkan-utility-libraries=build per architecture instead of noarch"

stage_port() {
  local port="$1" subject
  subject="$(printf '%s\n' "$subjects" | sed -n "s/^$port=//p")"

  rm -rf "${target:?}/graphics/$port"
  cp -R "$root/ports/graphics/$port" "$target/graphics/$port"

  echo "== $port"
  ( cd "$target/graphics/$port" && port lint --nitpick )

  git -C "$target" add "graphics/$port"
  if git -C "$target" diff --cached --quiet; then
    echo "   no difference from the checkout, nothing to commit"
    return 0
  fi
  git -C "$target" commit --quiet --message "graphics/$port: $subject"
  echo "   committed: graphics/$port: $subject"
}

for port in vulkan-tools vulkan-validationlayers vulkan-utility-libraries; do
  stage_port "$port"
done

echo "Staged on branch '$branch' in $target:"
git -C "$target" log --oneline --decorate -4
cat <<EOF

Next:
  git -C "$target" push --set-upstream origin $branch

then open a pull request against macports/macports-ports from that branch. The three
commits are independent: a reviewer can take one and ask for changes on the others.
EOF
