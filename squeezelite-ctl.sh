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
#   ./squeezelite-ctl.sh set name="Foo" lms=...       # multiple in one call
#   ./squeezelite-ctl.sh edit                         # open the file in $EDITOR
#   ./squeezelite-ctl.sh restart                      # restart the service
#   ./squeezelite-ctl.sh logs [-f] [-n N]             # journalctl -u squeezelite ...
#   ./squeezelite-ctl.sh minidsp [args...]            # run minidsp inside the CT
#
# Override the target container with the CTID env var (default: 201):
#   CTID=210 ./squeezelite-ctl.sh status

set -euo pipefail

CTID="${CTID:-201}"
CONF="/etc/default/squeezelite"

err()  { echo "ERROR: $*" >&2; exit 1; }

ensure_running() {
    pct status "$CTID" 2>/dev/null | grep -q running \
        || err "container $CTID is not running"
}

key_to_var() {
    case "$1" in
        name)   echo PLAYER_NAME ;;
        lms)    echo LMS_IP ;;
        device) echo ALSA_DEVICE ;;
        buffer) echo ALSA_PARAMS ;;
        extra)  echo EXTRA_OPTS ;;
        *) err "unknown key '$1' (allowed: name, lms, device, buffer, extra)" ;;
    esac
}

cmd_status() {
    ensure_running
    echo "=== container $CTID ==="
    pct exec "$CTID" -- ip -4 -br addr show eth0 2>/dev/null | awk '{print "ip:    " $3}'
    pct exec "$CTID" -- hostname               2>/dev/null | awk '{print "host:  " $0}'
    pct exec "$CTID" -- systemctl is-active squeezelite 2>/dev/null \
                                                    | awk '{print "state: " $0}' || true
    echo
    echo "=== $CONF ==="
    pct exec "$CTID" -- cat "$CONF"
    echo
    echo "=== minidsp (live state) ==="
    pct exec "$CTID" -- minidsp 2>&1 | head -3 || true
}

cmd_set() {
    ensure_running
    [ $# -gt 0 ] || err "usage: set key=value [key=value ...]"

    # Edit on host (avoids in-container quoting hell), push back, restart
    local tmp; tmp=$(mktemp); trap "rm -f $tmp" RETURN
    pct exec "$CTID" -- cat "$CONF" > "$tmp"

    for kv in "$@"; do
        [[ "$kv" == *=* ]] || err "'$kv' is not key=value"
        local key="${kv%%=*}" value="${kv#*=}" var
        var=$(key_to_var "$key")
        # Escape for inclusion inside double-quoted string in the conf file.
        # Need to escape: backslash, double-quote, dollar, backtick.
        local esc; esc=$(printf '%s' "$value" | sed 's/[\\$`"]/\\&/g')
        if grep -q "^${var}=" "$tmp"; then
            # Replace the line via awk (sed regex over | gets tangled by paths)
            awk -v var="$var" -v val="$esc" '
                $0 ~ "^"var"=" { print var "=\"" val "\""; next }
                                { print }
            ' "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
        else
            printf '%s="%s"\n' "$var" "$esc" >> "$tmp"
        fi
        printf "set %-12s = %s\n" "$var" "$value"
    done

    pct push "$CTID" "$tmp" "$CONF"
    pct exec "$CTID" -- chmod 644 "$CONF"
    pct exec "$CTID" -- systemctl restart squeezelite
    sleep 1
    pct exec "$CTID" -- systemctl is-active squeezelite \
        | awk '{print "service: " $0}'
}

cmd_edit() {
    ensure_running
    pct exec "$CTID" -- "${EDITOR:-nano}" "$CONF"
    pct exec "$CTID" -- systemctl restart squeezelite
}

cmd_restart() {
    ensure_running
    pct exec "$CTID" -- systemctl restart squeezelite
    sleep 1
    pct exec "$CTID" -- systemctl is-active squeezelite
}

cmd_logs() {
    ensure_running
    pct exec "$CTID" -- journalctl -u squeezelite --no-pager "$@"
}

cmd_minidsp() {
    ensure_running
    pct exec "$CTID" -- minidsp "$@"
}

usage() { sed -n '2,/^$/{s/^# \?//;p}' "$0"; exit 1; }

[ $# -eq 0 ] && { cmd_status; exit 0; }

cmd="$1"; shift
case "$cmd" in
    status)         cmd_status   "$@" ;;
    set)            cmd_set      "$@" ;;
    edit)           cmd_edit     "$@" ;;
    restart)        cmd_restart  "$@" ;;
    logs)           cmd_logs     "$@" ;;
    minidsp)        cmd_minidsp  "$@" ;;
    -h|--help|help) usage ;;
    *) echo "unknown command: $cmd" >&2; usage ;;
esac
