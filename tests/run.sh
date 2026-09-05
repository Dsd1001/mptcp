#!/usr/bin/env bash

set -u

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CTL=$ROOT_DIR/bin/mptcp-abctl
LIB=$ROOT_DIR/lib/mptcp-ab-lib.sh
TEMP_DIR=$(mktemp -d)
PASS=0
FAIL=0
trap 'rm -rf "$TEMP_DIR"' EXIT

pass()
{
    PASS=$((PASS + 1))
    printf 'ok %d - %s\n' "$PASS" "$1"
}

fail()
{
    FAIL=$((FAIL + 1))
    printf 'not ok - %s\n' "$1" >&2
}

run_ctl()
{
    MPTCP_AB_SKIP_ZONEINFO=1 \
    MPTCP_AB_LIB=$LIB \
    MPTCP_AB_CONFIG_FILE=$1 \
        "$CTL" "${@:2}"
}

expect_output()
{
    local name=$1
    local expected=$2
    shift 2
    local output rc
    output=$("$@" 2>/dev/null)
    rc=$?
    if [[ $rc -eq 0 && $output == "$expected" ]]; then
        pass "$name"
    else
        fail "$name (rc=$rc output='$output' expected='$expected')"
    fi
}

expect_failure()
{
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$name (unexpected success)"
    else
        pass "$name"
    fi
}

EDGE_CONFIG=$TEMP_DIR/edge.conf
LANDING_CONFIG=$TEMP_DIR/landing.conf
cp "$ROOT_DIR/examples/edge.conf" "$EDGE_CONFIG"
cp "$ROOT_DIR/examples/landing.conf" "$LANDING_CONFIG"

if run_ctl "$EDGE_CONFIG" validate-config "$EDGE_CONFIG" >/dev/null; then
    pass 'valid Edge configuration'
else
    fail 'valid Edge configuration'
fi

expect_output '00:59 is group B' B run_ctl "$EDGE_CONFIG" current-group 0059
expect_output '01:00 is group A' A run_ctl "$EDGE_CONFIG" current-group 0100
expect_output '19:59 is group A' A run_ctl "$EDGE_CONFIG" current-group 1959
expect_output '20:00 is group B' B run_ctl "$EDGE_CONFIG" current-group 2000

WRAP_CONFIG=$TEMP_DIR/wrap.conf
sed -e 's/^A_START=.*/A_START=2000/' -e 's/^B_START=.*/B_START=0100/' "$EDGE_CONFIG" >"$WRAP_CONFIG"
expect_output 'wrapped schedule before midnight is A' A run_ctl "$WRAP_CONFIG" current-group 2359
expect_output 'wrapped schedule after midnight is A' A run_ctl "$WRAP_CONFIG" current-group 0059
expect_output 'wrapped schedule daytime is B' B run_ctl "$WRAP_CONFIG" current-group 1200

BAD_IP=$TEMP_DIR/bad-ip.conf
sed 's/192\.0\.2\.11/999.0.2.11/' "$EDGE_CONFIG" >"$BAD_IP"
expect_failure 'invalid IPv4 is rejected' run_ctl "$BAD_IP" validate-config "$BAD_IP"

DUPLICATE=$TEMP_DIR/duplicate.conf
sed 's/GROUP_A=.*/GROUP_A=192.0.2.11,192.0.2.11/' "$EDGE_CONFIG" >"$DUPLICATE"
expect_failure 'duplicate relay is rejected' run_ctl "$DUPLICATE" validate-config "$DUPLICATE"

CROSS_GROUP=$TEMP_DIR/cross-group.conf
sed 's/GROUP_B=.*/GROUP_B=192.0.2.11,198.51.100.21/' "$EDGE_CONFIG" >"$CROSS_GROUP"
expect_failure 'cross-group relay is rejected' run_ctl "$CROSS_GROUP" validate-config "$CROSS_GROUP"

BAD_PRIMARY=$TEMP_DIR/bad-primary.conf
sed 's/^PRIMARY_A=.*/PRIMARY_A=203.0.113.1/' "$EDGE_CONFIG" >"$BAD_PRIMARY"
expect_failure 'primary outside its group is rejected' run_ctl "$BAD_PRIMARY" validate-config "$BAD_PRIMARY"

TOO_MANY=$TEMP_DIR/too-many.conf
sed 's/^GROUP_A=.*/GROUP_A=203.0.113.1,203.0.113.2,203.0.113.3,203.0.113.4,203.0.113.5,203.0.113.6,203.0.113.7,203.0.113.8,203.0.113.9/; s/^PRIMARY_A=.*/PRIMARY_A=203.0.113.1/' "$EDGE_CONFIG" >"$TOO_MANY"
expect_failure 'a ninth relay is rejected' run_ctl "$TOO_MANY" validate-config "$TOO_MANY"

BAD_DELAY=$TEMP_DIR/bad-delay.conf
sed 's/^EDGE_SWITCH_DELAY=.*/EDGE_SWITCH_DELAY=60.01/' "$EDGE_CONFIG" >"$BAD_DELAY"
expect_failure 'an Edge delay over 60 seconds is rejected' run_ctl "$BAD_DELAY" validate-config "$BAD_DELAY"

SLOW_PROBES=$TEMP_DIR/slow-probes.conf
sed -e 's/^PROBE_TIMEOUT=.*/PROBE_TIMEOUT=60/' -e 's/^PROBE_ATTEMPTS=.*/PROBE_ATTEMPTS=10/' \
    "$EDGE_CONFIG" >"$SLOW_PROBES"
expect_failure 'a probe plan over the service budget is rejected' run_ctl "$SLOW_PROBES" validate-config "$SLOW_PROBES"

INJECTION=$TEMP_DIR/injection.conf
INJECTION_MARKER=$TEMP_DIR/should-not-exist
cp "$EDGE_CONFIG" "$INJECTION"
printf 'UNKNOWN=$(touch %s)\n' "$INJECTION_MARKER" >>"$INJECTION"
expect_failure 'unknown executable configuration is rejected' run_ctl "$INJECTION" validate-config "$INJECTION"
if [[ ! -e $INJECTION_MARKER ]]; then
    pass 'configuration is never evaluated as shell'
else
    fail 'configuration is never evaluated as shell'
fi

LANDING_PLAN=$(run_ctl "$LANDING_CONFIG" plan --group A 2>/dev/null)
ADVERTISED_LINE=$(printf '%s\n' "$LANDING_PLAN" | awk -F= '$1 == "advertised_endpoints" {print $2}')
if [[ $ADVERTISED_LINE != *'192.0.2.11'* && $ADVERTISED_LINE == *'192.0.2.12'* && $ADVERTISED_LINE == *'192.0.2.15'* ]]; then
    pass 'Landing plan excludes configured primary and includes secondaries'
else
    fail 'Landing plan excludes configured primary and includes secondaries'
fi

if bash -n "$ROOT_DIR/install.sh" "$ROOT_DIR/bin/mptcp-abctl" "$ROOT_DIR/lib/"*.sh "$ROOT_DIR/tests/"*.sh; then
    pass 'all shell files pass bash syntax validation'
else
    fail 'all shell files pass bash syntax validation'
fi

if MPTCP_AB_SKIP_ZONEINFO=1 "$ROOT_DIR/install.sh" plan --config "$EDGE_CONFIG" --non-interactive >/dev/null 2>&1; then
    pass 'installer dry plan succeeds without root'
else
    fail 'installer dry plan succeeds without root'
fi

CUSTOM_RUNTIME=$TEMP_DIR/custom-runtime.conf
sed 's/^EDGE_SERVICE=.*/EDGE_SERVICE=custom-edge.service/' "$EDGE_CONFIG" >"$CUSTOM_RUNTIME"
expect_failure 'installer rejects an Edge service that its fixed unit cannot manage' \
    env MPTCP_AB_SKIP_ZONEINFO=1 "$ROOT_DIR/install.sh" plan --config "$CUSTOM_RUNTIME" --non-interactive

if grep -qx 'OnActiveSec=60s' "$ROOT_DIR/systemd/mptcp-ab-switch.timer.in" &&
   grep -qx 'OnUnitInactiveSec=60s' "$ROOT_DIR/systemd/mptcp-ab-switch.timer.in" &&
   grep -Eq '^Wants=.*mptcp-ab-bootstrap\.service' "$ROOT_DIR/systemd/mptcp-ab-switch.service" &&
   grep -Eq '^After=.*mptcp-ab-bootstrap\.service' "$ROOT_DIR/systemd/mptcp-ab-switch.service" &&
   grep -qx 'Restart=on-failure' "$ROOT_DIR/systemd/mptcp-ab-switch.service" &&
   ! grep -q '^StartLimit' "$ROOT_DIR/systemd/mptcp-ab-switch.service" &&
   grep -qx 'TimeoutStartSec=720s' "$ROOT_DIR/systemd/mptcp-ab-switch.service" &&
   grep -qx 'TimeoutStartSec=420s' "$ROOT_DIR/systemd/mptcp-ab-bootstrap.service" &&
   grep -qx 'DynamicUser=yes' "$ROOT_DIR/systemd/mptcp-port-tunnel-client.service" &&
   grep -qx 'ExecStartPre=+/usr/local/sbin/mptcp-abctl validate-runtime' \
       "$ROOT_DIR/systemd/mptcp-port-tunnel-client.service"; then
    pass 'systemd units seed health checks and preserve privileged Edge preflight'
else
    fail 'systemd units seed health checks and preserve privileged Edge preflight'
fi

if grep -q 'sysctl modprobe sha256sum' "$ROOT_DIR/install.sh" &&
   grep -q 'kmod procps' "$ROOT_DIR/install.sh" &&
   grep -q 'sysctl -p /etc/sysctl.d/90-mptcp-ab.conf' "$ROOT_DIR/install.sh" &&
   ! grep -q 'sysctl --system' "$ROOT_DIR/install.sh" &&
   ! grep -q 'systemd-timesyncd' "$ROOT_DIR/install.sh" \
       "$ROOT_DIR/systemd/mptcp-ab-bootstrap.service" \
       "$ROOT_DIR/systemd/mptcp-ab-switch.service" &&
   awk '
       /^resolve_edge_binary\(\)$/ { in_resolver = 1; next }
       in_resolver && /^}$/ { exit }
       in_resolver && /candidate=\$BINARY_SOURCE/ { explicit = NR }
       in_resolver && /payload_for_arch/ { payload = NR }
       END { exit !(explicit && payload > explicit) }
   ' "$ROOT_DIR/install.sh"; then
    pass 'installer checks platform commands and selects the bundled source build'
else
    fail 'installer checks platform commands and selects the bundled source build'
fi

if (cd "$ROOT_DIR/payload" && shasum -a 256 -c SHA256SUMS) &&
   [[ -f $ROOT_DIR/payload/linux-amd64/mptcp-port-tunnel && -f $ROOT_DIR/tunnel/main.go ]]; then
    pass 'bundled amd64 and arm64 source-built tunnel checksums'
else
    fail 'bundled amd64 and arm64 source-built tunnel checksums'
fi

FAKE_BIN=$TEMP_DIR/fake-bin
FAKE_STATE=$TEMP_DIR/fake-state
mkdir -p "$FAKE_BIN" "$FAKE_STATE"
printf '2 2\n' >"$FAKE_STATE/limits"
: >"$FAKE_STATE/endpoints"
: >"$FAKE_STATE/restarts"

cat >"$FAKE_BIN/ip" <<'EOF'
#!/usr/bin/env bash
set -u
case "$*" in
    '-4 route show default')
        printf 'default via 192.0.2.1 dev eth0\n'
        ;;
    'mptcp limits show')
        read -r subflows accepted <"$FAKE_STATE/limits"
        printf 'add_addr_accepted %s subflows %s\n' "$accepted" "$subflows"
        ;;
    mptcp\ limits\ set\ subflows\ *)
        printf '%s %s\n' "$5" "$7" >"$FAKE_STATE/limits"
        ;;
    'mptcp endpoint show')
        [[ ${FAKE_IP_FAIL_SHOW:-0} != 1 ]] || exit 1
        cat "$FAKE_STATE/endpoints"
        ;;
    mptcp\ endpoint\ add\ *)
        address=$4
        id=$6
        device=$9
        [[ ${FAKE_IP_FAIL_ADD:-} != "$address" ]] || exit 1
        printf '%s id %s signal dev %s\n' "$address" "$id" "$device" >>"$FAKE_STATE/endpoints"
        if [[ ${FAKE_IP_INTERRUPT_ADD:-} == "$address" ]]; then
            kill -TERM "$PPID"
        fi
        ;;
    mptcp\ endpoint\ delete\ id\ *)
        id=$5
        awk -v wanted="$id" '{drop=0; for (i=1; i<NF; i++) if ($i == "id" && $(i+1) == wanted) drop=1; if (!drop) print}' \
            "$FAKE_STATE/endpoints" >"$FAKE_STATE/endpoints.new"
        mv "$FAKE_STATE/endpoints.new" "$FAKE_STATE/endpoints"
        ;;
    *)
        printf 'unexpected fake ip invocation: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF

cat >"$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
command_name=${1:-}
shift || :
case $command_name in
    is-active|is-enabled)
        [[ ${1:-} == --quiet ]] && shift
        if [[ -f $FAKE_STATE/service-state && ${1:-} == mptcp-port-tunnel-client.service ]]; then
            grep -qx active "$FAKE_STATE/service-state"
            exit $?
        fi
        exit 0
        ;;
    restart)
        printf '%s\n' "${1:-}" >>"$FAKE_STATE/restarts"
        if [[ -n ${FAKE_SYSTEMCTL_READONLY_RUNTIME:-} ]]; then
            chmod 0555 "$FAKE_SYSTEMCTL_READONLY_RUNTIME"
        fi
        [[ ${FAKE_SYSTEMCTL_FAIL_RESTART:-} != "${1:-}" ]] || exit 1
        [[ ${1:-} != mptcp-port-tunnel-client.service ]] || printf 'active\n' >"$FAKE_STATE/service-state"
        ;;
    stop)
        printf 'stop %s\n' "${1:-}" >>"$FAKE_STATE/restarts"
        [[ ${1:-} != mptcp-port-tunnel-client.service ]] || printf 'inactive\n' >"$FAKE_STATE/service-state"
        ;;
    *) exit 0 ;;
esac
EOF

cat >"$FAKE_BIN/ss" <<'EOF'
#!/usr/bin/env bash
[[ ${FAKE_SS_NO_LISTENER:-0} != 1 ]] || exit 0
case "$*" in
    *-ltn*) printf 'LISTEN 0 4096 0.0.0.0:10029 0.0.0.0:*\n' ;;
    *-lnM*) printf 'LISTEN 0 4096 *:20000 *:*\n' ;;
esac
EOF

cat >"$FAKE_BIN/timedatectl" <<'EOF'
#!/usr/bin/env bash
set -u
count=0
[[ ! -f $FAKE_STATE/sync-checks ]] || count=$(cat "$FAKE_STATE/sync-checks")
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_STATE/sync-checks"
if ((count >= ${FAKE_TIME_SYNC_AFTER:-1})); then
    printf 'yes\n'
else
    printf 'no\n'
fi
EOF

cat >"$FAKE_BIN/date" <<'EOF'
#!/usr/bin/env bash
set -u
[[ ${1:-} == +%H%M && -n ${FAKE_DATE_STATE:-} ]] || exec /bin/date "$@"
count=0
[[ ! -f $FAKE_DATE_STATE ]] || count=$(cat "$FAKE_DATE_STATE")
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_DATE_STATE"
if ((count == 1)); then
    printf '1959\n'
else
    printf '2000\n'
fi
EOF

cat >"$FAKE_BIN/tunnel" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
    --help) exit 0 ;;
    probe)
        server=
        while [[ $# -gt 0 ]]; do
            [[ $1 == --server ]] && { shift; server=${1:-}; }
            shift || :
        done
        case ",${FAKE_HEALTHY:-}," in
            *",$server,"*) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 2 ;;
esac
EOF

cat >"$FAKE_BIN/flock" <<'EOF'
#!/usr/bin/env bash
[[ ${FAKE_FLOCK_FAIL:-0} != 1 ]]
EOF
chmod 0755 "$FAKE_BIN"/*

run_mock_ctl()
{
    MPTCP_AB_SKIP_ZONEINFO=1 \
    MPTCP_AB_ALLOW_NONROOT=1 \
    MPTCP_AB_SKIP_CHOWN=1 \
    MPTCP_AB_LIB=$LIB \
    MPTCP_AB_CONFIG_FILE=$1 \
    MPTCP_AB_STATE_DIR=$FAKE_STATE/runtime \
    MPTCP_AB_RUN_DIR=$FAKE_STATE/run \
    MPTCP_AB_IP_CMD=$FAKE_BIN/ip \
    MPTCP_AB_SS_CMD=$FAKE_BIN/ss \
    MPTCP_AB_SYSTEMCTL_CMD=$FAKE_BIN/systemctl \
    MPTCP_AB_TIMEDATECTL_CMD=$FAKE_BIN/timedatectl \
    MPTCP_AB_FLOCK_CMD=$FAKE_BIN/flock \
    FAKE_STATE=$FAKE_STATE \
        "$CTL" "${@:2}"
}

MOCK_EDGE=$TEMP_DIR/mock-edge.conf
sed -e "s|^EDGE_BINARY=.*|EDGE_BINARY=$FAKE_BIN/tunnel|" \
    -e "s|^EDGE_SERVER_FILE=.*|EDGE_SERVER_FILE=$FAKE_STATE/runtime/active-server|" \
    -e 's/^ENDPOINT_DEVICE=.*/ENDPOINT_DEVICE=eth0/' \
    -e 's/^REQUIRE_TIME_SYNC=.*/REQUIRE_TIME_SYNC=no/' \
    "$EDGE_CONFIG" >"$MOCK_EDGE"

if FAKE_HEALTHY=192.0.2.11:20000 run_mock_ctl "$MOCK_EDGE" switch --group A --boot >/dev/null 2>&1 &&
   [[ $(cat "$FAKE_STATE/runtime/active-server") == 192.0.2.11:20000 ]] &&
   [[ $(cat "$FAKE_STATE/runtime/active-group") == A ]] &&
   [[ $(cat "$FAKE_STATE/limits") == '8 8' ]]; then
    pass 'mock Edge transaction selects target and commits state'
else
    fail 'mock Edge transaction selects target and commits state'
fi

SYNC_EDGE=$TEMP_DIR/sync-edge.conf
sed 's/^REQUIRE_TIME_SYNC=.*/REQUIRE_TIME_SYNC=yes/' "$MOCK_EDGE" >"$SYNC_EDGE"
: >"$FAKE_STATE/sync-checks"
if FAKE_HEALTHY=192.0.2.11:20000 FAKE_TIME_SYNC_AFTER=3 \
   MPTCP_AB_BOOT_SYNC_ATTEMPTS=4 MPTCP_AB_BOOT_SYNC_INTERVAL=0 \
   run_mock_ctl "$SYNC_EDGE" switch --group A --boot >/dev/null 2>&1 &&
   [[ $(cat "$FAKE_STATE/sync-checks") == 3 ]]; then
    pass 'boot transaction waits for delayed time synchronization'
else
    fail 'boot transaction waits for delayed time synchronization'
fi

EDGE_TARGET_BEFORE=$(cat "$FAKE_STATE/runtime/active-server")
EDGE_GROUP_BEFORE=$(cat "$FAKE_STATE/runtime/active-group")
EDGE_LIMITS_BEFORE=$(cat "$FAKE_STATE/limits")
printf 'inactive\n' >"$FAKE_STATE/service-state"
if FAKE_HEALTHY=198.51.100.21:20000 FAKE_SS_NO_LISTENER=1 \
   MPTCP_AB_READY_ATTEMPTS=1 MPTCP_AB_READY_INTERVAL=0 \
   run_mock_ctl "$MOCK_EDGE" switch --group B >/dev/null 2>&1; then
    fail 'failed Edge readiness rolls back an initially inactive service (unexpected success)'
elif [[ $(cat "$FAKE_STATE/runtime/active-server") == "$EDGE_TARGET_BEFORE" &&
        $(cat "$FAKE_STATE/runtime/active-group") == "$EDGE_GROUP_BEFORE" &&
        $(cat "$FAKE_STATE/limits") == "$EDGE_LIMITS_BEFORE" &&
        $(cat "$FAKE_STATE/service-state") == inactive ]] &&
     grep -qx 'stop mptcp-port-tunnel-client.service' "$FAKE_STATE/restarts"; then
    pass 'failed Edge readiness restores state and stops an initially inactive service'
else
    fail 'failed Edge readiness restores state and stops an initially inactive service'
fi
rm -f "$FAKE_STATE/service-state"

HEALTH_EDGE=$TEMP_DIR/health-edge.conf
sed 's/^EDGE_SWITCH_DELAY=.*/EDGE_SWITCH_DELAY=0/' "$MOCK_EDGE" >"$HEALTH_EDGE"
HEALTH_EDGE_CLOSED=$TEMP_DIR/health-edge-closed.conf
sed 's/^FAIL_OPEN=.*/FAIL_OPEN=no/' "$HEALTH_EDGE" >"$HEALTH_EDGE_CLOSED"
RESTARTS_BEFORE=$(wc -l <"$FAKE_STATE/restarts" | tr -d ' ')
if FAKE_HEALTHY=192.0.2.12:20000 run_mock_ctl "$HEALTH_EDGE" switch --scheduled --group A >/dev/null 2>&1 &&
   [[ $(cat "$FAKE_STATE/runtime/active-server") == 192.0.2.12:20000 ]] &&
   [[ $(wc -l <"$FAKE_STATE/restarts" | tr -d ' ') == $((RESTARTS_BEFORE + 1)) ]]; then
    pass 'scheduled health check fails over to a healthy relay in the same group'
else
    fail 'scheduled health check fails over to a healthy relay in the same group'
fi
RESTARTS_AFTER_FAILOVER=$(wc -l <"$FAKE_STATE/restarts" | tr -d ' ')
if FAKE_HEALTHY=192.0.2.12:20000 run_mock_ctl "$HEALTH_EDGE" switch --scheduled --group A >/dev/null 2>&1 &&
   [[ $(wc -l <"$FAKE_STATE/restarts" | tr -d ' ') == "$RESTARTS_AFTER_FAILOVER" ]]; then
    pass 'scheduled health check does not restart a healthy current relay'
else
    fail 'scheduled health check does not restart a healthy current relay'
fi

printf 'active\n' >"$FAKE_STATE/service-state"
printf '3 4\n' >"$FAKE_STATE/limits"
EDGE_RUNTIME_DIR=$FAKE_STATE/runtime
if FAKE_HEALTHY=198.51.100.21:20000 \
   FAKE_SYSTEMCTL_FAIL_RESTART=mptcp-port-tunnel-client.service \
   FAKE_SYSTEMCTL_READONLY_RUNTIME=$EDGE_RUNTIME_DIR \
   MPTCP_AB_READY_ATTEMPTS=1 MPTCP_AB_READY_INTERVAL=0 \
   run_mock_ctl "$HEALTH_EDGE" switch --group B >/dev/null 2>&1; then
    EDGE_BEST_EFFORT_RC=0
else
    EDGE_BEST_EFFORT_RC=$?
fi
chmod 0755 "$EDGE_RUNTIME_DIR"
if [[ $EDGE_BEST_EFFORT_RC -ne 0 && $(cat "$FAKE_STATE/limits") == '3 4' &&
      $(cat "$FAKE_STATE/service-state") == inactive ]]; then
    pass 'incomplete Edge file rollback still restores limits and stops the client'
else
    fail 'incomplete Edge file rollback still restores limits and stops the client'
fi
printf '8 8\n' >"$FAKE_STATE/limits"
rm -f "$FAKE_STATE/service-state"

FAKE_DATE_STATE=$FAKE_STATE/date-count
rm -f "$FAKE_DATE_STATE"
if PATH="$FAKE_BIN:$PATH" FAKE_DATE_STATE=$FAKE_DATE_STATE \
   FAKE_HEALTHY=198.51.100.21:20000 \
   run_mock_ctl "$HEALTH_EDGE_CLOSED" switch --scheduled >/dev/null 2>&1 &&
   [[ $(cat "$FAKE_STATE/runtime/active-group") == B ]] &&
   [[ $(cat "$FAKE_STATE/runtime/active-server") == 198.51.100.21:20000 ]] &&
   (( $(cat "$FAKE_DATE_STATE") >= 3 )); then
    pass 'scheduled Edge check reselects when relay probing crosses a group boundary'
else
    fail 'scheduled Edge check reselects when relay probing crosses a group boundary'
fi

LOCK_TARGET_BEFORE=$(cat "$FAKE_STATE/runtime/active-server")
LOCK_GROUP_BEFORE=$(cat "$FAKE_STATE/runtime/active-group")
LOCK_LIMITS_BEFORE=$(cat "$FAKE_STATE/limits")
if FAKE_FLOCK_FAIL=1 run_mock_ctl "$HEALTH_EDGE" switch --scheduled --group B >/dev/null 2>&1; then
    fail 'lock contention rejects a scheduled switch (unexpected success)'
elif [[ $(cat "$FAKE_STATE/runtime/active-server") == "$LOCK_TARGET_BEFORE" &&
        $(cat "$FAKE_STATE/runtime/active-group") == "$LOCK_GROUP_BEFORE" &&
        $(cat "$FAKE_STATE/limits") == "$LOCK_LIMITS_BEFORE" ]]; then
    pass 'lock contention leaves Edge state unchanged for systemd retry'
else
    fail 'lock contention leaves Edge state unchanged for systemd retry'
fi

DRIFT_ENV=$TEMP_DIR/client-drift.env
printf 'LISTEN_ADDRESS=0.0.0.0:10029\nSERVER_FILE=/tmp/wrong-server\n' >"$DRIFT_ENV"
if MPTCP_AB_CLIENT_ENV_FILE=$DRIFT_ENV run_mock_ctl "$MOCK_EDGE" validate-runtime >"$TEMP_DIR/drift.out" 2>&1; then
    fail 'Edge runtime rejects a client.env mismatch (unexpected success)'
elif grep -q 'does not match the main configuration' "$TEMP_DIR/drift.out"; then
    pass 'Edge runtime rejects a client.env mismatch'
else
    fail 'Edge runtime rejects a client.env mismatch'
fi

MOCK_LANDING=$TEMP_DIR/mock-landing.conf
sed -e 's/^ENDPOINT_DEVICE=.*/ENDPOINT_DEVICE=eth0/' \
    -e 's/^REQUIRE_TIME_SYNC=.*/REQUIRE_TIME_SYNC=no/' \
    "$LANDING_CONFIG" >"$MOCK_LANDING"
: >"$FAKE_STATE/endpoints"
printf '2 2\n' >"$FAKE_STATE/limits"
rm -rf "$FAKE_STATE/runtime" "$FAKE_STATE/run"

if run_mock_ctl "$MOCK_LANDING" switch --group A --boot >/dev/null 2>&1 &&
   [[ $(wc -l <"$FAKE_STATE/endpoints" | tr -d ' ') == 4 ]] &&
   ! grep -q '^192\.0\.2\.11 ' "$FAKE_STATE/endpoints" &&
   grep -q '^192\.0\.2\.15 id 104 signal dev eth0$' "$FAKE_STATE/endpoints"; then
    pass 'mock Landing transaction publishes A secondaries'
else
    fail 'mock Landing transaction publishes A secondaries'
fi

LANDING_ENDPOINTS_BEFORE_STATUS=$(cat "$FAKE_STATE/endpoints")
printf '203.0.113.10 id 200 signal dev eth0\n' >>"$FAKE_STATE/endpoints"
if LANDING_STATUS=$(run_mock_ctl "$MOCK_LANDING" status 2>/dev/null) &&
   [[ $LANDING_STATUS == *'192.0.2.12 id 101 signal dev eth0'* ]] &&
   [[ $LANDING_STATUS != *'203.0.113.10'* ]]; then
    pass 'Landing status ignores an unowned final endpoint without failing'
else
    fail 'Landing status ignores an unowned final endpoint without failing'
fi
printf '%s\n' "$LANDING_ENDPOINTS_BEFORE_STATUS" >"$FAKE_STATE/endpoints"

if run_mock_ctl "$MOCK_LANDING" switch --group B --boot >/dev/null 2>&1 &&
   [[ $(wc -l <"$FAKE_STATE/endpoints" | tr -d ' ') == 2 ]] &&
   ! grep -q '^198\.51\.100\.21 ' "$FAKE_STATE/endpoints" &&
   grep -q '^198\.51\.100\.23 id 102 signal dev eth0$' "$FAKE_STATE/endpoints"; then
    pass 'mock Landing transaction replaces A with B atomically at controller level'
else
    fail 'mock Landing transaction replaces A with B atomically at controller level'
fi

LANDING_BEFORE_SHOW_FAILURE=$(cat "$FAKE_STATE/endpoints")
if FAKE_IP_FAIL_SHOW=1 run_mock_ctl "$MOCK_LANDING" switch --group A --boot >/dev/null 2>&1; then
    fail 'Landing refuses a transaction when endpoint inventory fails (unexpected success)'
elif [[ $(cat "$FAKE_STATE/endpoints") == "$LANDING_BEFORE_SHOW_FAILURE" ]]; then
    pass 'Landing inventory failure leaves endpoints unchanged'
else
    fail 'Landing inventory failure leaves endpoints unchanged'
fi

BEFORE_ENDPOINTS=$(cat "$FAKE_STATE/endpoints")
BEFORE_LIMITS=$(cat "$FAKE_STATE/limits")
BEFORE_GROUP=$(cat "$FAKE_STATE/runtime/active-group")
if FAKE_IP_FAIL_ADD=192.0.2.13 run_mock_ctl "$MOCK_LANDING" switch --group A --boot >/dev/null 2>&1; then
    fail 'mock Landing injected endpoint failure triggers rollback (unexpected success)'
elif [[ $(cat "$FAKE_STATE/endpoints") == "$BEFORE_ENDPOINTS" &&
        $(cat "$FAKE_STATE/limits") == "$BEFORE_LIMITS" &&
        $(cat "$FAKE_STATE/runtime/active-group") == "$BEFORE_GROUP" ]]; then
    pass 'mock Landing endpoint failure restores endpoints, limits, and group'
else
    fail 'mock Landing endpoint failure restores endpoints, limits, and group'
fi

RECONFIG_LANDING=$TEMP_DIR/reconfigure-landing.conf
sed -e 's/^ENDPOINT_ID_BASE=.*/ENDPOINT_ID_BASE=120/' \
    -e 's/^ENDPOINT_DEVICE=.*/ENDPOINT_DEVICE=ens3/' "$MOCK_LANDING" >"$RECONFIG_LANDING"
if run_mock_ctl "$RECONFIG_LANDING" switch --group A --boot >/dev/null 2>&1 &&
   [[ $(wc -l <"$FAKE_STATE/endpoints" | tr -d ' ') == 4 ]] &&
   ! grep -Eq ' id 10[1-7] ' "$FAKE_STATE/endpoints" &&
   grep -q '^192\.0\.2\.15 id 124 signal dev ens3$' "$FAKE_STATE/endpoints"; then
    pass 'Landing reconfigure replaces old IDs and interface using ownership state'
else
    fail 'Landing reconfigure replaces old IDs and interface using ownership state'
fi

if run_mock_ctl "$RECONFIG_LANDING" cleanup-landing >/dev/null 2>&1 &&
   [[ ! -s $FAKE_STATE/endpoints && $(cat "$FAKE_STATE/limits") == '2 2' &&
      ! -e $FAKE_STATE/runtime/landing-runtime.state ]]; then
    pass 'Landing cleanup removes owned endpoints and restores original limits'
else
    fail 'Landing cleanup removes owned endpoints and restores original limits'
fi

CUSTOM_PORTS=$TEMP_DIR/custom-ports.conf
sed -e 's/^RELAY_PORT=.*/RELAY_PORT=21000/' \
    -e 's/^RELAY_PORTS=.*/RELAY_PORTS=192.0.2.11:21001,192.0.2.12:21002/' \
    -e 's/^LANDING_PORT=.*/LANDING_PORT=22000/' \
    -e 's/^LISTEN_ADDRESS=.*/LISTEN_ADDRESS=127.0.0.1:23000/' \
    -e 's/^A_START=.*/A_START=0830/' -e 's/^B_START=.*/B_START=2345/' \
    "$MOCK_EDGE" >"$CUSTOM_PORTS"
if run_ctl "$CUSTOM_PORTS" validate-config >/dev/null &&
   PORT_PLAN=$(run_ctl "$CUSTOM_PORTS" plan --group A) &&
   [[ $PORT_PLAN == *'edge_listen=127.0.0.1:23000'* &&
      $PORT_PLAN == *'relay_target=192.0.2.11:21001'* &&
      $PORT_PLAN == *'relay_target=192.0.2.13:21000'* &&
      $PORT_PLAN == *'landing_port=22000'* ]]; then
    pass 'Edge, default Relay, individual Relay and Landing ports are independent'
else
    fail 'independent port configuration'
fi
expect_output 'custom A boundary is inclusive' A run_ctl "$CUSTOM_PORTS" current-group 0830
expect_output 'custom B boundary is inclusive' B run_ctl "$CUSTOM_PORTS" current-group 2345

BAD_PORTS=$TEMP_DIR/bad-ports.conf
for entry in '192.0.2.11:0' '192.0.2.11:65536' '192.0.2.11:abc' \
    '192.0.2.11:21000,192.0.2.11:21001' '192.0.2.254:21000' '192.0.2.11:21000,'; do
    sed "s/^RELAY_PORTS=.*/RELAY_PORTS=$entry/" "$CUSTOM_PORTS" >"$BAD_PORTS"
    expect_failure "invalid Relay port override rejected: $entry" run_ctl "$BAD_PORTS" validate-config
done
sed 's/^LANDING_PORT=.*/LANDING_PORT=65536/' "$CUSTOM_PORTS" >"$BAD_PORTS"
expect_failure 'invalid Landing port rejected' run_ctl "$BAD_PORTS" validate-config
sed '/^LANDING_PORT=/d; /^RELAY_PORTS=/d; s/^RELAY_PORT=.*/RELAY_PORT=23456/' "$MOCK_EDGE" >"$BAD_PORTS"
if LEGACY_PLAN=$(run_ctl "$BAD_PORTS" plan --group A) && [[ $LEGACY_PLAN == *'landing_port=23456'* ]]; then
    pass 'legacy configuration inherits Landing port from RELAY_PORT'
else
    fail 'legacy port compatibility'
fi

if RULES=$(run_ctl "$CUSTOM_PORTS" network-plan) &&
   [[ $RULES == *'ip daddr 192.0.2.11 tcp dport 22000 dnat to 192.0.2.11:21001'* &&
      $RULES == *'ip daddr 192.0.2.12 tcp dport 22000 dnat to 192.0.2.12:21002'* &&
      $RULES == *'ip daddr 192.0.2.13 tcp dport 22000 dnat to 192.0.2.13:21000'* &&
      $RULES != *'flush ruleset'* ]]; then
    pass 'Edge maps initial connections and MPTCP subflows to individual public ports'
else
    fail 'Edge port mapping rules'
fi
if RELAY_PLAN=$("$ROOT_DIR/install.sh" plan --config "$ROOT_DIR/examples/relay.conf" --non-interactive) &&
   [[ $RELAY_PLAN == *'forward_to=192.0.2.10:22000'* ]]; then
    pass 'Relay installer plan does not require Edge groups or a tunnel binary'
else
    fail 'Relay installer plan'
fi
if RULES=$(run_ctl "$ROOT_DIR/examples/relay.conf" network-plan) &&
   [[ $RULES == *'tcp dport 21000 dnat to 192.0.2.10:22000'* &&
      $RULES == *'ct original proto-dst 21000 ip daddr 192.0.2.10 tcp dport 22000 masquerade'* ]]; then
    pass 'Relay maps its public port to the independent Landing port with return NAT'
else
    fail 'Relay port mapping rules'
fi
sed 's/^LANDING_ADDRESS=.*/LANDING_ADDRESS=/' "$ROOT_DIR/examples/relay.conf" >"$BAD_PORTS"
expect_failure 'Relay requires a Landing destination' run_ctl "$BAD_PORTS" validate-config

rm -f "$FAKE_STATE/service-state"
printf 'inactive\n' >"$FAKE_STATE/service-state"
if FAKE_HEALTHY=192.0.2.11:22000 run_mock_ctl "$CUSTOM_PORTS" switch --group A --boot >/dev/null 2>&1 &&
   [[ $(cat "$FAKE_STATE/runtime/active-server") == 192.0.2.11:22000 ]]; then
    pass 'Edge probes and stores the logical Landing port for kernel NAT mapping'
else
    fail 'Edge logical port selection'
fi
for mode in --boot manual; do
    rm -f "$FAKE_DATE_STATE"
    mode_args=()
    [[ $mode == manual ]] || mode_args=("$mode")
    if PATH="$FAKE_BIN:$PATH" FAKE_DATE_STATE=$FAKE_DATE_STATE FAKE_HEALTHY=198.51.100.21:20000 \
       run_mock_ctl "$HEALTH_EDGE_CLOSED" switch ${mode_args[@]+"${mode_args[@]}"} >/dev/null 2>&1 &&
       [[ $(cat "$FAKE_STATE/runtime/active-group") == B ]]; then
        pass "$mode switch rechecks the schedule after probes cross a boundary"
    else
        fail "$mode schedule convergence"
    fi
done

: >"$FAKE_STATE/endpoints"
if run_mock_ctl "$MOCK_LANDING" switch --group A >/dev/null 2>&1; then
    if FAKE_IP_INTERRUPT_ADD=198.51.100.22 run_mock_ctl "$MOCK_LANDING" switch --group B >/dev/null 2>&1; then
        fail 'interrupted Landing switch unexpectedly succeeded'
    elif [[ -d $FAKE_STATE/runtime/landing-transaction ]] &&
         run_mock_ctl "$MOCK_LANDING" switch --group B >"$TEMP_DIR/recover.out" 2>&1 &&
         grep -q 'recovering an interrupted' "$TEMP_DIR/recover.out" &&
         [[ $(cat "$FAKE_STATE/runtime/active-group") == B &&
            ! -d $FAKE_STATE/runtime/landing-transaction ]]; then
        pass 'Landing recovers a process interruption between endpoint updates and ownership commit'
    else
        fail 'Landing interruption recovery'
    fi
else
    fail 'Landing interruption fixture'
fi
if FAKE_IP_INTERRUPT_ADD=192.0.2.12 run_mock_ctl "$MOCK_LANDING" switch --group A >/dev/null 2>&1; then
    fail 'second Landing interruption unexpectedly succeeded'
elif run_mock_ctl "$MOCK_LANDING" cleanup-landing >/dev/null 2>&1 &&
     [[ ! -s $FAKE_STATE/endpoints && ! -d $FAKE_STATE/runtime/landing-transaction ]]; then
    pass 'Landing cleanup recovers an interrupted switch before removing owned endpoints'
else
    fail 'Landing cleanup after interruption'
fi

if bash "$ROOT_DIR/tests/network.sh" >"$TEMP_DIR/network.out" 2>&1; then
    pass 'network replacement, rollback, ownership, role transition and cleanup'
else
    cat "$TEMP_DIR/network.out" >&2
    fail 'network lifecycle'
fi
if command -v expect >/dev/null 2>&1; then
    if expect "$ROOT_DIR/tests/interactive.exp"; then
        pass 'interactive terminal validates ports and times and produces the requested plan'
    else
        fail 'interactive terminal workflow'
    fi
else
    printf 'skip - interactive terminal workflow requires expect\n'
fi

if (cd "$ROOT_DIR" && shasum -a 256 -c payload/SOURCE_SHA256SUMS) >/dev/null; then
    pass 'source manifest matches the delivered tunnel source'
else
    fail 'source manifest does not match the delivered tunnel source'
fi
sed 's/^LANDING_BACKEND=.*/LANDING_BACKEND=127.0.0.1:70000/' "$ROOT_DIR/examples/landing.conf" >"$BAD_PORTS"
expect_failure 'managed Landing rejects an invalid backend port' run_ctl "$BAD_PORTS" validate-config
sed 's/^LANDING_SERVICE=.*/LANDING_SERVICE=external.service/' "$ROOT_DIR/examples/landing.conf" >"$BAD_PORTS"
expect_failure 'managed Landing cannot take ownership of a third-party service' run_ctl "$BAD_PORTS" validate-config

AGGREGATE_CONFIG=$ROOT_DIR/examples/aggregate-edge.conf
expect_output 'aggregate mode stays active before the old A boundary' A run_ctl "$AGGREGATE_CONFIG" current-group 0059
expect_output 'aggregate mode stays active after the old B boundary' A run_ctl "$AGGREGATE_CONFIG" current-group 2001
expect_failure 'aggregate mode rejects an explicit B plan' run_ctl "$AGGREGATE_CONFIG" plan --group B
sed 's/^SUBFLOWS=.*/SUBFLOWS=0/' "$AGGREGATE_CONFIG" >"$BAD_PORTS"
expect_failure 'aggregation rejects disabled subflows' run_ctl "$BAD_PORTS" validate-config
sed -e 's/^GROUP_A=.*/GROUP_A=192.0.2.1/' "$AGGREGATE_CONFIG" >"$BAD_PORTS"
expect_failure 'aggregation rejects a single relay' run_ctl "$BAD_PORTS" validate-config
if AGGREGATE_PLAN=$(run_ctl "$ROOT_DIR/examples/aggregate-landing.conf" plan) &&
   [[ $AGGREGATE_PLAN == *'advertised_endpoints=192.0.2.1,192.0.2.2'* ]]; then
    pass 'aggregate Landing advertises all relay addresses'
else
    fail 'aggregate Landing endpoint plan'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
