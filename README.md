# Interactive MPTCP Aggregation And Scheduling

[Full Chinese documentation](README.zh-CN.md)

## Publication Package

Run `bash scripts/package-public.sh` to build a checked, redistributable package
in `dist/`. This uses an explicit allowlist and scans both the staged files and
the archive. Local deployment reports and old archives are ignored by Git and
excluded from the package. Review changes before publication; automated pattern
checks supplement manual review and cannot identify every possible secret.

One package supports Edge, Relay and Landing, with independent Edge listener,
per-Relay public ports, Landing application port, timezone and A/B switch times.
The wizard defaults to always-on aggregation: all relays in GROUP_A can carry
subflows of the same TCP connection concurrently. MODE=scheduled retains A/B
calendar switching; a group/initial-target change restarts the Edge client.

## Always-On Aggregation

Use examples/aggregate-edge.conf and examples/aggregate-landing.conf, or select
aggregate in the wizard. Set MODE=aggregate, place 2-8 relays in GROUP_A, select
PRIMARY_A for the initial connection, and leave GROUP_B/PRIMARY_B empty.
LANDING_BACKEND selects the real TCP application behind the included server.
Both architectures use the same configuration and installer.

All aggregate relay addresses are advertised without the backup flag. The Linux
MPTCP scheduler decides how much data each subflow carries; this is not a fixed
50/50 split. The aggregate timer checks health every 60 seconds and contains no
OnCalendar entries. Old configurations without MODE keep scheduled behavior.
Primary failure may change the initial target and restart the client; low-load
traffic does not necessarily use every path. Validate received throughput and
per-subflow byte counters, not only connected subflow count.

Single-stream aggregation and failover were validated on Linux amd64/arm64.
See [validation scope](docs/VALIDATION.md) for methodology and limitations.

## Interactive Setup

Deploy Landing, then Relays, then Edge:

```bash
sudo ./install.sh
```

The menu offers install, reconfigure, plan, doctor and uninstall. The wizard asks
for role, default and per-Relay ports, Landing port, groups/primaries, timezone,
switch times (`HH:MM` or `HHMM`), local listener or forwarding destination,
interface, time synchronization, FQ and BBR. Invalid ports/IPs/times are retried.
An optional advanced step configures endpoint IDs, subflow/address limits and
Edge probe timeouts/retries. Reconfiguration preserves existing defaults, including
advanced values and disabled FQ/BBR. The health interval and tunnel connection
lifetime flags remain defined in the packaged systemd units.

```bash
sudo ./install.sh install --role landing --install-deps
sudo ./install.sh install --role relay --install-deps
sudo ./install.sh install --role edge --install-deps
./install.sh plan --role edge  # interactive preview without root
```

Edge/Landing need Linux MPTCP, systemd and recent iproute2. Relay needs Linux
forwarding and systemd. All roles use nftables and jq. Automatic dependency
installation supports Debian/Ubuntu via apt-get.

Landing can install the included MPTCP server and forward to LANDING_BACKEND
(IPv4:port), or use an external native IPPROTO_MPTCP application on LANDING_PORT.
For the included server, set LANDING_SERVICE=mptcp-port-tunnel-server.service.
The installer does not modify third-party application configuration.
Verify port 22000 with `ss -4 -H -lnM 'sport = :22000'`. Ordinary TCP listeners
are insufficient. The application and endpoints must share a network namespace.

Both Linux amd64 and arm64 binaries are built from the new Go source in tunnel/.
No previous tunnel binary is used. The installer selects the architecture and
verifies its checksum and CLI. Relay uses kernel NAT and needs no tunnel binary.
Rebuild with `MPTCP_GO=/path/to/go bash tunnel/build.sh` (Go 1.23+).
The client and server require negotiated native MPTCP and reject TCP fallback.
This is an IPv4 TCP tunnel, without added encryption/authentication or UDP support.
Use authenticated application protocols and restrict exposed ports as appropriate.
On Linux 6.1, MPTCP does not support TCP_USER_TIMEOUT. The program logs this once
and retains application write, idle and age limits; write timeout does not equal
the kernel's unacknowledged-data timeout. Build/source hashes and toolchain details
are in payload/SHA256SUMS, payload/SOURCE_SHA256SUMS and payload/BUILDINFO.

## Independent Ports

Example Edge/Landing config (change ROLE to landing on Landing):

```ini
ROLE=edge
LISTEN_ADDRESS=0.0.0.0:10029
RELAY_PORT=21000
RELAY_PORTS=192.0.2.1:21001,192.0.2.2:21002,192.0.2.3:31001
LANDING_PORT=22000
GROUP_A=192.0.2.1,192.0.2.2
PRIMARY_A=192.0.2.1
GROUP_B=192.0.2.3
PRIMARY_B=192.0.2.3
TIMEZONE=Asia/Hong_Kong
A_START=0830
B_START=2345
```

RELAY_PORTS overrides RELAY_PORT by IP. Each group supports 1-8 unique IPv4
addresses; groups cannot overlap. Both roles must use matching ports, groups,
primaries and schedules. Legacy configs inherit LANDING_PORT from RELAY_PORT.

Relay A1 config:

```ini
ROLE=relay
RELAY_LISTEN_ADDRESS=0.0.0.0
RELAY_PORT=21001
LANDING_ADDRESS=198.51.100.10
LANDING_PORT=22000
```

Replace documentation IPs with real addresses. A wildcard Relay listen address
matches all local destination addresses. With provider NAT, an explicit listen
address should be the local address after that NAT.

Landing advertises all aggregate Relay IPs (scheduled mode: secondaries), without
explicit endpoint ports. Edge
uses LANDING_PORT as the logical destination port for initial connections and
MP_JOIN subflows; nftables OUTPUT DNAT maps each Relay IP to its public port.
Relay DNAT/MASQUERADE forwards to the actual Landing listener. The active-server
file contains the logical port; plan/probe output shows public ports. Edge client
and mapping rules must share a network namespace.

Only owned ip mptcp_ab_edge and ip mptcp_ab_relay tables are replaced, using a
checked atomic nft batch. Foreign tables are rejected. Existing firewall DROP,
cloud security groups and conflicting NAT still need to allow traffic. Edge
mapping affects all local TCP to those Relay IP/logical-port combinations;
reserve them for the tunnel. Existing Relay forwarding can be kept instead of
installing this role, provided it matches the new ports and Landing target.

## Operation

```bash
sudo ./install.sh reconfigure
sudo ./install.sh reconfigure --config ./new.conf --non-interactive --yes
sudo mptcp-abctl doctor
sudo mptcp-abctl status
sudo mptcp-abctl probe A          # Edge
sudo mptcp-abctl probe B
sudo mptcp-abctl switch           # Edge/Landing, follow time
sudo mptcp-abctl switch --group B # override this invocation
sudo mptcp-abctl network-plan
sudo mptcp-abctl network-apply
```

Interactive reconfiguration uses installed settings as defaults. Use reconfigure
for port/group/schedule changes so network rules, client environment and timer
calendars update together. Config is strict KEY=VALUE in /etc/mptcp-ab/config.conf,
never evaluated as shell. See examples/ for all three roles.

Edge keeps a healthy current Relay, then tries primary and other group members.
FAIL_OPEN=yes tries primary if all probes fail; no retains the old target and
reports failure. Default schedule is A from 01:00 inclusive to 20:00 exclusive in
Hong Kong time, B otherwise. The timer checks about 60 seconds after each run.
Edge delays scheduled checks by 0.5 seconds; this is not cross-host coordination.
Boot, manual and scheduled switches without --group recheck time after probes.

Landing journals the prior state before updating endpoints. Interrupted switches
are recovered before the next switch or cleanup; foreign endpoints stay protected.
For a persistent manual override stop both timers, then switch Landing before Edge.
Relay forwards continuously and does not run a group timer.

## Migration And Removal

Use --migrate in a maintenance window to replace known legacy controllers of the
same role. It cannot combine with --no-start and does not restore all old services
on failure. File deployment is not a whole-host transaction; configuration/unit
backups are under /var/lib/mptcp-ab/backups/.

--no-start deploys/enables units and applies sysctl, but does not apply new network
rules or start the client/timer. Start mptcp-ab-network.service first, then bootstrap
(Edge/Landing), optional FQ, client (Edge) and timer (Edge/Landing). Changing a managed
Landing to another role requires immediate cleanup and cannot use --no-start.

```bash
sudo ./install.sh uninstall
sudo ./install.sh uninstall --purge
```

Removal cleans owned nftables tables, services and Landing endpoints, restores
original Landing limits if not changed externally and restores a replaced binary.
Default removal keeps configuration/state/backups; --purge deletes them. Live
sysctl (including forwarding), Edge limits and the original qdisc are not restored.

## Tests

```bash
bash tests/run.sh
expect tests/interactive.exp
```

Local tests cover config/ports/schedules, actual terminal interaction, Edge failover,
Landing interruption recovery, nftables ownership/lifecycle and binary checksums.
Network mocks require jq; terminal tests require expect. Real Linux verification
of systemd, nft syntax, MPTCP subflows, NAT and end-to-end traffic is still required.
