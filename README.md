# squeezelite-minidsp-proxmox-lxc

Provision a [squeezelite](https://github.com/ralph-irving/squeezelite) +
[minidsp-rs](https://github.com/mrene/minidsp-rs) audio player as a Proxmox
**LXC container** with USB passthrough to a MiniDSP (DDRC-24 tested) — and
manage its runtime settings from the Proxmox host without entering the
container.

LXC is used instead of a VM because QEMU's USB controller emulation drops
isochronous frames on USB audio and produces audible distortion. An LXC
shares the host kernel, so the MiniDSP appears as a real local USB device
and audio is bare-metal clean. The trade-off is a privileged container
(weaker isolation than a VM) — acceptable for a single-purpose appliance.

## Prerequisites

- Proxmox VE host (8.x tested) with the MiniDSP plugged into a host USB port
- Logitech Media Server / Lyrion Music Server reachable on the LAN (or
  configure `LMS_IP=` to point at one)
- MQTT broker reachable on the LAN — Home Assistant's Mosquitto add-on works
  out of the box. Defaults to `mqtt://mqtt:mqtt@192.168.1.3:1883`; override
  with `MQTT_HOST` / `MQTT_USER` / `MQTT_PASS` env vars (see below).

## Quick start

On the Proxmox host, as root:

```sh
git clone https://github.com/patapovich/squeezelite-minidsp-proxmox-lxc.git
cd squeezelite-minidsp-proxmox-lxc
./proxmox-create-lxc.sh
```

The script downloads the Debian 12 LXC template (~120 MB once), creates a
privileged container, bind-mounts `/dev/snd` and `/dev/bus/usb` (cgroup
char-major 116 + 189), then runs `setup.sh` inside the container to:

- build squeezelite from
  [`patapovich/squeezelite#fix-volume-script-w-option`](https://github.com/patapovich/squeezelite/tree/fix-volume-script-w-option)
  with `-DGPIO -DRESAMPLE -DDSD -DVISEXPORT -DUSE_SSL -DOPUS`
- install minidsp-rs from upstream `.deb`
- drop in `squeezelite-source` / `squeezelite-volume` from
  [`patapovich/squeezelite-minidsp`](https://github.com/patapovich/squeezelite-minidsp)
  (called by `-S` and `-w` to switch the MiniDSP input and follow LMS volume)
- write key=value `/etc/default/squeezelite` + a small launcher wrapper
- start `minidspd` (HTTP/WS API on `127.0.0.1:5380` + Unix socket
  `/tmp/minidsp.sock`) so the local CLI and the HA bridge share one device
  session — no more USB contention between LMS volume writes and HA writes
- install `minidsp-mqtt`, a small Python bridge that exposes master volume,
  mute, source and preset over MQTT with **Home Assistant autodiscovery**
- enable `squeezelite.service`, `minidsp.service` and
  `minidsp-mqtt.service` systemd units

Total time on first run: ~3 minutes (squeezelite is built from source).

## Tunables (env vars on the Proxmox host)

| Var | Default | Notes |
|---|---|---|
| `CTID` | `201` | Proxmox container ID |
| `CT_HOSTNAME` | `squeezelite` | container hostname |
| `MEMORY` | `512` | MB |
| `CORES` | `2` | vCPU |
| `DISK_SIZE` | `4` | rootfs GB |
| `STORAGE` | `local-lvm` | rootfs storage |
| `BRIDGE` | `vmbr0` | network bridge |
| `PASSWORD` | `squeezelite` | container root password |
| `PLAYER_NAME` | `squeezelite` | shown in LMS |
| `LMS_IP` | *(empty)* | LMS server IP — empty = auto-discover |
| `MQTT_HOST` | `192.168.1.3` | MQTT broker (HA Mosquitto add-on) |
| `MQTT_PORT` | `1883` | MQTT broker port |
| `MQTT_USER` | `mqtt` | MQTT username |
| `MQTT_PASS` | `mqtt` | MQTT password |
| `DEBIAN_RELEASE` | `bookworm` | `bookworm`/`trixie`/`bullseye` |

Example: `CTID=210 PLAYER_NAME="Living Room" LMS_IP=192.168.1.10 MQTT_HOST=192.168.1.3 ./proxmox-create-lxc.sh`

## Day-to-day management — `squeezelite-ctl.sh`

Run from the Proxmox host (no need to enter the container):

```sh
./squeezelite-ctl.sh                              # status + current config + minidsp state
./squeezelite-ctl.sh set name="Living Room"       # change player name (spaces ok)
./squeezelite-ctl.sh set lms=192.168.1.10         # set LMS IP[:port]
./squeezelite-ctl.sh set lms=                     # back to auto-discover
./squeezelite-ctl.sh set device=hw:CARD=DDRC24,DEV=0
./squeezelite-ctl.sh set buffer=80:4::1           # squeezelite -a (buffer:periods:format:mmap)
./squeezelite-ctl.sh set extra="-d output=info"   # any extra squeezelite flags
./squeezelite-ctl.sh set floor=-72                # FLOOR_DB (used by both LMS + HA paths)
./squeezelite-ctl.sh set curve=2                  # CURVE_K (1=linear, >1=bottom-heavy)
./squeezelite-ctl.sh set mqtt-host=192.168.1.3    # MQTT broker for HA bridge
./squeezelite-ctl.sh set mqtt-user=mqtt mqtt-pass=mqtt
./squeezelite-ctl.sh set sources=Analog,Toslink,Spdif,Aesebu  # HA source-select options
./squeezelite-ctl.sh set name="Foo" lms=...       # multiple in one call
./squeezelite-ctl.sh edit                         # open /etc/default/squeezelite
./squeezelite-ctl.sh edit-mqtt                    # open /etc/default/minidsp-mqtt
./squeezelite-ctl.sh restart                      # restart squeezelite + minidsp + minidsp-mqtt
./squeezelite-ctl.sh logs -n 50                   # journalctl across all 3 units
./squeezelite-ctl.sh logs -f                      # follow live
./squeezelite-ctl.sh minidsp source toslink       # any minidsp CLI command (via /tmp/minidsp.sock)
CTID=210 ./squeezelite-ctl.sh ...                 # target a different CT
```

Each `set` writes the requested var into the container's
`/etc/default/squeezelite` (or `/etc/default/minidsp-mqtt` for `mqtt-*` and
`sources`/`node-id`) and restarts whichever services are affected. `floor`
and `curve` live in `/etc/default/squeezelite` and feed both the LMS path
(via squeezelite-volume) and the HA path (via minidsp-mqtt), so the slider
behaves identically in both UIs.

## Home Assistant integration

`minidsp-mqtt` runs inside the container as a systemd service and bridges
the [minidsp-rs HTTP/WS daemon](https://minidsp-rs.pages.dev/daemon/http) to
MQTT. With HA's MQTT integration enabled and discovery on (the default), one
HA device appears on first connect with these entities:

| Entity | Type | Notes |
|---|---|---|
| Volume | `number` 0–100 | Same curve as `squeezelite-volume`. LMS / IR / HA agree. |
| Mute | `switch` | Independent of volume slider. |
| Source | `select` | Options come from `SOURCES` env. The bridge ships a generic default of `Analog,Toslink,Spdif,Aesebu`; **DDRC-24 has `Usb` instead of `Spdif`** — set `./squeezelite-ctl.sh set sources=Analog,Toslink,Usb,Aesebu` to match. |
| Preset | `select` | `Config 1`–`Config 4`. |
| Bridge online | `binary_sensor` | LWT — `offline` if the bridge is down. |

Volume curve (matches `squeezelite-volume`):

```
gain_dB = FLOOR_DB * (1 - (vol/100)^CURVE_K)        # vol = 1..100
vol = 0  →  gain = -127 dB (hard mute)
```

Defaults `FLOOR_DB=-50`, `CURVE_K=2`. Both the LMS-driven path and the HA
slider read the same `/etc/default/squeezelite`, so changing `floor` or
`curve` updates both at once.

MQTT topic layout (`minidsp/<NODE_ID>/...`):

```
master/volume        state, retained, "0".."100"
master/volume/set    command,         "0".."100"
master/mute          state, retained, "ON" / "OFF"
master/mute/set      command,         "ON" / "OFF"
master/source        state, retained, e.g. "Toslink"
master/source/set    command,         e.g. "Toslink"
master/preset        state, retained, "Config 1".."Config 4"
master/preset/set    command,         "Config 1".."Config 4" or "1".."4"
status               LWT, retained,   "online" / "offline"
homeassistant/.../config    HA discovery, retained
```

Diagnostic: `pct exec <CTID> -- curl -s http://127.0.0.1:5380/devices/0`
returns the live master state straight from minidspd.

## How USB + audio reach the container

`/etc/pve/lxc/<CTID>.conf` ends up with:

```
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
```

`/dev/snd` exposes the host's ALSA cards (so squeezelite's `-o
hw:CARD=…` works), and `/dev/bus/usb` lets `minidsp-rs` talk to the MiniDSP
via libusb. No hidraw bind needed — minidsp-rs uses libusb, not hidraw.

## Credits

- [squeezelite](https://github.com/ralph-irving/squeezelite) — Ralph Irving
- [minidsp-rs](https://github.com/mrene/minidsp-rs) — Mathieu Rene
- [squeezelite -w fork branch](https://github.com/patapovich/squeezelite/tree/fix-volume-script-w-option)
- [squeezelite-minidsp helper scripts](https://github.com/patapovich/squeezelite-minidsp)
