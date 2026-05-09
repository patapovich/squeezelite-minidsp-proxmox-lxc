#!/bin/bash
# Installs squeezelite (with -w volume script support) + minidsp-rs on a fresh
# Debian system. Designed to be invoked once at first boot via cloud-init,
# but is also safe to re-run on any minimal Debian 12/13 install.
#
# Optional env vars:
#   PLAYER_NAME   Player name shown in LMS         (default: squeezelite)
#   LMS_IP        LMS server IP, empty = discover  (default: empty)
#   MINIDSP_VER   minidsp-rs release version       (default: 0.1.10)

set -eu

PLAYER_NAME="${PLAYER_NAME:-squeezelite}"
LMS_IP="${LMS_IP:-}"
MINIDSP_VER="${MINIDSP_VER:-0.1.10}"

export DEBIAN_FRONTEND=noninteractive

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
    libssl-dev

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
cat > /etc/default/squeezelite << EOF
# squeezelite settings — edit then: systemctl restart squeezelite
# (or use squeezelite-ctl.sh on the Proxmox host:
#    ./squeezelite-ctl.sh set name="Living Room" lms=192.168.1.10)

# Player name shown in LMS (spaces allowed)
PLAYER_NAME="${PLAYER_NAME}"

# LMS server IP[:port]. Empty = auto-discover.
LMS_IP="${LMS_IP}"

# ALSA output device for squeezelite -o
ALSA_DEVICE="${ALSA_DEVICE}"

# ALSA params for squeezelite -a, format buffer:periods:format:mmap
# 80:4::1 = 80 ms buffer, 4 periods, format=auto (device picks S32_LE on
# capable DACs), mmap=on. Empirically clean on USB DACs; smaller buffers /
# mmap=0 stutter audibly. Empty = squeezelite defaults.
ALSA_PARAMS="80:4::1"

# Anything else to append (e.g. -d output=info, -c flac,pcm)
EXTRA_OPTS=""

# squeezelite-volume floor (max attenuation when slider=1). Lower magnitude
# = less touchy, less dynamic range. Default in the script is -50; common
# tweaks: -30 (very gentle), -40 (gentle), -60 (more dynamic).
FLOOR_DB="-50"
EOF

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

systemctl daemon-reload
systemctl enable squeezelite.service
systemctl restart squeezelite.service || true

echo ""
echo "==> Setup complete."
printf "    Player: %s\n" "${PLAYER_NAME}"
printf "    Audio:  %s\n" "${ALSA_DEVICE}"
printf "    LMS:    %s\n" "${LMS_IP:-auto-discover}"
echo ""
echo "    Inspect:  systemctl status squeezelite"
echo "    Logs:     journalctl -u squeezelite -f"
echo "    MiniDSP:  minidsp"
echo "    Config:   /etc/default/squeezelite (or squeezelite-ctl.sh on host)"
