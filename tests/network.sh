#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export TEST_NETWORK=$WORK
export MPTCP_AB_RUN_DIR=$WORK/run
export MPTCP_AB_STATE_DIR=$WORK/state
mkdir -p "$WORK/bin"
cat >"$WORK/bin/nft" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $* == '-j list tables' ]]; then
    printf '{"nftables":['
    sep=
    for name in mptcp_ab_edge mptcp_ab_relay; do
        [[ -f $TEST_NETWORK/$name.owner ]] || continue
        printf '%s{"table":{"family":"ip","name":"%s"}}' "$sep" "$name"
        sep=,
    done
    printf ']}\n'
elif [[ $* == '-j list table ip '* ]]; then
    name=$5
    [[ -f $TEST_NETWORK/$name.owner ]] || exit 1
    if [[ ${FAKE_NFT_OLD_JSON:-0} == 1 ]]; then
        jq -n --arg name "$name" '{nftables:[{table:{family:"ip",name:$name}}]}'
        exit
    fi
    jq -n --arg name "$name" --arg owner "$(cat "$TEST_NETWORK/$name.owner")" \
        '{nftables:[{table:{family:"ip",name:$name,comment:$owner}}]}'
elif [[ $* == 'list table ip '* ]]; then
    name=$4
    printf 'table ip %s {\n\tcomment "%s"\n}\n' "$name" "$(cat "$TEST_NETWORK/$name.owner")"
elif [[ $1 == --check ]]; then
    [[ ${FAKE_NFT_FAIL_CHECK:-0} != 1 ]]
elif [[ $1 == -f ]]; then
    [[ ${FAKE_NFT_FAIL_APPLY:-0} != 1 ]] || exit 1
    cp "$2" "$TEST_NETWORK/applied"
    while read -r action kind family name rest; do
        [[ $kind == table ]] || continue
        case $action in
            delete) rm -f "$TEST_NETWORK/$name.owner" ;;
            add) printf 'mptcp-ab-switch\n' >"$TEST_NETWORK/$name.owner" ;;
        esac
    done <"$2"
else
    exit 2
fi
EOF
cat >"$WORK/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/bin/nft" "$WORK/bin/flock"
export MPTCP_AB_NFT_CMD=$WORK/bin/nft
source "$ROOT_DIR/lib/mptcp-ab-lib.sh"
source "$ROOT_DIR/lib/mptcp-ab-network.sh"
FLOCK_CMD=$WORK/bin/flock
LOCK_FILE=$WORK/run/switch.lock
require_root() { return 0; }
require_command_path() { [[ -n $1 && -x $1 ]]; }
ab_load_config "$ROOT_DIR/examples/edge.conf"
LANDING_PORT=22000
RELAY_PORT=21000
RELAY_PORTS=192.0.2.11:21001
network_apply
grep -q 'tcp dport 22000 dnat to 192.0.2.11:21001' "$WORK/applied"
cp "$WORK/applied" "$WORK/before"
RELAY_PORTS=192.0.2.11:21002
if FAKE_NFT_FAIL_CHECK=1 network_apply; then exit 1; fi
cmp "$WORK/before" "$WORK/applied"
if FAKE_NFT_FAIL_APPLY=1 network_apply; then exit 1; fi
cmp "$WORK/before" "$WORK/applied"
network_apply
grep -q '^delete table ip mptcp_ab_edge' "$WORK/applied"
grep -q 'dnat to 192.0.2.11:21002' "$WORK/applied"
FAKE_NFT_OLD_JSON=1 network_apply
printf 'external-owner\n' >"$WORK/mptcp_ab_relay.owner"
cp "$WORK/applied" "$WORK/before"
if network_apply; then exit 1; fi
if FAKE_NFT_OLD_JSON=1 network_apply; then exit 1; fi
cmp "$WORK/before" "$WORK/applied"
rm "$WORK/mptcp_ab_relay.owner"
ab_load_config "$ROOT_DIR/examples/relay.conf"
network_apply
[[ ! -e $WORK/mptcp_ab_edge.owner && -f $WORK/mptcp_ab_relay.owner ]]
grep -q 'dnat to 192.0.2.10:22000' "$WORK/applied"
network_apply cleanup
[[ ! -e $WORK/mptcp_ab_relay.owner ]]
network_apply cleanup
printf 'network replacement, failure preservation, ownership conflict, role transition and cleanup passed\n'
