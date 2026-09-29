#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
mkdir -p dist
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
for path in .gitignore .gitattributes README.md README.zh-CN.md install.sh bin lib systemd examples tunnel tests scripts docs payload; do
    cp -R "$path" "$stage/"
done
# The Native installer does not include macos/engine. Userspace-only builders
# and the disposable-VM harness belong to package-userspace.py, not this bundle.
rm -rf "$stage/tests/userspace"
rm -f "$stage/scripts/build-userspace-landing.sh" "$stage/scripts/package-userspace.py"
find "$stage" -type d -name __pycache__ -prune -exec rm -rf {} +
python3 scripts/check-public.py "$stage"
# USTAR stores no extended filesystem attributes; normalize owner metadata.
owner_flags=(--uid=0 --gid=0 --uname=root --gname=root)
if tar --version | grep -q 'GNU tar'; then
    owner_flags=(--owner=0 --group=0 --numeric-owner)
fi
COPYFILE_DISABLE=1 tar --format=ustar "${owner_flags[@]}" \
    -czf dist/mptcp-ab-switch.tar.gz -C "$stage" \
    .gitignore .gitattributes README.md README.zh-CN.md install.sh bin lib systemd examples tunnel tests scripts docs payload
python3 scripts/check-public.py dist/mptcp-ab-switch.tar.gz
cd dist
shasum -a 256 mptcp-ab-switch.tar.gz >mptcp-ab-switch.tar.gz.sha256
