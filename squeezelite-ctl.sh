#!/bin/bash
# squeezelite-ctl.sh — manage a squeezelite LXC container's settings from the
# Proxmox host without entering the container.
#
# Usage:
#   ./squeezelite-ctl.sh                              # show status + config
#   ./squeezelite-ctl.sh status
#   ./squeezelite-ctl.sh set name="Living Room"       # change player name (spaces ok)
#   ./squeezelite-ctl.sh set lms=192.168.1.10         # set LMS server IP[:port]
#   ./squeezelite-ctl.sh set lms=                     # clear → LMS auto-discover
#   ./squeezelite-ctl.sh set device=hw:0,0            # change ALSA output
#   ./squeezelite-ctl.sh set buffer=120:4::1          # change ALSA params (-a)
#   ./squeezelite-ctl.sh set extra="-d output=info"   # extra squeezelite flags
#   ./squeezelite-ctl.sh set floor=-30                # volume-script floor
#   ./squeezelite-ctl.sh set curve=2                  # volume-script curve exponent (1=linear, >1=bottom-heavy)
#   ./squeezelite-ctl.sh set mqtt-host=192.168.1.3    # MQTT broker for HA bridge
#   ./squeezelite-ctl.sh set mqtt-user=mqtt mqtt-pass=mqtt
#   ./squeezelite-ctl.sh set sources=Analog,Toslink,Spdif,Aesebu  # HA select options
#   ./squeezelite-ctl.sh set ha-floor=54              # HA slider linear-in-dB floor (bridge only)
#   ./squeezelite-ctl.sh set name="Foo" lms=...       # multiple in one call
#   ./squeezelite-ctl.sh edit                         # open /etc/default/squeezelite
#   ./squeezelite-ctl.sh edit-mqtt                    # open /etc/default/minidsp-mqtt
#   ./squeezelite-ctl.sh restart                      # restart squeezelite + minidsp-mqtt
#   ./squeezelite-ctl.sh logs [-f] [-n N]             # journalctl for all 3 units
#   ./squeezelite-ctl.sh minidsp [args...]            # run minidsp inside the CT
#
# Override the target container with the CTID env var (default: 201):
#   CTID=210 ./squeezelite-ctl.sh status

set -euo pipefail

CTID="${CTID:-201}"
CONF_SQ="/etc/default/squeezelite"
CONF_MQ="/etc/default/minidsp-mqtt"

err()  { echo "ERROR: $*" >&2; exit 1; }

ensure_running() {
    pct status "$CTID" 2>/dev/null | grep -q running \
        || err "container $CTID is not running"
}

# Map ctl key → (var, conf file, service-to-restart).
# Tab-separated; keep aligned for readability.
key_meta() {
    case "$1" in
        name)      echo "PLAYER_NAME	$CONF_SQ	squeezelite" ;;
        lms)       echo "LMS_IP	$CONF_SQ	squeezelite" ;;
        device)    echo "ALSA_DEVICE	$CONF_SQ	squeezelite" ;;
        buffer)    echo "ALSA_PARAMS	$CONF_SQ	squeezelite" ;;
        extra)     echo "EXTRA_OPTS	$CONF_SQ	squeezelite" ;;
        floor)     echo "FLOOR_DB	$CONF_SQ	squeezelite minidsp-mqtt" ;;
        curve)     echo "CURVE_K	$CONF_SQ	squeezelite minidsp-mqtt" ;;
        mqtt-host) echo "MQTT_HOST	$CONF_MQ	minidsp-mqtt" ;;
        mqtt-port) echo "MQTT_PORT	$CONF_MQ	minidsp-mqtt" ;;
        mqtt-user) echo "MQTT_USER	$CONF_MQ	minidsp-mqtt" ;;
        mqtt-pass) echo "MQTT_PASS	$CONF_MQ	minidsp-mqtt" ;;
        sources)   echo "SOURCES	$CONF_MQ	minidsp-mqtt" ;;
        node-id)   echo "NODE_ID	$CONF_MQ	minidsp-mqtt" ;;
        ha-floor)  echo "LMS_VOL_FLOOR	$CONF_MQ	minidsp-mqtt" ;;
        *) err "unknown key '$1' (allowed: name, lms, device, buffer, extra, floor, curve, mqtt-host, mqtt-port, mqtt-user, mqtt-pass, sources, node-id, ha-floor)" ;;
    esac
}

cmd_status() {
    ensure_running
    echo "=== container $CTID ==="
    pct exec "$CTID" -- ip -4 -br addr show eth0 2>/dev/null | awk '{print "ip:    " $3}'
    pct exec "$CTID" -- hostname               2>/dev/null | awk '{print "host:  " $0}'
    for svc in squeezelite minidsp minidsp-mqtt; do
        pct exec "$CTID" -- systemctl is-active "$svc" 2>/dev/null \
            | awk -v s="$svc" '{printf "%-14s %s\n", s":", $0}' || true
    done
    echo
    echo "=== $CONF_SQ ==="
    pct exec "$CTID" -- cat "$CONF_SQ" 2>/dev/null
    echo
    echo "=== $CONF_MQ ==="
    pct exec "$CTID" -- cat "$CONF_MQ" 2>/dev/null
    echo
    echo "=== minidsp (live state) ==="
    pct exec "$CTID" -- minidsp 2>&1 | head -3 || true
}

cmd_set() {
    ensure_running
    [ $# -gt 0 ] || err "usage: set key=value [key=value ...]"

    # Group writes by target conf file and accumulate services to restart.
    # We edit on the host (avoids in-container quoting hell), then push.
    local files=()           # unique conf paths touched
    local services=""        # space-separated, deduped below

    declare -A tmp_for       # conf path -> tmp file
    declare -A pushed        # marker for "we pulled this conf already"

    cleanup() { for f in "${tmp_for[@]}"; do [ -n "$f" ] && rm -f "$f"; done; }
    trap cleanup RETURN

    for kv in "$@"; do
        [[ "$kv" == *=* ]] || err "'$kv' is not key=value"
        local key="${kv%%=*}" value="${kv#*=}"
        local meta; meta=$(key_meta "$key")
        local var conf svc_list
        var=$(printf '%s' "$meta" | cut -f1)
        conf=$(printf '%s' "$meta" | cut -f2)
        svc_list=$(printf '%s' "$meta" | cut -f3)

        if [ -z "${pushed[$conf]:-}" ]; then
            local tmp; tmp=$(mktemp)
            tmp_for[$conf]="$tmp"
            pct exec "$CTID" -- cat "$conf" > "$tmp" 2>/dev/null || : > "$tmp"
            pushed[$conf]=1
            files+=("$conf")
        fi
        local tmp="${tmp_for[$conf]}"

        # Escape for double-quoted string: backslash, dquote, dollar, backtick.
        local esc; esc=$(printf '%s' "$value" | sed 's/[\\$`"]/\\&/g')
        if grep -q "^${var}=" "$tmp"; then
            awk -v var="$var" -v val="$esc" '
                $0 ~ "^"var"=" { print var "=\"" val "\""; next }
                                { print }
            ' "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
        else
            printf '%s="%s"\n' "$var" "$esc" >> "$tmp"
        fi
        printf "set %-14s = %s   (-> %s)\n" "$var" "$value" "$conf"

        services="$services $svc_list"
    done

    # Push edited files back into the container.
    for conf in "${files[@]}"; do
        pct push "$CTID" "${tmp_for[$conf]}" "$conf"
    done
    # Re-apply expected modes (the bridge file is 0640 root:squeezelite).
    pct exec "$CTID" -- chmod 644 "$CONF_SQ"  2>/dev/null || true
    pct exec "$CTID" -- chmod 640 "$CONF_MQ"  2>/dev/null || true
    pct exec "$CTID" -- chgrp audio "$CONF_MQ" 2>/dev/null || true

    # Dedup + restart.
    local svcs; svcs=$(printf '%s\n' $services | awk 'NF && !seen[$0]++' | tr '\n' ' ')
    [ -n "$svcs" ] && pct exec "$CTID" -- systemctl restart $svcs
    sleep 1
    for s in $svcs; do
        pct exec "$CTID" -- systemctl is-active "$s" \
            | awk -v n="$s" '{printf "%-14s %s\n", n":", $0}'
    done
}

cmd_edit() {
    ensure_running
    pct exec "$CTID" -- "${EDITOR:-nano}" "$CONF_SQ"
    pct exec "$CTID" -- systemctl restart squeezelite
}

cmd_edit_mqtt() {
    ensure_running
    pct exec "$CTID" -- "${EDITOR:-nano}" "$CONF_MQ"
    pct exec "$CTID" -- systemctl restart minidsp-mqtt
}

cmd_restart() {
    ensure_running
    pct exec "$CTID" -- systemctl restart minidsp minidsp-mqtt squeezelite
    sleep 1
    for s in minidsp minidsp-mqtt squeezelite; do
        pct exec "$CTID" -- systemctl is-active "$s" \
            | awk -v n="$s" '{printf "%-14s %s\n", n":", $0}'
    done
}

cmd_logs() {
    ensure_running
    pct exec "$CTID" -- journalctl \
        -u squeezelite -u minidsp -u minidsp-mqtt --no-pager "$@"
}

cmd_minidsp() {
    ensure_running
    pct exec "$CTID" -- minidsp "$@"
}

usage() { sed -n '2,/^$/{s/^# \?//;p}' "$0"; exit 1; }

[ $# -eq 0 ] && { cmd_status; exit 0; }

cmd="$1"; shift
case "$cmd" in
    status)         cmd_status     "$@" ;;
    set)            cmd_set        "$@" ;;
    edit)           cmd_edit       "$@" ;;
    edit-mqtt)      cmd_edit_mqtt  "$@" ;;
    restart)        cmd_restart    "$@" ;;
    logs)           cmd_logs       "$@" ;;
    minidsp)        cmd_minidsp    "$@" ;;
    -h|--help|help) usage ;;
    *) echo "unknown command: $cmd" >&2; usage ;;
esac
