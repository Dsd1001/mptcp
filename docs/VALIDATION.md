# Validation Scope

The installer and source-built TCP tunnel have been exercised on Linux amd64
and arm64 with a native MPTCP-capable kernel. Published examples and test
fixtures use documentation-only addresses, loopback or wildcard addresses.

Functional checks covered:

- Interactive installation, reconfiguration and invalid-input handling.
- Independent Edge, per-Relay and Landing ports.
- Native MPTCP negotiation and rejection of ordinary TCP fallback.
- Bidirectional integrity, half-close, timeouts and cancellation.
- Multiple Relay subflows carrying the same TCP data connection.
- Short, rate-capped single-Relay versus dual-Relay throughput comparisons.
- Path interruption, failed target selection and scheduled group changes.
- Ownership checks, atomic network replacement and recovery of Landing state.

Dual-path receiver throughput exceeded either individual-path baseline in the
bounded comparison. This is functional evidence, not a sustained throughput or
availability guarantee. Results depend on path capacities, latency, congestion,
kernel scheduling and provider traffic policy.

Raw host inventories, addresses, account details, socket tokens, timestamps,
application inventories and deployment logs are intentionally not published.

Run local regression checks with `bash tests/run.sh`. Tunnel checks require a
Go toolchain: `cd tunnel && go test -race ./... && go vet ./...`.

Before production use, validate the actual network and backend under an
appropriate traffic budget. The tunnel carries IPv4 TCP and adds no encryption
or authentication. The kernel's MPTCP settings are shared within a network
namespace. A controller change of the initial Relay can restart the Edge
client and interrupt connections.
