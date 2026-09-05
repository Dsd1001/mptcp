#!/usr/bin/env bash

NFT_CMD=${MPTCP_AB_NFT_CMD:-$(command -v nft 2>/dev/null || true)}
JQ_CMD=${MPTCP_AB_JQ_CMD:-$(command -v jq 2>/dev/null || true)}
NETWORK_OWNER=mptcp-ab-switch

network_table_present()
{
    local name=$1 inventory
    inventory=$($NFT_CMD -j list tables) || return 2
    $JQ_CMD -e --arg name "$name" \
        'any(.nftables[]; .table.family == "ip" and .table.name == $name)' \
        <<<"$inventory" >/dev/null
}

network_assert_owned()
{
    local name=$1 inventory declaration
    inventory=$($NFT_CMD -j list table ip "$name") || return 1
    if $JQ_CMD -e --arg name "$name" --arg owner "$NETWORK_OWNER" \
        'any(.nftables[]; .table.family == "ip" and .table.name == $name and .table.comment == $owner)' \
        <<<"$inventory" >/dev/null; then
        return 0
    fi
    # nft 1.0.6 omits table comments from JSON; only accept a table-level comment.
    if $JQ_CMD -e --arg name "$name" \
        'any(.nftables[]; .table.family == "ip" and .table.name == $name and (.table | has("comment") | not))' \
        <<<"$inventory" >/dev/null; then
        declaration=$($NFT_CMD list table ip "$name") || return 1
        if awk -v header="table ip $name {" -v marker="comment \"$NETWORK_OWNER\"" '
            NR == 1 { if ($0 != header) exit 1; next }
            { sub(/^[[:space:]]+/, ""); if ($0 == "") next; exit ($0 != marker) }
            END { if (NR < 2) exit 1 }
        ' <<<"$declaration"; then
            return 0
        fi
    fi
    ab_error "nftables table ip $name is not owned by this tool"
    return 1
}

network_plan()
{
    local address port addresses=()
    case $ROLE in
        edge)
            printf 'edge_listen=%s\nlanding_port=%s\n' "$LISTEN_ADDRESS" "$LANDING_PORT"
            IFS=, read -r -a addresses <<<"$GROUP_A,$GROUP_B"
            for address in "${addresses[@]}"; do
                port=$(ab_relay_port "$address")
                printf 'relay_target=%s:%s (Edge logical port %s)\n' "$address" "$port" "$LANDING_PORT"
            done
            ;;
        relay)
            printf 'role=relay\nrelay_listen=%s:%s\nforward_to=%s:%s\nsnat=masquerade\n' \
                "$RELAY_LISTEN_ADDRESS" "$RELAY_PORT" "$LANDING_ADDRESS" "$LANDING_PORT"
            ;;
        landing) printf 'landing_listener_port=%s\n' "$LANDING_PORT" ;;
    esac
}

network_render_rules()
{
    local address port addresses=()
    case $ROLE in
        edge)
            printf 'add table ip mptcp_ab_edge { comment "%s"; }\n' "$NETWORK_OWNER"
            printf 'add chain ip mptcp_ab_edge output { type nat hook output priority -100; policy accept; }\n'
            IFS=, read -r -a addresses <<<"$GROUP_A,$GROUP_B"
            for address in "${addresses[@]}"; do
                port=$(ab_relay_port "$address")
                [[ $port != "$LANDING_PORT" ]] || continue
                printf 'add rule ip mptcp_ab_edge output ip daddr %s tcp dport %s dnat to %s:%s\n' \
                    "$address" "$LANDING_PORT" "$address" "$port"
            done
            ;;
        relay)
            printf 'add table ip mptcp_ab_relay { comment "%s"; }\n' "$NETWORK_OWNER"
            printf 'add chain ip mptcp_ab_relay prerouting { type nat hook prerouting priority dstnat; policy accept; }\n'
            printf 'add chain ip mptcp_ab_relay postrouting { type nat hook postrouting priority srcnat; policy accept; }\n'
            printf 'add chain ip mptcp_ab_relay forward { type filter hook forward priority filter; policy accept; }\n'
            printf 'add rule ip mptcp_ab_relay prerouting fib daddr type local '
            [[ $RELAY_LISTEN_ADDRESS == 0.0.0.0 ]] || printf 'ip daddr %s ' "$RELAY_LISTEN_ADDRESS"
            printf 'tcp dport %s dnat to %s:%s\n' "$RELAY_PORT" "$LANDING_ADDRESS" "$LANDING_PORT"
            printf 'add rule ip mptcp_ab_relay postrouting meta l4proto tcp ct status dnat ct original proto-dst %s ip daddr %s tcp dport %s masquerade\n' \
                "$RELAY_PORT" "$LANDING_ADDRESS" "$LANDING_PORT"
            printf 'add rule ip mptcp_ab_relay forward meta l4proto tcp ct status dnat ct original proto-dst %s ip daddr %s tcp dport %s accept\n' \
                "$RELAY_PORT" "$LANDING_ADDRESS" "$LANDING_PORT"
            printf 'add rule ip mptcp_ab_relay forward ct status dnat ct state established,related ip saddr %s tcp sport %s accept\n' \
                "$LANDING_ADDRESS" "$LANDING_PORT"
            ;;
    esac
}

network_apply()
(
    local mode=${1:-apply} name present work
    require_root
    require_command_path "$NFT_CMD" nft
    require_command_path "$JQ_CMD" jq
    require_command_path "$FLOCK_CMD" flock
    mkdir -p "$MPTCP_AB_RUN_DIR"
    exec 9>"$LOCK_FILE"
    $FLOCK_CMD -n 9 || { ab_error "another transaction is active"; return 1; }
    work=$(mktemp "$MPTCP_AB_RUN_DIR/network.XXXXXX") || return 1
    trap 'rm -f "$work"' EXIT
    for name in mptcp_ab_edge mptcp_ab_relay; do
        present=0
        network_table_present "$name" || present=$?
        case $present in
            0)
                network_assert_owned "$name" || return 1
                printf 'delete table ip %s\n' "$name" >>"$work"
                ;;
            1) ;;
            *) ab_error "cannot inspect nftables tables"; return 1 ;;
        esac
    done
    [[ $mode == cleanup ]] || network_render_rules >>"$work"
    # nft applies the whole batch atomically, including replacement of old rules.
    $NFT_CMD --check -f "$work" || return 1
    $NFT_CMD -f "$work" || return 1
    ab_log "managed network rules $mode completed"
)

network_ready()
{
    case $ROLE in
        edge) network_assert_owned mptcp_ab_edge ;;
        relay)
            [[ $(cat /proc/sys/net/ipv4/ip_forward) == 1 ]] && network_assert_owned mptcp_ab_relay
            ;;
        landing) return 0 ;;
    esac
}
