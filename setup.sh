#!/bin/bash
# Installs squeezelite (with -w volume script support) + minidsp-rs on a fresh
# Debian system. Designed to be invoked once at first boot via cloud-init,
# but is also safe to re-run on any minimal Debian 12/13 install.
#
# Optional env vars:
#   PLAYER_NAME   Player name shown in LMS         (default: squeezelite)
#   LMS_IP        LMS server IP, empty = discover  (default: empty)
#   MINIDSP_VER   minidsp-rs release version       (default: 0.1.10)
#   MQTT_HOST     MQTT broker for HA bridge        (default: 192.168.1.3)
#   MQTT_PORT     MQTT broker port                 (default: 1883)
#   MQTT_USER     MQTT username                    (default: mqtt)
#   MQTT_PASS     MQTT password                    (default: mqtt)

set -eu

PLAYER_NAME="${PLAYER_NAME:-squeezelite}"
LMS_IP="${LMS_IP:-}"
MINIDSP_VER="${MINIDSP_VER:-0.1.10}"
MQTT_HOST="${MQTT_HOST:-192.168.1.3}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-mqtt}"
MQTT_PASS="${MQTT_PASS:-mqtt}"

export DEBIAN_FRONTEND=noninteractive

# Escape a value for embedding inside a double-quoted string in the generated
# config files (backslash, dquote, dollar, backtick) — the same rule
# squeezelite-ctl.sh applies when editing the same files. Without this, a
# PLAYER_NAME like `5" Speakers` writes an unterminated quote that makes
# squeezelite-launch fail at source time, and $(...) would execute on every
# service start.
esc() { printf '%s' "$1" | sed 's/[\\$`"]/\\&/g'; }

echo "==> Updating apt index..."
apt-get update -q

# Install everything we need to build squeezelite and run it against an ALSA
# USB card + MiniDSP. Nothing more.
#
# Bootstrap utilities:
#   ca-certificates        TLS roots for git/curl
#   curl                   pulls minidsp_*.deb release
#   git                    clones squeezelite + squeezelite-minidsp
#   usbutils               lsusb (diagnostics; setup logs `lsusb` to confirm passthrough)
# Audio helpers (needed at runtime):
#   alsa-utils             provides aplay -l (we use it for card autodetect)
# Compilation toolchain:
#   build-essential        gcc, make, libc6-dev (pthread/m/rt/dl)
# Library headers (squeezelite #includes them; .so files come transitively):
#   libasound2-dev         <alsa/asoundlib.h>  + -lasound link
#   libflac-dev            <FLAC/stream_decoder.h>
#   libvorbis-dev          <vorbis/vorbisfile.h>
#   libopusfile-dev        <opusfile.h>        (pulls libopusfile0)
#   libopus-dev            <opus/opus.h>       (build adds -I/usr/include/opus)
#   libmad0-dev            <mad.h>
#   libmpg123-dev          <mpg123.h>
#   libfaad-dev            <neaacdec.h>
#   libsoxr-dev            <soxr.h>
#   libssl-dev             <openssl/*.h>       (sslsym.c dlopens libssl/libcrypto)
#
# Codecs are dlopen()'d at runtime by squeezelite (no -DLINKALL), so we don't
# link them at build time; the runtime SONAMEs (libFLAC.so.X, libmad.so.0, etc.)
# arrive automatically as Depends: of the matching -dev packages.
echo "==> Installing build + runtime dependencies..."
apt-get install -y --no-install-recommends \
    ca-certificates curl git usbutils \
    alsa-utils \
    build-essential \
    libasound2-dev \
    libflac-dev \
    libvorbis-dev \
    libopusfile-dev \
    libopus-dev \
    libmad0-dev \
    libmpg123-dev \
    libfaad-dev \
    libsoxr-dev \
    libssl-dev \
    python3 python3-paho-mqtt python3-websockets python3-httpx

echo "==> Building squeezelite from patapovich/squeezelite (fix-volume-script-w-option)..."
cd /tmp
rm -rf squeezelite-src
git clone -q --branch fix-volume-script-w-option --depth 1 \
    https://github.com/patapovich/squeezelite.git squeezelite-src
cd squeezelite-src
# -DGPIO enables the -S "power script" arg (used by squeezelite-source to
# switch the MiniDSP input on LMS power on/off). Without -DRPI, gpio.c does
# not include <gpiod.h> nor link -lgpiod (the libgpiod calls are gated behind
# #if RPI), so this adds zero new dependencies — only argv parsing + system().
make -s OPTS="-DRESAMPLE -DDSD -DVISEXPORT -DUSE_SSL -DOPUS -DGPIO -I/usr/include/opus"
install -Dm 755 squeezelite /usr/local/bin/squeezelite
gcc -Os -fomit-frame-pointer -fcommon -s -o alsacap tools/alsacap.c -lasound \
    && install -Dm 755 alsacap /usr/local/bin/alsacap
cd /tmp && rm -rf squeezelite-src

echo "==> Installing minidsp-rs ${MINIDSP_VER} (.deb from upstream)..."
ARCH=$(dpkg --print-architecture)
DEB="minidsp_${MINIDSP_VER}-1_${ARCH}.deb"
cd /tmp
curl -fLO "https://github.com/mrene/minidsp-rs/releases/download/v${MINIDSP_VER}/${DEB}"
apt-get install -y "./${DEB}"
rm -f "${DEB}"

echo "==> Installing squeezelite-minidsp helper scripts..."
rm -rf /tmp/sq-minidsp
git clone -q --depth 1 https://github.com/patapovich/squeezelite-minidsp.git /tmp/sq-minidsp
install -Dm 755 /tmp/sq-minidsp/squeezelite-source /usr/local/bin/squeezelite-source
install -Dm 755 /tmp/sq-minidsp/squeezelite-volume /usr/local/bin/squeezelite-volume
rm -rf /tmp/sq-minidsp

echo "==> Installing minidsp-mqtt bridge..."
# Pull this repo's own minidsp-mqtt script. proxmox-create-lxc.sh copies it
# into the container before running setup.sh; if it's not present (manual
# install on a bare Debian system), fall back to a git fetch.
if [ ! -x /usr/local/bin/minidsp-mqtt ]; then
    rm -rf /tmp/sq-lxc
    git clone -q --depth 1 \
        https://github.com/patapovich/squeezelite-minidsp-proxmox-lxc.git /tmp/sq-lxc \
        || true
    if [ -r /tmp/sq-lxc/minidsp-mqtt ]; then
        install -Dm 755 /tmp/sq-lxc/minidsp-mqtt /usr/local/bin/minidsp-mqtt
    fi
    rm -rf /tmp/sq-lxc
fi
[ -x /usr/local/bin/minidsp-mqtt ] || \
    { echo "ERROR: /usr/local/bin/minidsp-mqtt missing — push it before running setup.sh"; exit 1; }

echo "==> Creating squeezelite system user..."
getent group plugdev >/dev/null 2>&1 || groupadd -r plugdev
if ! id -u squeezelite >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -d /nonexistent -g audio -G plugdev,audio squeezelite
fi
usermod -aG plugdev,audio squeezelite

echo "==> Installing udev rule for MiniDSP HID (vendor 2752)..."
cat > /etc/udev/rules.d/70-minidsp.rules << 'EOF'
SUBSYSTEM=="usb",    ATTRS{idVendor}=="2752", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="2752", MODE="0660", GROUP="plugdev"
EOF
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

echo "==> Pinning USB audio to ALSA index 0..."
echo "options snd-usb-audio index=0" > /etc/modprobe.d/alsa-usb.conf
modprobe snd-usb-audio 2>/dev/null || true
sleep 2

echo "==> Auto-detecting USB audio device..."
ALSA_CARD=$(aplay -l 2>/dev/null | awk '/^card.*[Uu][Ss][Bb]/ {print $3; exit}')
[ -z "${ALSA_CARD:-}" ] && ALSA_CARD=$(aplay -l 2>/dev/null | awk '/^card/ {print $3; exit}')

if [ -n "${ALSA_CARD:-}" ]; then
    ALSA_DEVICE="hw:CARD=${ALSA_CARD},DEV=0"
    echo "    Using ${ALSA_DEVICE}"
else
    ALSA_DEVICE="hw:0,0"
    echo "    WARNING: no audio device detected; defaulting to hw:0,0"
    echo "    After reboot run: aplay -l   then edit /etc/default/squeezelite"
fi

echo "==> Writing /etc/default/squeezelite (key=value form) ..."
# Settings as plain VAR="value" pairs so values can contain spaces (player
# names like "Living Room") and so a host-side management script
# (squeezelite-ctl.sh) can edit individual keys without parsing one long
# SL_OPTS string. The /usr/local/sbin/squeezelite-launch wrapper sources
# this file and constructs the squeezelite argv from the variables.
#
# Create-only: a re-run must never clobber tuned settings (player name,
# floor/curve, idle timeout) — that's what makes "safe to re-run" true.
if [ -f /etc/default/squeezelite ]; then
    echo "    /etc/default/squeezelite exists — leaving it untouched (delete it to regenerate)"
else
cat > /etc/default/squeezelite << EOF
# squeezelite settings — edit then: systemctl restart squeezelite
# (or use squeezelite-ctl.sh on the Proxmox host:
#    ./squeezelite-ctl.sh set name="Living Room" lms=192.168.1.10)

# Player name shown in LMS (spaces allowed)
PLAYER_NAME="$(esc "$PLAYER_NAME")"

# LMS server IP[:port]. Empty = auto-discover.
LMS_IP="$(esc "$LMS_IP")"

# ALSA output device for squeezelite -o
ALSA_DEVICE="$(esc "$ALSA_DEVICE")"

# ALSA params for squeezelite -a, format buffer:periods:format:mmap
# 80:4::1 = 80 ms buffer, 4 periods, format=auto (device picks S32_LE on
# capable DACs), mmap=on. Empirically clean on USB DACs; smaller buffers /
# mmap=0 stutter audibly. Empty = squeezelite defaults.
ALSA_PARAMS="80:4::1"

# Anything else to append (e.g. -d output=info, -c flac,pcm)
EXTRA_OPTS=""

# Idle timeout (seconds) for squeezelite -C: after this long with no
# playback the ALSA device is closed and the -S source script switches the
# MiniDSP input to Toslink (vinyl). Playback resuming switches back to Usb
# and reopens the device. Empty = never release the device.
IDLE_TIMEOUT="300"

# squeezelite-volume / minidsp-mqtt volume curve.
#   gain_dB = FLOOR_DB * (1 - (vol/100)^CURVE_K)
# Both the LMS path (squeezelite-volume) and the HA path (minidsp-mqtt) read
# these vars so the slider behaves identically everywhere.
#   FLOOR_DB  Lower magnitude = less dynamic range, hotter minimum.
#             Defaults: -30 gentle, -50 default, -60 more dynamic, -72 wide.
#   CURVE_K   1 = linear in dB. >1 = bottom-heavy (slider 1-30 sits near
#             floor, listening sweet spot moves up). <1 = audio-taper feel.
FLOOR_DB="-50"
CURVE_K="2"
EOF
fi

echo "==> Installing /usr/local/sbin/squeezelite-launch ..."
# Tiny wrapper that reads /etc/default/squeezelite key=value pairs and execs
# squeezelite with a properly quoted argv. systemd's $VAR expansion
# word-splits, which would corrupt names like "Living Room"; bash arrays
# preserve whitespace correctly.
cat > /usr/local/sbin/squeezelite-launch << 'LAUNCH'
#!/bin/bash
set -eu
# `set -a` auto-exports everything sourced from the conf file so the env
# vars (FLOOR_DB etc.) propagate into the volume-script processes squeezelite
# forks via system().
set -a
. /etc/default/squeezelite
set +a
args=(
    -o "${ALSA_DEVICE}"
    -n "${PLAYER_NAME}"
    -S /usr/local/bin/squeezelite-source
    -w /usr/local/bin/squeezelite-volume
)
[ -n "${ALSA_PARAMS:-}" ] && args+=(-a "${ALSA_PARAMS}")
[ -n "${LMS_IP:-}"      ] && args+=(-s "${LMS_IP}")
[ -n "${IDLE_TIMEOUT:-}" ] && args+=(-C "${IDLE_TIMEOUT}")
# EXTRA_OPTS is intentionally word-split (use it for multiple flags)
[ -n "${EXTRA_OPTS:-}"  ] && args+=(${EXTRA_OPTS})
exec /usr/local/bin/squeezelite "${args[@]}"
LAUNCH
chmod 755 /usr/local/sbin/squeezelite-launch

echo "==> Installing systemd unit..."
cat > /etc/systemd/system/squeezelite.service << 'EOF'
[Unit]
Description=Squeezelite player (with MiniDSP source/volume integration)
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=squeezelite
Group=audio
SupplementaryGroups=plugdev
ExecStart=/usr/local/sbin/squeezelite-launch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Configuring minidspd (HTTP API + Unix socket)..."
# minidspd exposes:
#   - HTTP/WS API on 127.0.0.1:5380 (consumed by minidsp-mqtt for HA control)
#   - /tmp/minidsp.sock so the local `minidsp` CLI multiplexes onto the same
#     device session — squeezelite-volume's `minidsp gain ...` calls and the
#     bridge no longer race for the USB endpoint.
mkdir -p /etc/minidsp
cat > /etc/minidsp/config.toml << 'EOF'
# Managed by setup.sh — manual edits get overwritten on re-run.

# HTTP/WS API on a local port + Unix socket.
# The Unix socket lets the local `minidsp` CLI multiplex through the same
# device session as the daemon, avoiding USB contention with squeezelite-volume.
[http_server]
bind_address = "127.0.0.1:5380"
bind_unix_path = "/tmp/minidsp.sock"

# TCP server on the legacy port used by the official MiniDSP plugin/mobile
# apps. Kept so the "official" tooling still works alongside the bridge.
# Bound to all interfaces: the apps connect over the LAN to <CT_IP>:5333 —
# a loopback bind would make this feature unreachable from anywhere.
# (Trusted-LAN appliance; delete this block if LAN exposure is unwanted.)
[[tcp_server]]
bind_address = "0.0.0.0:5333"
EOF

echo "==> Installing minidsp.service systemd unit..."
cat > /etc/systemd/system/minidsp.service << 'EOF'
[Unit]
Description=minidsp-rs daemon (HTTP/WS API for HA bridge + multiplexed CLI)
After=network-online.target
Wants=network-online.target
Before=squeezelite.service minidsp-mqtt.service

[Service]
Type=simple
# Run as root: in a privileged LXC the host's udev does NOT apply our
# /etc/udev/rules.d/70-minidsp.rules (host has no 'plugdev' group), so
# /dev/bus/usb/<bus>/<dev> ends up root:root mode 664. minidspd needs
# read+write to open the device via libusb. The factory minidsp.service
# (.deb) runs as root for the same reason.
ExecStart=/usr/bin/minidspd --config /etc/minidsp/config.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Writing /etc/default/minidsp-mqtt ..."
# 0640 root:audio — readable by the bridge service (which runs as
# User=squeezelite Group=audio), not world-readable. The container has no
# 'squeezelite' group; the squeezelite user's primary group is audio.
#
# Create-only, like /etc/default/squeezelite above: a re-run must never wipe
# the per-install CALIBRATION table, MQTT credentials, or LMS sync settings.
if [ -f /etc/default/minidsp-mqtt ]; then
    echo "    /etc/default/minidsp-mqtt exists — leaving it untouched (delete it to regenerate)"
else
install -m 0640 -g audio /dev/null /etc/default/minidsp-mqtt
cat > /etc/default/minidsp-mqtt << EOF
# minidsp-mqtt bridge settings.
# (Edit then: systemctl restart minidsp-mqtt — or use squeezelite-ctl.sh
#  on the Proxmox host: ./squeezelite-ctl.sh set mqtt-host=...)

# minidspd HTTP API (local)
MINIDSPD_URL="http://127.0.0.1:5380"
DEVICE_INDEX="0"

# MQTT broker — Home Assistant Mosquitto add-on by default
MQTT_HOST="$(esc "$MQTT_HOST")"
MQTT_PORT="$(esc "$MQTT_PORT")"
MQTT_USER="$(esc "$MQTT_USER")"
MQTT_PASS="$(esc "$MQTT_PASS")"

# Topic / discovery layout. NODE_ID defaults to the container hostname so a
# second container gets its own topics, HA unique_ids, and MQTT client-id —
# two bridges sharing NODE_ID would cross-drive each other's DSPs and kick
# each other off the broker (duplicate client-id).
BASE_TOPIC="minidsp"
DISCOVERY_PREFIX="homeassistant"
NODE_ID="$(esc "${NODE_ID:-$(hostname)}")"

# Source enum exposed in HA. Empty = auto-discover from minidspd's
# product_name. Set explicitly only to override the lookup for a product
# we don't know about, or to expose a custom subset.
SOURCES=""

# HA ↔ LMS slider parity (101-point calibration table).
# Maps LMS UI slider position (0-100) to the integer "squeezelite-vol"
# that squeezelite-volume actually receives when LMS sends an AUDG packet
# for that slider position. LMS's internal slider→ldB curve isn't a clean
# formula, so a sampled table is the only way to get HA == LMS UI exactly.
#
# Default below was measured on 2026-05 against this CT. Re-measure per
# install if HA ever drifts from LMS UI:
#   for V in \$(seq 0 100); do
#     curl -s http://<lms>:9000/jsonrpc.js \\
#       -d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"<MAC>\",[\"mixer\",\"volume\",\"\$V\"]]}" >/dev/null
#     sleep 0.6
#     echo -n "\$V:\$(cat /tmp/sq-volume-req),"
#   done
CALIBRATION="0:0,1:0,2:1,3:3,4:6,5:8,6:9,7:12,8:14,9:16,10:18,11:20,12:22,13:24,14:26,15:28,16:30,17:32,18:34,19:36,20:38,21:40,22:42,23:44,24:47,25:49,26:49,27:50,28:51,29:51,30:52,31:53,32:53,33:54,34:55,35:55,36:56,37:57,38:58,39:58,40:58,41:60,42:60,43:61,44:62,45:62,46:63,47:64,48:64,49:65,50:66,51:67,52:67,53:68,54:69,55:69,56:70,57:70,58:71,59:72,60:72,61:73,62:74,63:75,64:75,65:76,66:77,67:77,68:78,69:79,70:80,71:80,72:81,73:81,74:82,75:83,76:83,77:84,78:85,79:86,80:86,81:87,82:88,83:88,84:89,85:90,86:90,87:91,88:92,89:92,90:93,91:94,92:95,93:95,94:96,95:97,96:97,97:98,98:99,99:99,100:100"

# Best-effort LMS push so HA-driven volume changes also update the LMS UI
# slider (otherwise LMS will eventually re-assert its stale slider position
# and overwrite HA's write). Leave both empty to skip; HA direct device
# control still works without LMS reachable. Player MAC is the squeezelite
# slim ID — find it with: curl -s http://<LMS>:9000/jsonrpc.js -d
# '{"id":1,"method":"slim.request","params":["",["players","0","20"]]}'
LMS_HOST=""
LMS_HTTP_PORT="9000"
LMS_PLAYER_MAC=""

LOG_LEVEL="INFO"
EOF
fi
chmod 0640 /etc/default/minidsp-mqtt
chgrp audio /etc/default/minidsp-mqtt

echo "==> Installing minidsp-mqtt.service systemd unit..."
# Sources both env files: /etc/default/squeezelite owns FLOOR_DB / CURVE_K so
# the HA slider and LMS path use the same curve; /etc/default/minidsp-mqtt
# owns MQTT/topic settings.
cat > /etc/systemd/system/minidsp-mqtt.service << 'EOF'
[Unit]
Description=MiniDSP <-> MQTT bridge (Home Assistant autodiscovery)
After=network-online.target minidsp.service
Wants=network-online.target
Requires=minidsp.service

[Service]
Type=simple
User=squeezelite
Group=audio
EnvironmentFile=/etc/default/squeezelite
EnvironmentFile=/etc/default/minidsp-mqtt
ExecStart=/usr/local/bin/minidsp-mqtt
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Installing minidsp-watchdog (auto-recovers from minidspd HID stalls)..."
# minidsp-rs has a bug where the HID receive loop can fail silently — the
# daemon stays "running" (so Restart=on-failure never triggers) but every
# /devices/0 call returns 500 DeviceNotReady. The watchdog probes the HTTP
# API every 60s; after 2 consecutive failures it restarts both minidsp +
# minidsp-mqtt and resets the counter.
cat > /usr/local/sbin/minidsp-health-check << 'EOF'
#!/bin/bash
set -eu
# Respect a deliberate stop (e.g. `systemctl stop minidsp` to debug the DSP
# with the minidsp CLI in direct-USB mode): the watchdog's job is only the
# "daemon running but HID loop wedged" case — never resurrect a service an
# admin intentionally stopped.
systemctl is-active --quiet minidsp.service || exit 0
URL="http://127.0.0.1:5380/devices/0"
STATE=/run/minidsp-watchdog.fail-count
THRESHOLD=2
fails=0
[ -r "$STATE" ] && fails=$(cat "$STATE" 2>/dev/null || echo 0)
if curl -sf -m 5 "$URL" >/dev/null 2>&1; then
    [ "$fails" -gt 0 ] && logger -t minidsp-watchdog "minidspd recovered after $fails failed checks"
    echo 0 > "$STATE"
    exit 0
fi
fails=$((fails + 1))
echo "$fails" > "$STATE"
if [ "$fails" -ge "$THRESHOLD" ]; then
    logger -t minidsp-watchdog "minidspd unresponsive after $fails checks; restarting minidsp + minidsp-mqtt"
    systemctl restart minidsp.service
    sleep 2
    systemctl restart minidsp-mqtt.service
    echo 0 > "$STATE"
else
    logger -t minidsp-watchdog "minidspd check #$fails failed (threshold $THRESHOLD)"
fi
EOF
chmod 755 /usr/local/sbin/minidsp-health-check

cat > /etc/systemd/system/minidsp-watchdog.service << 'EOF'
[Unit]
Description=MiniDSP daemon health check + auto-restart
After=minidsp.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/minidsp-health-check
EOF

cat > /etc/systemd/system/minidsp-watchdog.timer << 'EOF'
[Unit]
Description=Run minidsp-watchdog every 60 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=false

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable squeezelite.service minidsp.service minidsp-mqtt.service minidsp-watchdog.timer
systemctl restart minidsp.service     || true
sleep 1
systemctl restart minidsp-mqtt.service || true
systemctl restart squeezelite.service  || true
systemctl restart minidsp-watchdog.timer || true

echo ""
echo "==> Setup complete."
printf "    Player: %s\n" "${PLAYER_NAME}"
printf "    Audio:  %s\n" "${ALSA_DEVICE}"
printf "    LMS:    %s\n" "${LMS_IP:-auto-discover}"
printf "    MQTT:   %s@%s:%s\n" "${MQTT_USER}" "${MQTT_HOST}" "${MQTT_PORT}"
echo ""
echo "    Inspect:  systemctl status squeezelite minidsp minidsp-mqtt"
echo "    Logs:     journalctl -u squeezelite -u minidsp -u minidsp-mqtt -f"
echo "    Watchdog: journalctl -t minidsp-watchdog          # auto-restart events"
echo "    MiniDSP:  minidsp                       (CLI; goes through minidspd)"
echo "    HTTP API: curl http://127.0.0.1:5380/devices/0"
echo "    Config:   /etc/default/squeezelite, /etc/default/minidsp-mqtt"
echo "              (or squeezelite-ctl.sh on the Proxmox host)"
