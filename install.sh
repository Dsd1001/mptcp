#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LOCAL_LIB=$SCRIPT_DIR/lib/mptcp-ab-lib.sh
LOCAL_CTL=$SCRIPT_DIR/bin/mptcp-abctl
CONFIG_DEST=/etc/mptcp-ab/config.conf
STATE_DIR=/var/lib/mptcp-ab
DOC_DIR=/usr/share/doc/mptcp-ab-switch
ACTION=install
SHOW_MENU=0
[[ $# -ne 0 || ! -t 0 ]] || SHOW_MENU=1
CONFIG_SOURCE=
ROLE_OVERRIDE=
BINARY_SOURCE=
NON_INTERACTIVE=0
ASSUME_YES=0
INSTALL_DEPS=0
PURGE=0
MIGRATE=0
NO_START=0
RESOLVED_EDGE_BINARY=
BINARY_TARGET=/usr/local/bin/mptcp-port-tunnel
BINARY_OWNERSHIP_MARKER=$STATE_DIR/tunnel-binary.ownership
BINARY_ORIGINAL=$STATE_DIR/originals/mptcp-port-tunnel
LANDING_OWNERSHIP_FILE=$STATE_DIR/landing-runtime.state

usage()
{
    cat <<'EOF'
Usage:
  sudo ./install.sh [install] [OPTIONS]
  sudo ./install.sh reconfigure [OPTIONS]
  ./install.sh plan --config FILE
  sudo ./install.sh doctor
  sudo ./install.sh uninstall [--purge]

Options:
  --config FILE          Use an existing configuration
  --role edge|relay|landing Role used by the interactive installer
  --binary FILE          Override the bundled tunnel binary
  --non-interactive      Require all values from --config
  --yes                  Skip the final confirmation
  --install-deps         Install missing Debian packages with apt-get
  --migrate              Disable conflicting legacy hard-switch units
  --no-start             Install files without starting services
  --purge                With uninstall, also remove configuration/state
  -h, --help             Show this help

Bundled tunnel binaries are built from tunnel/ for Linux amd64 and arm64.
EOF
}

die()
{
    printf 'install.sh: ERROR: %s\n' "$*" >&2
    exit 1
}

note()
{
    printf 'install.sh: %s\n' "$*" >&2
}

if [[ $# -gt 0 ]]; then
    case $1 in
        install|reconfigure|plan|doctor|uninstall) ACTION=$1; shift ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --config) shift; [[ $# -gt 0 ]] || die "--config requires a file"; CONFIG_SOURCE=$1 ;;
        --role) shift; [[ $# -gt 0 ]] || die "--role requires edge or landing"; ROLE_OVERRIDE=$1 ;;
        --binary) shift; [[ $# -gt 0 ]] || die "--binary requires a file"; BINARY_SOURCE=$1 ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        --yes) ASSUME_YES=1 ;;
        --install-deps) INSTALL_DEPS=1 ;;
        --purge) PURGE=1 ;;
        --migrate) MIGRATE=1 ;;
        --no-start) NO_START=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

if [[ $MIGRATE == 1 && $NO_START == 1 ]]; then
    die "--migrate cannot be combined with --no-start; migration must apply and verify the replacement runtime"
fi

for required_file in \
    "$LOCAL_LIB" \
    "$SCRIPT_DIR/lib/mptcp-ab-network.sh" \
    "$LOCAL_CTL" \
    "$SCRIPT_DIR/README.md" \
    "$SCRIPT_DIR/README.zh-CN.md" \
    "$SCRIPT_DIR/payload/SHA256SUMS" \
    "$SCRIPT_DIR/systemd/90-mptcp-ab.conf" \
    "$SCRIPT_DIR/systemd/mptcp-ab-bootstrap.service" \
    "$SCRIPT_DIR/systemd/mptcp-ab-network.service" \
    "$SCRIPT_DIR/systemd/mptcp-ab-fq.service" \
    "$SCRIPT_DIR/systemd/mptcp-ab-switch.service" \
    "$SCRIPT_DIR/systemd/mptcp-ab-switch.timer.in" \
    "$SCRIPT_DIR/systemd/mptcp-port-tunnel-server.service" \
    "$SCRIPT_DIR/systemd/mptcp-port-tunnel-client.service"; do
    [[ -f $required_file ]] || die "incomplete package; missing $required_file"
done
[[ -x $LOCAL_CTL ]] || die "controller is not executable: $LOCAL_CTL"
# shellcheck source=lib/mptcp-ab-lib.sh
. "$LOCAL_LIB"

require_root()
{
    [[ $EUID -eq 0 ]] || die "$ACTION must run as root"
}

prompt_value()
{
    local label=$1
    local default=$2
    local value
    if [[ -n $default ]]; then
        read -r -p "$label [$default]: " value || return 1
        value=${value:-$default}
    else
        read -r -p "$label: " value || return 1
    fi
    printf '%s\n' "$value"
}

prompt_yes_no()
{
    local label=$1
    local default=${2:-yes}
    local suffix='[Y/n]'
    local answer
    [[ $default == no ]] && suffix='[y/N]'
    read -r -p "$label $suffix: " answer
    answer=$(printf '%s' "${answer:-$default}" | tr '[:upper:]' '[:lower:]')
    [[ $answer == y || $answer == yes ]]
}

prompt_valid()
{
    local label=$1 default=$2 value
    shift 2
    while :; do
        value=$(prompt_value "$label" "$default") || return 1
        if "$@" "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
        note "Invalid value: $value; please try again."
    done
}

valid_role() { [[ $1 == edge || $1 == relay || $1 == landing ]]; }
valid_mode() { [[ $1 == aggregate || $1 == scheduled ]]; }
valid_aggregate_group() { valid_group "$1" && (($(ab_csv_count "$1") >= 2)); }
valid_action() { [[ $1 == install || $1 == reconfigure || $1 == plan || $1 == doctor || $1 == uninstall ]]; }
valid_timezone() { [[ $1 =~ ^[A-Za-z0-9_+./-]+$ && $1 != /* && $1 != *..* && -f /usr/share/zoneinfo/$1 ]]; }
valid_interface() { [[ $1 == auto || $1 =~ ^[A-Za-z0-9_.:-]+$ ]]; }
valid_landing_address() { ab_valid_ipv4 "$1" && [[ $1 != 0.0.0.0 && $1 != 127.* ]]; }
valid_service() { [[ $1 == - || $1 =~ ^[A-Za-z0-9_.@:-]+\.service$ ]]; }
valid_time() { [[ $1 =~ ^[0-2][0-9]:?[0-5][0-9]$ ]] && ab_valid_hhmm "${1/:/}"; }
valid_group() { ab_validate_csv_group relays "$1" && (($(ab_csv_count "$1") <= 8)); }
valid_group_b() { valid_group "$2" && ! overlap_groups "$1" "$2"; }
overlap_groups() {
    local address entries=()
    IFS=, read -r -a entries <<<"$1"
    for address in "${entries[@]}"; do
        ab_csv_contains "$2" "$address" && return 0
    done
    return 1
}
valid_b_time() { valid_time "$2" && [[ ${2/:/} != "$1" ]]; }
valid_delay() { [[ $1 =~ ^([0-9]|[1-5][0-9])([.][0-9]+)?$ || $1 == 60 ]]; }
valid_backend() { ab_valid_ipv4 "${1%:*}" && ab_valid_port "${1##*:}"; }
valid_integer_range() { ab_is_uint "$3" && ((${#3} <= 5)) && ((10#$3 >= $1 && 10#$3 <= $2)); }
valid_probe_timeout() { valid_integer_range 1 60 "$3" && (($1 * ($2 * 10#$3 + $2 - 1) <= 180)); }
valid_probe_attempts() { valid_integer_range 1 10 "$3" && (($1 * (10#$3 * $2 + 10#$3 - 1) <= 180)); }

detect_interface()
{
    ip -4 route show default 2>/dev/null | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

write_interactive_config()
{
    local target=$1
    local role group_a group_b primary_a primary_b relay_port timezone a_start b_start
    local endpoint_device listen_address delay fail_open require_sync enable_fq enable_bbr landing_service
    local landing_port landing_address relay_listen relay_ports= address port listen_host listen_port custom_ports=no
    local addresses=() landing_backend= mode=aggregate managed_landing=yes
    local endpoint_id subflows accepted probe_timeout probe_attempts count_a count_b max_count minimum=0

    [[ -t 0 ]] || die "interactive installation requires a terminal; use --non-interactive --config FILE"
    ab_apply_config_defaults
    if [[ $ACTION == reconfigure && -f $CONFIG_DEST ]]; then
        ab_load_config "$CONFIG_DEST"
        mode=$MODE
        [[ -n $LANDING_BACKEND ]] || managed_landing=no
    fi
    role=${ROLE_OVERRIDE:-$(prompt_valid 'Role (edge, relay, landing)' "${ROLE:-edge}" valid_role)}
    valid_role "$role" || die "invalid role: $role"
    relay_port=$(prompt_valid 'Relay public TCP port (default for all relays)' "$RELAY_PORT" ab_valid_port)
    landing_port=$(prompt_valid 'Landing application MPTCP port' "${LANDING_PORT:-$relay_port}" ab_valid_port)
    landing_address=$LANDING_ADDRESS
    relay_listen=$RELAY_LISTEN_ADDRESS
    group_a= group_b= primary_a= primary_b=
    timezone=$TIMEZONE a_start=$A_START b_start=$B_START
    if [[ $role == relay ]]; then
        relay_listen=$(prompt_valid 'Relay local destination IPv4 (0.0.0.0 for all local addresses)' "$relay_listen" ab_valid_ipv4)
        landing_address=$(prompt_valid 'Landing reachable IPv4 address' "$landing_address" valid_landing_address)
    else
        mode=$(prompt_valid 'Mode (aggregate, scheduled)' "$mode" valid_mode)
        if [[ $mode == aggregate ]]; then
            group_a=$(prompt_valid 'Simultaneous relay IPv4 addresses, comma separated (2-8)' "$GROUP_A" valid_aggregate_group)
        else
            group_a=$(prompt_valid 'A relay IPv4 addresses, comma separated (1-8)' "$GROUP_A" valid_group)
        fi
        primary_a=$(prompt_valid 'A preferred primary relay' "${PRIMARY_A:-${group_a%%,*}}" ab_csv_contains "$group_a")
        if [[ $mode == scheduled ]]; then
            group_b=$(prompt_valid 'B relay IPv4 addresses, comma separated (1-8)' "$GROUP_B" valid_group_b "$group_a")
            primary_b=$(prompt_valid 'B preferred primary relay' "${PRIMARY_B:-${group_b%%,*}}" ab_csv_contains "$group_b")
        fi
        [[ -z $RELAY_PORTS ]] || custom_ports=yes
        if prompt_yes_no 'Customize individual Relay public ports?' "$custom_ports"; then
            IFS=, read -r -a addresses <<<"$group_a,$group_b"
            for address in "${addresses[@]}"; do
                port=$(prompt_valid "Public TCP port for Relay $address" "$(RELAY_PORT=$relay_port ab_relay_port "$address")" ab_valid_port)
                relay_ports="${relay_ports:+$relay_ports,}$address:$port"
            done
        else
            relay_ports=
        fi
        if [[ $mode == scheduled ]]; then
            timezone=$(prompt_valid 'Schedule timezone' "$TIMEZONE" valid_timezone)
            a_start=$(prompt_valid 'A group starts (HH:MM or HHMM)' "$A_START" valid_time)
            a_start=${a_start/:/}
            b_start=$(prompt_valid 'B group starts (HH:MM or HHMM)' "$B_START" valid_b_time "$a_start")
            b_start=${b_start/:/}
        fi
    fi
    endpoint_device=$(prompt_valid 'Default network interface or auto' "$ENDPOINT_DEVICE" valid_interface)
    endpoint_id=$ENDPOINT_ID_BASE subflows=$SUBFLOWS accepted=$ADD_ADDR_ACCEPTED
    probe_timeout=$PROBE_TIMEOUT probe_attempts=$PROBE_ATTEMPTS
    listen_address=$LISTEN_ADDRESS
    delay=$EDGE_SWITCH_DELAY
    fail_open=$FAIL_OPEN
    landing_service=$LANDING_SERVICE
    landing_backend=$LANDING_BACKEND
    if [[ $role == edge ]]; then
        listen_host=$(prompt_valid 'Edge local listen IPv4' "${LISTEN_ADDRESS%:*}" ab_valid_ipv4)
        listen_port=$(prompt_valid 'Edge local listen TCP port' "${LISTEN_ADDRESS##*:}" ab_valid_port)
        listen_address=$listen_host:$listen_port
        if [[ $mode == scheduled ]]; then
            delay=$(prompt_valid 'Scheduled Edge delay after Landing, seconds' "$delay" valid_delay)
        else
            delay=0
        fi
        prompt_yes_no 'Use preferred primary when every health probe fails?' "$FAIL_OPEN" && fail_open=yes || fail_open=no
    elif [[ $role == landing ]]; then
        if prompt_yes_no 'Install the bundled MPTCP server to forward to a TCP backend?' "$managed_landing"; then
            landing_backend=$(prompt_valid 'Landing TCP backend IPv4:port' "${landing_backend:-127.0.0.1:1000}" valid_backend)
            landing_service=mptcp-port-tunnel-server.service
        else
            landing_backend=
            [[ $landing_service != mptcp-port-tunnel-server.service ]] || landing_service=-
            landing_service=$(prompt_valid "Landing MPTCP application service ('-' to skip service check)" "$landing_service" valid_service)
        fi
    fi
    require_sync=no
    if [[ $mode == scheduled ]]; then
        prompt_yes_no 'Require synchronized system time before switching?' "$REQUIRE_TIME_SYNC" && require_sync=yes || require_sync=no
    fi
    prompt_yes_no 'Apply an FQ root qdisc?' "$ENABLE_FQ" && enable_fq=yes || enable_fq=no
    enable_bbr=$ENABLE_BBR
    if prompt_yes_no 'Use BBR automatically when the kernel provides it?' "$([[ $ENABLE_BBR == no ]] && printf no || printf yes)"; then
        [[ $enable_bbr == yes ]] || enable_bbr=auto
    else
        enable_bbr=no
    fi
    if [[ $role != relay ]]; then
        count_a=$(ab_csv_count "$group_a")
        count_b=0
        [[ -z $group_b ]] || count_b=$(ab_csv_count "$group_b")
        max_count=$count_a
        ((count_b <= max_count)) || max_count=$count_b
        [[ $mode != aggregate ]] || minimum=$((count_a - 1))
        ((10#$subflows >= minimum)) || subflows=$minimum
        ((10#$accepted >= minimum)) || accepted=$minimum
    fi
    if [[ $role != relay ]] && prompt_yes_no 'Customize advanced MPTCP and health probe settings?' no; then
        endpoint_id=$(prompt_valid 'Managed endpoint ID base (1-247)' "$endpoint_id" valid_integer_range 1 247)
        subflows=$(prompt_valid "Maximum additional MPTCP subflows ($minimum-8)" "$subflows" valid_integer_range "$minimum" 8)
        accepted=$(prompt_valid "Maximum accepted remote addresses ($minimum-8)" "$accepted" valid_integer_range "$minimum" 8)
        if [[ $role == edge ]]; then
            probe_timeout=$(prompt_valid 'Relay probe timeout in seconds (1-60, total budget <=180s)' "$probe_timeout" valid_probe_timeout "$max_count" "$probe_attempts")
            probe_attempts=$(prompt_valid 'Relay probe attempts (1-10, total budget <=180s)' "$probe_attempts" valid_probe_attempts "$max_count" "$probe_timeout")
        fi
    fi

    umask 077
    cat >"$target" <<EOF
SCHEMA_VERSION=1
ROLE=$role
MODE=$mode
TIMEZONE=$timezone
A_START=$a_start
B_START=$b_start
RELAY_PORT=$relay_port
RELAY_PORTS=$relay_ports
LANDING_PORT=$landing_port
LANDING_ADDRESS=$landing_address
RELAY_LISTEN_ADDRESS=$relay_listen
GROUP_A=$group_a
GROUP_B=$group_b
PRIMARY_A=$primary_a
PRIMARY_B=$primary_b
ENDPOINT_DEVICE=$endpoint_device
ENDPOINT_ID_BASE=$endpoint_id
LISTEN_ADDRESS=$listen_address
EDGE_BINARY=/usr/local/bin/mptcp-port-tunnel
EDGE_SERVICE=mptcp-port-tunnel-client.service
EDGE_SERVER_FILE=/var/lib/mptcp-ab/active-server
EDGE_SWITCH_DELAY=$delay
PROBE_TIMEOUT=$probe_timeout
PROBE_ATTEMPTS=$probe_attempts
FAIL_OPEN=$fail_open
SUBFLOWS=$subflows
ADD_ADDR_ACCEPTED=$accepted
REQUIRE_TIME_SYNC=$require_sync
ENABLE_FQ=$enable_fq
ENABLE_BBR=$enable_bbr
LANDING_SERVICE=$landing_service
LANDING_BACKEND=$landing_backend
EOF
}

prepare_config()
{
    local output=$1
    if [[ -n $CONFIG_SOURCE ]]; then
        [[ -f $CONFIG_SOURCE ]] || die "configuration file not found: $CONFIG_SOURCE"
        cp "$CONFIG_SOURCE" "$output"
    elif [[ $NON_INTERACTIVE == 1 ]]; then
        die "--non-interactive requires --config FILE"
    elif [[ $ACTION == reconfigure && -f $CONFIG_DEST && ! -t 0 ]]; then
        cp "$CONFIG_DEST" "$output"
        note "using existing $CONFIG_DEST; pass --config to change it non-interactively"
    else
        write_interactive_config "$output"
    fi

    MPTCP_AB_SKIP_ZONEINFO=0 MPTCP_AB_CONFIG_FILE=$output MPTCP_AB_LIB=$LOCAL_LIB \
        "$LOCAL_CTL" validate-config "$output" >/dev/null
    ab_load_config "$output"
    if [[ -n $ROLE_OVERRIDE && $ROLE != "$ROLE_OVERRIDE" ]]; then
        die "--role $ROLE_OVERRIDE does not match ROLE=$ROLE in the configuration"
    fi
    if [[ $ROLE == edge ]]; then
        [[ $EDGE_BINARY == "$BINARY_TARGET" ]] ||
            die "the packaged Edge unit requires EDGE_BINARY=$BINARY_TARGET"
        [[ $EDGE_SERVICE == mptcp-port-tunnel-client.service ]] ||
            die "the packaged Edge unit requires EDGE_SERVICE=mptcp-port-tunnel-client.service"
        [[ $EDGE_SERVER_FILE == /var/lib/mptcp-ab/active-server ]] ||
            die "the packaged Edge unit requires EDGE_SERVER_FILE=/var/lib/mptcp-ab/active-server"
    elif [[ -n $BINARY_SOURCE && ( $ROLE != landing || -z $LANDING_BACKEND ) ]]; then
        die "--binary requires Edge or a managed Landing server"
    fi
}

show_plan()
{
    local config=$1
    MPTCP_AB_CONFIG_FILE=$config MPTCP_AB_LIB=$LOCAL_LIB "$LOCAL_CTL" plan
    [[ $ROLE != relay ]] || return 0
    if [[ $MODE == aggregate ]]; then
        printf 'mode=aggregate\nschedule=always-on\nhard_switch=only if initial relay fails\n'
        printf 'landing_advertises=all aggregate relays\n'
    else
        printf 'mode=scheduled\nschedule=%s-%s %s\nhard_switch=yes\n' "$A_START" "$B_START" "$TIMEZONE"
        printf 'landing_advertises=all relays in the active group except its configured primary\n'
    fi
    cat <<EOF
landing_backend=${LANDING_BACKEND:-external native MPTCP application}
EOF
}

install_missing_dependencies()
{
    local missing=()
    local command_name
    for command_name in \
        ip ss tc flock timeout nc systemctl timedatectl logger awk sed grep sort cmp stat \
        sysctl modprobe sha256sum nft jq; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    if [[ $INSTALL_DEPS != 1 ]]; then
        die "missing commands: ${missing[*]}; rerun with --install-deps on Debian"
    fi
    command -v apt-get >/dev/null 2>&1 || die "automatic dependency installation requires apt-get"
    note "installing Debian runtime dependencies"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        iproute2 util-linux coreutils netcat-openbsd kmod procps nftables jq
    missing=()
    for command_name in \
        ip ss tc flock timeout nc systemctl timedatectl logger awk sed grep sort cmp stat \
        sysctl modprobe sha256sum nft jq; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "commands are still missing after dependency installation: ${missing[*]}"
}

preflight_platform()
{
    [[ $(uname -s) == Linux ]] || die "installation requires Linux"
    [[ -d /run/systemd/system ]] || die "installation requires systemd"
    install_missing_dependencies
    [[ $ROLE != relay ]] || return 0
    [[ -e /proc/sys/net/mptcp/enabled ]] || die "the running kernel does not provide MPTCP"
    ip mptcp limits show >/dev/null 2>&1 || die "iproute2 does not provide a working 'ip mptcp' interface"
}

payload_for_arch()
{
    case $(uname -m) in
        aarch64|arm64) printf '%s\n' "$SCRIPT_DIR/payload/linux-arm64/mptcp-port-tunnel" ;;
        x86_64|amd64) printf '%s\n' "$SCRIPT_DIR/payload/linux-amd64/mptcp-port-tunnel" ;;
        *) return 1 ;;
    esac
}

resolve_edge_binary()
{
    local candidate=
    if [[ -n $BINARY_SOURCE ]]; then
        candidate=$BINARY_SOURCE
    elif candidate=$(payload_for_arch 2>/dev/null) && [[ -f $candidate ]]; then
        :
    else
        if [[ $NON_INTERACTIVE == 0 && -t 0 ]]; then
            candidate=$(prompt_value "Path to compatible Linux $(uname -m) mptcp-port-tunnel binary" '')
        else
            die "no tunnel binary is available for $(uname -m); pass --binary FILE"
        fi
    fi
    [[ -f $candidate && -x $candidate ]] || die "Edge tunnel binary is not executable: $candidate"
    verify_bundled_edge_binary "$candidate"
    validate_edge_binary_contract "$candidate"
    printf '%s\n' "$candidate"
}

verify_bundled_edge_binary()
{
    local candidate=$1
    local relative expected actual

    [[ $candidate == "$SCRIPT_DIR"/payload/* ]] || return 0
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required to verify the bundled Edge binary"
    relative=${candidate#"$SCRIPT_DIR/payload/"}
    expected=$(awk -v path="$relative" '$2 == path {print $1}' "$SCRIPT_DIR/payload/SHA256SUMS")
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || die "no valid checksum is recorded for bundled payload: $relative"
    actual=$(sha256sum "$candidate" | awk '{print $1}')
    [[ $actual == "$expected" ]] || die "bundled Edge binary checksum mismatch: $relative"
}

validate_edge_binary_contract()
{
    local candidate=$1
    local help flag
    local client_flags=(
        listen server-file dial-timeout max-connections tcp-user-timeout
        tcp-keepalive-idle tcp-keepalive-interval tcp-keepalive-count
        tcp-idle-timeout tcp-soft-max-age tcp-soft-age-idle-grace
        tcp-hard-max-age tcp-max-age-jitter retired-target-idle-timeout
        retired-target-max-age
    )
    local probe_flags=(server timeout)

    if ! help=$("$candidate" client tcp --help 2>&1); then
        die "Edge tunnel binary does not provide 'client tcp --help': $candidate"
    fi
    for flag in "${client_flags[@]}"; do
        if ! grep -Eq "^[[:space:]]+-$flag([[:space:]]|$)" <<<"$help"; then
            die "Edge tunnel binary is missing client tcp flag --$flag: $candidate"
        fi
    done
    if ! help=$("$candidate" probe --help 2>&1); then
        die "Edge tunnel binary does not provide 'probe --help': $candidate"
    fi
    for flag in "${probe_flags[@]}"; do
        if ! grep -Eq "^[[:space:]]+-$flag([[:space:]]|$)" <<<"$help"; then
            die "Edge tunnel binary is missing probe flag --$flag: $candidate"
        fi
    done
}

backup_managed_files()
{
    local backup_dir=$1
    local path encoded
    mkdir -p "$backup_dir"
    : >"$backup_dir/manifest"
    for path in \
        /etc/mptcp-ab/config.conf \
        /etc/mptcp-ab/client.env \
        /etc/mptcp-ab/server.env \
        /etc/mptcp-ab/interface.env \
        /etc/sysctl.d/90-mptcp-ab.conf \
        /etc/sysctl.d/91-mptcp-ab-performance.conf \
        /etc/sysctl.d/92-mptcp-ab-network.conf \
        /etc/systemd/system/mptcp-ab-network.service \
        /etc/systemd/system/mptcp-ab-bootstrap.service \
        /etc/systemd/system/mptcp-ab-switch.service \
        /etc/systemd/system/mptcp-ab-switch.timer \
        /etc/systemd/system/mptcp-ab-fq.service \
        /etc/systemd/system/mptcp-port-tunnel-server.service \
        /etc/systemd/system/mptcp-port-tunnel-client.service; do
        if [[ -e $path ]]; then
            encoded=${path//\//__}
            cp -a "$path" "$backup_dir/$encoded"
            printf '%s %s\n' "$encoded" "$path" >>"$backup_dir/manifest"
        fi
    done
}

atomic_install()
{
    local source=$1
    local target=$2
    local mode=$3
    local dir tmp
    dir=${target%/*}
    mkdir -p "$dir"
    tmp=$(mktemp "$dir/.mptcp-ab-install.XXXXXX")
    install -m "$mode" "$source" "$tmp"
    chown root:root "$tmp"
    mv -f "$tmp" "$target"
}

write_text_file()
{
    local target=$1
    local mode=$2
    local content=$3
    local tmp
    tmp=$(mktemp)
    printf '%s' "$content" >"$tmp"
    atomic_install "$tmp" "$target" "$mode"
    rm -f "$tmp"
}

timer_calendar()
{
    local hhmm=$1
    printf '*-*-* %s:%s:00 %s\n' "${hhmm:0:2}" "${hhmm:2:2}" "$TIMEZONE"
}

render_timer()
{
    local output=$1
    local a_calendar b_calendar
    if [[ $MODE == aggregate ]]; then
        sed '/^OnCalendar=/d' "$SCRIPT_DIR/systemd/mptcp-ab-switch.timer.in" >"$output"
        return
    fi
    a_calendar=$(timer_calendar "$A_START")
    b_calendar=$(timer_calendar "$B_START")
    sed -e "s|@A_ON_CALENDAR@|$a_calendar|" \
        -e "s|@B_ON_CALENDAR@|$b_calendar|" \
        "$SCRIPT_DIR/systemd/mptcp-ab-switch.timer.in" >"$output"
}

quiesce_managed_switching()
{
    systemctl stop mptcp-ab-switch.timer >/dev/null 2>&1 || :
    mkdir -p /run/mptcp-ab
    exec 8>/run/mptcp-ab/switch.lock
    flock -w 450 8 || die "an existing MPTCP switch did not finish within 450 seconds"
    systemctl stop mptcp-ab-switch.service >/dev/null 2>&1 || :
}

release_managed_switch_lock()
{
    flock -u 8 || die "failed to release the MPTCP switch lock"
    exec 8>&-
}

cleanup_landing_runtime()
{
    [[ -e $LANDING_OWNERSHIP_FILE || -L $LANDING_OWNERSHIP_FILE || -d $STATE_DIR/landing-transaction ]] || return 0
    MPTCP_AB_LIB=$LOCAL_LIB \
    MPTCP_AB_STATE_DIR=$STATE_DIR \
    MPTCP_AB_RUN_DIR=/run/mptcp-ab \
        "$LOCAL_CTL" cleanup-landing
}

validate_runtime_transition_options()
{
    [[ $ROLE != landing && ( -e $LANDING_OWNERSHIP_FILE || -L $LANDING_OWNERSHIP_FILE || -d $STATE_DIR/landing-transaction ) ]] || return 0
    [[ $NO_START == 0 ]] ||
        die "cannot change a managed Landing role with --no-start; runtime cleanup must be applied"
}

cleanup_landing_before_edge_install()
{
    [[ $ROLE != landing && ( -e $LANDING_OWNERSHIP_FILE || -L $LANDING_OWNERSHIP_FILE || -d $STATE_DIR/landing-transaction ) ]] || return 0
    release_managed_switch_lock
    cleanup_landing_runtime
    quiesce_managed_switching
}

stop_edge_client_before_install()
{
    local state

    [[ $NO_START == 1 ]] || systemctl stop mptcp-port-tunnel-server.service >/dev/null 2>&1 || :

    [[ $ROLE != edge || $NO_START == 0 ]] || return 0
    systemctl stop mptcp-port-tunnel-client.service >/dev/null 2>&1 || :
    state=$(systemctl is-active mptcp-port-tunnel-client.service 2>/dev/null || true)
    case $state in
        active|activating|reloading|deactivating)
            die "cannot stop the Edge client before updating network rules and role files"
            ;;
    esac
}

disable_legacy_units_if_requested()
{
    local conflicts=()
    local legacy_units=()
    local opposite_units=()
    local unit
    case $ROLE in
        edge)
            legacy_units=(
                mptcp-hard-switch-edge.timer
                mptcp-hard-switch-edge.service
                mptcp-port-tunnel-client-tcp-ab.service
            )
            opposite_units=(
                mptcp-hard-switch-landing.timer
                mptcp-reconcile-effective-membership-landing.timer
                mptcp-hard-switch-landing.service
                mptcp-reconcile-effective-membership-landing.service
            )
            ;;
        landing)
            legacy_units=(
                mptcp-hard-switch-landing.timer
                mptcp-reconcile-effective-membership-landing.timer
                mptcp-hard-switch-landing.service
                mptcp-reconcile-effective-membership-landing.service
            )
            opposite_units=(
                mptcp-hard-switch-edge.timer
                mptcp-hard-switch-edge.service
                mptcp-port-tunnel-client-tcp-ab.service
            )
            ;;
        relay)
            opposite_units=(
                mptcp-hard-switch-edge.timer mptcp-hard-switch-edge.service
                mptcp-port-tunnel-client-tcp-ab.service
                mptcp-hard-switch-landing.timer mptcp-hard-switch-landing.service
                mptcp-reconcile-effective-membership-landing.timer
                mptcp-reconcile-effective-membership-landing.service
            )
            ;;
    esac
    for unit in "${opposite_units[@]}"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null ||
           systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            die "legacy unit $unit belongs to the opposite role; stop it and clean its old runtime before changing roles"
        fi
    done
    for unit in "${legacy_units[@]}"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null ||
           systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            conflicts+=("$unit")
        fi
    done
    [[ ${#conflicts[@]} -eq 0 ]] && return 0
    if [[ $MIGRATE != 1 ]]; then
        die "conflicting legacy units are active or enabled: ${conflicts[*]}; rerun with --migrate during a maintenance window"
    fi
    note "disabling legacy units: ${conflicts[*]}"
    for unit in "${legacy_units[@]}"; do
        systemctl disable "$unit" >/dev/null 2>&1 || :
        systemctl stop "$unit" >/dev/null 2>&1 || :
    done
    for unit in "${legacy_units[@]}"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null ||
           systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            die "failed to disable legacy unit: $unit"
        fi
    done
}

prepare_tunnel_binary_ownership()
{
    local ownership tmp

    if [[ -f $BINARY_OWNERSHIP_MARKER ]]; then
        ownership=$(sed -n '1p' "$BINARY_OWNERSHIP_MARKER")
        case $ownership in
            created) return 0 ;;
            replaced)
                [[ -e $BINARY_ORIGINAL || -L $BINARY_ORIGINAL ]] ||
                    die "tunnel binary ownership marker exists but its original backup is missing"
                return 0
                ;;
            *) die "invalid tunnel binary ownership marker: $BINARY_OWNERSHIP_MARKER" ;;
        esac
    fi

    mkdir -p "${BINARY_ORIGINAL%/*}"
    if [[ -e $BINARY_TARGET || -L $BINARY_TARGET ]]; then
        [[ ! -e $BINARY_ORIGINAL && ! -L $BINARY_ORIGINAL ]] ||
            die "refusing to overwrite untracked tunnel binary backup: $BINARY_ORIGINAL"
        tmp=$BINARY_ORIGINAL.tmp.$$
        cp -a "$BINARY_TARGET" "$tmp"
        mv -f "$tmp" "$BINARY_ORIGINAL"
        write_text_file "$BINARY_OWNERSHIP_MARKER" 0600 $'replaced\n'
    else
        write_text_file "$BINARY_OWNERSHIP_MARKER" 0600 $'created\n'
    fi
}

restore_or_remove_owned_tunnel_binary()
{
    local ownership tmp

    [[ -f $BINARY_OWNERSHIP_MARKER ]] || {
        note "leaving unowned tunnel binary unchanged: $BINARY_TARGET"
        return 0
    }
    ownership=$(sed -n '1p' "$BINARY_OWNERSHIP_MARKER")
    case $ownership in
        created)
            rm -f "$BINARY_TARGET"
            ;;
        replaced)
            [[ -e $BINARY_ORIGINAL || -L $BINARY_ORIGINAL ]] || {
                note "cannot restore original tunnel binary; backup is missing: $BINARY_ORIGINAL"
                return 1
            }
            tmp=$BINARY_TARGET.restore.$$
            rm -f "$tmp"
            cp -a "$BINARY_ORIGINAL" "$tmp" || return 1
            mv -f "$tmp" "$BINARY_TARGET" || return 1
            rm -f "$BINARY_ORIGINAL"
            ;;
        *)
            note "refusing to alter tunnel binary because its ownership marker is invalid"
            return 1
            ;;
    esac
    rm -f "$BINARY_OWNERSHIP_MARKER"
}

cleanup_legacy_landing_endpoints()
{
    local line address id endpoint_output
    [[ $MIGRATE == 1 && $ROLE == landing ]] || return 0
    endpoint_output=$(ip mptcp endpoint show) || die "cannot read MPTCP endpoints before migration"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        address=${line%% *}
        if ! ab_csv_contains "$GROUP_A" "$address" && ! ab_csv_contains "$GROUP_B" "$address"; then
            continue
        fi
        id=$(printf '%s\n' "$line" | awk '{for (i=1; i<NF; i++) if ($i == "id") {print $(i+1); exit}}')
        ab_is_uint "$id" || die "cannot parse legacy endpoint: $line"
        note "removing legacy relay endpoint $address id $id"
        ip mptcp endpoint delete id "$id"
    done <<<"$endpoint_output"
}

configure_performance()
{
    local use_bbr=0
    if [[ $ENABLE_BBR != no ]]; then
        modprobe tcp_bbr >/dev/null 2>&1 || :
        if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            use_bbr=1
        elif [[ $ENABLE_BBR == yes ]]; then
            die "ENABLE_BBR=yes but the running kernel does not provide BBR"
        fi
    fi
    if [[ $use_bbr == 1 ]]; then
        write_text_file /etc/sysctl.d/91-mptcp-ab-performance.conf 0644 $'# Managed by mptcp-ab-switch.\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n'
    else
        rm -f /etc/sysctl.d/91-mptcp-ab-performance.conf
    fi
}

install_files()
{
    local config=$1
    local timer_tmp=$2
    local interface edge_binary=

    mkdir -p /etc/mptcp-ab "$STATE_DIR/backups" "$DOC_DIR"
    chmod 0755 "$STATE_DIR"
    atomic_install "$config" "$CONFIG_DEST" 0600
    atomic_install "$LOCAL_LIB" /usr/local/lib/mptcp-ab/mptcp-ab-lib.sh 0644
    atomic_install "$SCRIPT_DIR/lib/mptcp-ab-network.sh" /usr/local/lib/mptcp-ab/mptcp-ab-network.sh 0644
    atomic_install "$LOCAL_CTL" /usr/local/sbin/mptcp-abctl 0755
    atomic_install "$SCRIPT_DIR/systemd/mptcp-ab-network.service" /etc/systemd/system/mptcp-ab-network.service 0644
    atomic_install "$SCRIPT_DIR/systemd/mptcp-ab-bootstrap.service" /etc/systemd/system/mptcp-ab-bootstrap.service 0644
    atomic_install "$SCRIPT_DIR/systemd/mptcp-ab-switch.service" /etc/systemd/system/mptcp-ab-switch.service 0644
    atomic_install "$timer_tmp" /etc/systemd/system/mptcp-ab-switch.timer 0644
    atomic_install "$SCRIPT_DIR/systemd/90-mptcp-ab.conf" /etc/sysctl.d/90-mptcp-ab.conf 0644
    if [[ $ROLE == relay ]]; then
        rm -f /etc/sysctl.d/90-mptcp-ab.conf
        write_text_file /etc/sysctl.d/92-mptcp-ab-network.conf 0644 $'# Managed by mptcp-ab-switch.\nnet.ipv4.ip_forward=1\n'
    else
        rm -f /etc/sysctl.d/92-mptcp-ab-network.conf
    fi
    atomic_install "$SCRIPT_DIR/README.md" "$DOC_DIR/README.md" 0644
    atomic_install "$SCRIPT_DIR/README.zh-CN.md" "$DOC_DIR/README.zh-CN.md" 0644

    interface=$ENDPOINT_DEVICE
    [[ $interface != auto ]] || interface=$(detect_interface)
    [[ -n $interface ]] || die "cannot detect the default IPv4 interface; configure ENDPOINT_DEVICE"
    write_text_file /etc/mptcp-ab/interface.env 0644 "$(printf 'NETWORK_INTERFACE=%s\n' "$interface")"

    if [[ $ENABLE_FQ == yes ]]; then
        atomic_install "$SCRIPT_DIR/systemd/mptcp-ab-fq.service" /etc/systemd/system/mptcp-ab-fq.service 0644
    else
        rm -f /etc/systemd/system/mptcp-ab-fq.service
    fi

    if [[ $ROLE == edge || ( $ROLE == landing && -n $LANDING_BACKEND ) ]]; then
        edge_binary=$RESOLVED_EDGE_BINARY
        [[ -n $edge_binary ]] || die "internal error: Edge binary was not resolved"
        if [[ $edge_binary != "$BINARY_TARGET" ]]; then
            prepare_tunnel_binary_ownership
            atomic_install "$edge_binary" "$BINARY_TARGET" 0755
        fi
    fi
    if [[ $ROLE == edge ]]; then
        atomic_install "$SCRIPT_DIR/systemd/mptcp-port-tunnel-client.service" /etc/systemd/system/mptcp-port-tunnel-client.service 0644
        write_text_file /etc/mptcp-ab/client.env 0644 "$(printf 'LISTEN_ADDRESS=%s\nSERVER_FILE=%s\n' "$LISTEN_ADDRESS" "$EDGE_SERVER_FILE")"
    else
        rm -f /etc/mptcp-ab/client.env /etc/systemd/system/mptcp-port-tunnel-client.service
    fi
    if [[ $ROLE == landing && -n $LANDING_BACKEND ]]; then
        atomic_install "$SCRIPT_DIR/systemd/mptcp-port-tunnel-server.service" /etc/systemd/system/mptcp-port-tunnel-server.service 0644
        write_text_file /etc/mptcp-ab/server.env 0644 "$(printf 'LANDING_PORT=%s\nLANDING_BACKEND=%s\n' "$LANDING_PORT" "$LANDING_BACKEND")"
    else
        rm -f /etc/mptcp-ab/server.env /etc/systemd/system/mptcp-port-tunnel-server.service
    fi
    configure_performance
}

enable_runtime()
{
    if [[ -f /etc/sysctl.d/90-mptcp-ab.conf ]]; then
        sysctl -p /etc/sysctl.d/90-mptcp-ab.conf >/dev/null
    fi
    if [[ -f /etc/sysctl.d/92-mptcp-ab-network.conf ]]; then
        sysctl -p /etc/sysctl.d/92-mptcp-ab-network.conf >/dev/null
    fi
    if [[ -f /etc/sysctl.d/91-mptcp-ab-performance.conf ]]; then
        sysctl -p /etc/sysctl.d/91-mptcp-ab-performance.conf >/dev/null
    fi
    systemctl daemon-reload
    systemctl enable mptcp-ab-network.service
    if [[ $ROLE == relay ]]; then
        systemctl disable --now mptcp-ab-bootstrap.service mptcp-ab-switch.timer
    else
        systemctl enable mptcp-ab-bootstrap.service mptcp-ab-switch.timer
    fi
    if [[ $ENABLE_FQ == yes ]]; then
        systemctl enable mptcp-ab-fq.service
    else
        systemctl disable --now mptcp-ab-fq.service 2>/dev/null || :
    fi
    if [[ $ROLE == edge ]]; then
        systemctl enable mptcp-port-tunnel-client.service
    else
        systemctl disable --now mptcp-port-tunnel-client.service 2>/dev/null || :
    fi
    if [[ $ROLE == landing && -n $LANDING_BACKEND ]]; then
        systemctl enable mptcp-port-tunnel-server.service
    else
        systemctl disable --now mptcp-port-tunnel-server.service 2>/dev/null || :
    fi
    if [[ $NO_START == 0 ]]; then
        systemctl restart mptcp-ab-network.service
        [[ $ROLE == relay ]] || systemctl restart mptcp-ab-bootstrap.service
        [[ $ENABLE_FQ == yes ]] && systemctl restart mptcp-ab-fq.service
        [[ $ROLE == edge ]] && systemctl restart mptcp-port-tunnel-client.service
        if [[ $ROLE == landing && -n $LANDING_BACKEND ]]; then
            systemctl restart mptcp-port-tunnel-server.service
        fi
        [[ $ROLE == relay ]] || systemctl restart mptcp-ab-switch.timer
    fi
    return 0
}

run_install()
{
    local temp_dir config timer_tmp backup_dir
    require_root
    [[ $(uname -s) == Linux ]] || die "installation requires Linux"
    [[ -d /run/systemd/system ]] || die "installation requires systemd"
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT
    config=$temp_dir/config.conf
    timer_tmp=$temp_dir/mptcp-ab-switch.timer
    prepare_config "$config"
    show_plan "$config"
    if [[ $ASSUME_YES != 1 ]] && ! prompt_yes_no 'Install this configuration?' yes; then
        note 'installation cancelled'
        exit 0
    fi
    preflight_platform
    if [[ $ROLE == edge || ( $ROLE == landing && -n $LANDING_BACKEND ) ]]; then
        RESOLVED_EDGE_BINARY=$(resolve_edge_binary)
    fi
    render_timer "$timer_tmp"
    backup_dir=$STATE_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ)-$$
    backup_managed_files "$backup_dir"
    if [[ $MIGRATE == 1 ]]; then
        ip mptcp endpoint show >"$backup_dir/pre-migration-endpoints"
        ip mptcp limits show >"$backup_dir/pre-migration-limits"
    fi
    validate_runtime_transition_options
    quiesce_managed_switching
    cleanup_landing_before_edge_install
    stop_edge_client_before_install
    disable_legacy_units_if_requested
    cleanup_legacy_landing_endpoints
    install_files "$config" "$timer_tmp"
    release_managed_switch_lock
    enable_runtime
    note "installation complete; run 'mptcp-abctl doctor' to verify the data-plane listener"
}

run_plan_action()
{
    local temp_dir config bundled
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT
    config=$temp_dir/config.conf
    prepare_config "$config"
    show_plan "$config"
    if [[ $ROLE == edge || ( $ROLE == landing && -n $LANDING_BACKEND ) ]]; then
        if [[ -n $BINARY_SOURCE ]]; then
            [[ -f $BINARY_SOURCE && -x $BINARY_SOURCE ]] ||
                die "Edge tunnel binary is not executable: $BINARY_SOURCE"
            printf 'edge_binary=%s\n' "$BINARY_SOURCE"
        elif bundled=$(payload_for_arch 2>/dev/null) && [[ -f $bundled ]]; then
            printf 'edge_binary=%s\n' "$bundled"
        else
            printf 'edge_binary=required (--binary FILE); no bundled payload for %s\n' "$(uname -m)"
        fi
    fi
}

run_uninstall()
{
    require_root
    quiesce_managed_switching
    release_managed_switch_lock
    systemctl stop mptcp-port-tunnel-server.service mptcp-port-tunnel-client.service mptcp-ab-bootstrap.service mptcp-ab-fq.service \
        >/dev/null 2>&1 || :
    cleanup_landing_runtime || die "Landing runtime cleanup failed; uninstall stopped"
    MPTCP_AB_LIB=$LOCAL_LIB "$LOCAL_CTL" network-cleanup || die "network cleanup failed; uninstall stopped"
    for unit in mptcp-ab-network.service mptcp-ab-switch.timer mptcp-ab-switch.service mptcp-ab-bootstrap.service mptcp-ab-fq.service mptcp-port-tunnel-client.service mptcp-port-tunnel-server.service; do
        systemctl disable --now "$unit" 2>/dev/null || :
    done
    restore_or_remove_owned_tunnel_binary || die "tunnel binary restoration failed; uninstall stopped to preserve its backup"
    rm -f \
        /etc/systemd/system/mptcp-ab-switch.timer \
        /etc/systemd/system/mptcp-ab-network.service \
        /etc/systemd/system/mptcp-ab-switch.service \
        /etc/systemd/system/mptcp-ab-bootstrap.service \
        /etc/systemd/system/mptcp-ab-fq.service \
        /etc/systemd/system/mptcp-port-tunnel-client.service \
        /etc/systemd/system/mptcp-port-tunnel-server.service \
        /etc/sysctl.d/90-mptcp-ab.conf \
        /etc/sysctl.d/91-mptcp-ab-performance.conf \
        /etc/sysctl.d/92-mptcp-ab-network.conf \
        /usr/local/sbin/mptcp-abctl \
        /usr/local/lib/mptcp-ab/mptcp-ab-lib.sh \
        /usr/local/lib/mptcp-ab/mptcp-ab-network.sh
    rm -rf /usr/share/doc/mptcp-ab-switch
    rmdir /usr/local/lib/mptcp-ab 2>/dev/null || :
    systemctl daemon-reload
    if [[ $PURGE == 1 ]]; then
        rm -rf /etc/mptcp-ab /var/lib/mptcp-ab /usr/share/doc/mptcp-ab-switch /usr/local/lib/mptcp-ab
        note 'uninstalled and purged configuration/state/backups'
    else
        note 'uninstalled; configuration and state were retained'
    fi
}

if [[ $SHOW_MENU == 1 ]]; then
    printf '\nMPTCP aggregation and schedule configuration\n' >&2
    ACTION=$(prompt_valid 'Action (install, reconfigure, plan, doctor, uninstall)' install valid_action)
    if [[ $ACTION == install || $ACTION == reconfigure ]]; then
        prompt_yes_no 'Install missing dependencies with apt-get?' yes && INSTALL_DEPS=1 || :
    elif [[ $ACTION == uninstall ]]; then
        prompt_yes_no 'Uninstall MPTCP services and managed network rules?' no || exit 0
    fi
fi

case $ACTION in
    install|reconfigure) run_install ;;
    plan) run_plan_action ;;
    doctor)
        require_root
        [[ -x /usr/local/sbin/mptcp-abctl ]] || die "mptcp-abctl is not installed"
        exec /usr/local/sbin/mptcp-abctl doctor
        ;;
    uninstall) run_uninstall ;;
esac
