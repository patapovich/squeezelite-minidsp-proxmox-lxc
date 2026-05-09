#!/bin/bash
# Creates a Proxmox LXC container running squeezelite + minidsp-rs.
#
# Use this instead of proxmox-create.sh (VM) when QEMU's USB audio passthrough
# is not viable — typical when the host has only one USB controller serving
# multiple devices, or when isochronous transfers stutter through QEMU's
# emulated EHCI/xHCI (audible distortion). LXC shares the host kernel, so the
# MiniDSP appears as a real USB device inside the container with no isoc
# emulation: bare-metal audio quality.
#
# Trade-offs vs the VM flavour:
#   + No QEMU USB emulation → no audio distortion
#   + Lower overhead (~50 MB RAM, no separate kernel)
#   + Boots in seconds
#   - Privileged LXC (shares host kernel/cgroups; weaker isolation than a VM)
#   - Other USB devices on the same host xHCI remain on the host (e.g. HA
#     Zigbee dongle is unaffected — that is the whole point of using LXC here)
#
# Run on the Proxmox host as root.
#
# Tunables (env):
#   CTID         container ID                       (default: 201)
#   CT_HOSTNAME  container hostname                 (default: squeezelite)
#                (named CT_HOSTNAME, not HOSTNAME, because bash exports
#                 $HOSTNAME by default — using HOSTNAME would silently inherit
#                 the Proxmox host's name)
#   MEMORY       MB                                 (default: 512)
#   CORES        vCPU cores                         (default: 2)
#   DISK_SIZE    rootfs GB                          (default: 4)
#   STORAGE      rootfs storage                     (default: local-lvm)
#   BRIDGE       network bridge                     (default: vmbr0)
#   PASSWORD     root password                      (default: squeezelite)
#   PLAYER_NAME  name shown in LMS                  (default: squeezelite)
#   LMS_IP       LMS server IP, empty = discover    (default: empty)
#   MQTT_HOST    MQTT broker (HA Mosquitto add-on)  (default: 192.168.1.3)
#   MQTT_PORT    MQTT broker port                   (default: 1883)
#   MQTT_USER    MQTT username                      (default: mqtt)
#   MQTT_PASS    MQTT password                      (default: mqtt)

set -euo pipefail

CTID="${CTID:-201}"
CT_HOSTNAME="${CT_HOSTNAME:-squeezelite}"
MEMORY="${MEMORY:-512}"
CORES="${CORES:-2}"
DISK_SIZE="${DISK_SIZE:-4}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
TPL_STORAGE="${TPL_STORAGE:-local}"
PASSWORD="${PASSWORD:-squeezelite}"

DEBIAN_RELEASE="${DEBIAN_RELEASE:-bookworm}"
case "$DEBIAN_RELEASE" in
    bookworm) DEBIAN_VERSION=12 ;;
    trixie)   DEBIAN_VERSION=13 ;;
    bullseye) DEBIAN_VERSION=11 ;;
    *) echo "ERROR: unknown DEBIAN_RELEASE '$DEBIAN_RELEASE'"; exit 1 ;;
esac
TEMPLATE="debian-${DEBIAN_VERSION}-standard"

PLAYER_NAME="${PLAYER_NAME:-squeezelite}"
LMS_IP="${LMS_IP:-}"
MQTT_HOST="${MQTT_HOST:-192.168.1.3}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-mqtt}"
MQTT_PASS="${MQTT_PASS:-mqtt}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"
BRIDGE_SCRIPT="${SCRIPT_DIR}/minidsp-mqtt"
[ -r "$SETUP_SCRIPT" ]  || { echo "ERROR: $SETUP_SCRIPT not found"; exit 1; }
[ -r "$BRIDGE_SCRIPT" ] || { echo "ERROR: $BRIDGE_SCRIPT not found"; exit 1; }
command -v pct >/dev/null 2>&1 || { echo "ERROR: pct not found — run on a Proxmox host"; exit 1; }

# ── Verify MiniDSP visible on host ────────────────────────────────────────────
MINIDSP_LINE=$(lsusb 2>/dev/null | grep -iE '2752:|miniDSP' | head -1 || true)
if [ -n "$MINIDSP_LINE" ]; then
    echo "==> MiniDSP detected on host: $MINIDSP_LINE"
else
    echo "WARNING: no MiniDSP currently visible on host (lsusb shows nothing matching 2752:/miniDSP)."
    echo "         The container will still install, but minidsp will fail until you plug it in."
fi

# Confirm at least one USB audio card is exposed by the host kernel.
# Using /proc/asound/cards (always present, no extra package needed) instead
# of aplay -l (Proxmox hosts don't ship alsa-utils).
HOST_USB_CARD=$(awk '/USB-Audio|miniDSP|DDRC/ {found=1; print; exit} END { if (!found) exit 1 }' /proc/asound/cards 2>/dev/null || true)
if [ -n "$HOST_USB_CARD" ]; then
    echo "==> Host USB audio card visible (will pass to container): ${HOST_USB_CARD// /}"
fi
echo

# ── Ensure 'snippets' not needed; ensure template available ──────────────────
echo "==> Refreshing pveam template index..."
pveam update >/dev/null 2>&1 || true

TPL_GLOB="/var/lib/vz/template/cache/${TEMPLATE}_*.tar.zst"
if ! ls $TPL_GLOB >/dev/null 2>&1; then
    echo "==> Downloading ${TEMPLATE} template..."
    TPL_NAME=$(pveam available --section system 2>/dev/null \
                | awk -v t="${TEMPLATE}" '$2 ~ t {print $2; exit}')
    [ -n "$TPL_NAME" ] || { echo "ERROR: ${TEMPLATE} not in pveam available list"; exit 1; }
    pveam download "$TPL_STORAGE" "$TPL_NAME"
fi
TPL_FILE=$(ls -t $TPL_GLOB | head -1)
TPL_REF="${TPL_STORAGE}:vztmpl/$(basename "$TPL_FILE")"
echo "==> Using template: $TPL_REF"
echo

# ── Existence guard ──────────────────────────────────────────────────────────
if pct status "$CTID" >/dev/null 2>&1; then
    echo "ERROR: container $CTID already exists. Pick a different CTID or 'pct destroy $CTID' first."
    exit 1
fi

# ── Create privileged LXC ────────────────────────────────────────────────────
# Privileged: --unprivileged 0. Required so /dev/snd + /dev/bus/usb device
# nodes work cleanly; user/group ID mapping with audio/plugdev would otherwise
# need extra config. This is a single-purpose appliance container so the
# privilege trade-off is acceptable.
echo "==> Creating LXC ${CTID} (${CT_HOSTNAME})..."
pct create "$CTID" "$TPL_REF" \
    --hostname     "$CT_HOSTNAME" \
    --password     "$PASSWORD" \
    --cores        "$CORES" \
    --memory       "$MEMORY" \
    --rootfs       "${STORAGE}:${DISK_SIZE}" \
    --net0         "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --features     "nesting=0" \
    --unprivileged 0 \
    --onboot       1 \
    --ostype       debian

# ── USB + audio passthrough via lxc.* config ─────────────────────────────────
# Major numbers:
#   116 = ALSA sound (/dev/snd/*)
#   189 = USB device nodes (/dev/bus/usb/*) — needed by libusb so minidsp-rs
#         can talk to the MiniDSP
#
# We do not need to bind-mount /dev/hidraw* — minidsp-rs talks via libusb,
# not hidraw, so /dev/bus/usb is sufficient.
CONF="/etc/pve/lxc/${CTID}.conf"
echo "==> Adding USB + ALSA passthrough to ${CONF}..."
cat >> "$CONF" << 'EOF'

# === squeezelite + MiniDSP passthrough ===
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
EOF

# ── Boot + run setup ─────────────────────────────────────────────────────────
echo "==> Starting container..."
pct start "$CTID"

echo "==> Waiting for container network..."
for i in $(seq 1 30); do
    pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
    sleep 1
done

echo "==> Pushing setup.sh + minidsp-mqtt into container..."
pct push "$CTID" "$SETUP_SCRIPT"  /usr/local/sbin/squeezelite-setup.sh
pct push "$CTID" "$BRIDGE_SCRIPT" /usr/local/bin/minidsp-mqtt
pct exec "$CTID" -- chmod 755 /usr/local/sbin/squeezelite-setup.sh /usr/local/bin/minidsp-mqtt

echo "==> Running setup.sh inside container (this builds squeezelite — ~3 min)..."
pct exec "$CTID" -- env \
    PLAYER_NAME="$PLAYER_NAME" \
    LMS_IP="$LMS_IP" \
    MQTT_HOST="$MQTT_HOST" \
    MQTT_PORT="$MQTT_PORT" \
    MQTT_USER="$MQTT_USER" \
    MQTT_PASS="$MQTT_PASS" \
    /usr/local/sbin/squeezelite-setup.sh

# ── Summary ──────────────────────────────────────────────────────────────────
CT_IP=$(pct exec "$CTID" -- ip -4 -br addr show eth0 2>/dev/null \
        | awk '{split($3,a,"/"); print a[1]}' | head -1)

cat <<INFO

==> LXC ${CTID} (${CT_HOSTNAME}) ready.
    IP:           ${CT_IP:-<DHCP pending>}
    Login:        pct enter ${CTID}     (or ssh root@${CT_IP:-<ip>})
    Player:       ${PLAYER_NAME}
    LMS:          ${LMS_IP:-auto-discover}
    MQTT:         ${MQTT_USER}@${MQTT_HOST}:${MQTT_PORT}

    Verify:
      pct exec ${CTID} -- systemctl status squeezelite minidsp minidsp-mqtt
      pct exec ${CTID} -- minidsp
      pct exec ${CTID} -- curl -s http://127.0.0.1:5380/devices/0
      pct exec ${CTID} -- aplay -l
INFO
