#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GO=${MPTCP_GO:-go}
export CGO_ENABLED=0 GOTOOLCHAIN=local
cd "$ROOT/tunnel"
version=2026.09.05
for arch in amd64 arm64; do
    mkdir -p "$ROOT/payload/linux-$arch"
    GOOS=linux GOARCH=$arch "$GO" build -trimpath -buildvcs=false \
        -ldflags="-s -w -buildid= -X main.version=$version" \
        -o "$ROOT/payload/linux-$arch/mptcp-port-tunnel" .
done
cd "$ROOT/payload"
shasum -a 256 linux-amd64/mptcp-port-tunnel linux-arm64/mptcp-port-tunnel >SHA256SUMS
cd "$ROOT"
shasum -a 256 tunnel/go.mod tunnel/*.go tunnel/build.sh >payload/SOURCE_SHA256SUMS
"$GO" version >payload/BUILDINFO
printf 'version=%s\nCGO_ENABLED=0\nGOOS=linux\nGOARCH=amd64,arm64\n' "$version" >>payload/BUILDINFO
"$GO" version
