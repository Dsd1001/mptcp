#!/usr/bin/env bash

# Shared configuration and validation helpers for mptcp-abctl and install.sh.
# The configuration parser intentionally does not source or eval input.

MPTCP_AB_CONFIG_FILE=${MPTCP_AB_CONFIG_FILE:-/etc/mptcp-ab/config.conf}
MPTCP_AB_STATE_DIR=${MPTCP_AB_STATE_DIR:-/var/lib/mptcp-ab}
MPTCP_AB_RUN_DIR=${MPTCP_AB_RUN_DIR:-/run/mptcp-ab}

ab_log()
{
    printf '%s\n' "mptcp-ab: $*" >&2
    command -v logger >/dev/null 2>&1 && logger -t mptcp-ab -- "$*" 2>/dev/null || :
}

ab_warn()
{
    printf '%s\n' "mptcp-ab: WARNING: $*" >&2
    command -v logger >/dev/null 2>&1 && logger -p user.warning -t mptcp-ab -- "$*" 2>/dev/null || :
}

ab_error()
{
    printf '%s\n' "mptcp-ab: ERROR: $*" >&2
    command -v logger >/dev/null 2>&1 && logger -p user.err -t mptcp-ab -- "$*" 2>/dev/null || :
    return 1
}

ab_is_uint()
{
    [[ ${1:-} =~ ^[0-9]+$ ]]
}

ab_valid_ipv4()
{
    local ip=${1:-}
    local a b c d extra octet

    [[ $ip =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    IFS=. read -r a b c d extra <<<"$ip"
    [[ -z ${extra:-} && -n ${a:-} && -n ${b:-} && -n ${c:-} && -n ${d:-} ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

ab_valid_port()
{
    [[ ${1:-} =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535))
}

ab_relay_port()
{
    local address=$1 entry
    local entries=()
    [[ -n $RELAY_PORTS ]] || { printf '%s\n' "$RELAY_PORT"; return 0; }
    IFS=, read -r -a entries <<<"$RELAY_PORTS"
    for entry in "${entries[@]}"; do
        if [[ ${entry%:*} == "$address" ]]; then
            printf '%s\n' "${entry##*:}"
            return 0
        fi
    done
    printf '%s\n' "$RELAY_PORT"
}

ab_validate_relay_ports()
{
    local entry address seen='|' entries=()
    [[ -n $RELAY_PORTS ]] || return 0
    [[ $RELAY_PORTS != ,* && $RELAY_PORTS != *, && $RELAY_PORTS != *,,* ]] || return 1
    IFS=, read -r -a entries <<<"$RELAY_PORTS"
    for entry in "${entries[@]}"; do
        [[ $entry == *:* ]] || return 1
        address=${entry%:*}
        ab_valid_ipv4 "$address" && ab_valid_port "${entry##*:}" || return 1
        ab_csv_contains "$GROUP_A,$GROUP_B" "$address" || return 1
        [[ $seen != *"|$address|"* ]] || return 1
        seen="$seen$address|"
    done
}

ab_valid_hhmm()
{
    local value=${1:-}
    local hour minute

    [[ $value =~ ^[0-2][0-9][0-5][0-9]$ ]] || return 1
    hour=${value:0:2}
    minute=${value:2:2}
    ((10#$hour <= 23 && 10#$minute <= 59))
}

ab_hhmm_to_minutes()
{
    local value=$1
    printf '%s\n' "$((10#${value:0:2} * 60 + 10#${value:2:2}))"
}

ab_csv_contains()
{
    local csv=$1
    local needle=$2
    local item
    local old_ifs=$IFS

    IFS=,
    for item in $csv; do
        [[ $item == "$needle" ]] && { IFS=$old_ifs; return 0; }
    done
    IFS=$old_ifs
    return 1
}

ab_csv_count()
{
    local csv=$1
    local item count=0
    local old_ifs=$IFS

    IFS=,
    for item in $csv; do
        [[ -n $item ]] || return 1
        count=$((count + 1))
    done
    IFS=$old_ifs
    printf '%s\n' "$count"
}

ab_validate_csv_group()
{
    local label=$1
    local csv=$2
    local item seen='|'
    local old_ifs=$IFS

    [[ -n $csv ]] || { ab_error "$label relay list is empty"; return 1; }
    [[ $csv != *, && $csv != ,* && $csv != *,,* ]] || {
        ab_error "$label relay list contains an empty item"
        return 1
    }
    IFS=,
    for item in $csv; do
        ab_valid_ipv4 "$item" || { IFS=$old_ifs; ab_error "$label contains invalid IPv4 address: $item"; return 1; }
        [[ $seen != *"|$item|"* ]] || { IFS=$old_ifs; ab_error "$label contains duplicate relay: $item"; return 1; }
        seen="${seen}${item}|"
    done
    IFS=$old_ifs
}

ab_validate_cross_group_uniqueness()
{
    local item
    local old_ifs=$IFS

    IFS=,
    for item in $GROUP_A; do
        if ab_csv_contains "$GROUP_B" "$item"; then
            IFS=$old_ifs
            ab_error "relay appears in both groups: $item"
            return 1
        fi
    done
    IFS=$old_ifs
}

ab_apply_config_defaults()
{
    SCHEMA_VERSION=1
    ROLE=
    MODE=scheduled
    TIMEZONE=Asia/Hong_Kong
    A_START=0100
    B_START=2000
    RELAY_PORT=20000
    RELAY_PORTS=
    LANDING_PORT=
    LANDING_ADDRESS=
    RELAY_LISTEN_ADDRESS=0.0.0.0
    GROUP_A=
    GROUP_B=
    PRIMARY_A=
    PRIMARY_B=
    ENDPOINT_DEVICE=auto
    ENDPOINT_ID_BASE=100
    LISTEN_ADDRESS=0.0.0.0:10029
    EDGE_BINARY=/usr/local/bin/mptcp-port-tunnel
    EDGE_SERVICE=mptcp-port-tunnel-client.service
    EDGE_SERVER_FILE=/var/lib/mptcp-ab/active-server
    EDGE_SWITCH_DELAY=0.5
    PROBE_TIMEOUT=3
    PROBE_ATTEMPTS=2
    FAIL_OPEN=yes
    SUBFLOWS=8
    ADD_ADDR_ACCEPTED=8
    REQUIRE_TIME_SYNC=yes
    ENABLE_FQ=yes
    ENABLE_BBR=auto
    LANDING_SERVICE=-
    LANDING_BACKEND=
}

ab_load_config()
{
    local config_file=${1:-$MPTCP_AB_CONFIG_FILE}
    local line key value seen='|'

    ab_apply_config_defaults
    [[ -f $config_file ]] || { ab_error "configuration file not found: $config_file"; return 1; }

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z $line || $line == \#* ]] && continue
        [[ $line == *=* ]] || { ab_error "invalid configuration line: $line"; return 1; }
        key=${line%%=*}
        value=${line#*=}
        [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] || { ab_error "invalid configuration key: $key"; return 1; }
        [[ $seen != *"|$key|"* ]] || { ab_error "duplicate configuration key: $key"; return 1; }
        seen="${seen}${key}|"
        case $key in
            SCHEMA_VERSION) SCHEMA_VERSION=$value ;;
            ROLE) ROLE=$value ;;
            MODE) MODE=$value ;;
            TIMEZONE) TIMEZONE=$value ;;
            A_START) A_START=$value ;;
            B_START) B_START=$value ;;
            RELAY_PORT) RELAY_PORT=$value ;;
            RELAY_PORTS) RELAY_PORTS=$value ;;
            LANDING_PORT) LANDING_PORT=$value ;;
            LANDING_ADDRESS) LANDING_ADDRESS=$value ;;
            RELAY_LISTEN_ADDRESS) RELAY_LISTEN_ADDRESS=$value ;;
            GROUP_A) GROUP_A=$value ;;
            GROUP_B) GROUP_B=$value ;;
            PRIMARY_A) PRIMARY_A=$value ;;
            PRIMARY_B) PRIMARY_B=$value ;;
            ENDPOINT_DEVICE) ENDPOINT_DEVICE=$value ;;
            ENDPOINT_ID_BASE) ENDPOINT_ID_BASE=$value ;;
            LISTEN_ADDRESS) LISTEN_ADDRESS=$value ;;
            EDGE_BINARY) EDGE_BINARY=$value ;;
            EDGE_SERVICE) EDGE_SERVICE=$value ;;
            EDGE_SERVER_FILE) EDGE_SERVER_FILE=$value ;;
            EDGE_SWITCH_DELAY) EDGE_SWITCH_DELAY=$value ;;
            PROBE_TIMEOUT) PROBE_TIMEOUT=$value ;;
            PROBE_ATTEMPTS) PROBE_ATTEMPTS=$value ;;
            FAIL_OPEN) FAIL_OPEN=$value ;;
            SUBFLOWS) SUBFLOWS=$value ;;
            ADD_ADDR_ACCEPTED) ADD_ADDR_ACCEPTED=$value ;;
            REQUIRE_TIME_SYNC) REQUIRE_TIME_SYNC=$value ;;
            ENABLE_FQ) ENABLE_FQ=$value ;;
            ENABLE_BBR) ENABLE_BBR=$value ;;
            LANDING_SERVICE) LANDING_SERVICE=$value ;;
            LANDING_BACKEND) LANDING_BACKEND=$value ;;
            *) ab_error "unknown configuration key: $key"; return 1 ;;
        esac
    done <"$config_file"

    ab_validate_config
}

ab_validate_config()
{
    local count_a count_b max_count max_id listen_host listen_port
    local delay_whole delay_fraction probe_budget

    [[ $SCHEMA_VERSION == 1 ]] || { ab_error "unsupported SCHEMA_VERSION: $SCHEMA_VERSION"; return 1; }
    [[ $ROLE == edge || $ROLE == relay || $ROLE == landing ]] || { ab_error "ROLE must be edge, relay, or landing"; return 1; }
    [[ $MODE == aggregate || $MODE == scheduled ]] || { ab_error "MODE must be aggregate or scheduled"; return 1; }
    [[ $TIMEZONE =~ ^[A-Za-z0-9_+./-]+$ && $TIMEZONE != /* && $TIMEZONE != *..* ]] || {
        ab_error "invalid TIMEZONE"
        return 1
    }
    if [[ ${MPTCP_AB_SKIP_ZONEINFO:-0} != 1 && ! -e /usr/share/zoneinfo/$TIMEZONE ]]; then
        ab_error "timezone data not found: $TIMEZONE"
        return 1
    fi
    ab_valid_hhmm "$A_START" || { ab_error "invalid A_START: $A_START"; return 1; }
    ab_valid_hhmm "$B_START" || { ab_error "invalid B_START: $B_START"; return 1; }
    [[ $A_START != "$B_START" ]] || { ab_error "A_START and B_START must differ"; return 1; }
    ab_valid_port "$RELAY_PORT" || { ab_error "invalid RELAY_PORT: $RELAY_PORT"; return 1; }
    LANDING_PORT=${LANDING_PORT:-$RELAY_PORT}
    ab_valid_port "$LANDING_PORT" || { ab_error "invalid LANDING_PORT: $LANDING_PORT"; return 1; }
    ab_valid_ipv4 "$RELAY_LISTEN_ADDRESS" || { ab_error "invalid RELAY_LISTEN_ADDRESS"; return 1; }
    [[ -z $LANDING_ADDRESS ]] || ab_valid_ipv4 "$LANDING_ADDRESS" || { ab_error "invalid LANDING_ADDRESS"; return 1; }
    if [[ $ROLE == relay ]]; then
        ab_valid_ipv4 "$LANDING_ADDRESS" && [[ $LANDING_ADDRESS != 0.0.0.0 && $LANDING_ADDRESS != 127.* ]] || {
            ab_error "Relay requires a reachable LANDING_ADDRESS"
            return 1
        }
        [[ $ENDPOINT_DEVICE == auto || $ENDPOINT_DEVICE =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
        [[ $ENABLE_FQ == yes || $ENABLE_FQ == no ]] || return 1
        [[ $ENABLE_BBR == auto || $ENABLE_BBR == yes || $ENABLE_BBR == no ]] || return 1
        return 0
    fi
    ab_validate_csv_group GROUP_A "$GROUP_A" || return 1
    count_b=0
    if [[ $MODE == scheduled ]]; then
        ab_validate_csv_group GROUP_B "$GROUP_B" || return 1
        ab_validate_cross_group_uniqueness || return 1
        count_b=$(ab_csv_count "$GROUP_B") || return 1
        ab_valid_ipv4 "$PRIMARY_B" && ab_csv_contains "$GROUP_B" "$PRIMARY_B" || {
            ab_error "PRIMARY_B must be a member of GROUP_B"
            return 1
        }
    else
        [[ -z $GROUP_B && -z $PRIMARY_B ]] || { ab_error "aggregate mode uses GROUP_A only; leave GROUP_B and PRIMARY_B empty"; return 1; }
    fi
    ab_validate_relay_ports || { ab_error "RELAY_PORTS must contain unique group-member IPv4:port entries"; return 1; }
    count_a=$(ab_csv_count "$GROUP_A") || return 1
    ((count_a <= 8 && count_b <= 8)) || {
        ab_error "each group supports at most 8 relays (one primary plus up to 7 advertised endpoints)"
        return 1
    }
    ab_valid_ipv4 "$PRIMARY_A" && ab_csv_contains "$GROUP_A" "$PRIMARY_A" || {
        ab_error "PRIMARY_A must be a member of GROUP_A"
        return 1
    }
    [[ $ENDPOINT_DEVICE == auto || $ENDPOINT_DEVICE =~ ^[A-Za-z0-9_.:-]+$ ]] || {
        ab_error "invalid ENDPOINT_DEVICE"
        return 1
    }
    ab_is_uint "$ENDPOINT_ID_BASE" || { ab_error "invalid ENDPOINT_ID_BASE"; return 1; }
    max_id=$((10#$ENDPOINT_ID_BASE + 8))
    ((10#$ENDPOINT_ID_BASE >= 1 && max_id <= 255)) || {
        ab_error "ENDPOINT_ID_BASE must reserve eight IDs in the range 1..255"
        return 1
    }
    [[ $LISTEN_ADDRESS == *:* ]] || { ab_error "invalid LISTEN_ADDRESS"; return 1; }
    listen_host=${LISTEN_ADDRESS%:*}
    listen_port=${LISTEN_ADDRESS##*:}
    ab_valid_ipv4 "$listen_host" && ab_valid_port "$listen_port" || {
        ab_error "LISTEN_ADDRESS must be an IPv4:port value"
        return 1
    }
    [[ $EDGE_BINARY == /* && $EDGE_BINARY =~ ^[A-Za-z0-9_./-]+$ ]] || { ab_error "invalid EDGE_BINARY"; return 1; }
    [[ $EDGE_SERVER_FILE == /* && $EDGE_SERVER_FILE =~ ^[A-Za-z0-9_./-]+$ ]] || { ab_error "invalid EDGE_SERVER_FILE"; return 1; }
    [[ $EDGE_SERVICE =~ ^[A-Za-z0-9_.@:-]+\.service$ ]] || { ab_error "invalid EDGE_SERVICE"; return 1; }
    [[ $EDGE_SWITCH_DELAY =~ ^[0-9]+([.][0-9]+)?$ ]] || { ab_error "invalid EDGE_SWITCH_DELAY"; return 1; }
    delay_whole=${EDGE_SWITCH_DELAY%%.*}
    delay_fraction=
    [[ $EDGE_SWITCH_DELAY != *.* ]] || delay_fraction=${EDGE_SWITCH_DELAY#*.}
    if ((10#$delay_whole > 60)) ||
       { ((10#$delay_whole == 60)) && [[ -n $delay_fraction && ! $delay_fraction =~ ^0+$ ]]; }; then
        ab_error "EDGE_SWITCH_DELAY must not exceed 60 seconds"
        return 1
    fi
    ab_is_uint "$PROBE_TIMEOUT" && ((10#$PROBE_TIMEOUT >= 1 && 10#$PROBE_TIMEOUT <= 60)) || {
        ab_error "PROBE_TIMEOUT must be between 1 and 60 seconds"
        return 1
    }
    ab_is_uint "$PROBE_ATTEMPTS" && ((10#$PROBE_ATTEMPTS >= 1 && 10#$PROBE_ATTEMPTS <= 10)) || {
        ab_error "PROBE_ATTEMPTS must be between 1 and 10"
        return 1
    }
    max_count=$count_a
    ((count_b <= max_count)) || max_count=$count_b
    probe_budget=$((10#$max_count * (10#$PROBE_ATTEMPTS * 10#$PROBE_TIMEOUT + 10#$PROBE_ATTEMPTS - 1)))
    ((probe_budget <= 180)) || {
        ab_error "relay probe configuration can take ${probe_budget}s; the maximum supported budget is 180s"
        return 1
    }
    [[ $FAIL_OPEN == yes || $FAIL_OPEN == no ]] || { ab_error "FAIL_OPEN must be yes or no"; return 1; }
    ab_is_uint "$SUBFLOWS" && ((10#$SUBFLOWS <= 8)) || { ab_error "SUBFLOWS must be 0..8"; return 1; }
    ab_is_uint "$ADD_ADDR_ACCEPTED" && ((10#$ADD_ADDR_ACCEPTED <= 8)) || {
        ab_error "ADD_ADDR_ACCEPTED must be 0..8"
        return 1
    }
    if [[ $MODE == aggregate ]]; then
        ((count_a >= 2 && 10#$SUBFLOWS >= count_a - 1 && 10#$ADD_ADDR_ACCEPTED >= count_a - 1)) || {
            ab_error "aggregation needs at least two relays and sufficient subflow/address limits"
            return 1
        }
    fi
    [[ $REQUIRE_TIME_SYNC == yes || $REQUIRE_TIME_SYNC == no ]] || {
        ab_error "REQUIRE_TIME_SYNC must be yes or no"
        return 1
    }
    [[ $ENABLE_FQ == yes || $ENABLE_FQ == no ]] || { ab_error "ENABLE_FQ must be yes or no"; return 1; }
    [[ $ENABLE_BBR == yes || $ENABLE_BBR == no || $ENABLE_BBR == auto ]] || {
        ab_error "ENABLE_BBR must be yes, no, or auto"
        return 1
    }
    [[ $LANDING_SERVICE == - || $LANDING_SERVICE =~ ^[A-Za-z0-9_.@:-]+\.service$ ]] || {
        ab_error "LANDING_SERVICE must be '-' or a systemd service name"
        return 1
    }
    if [[ -n $LANDING_BACKEND ]]; then
        ab_valid_ipv4 "${LANDING_BACKEND%:*}" && ab_valid_port "${LANDING_BACKEND##*:}" || {
            ab_error "LANDING_BACKEND must be an IPv4:port value"
            return 1
        }
        [[ $ROLE != landing || $LANDING_SERVICE == mptcp-port-tunnel-server.service ]] || {
            ab_error "LANDING_BACKEND requires LANDING_SERVICE=mptcp-port-tunnel-server.service"
            return 1
        }
    fi
}

ab_desired_group_for_hhmm()
{
    local now=$1
    local now_minutes a_minutes b_minutes

    [[ $MODE != aggregate ]] || { printf 'A\n'; return 0; }

    ab_valid_hhmm "$now" || return 1
    now_minutes=$(ab_hhmm_to_minutes "$now")
    a_minutes=$(ab_hhmm_to_minutes "$A_START")
    b_minutes=$(ab_hhmm_to_minutes "$B_START")
    if ((a_minutes < b_minutes)); then
        if ((now_minutes >= a_minutes && now_minutes < b_minutes)); then
            printf 'A\n'
        else
            printf 'B\n'
        fi
    else
        if ((now_minutes >= a_minutes || now_minutes < b_minutes)); then
            printf 'A\n'
        else
            printf 'B\n'
        fi
    fi
}

ab_desired_group_now()
{
    local now
    now=$(TZ=$TIMEZONE date +%H%M) || return 1
    ab_desired_group_for_hhmm "$now"
}

ab_select_group()
{
    [[ $MODE != aggregate || ${1:-} == A ]] || { ab_error "aggregate mode has only one always-active relay group (A)"; return 1; }
    case ${1:-} in
        A) AB_GROUP_CSV=$GROUP_A; AB_GROUP_PRIMARY=$PRIMARY_A ;;
        B) AB_GROUP_CSV=$GROUP_B; AB_GROUP_PRIMARY=$PRIMARY_B ;;
        *) return 1 ;;
    esac
}

ab_group_secondaries()
{
    local group=$1
    local item
    local old_ifs=$IFS

    ab_select_group "$group" || return 1
    IFS=,
    for item in $AB_GROUP_CSV; do
        [[ $MODE != aggregate && $item == "$AB_GROUP_PRIMARY" ]] || printf '%s\n' "$item"
    done
    IFS=$old_ifs
}

ab_group_candidates()
{
    local group=$1
    local current=${2:-}
    local item
    local old_ifs=$IFS

    ab_select_group "$group" || return 1
    if [[ -n $current ]] && ab_csv_contains "$AB_GROUP_CSV" "$current"; then
        printf '%s\n' "$current"
    fi
    [[ $AB_GROUP_PRIMARY == "$current" ]] || printf '%s\n' "$AB_GROUP_PRIMARY"
    IFS=,
    for item in $AB_GROUP_CSV; do
        [[ $item == "$current" || $item == "$AB_GROUP_PRIMARY" ]] || printf '%s\n' "$item"
    done
    IFS=$old_ifs
}

ab_owned_id()
{
    local id=${1:-}
    ab_is_uint "$id" || return 1
    ((10#$id >= 10#$ENDPOINT_ID_BASE + 1 && 10#$id <= 10#$ENDPOINT_ID_BASE + 8))
}

ab_atomic_write()
(
    local target=$1
    local content=$2
    local mode=${3:-0644}
    local dir tmp

    dir=${target%/*}
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$dir/.mptcp-ab.XXXXXX") || return 1
    trap 'rm -f "$tmp"' EXIT
    printf '%s\n' "$content" >"$tmp" || return 1
    chmod "$mode" "$tmp" || return 1
    if [[ ${MPTCP_AB_SKIP_CHOWN:-0} != 1 ]]; then
        chown root:root "$tmp" || return 1
    fi
    sync -f "$tmp" 2>/dev/null || sync "$tmp" 2>/dev/null || :
    mv -f "$tmp" "$target" || return 1
    sync -f "$dir" 2>/dev/null || :
)
