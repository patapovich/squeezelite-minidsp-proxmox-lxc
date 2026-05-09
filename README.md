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
- enable a `squeezelite.service` systemd unit

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
| `DEBIAN_RELEASE` | `bookworm` | `bookworm`/`trixie`/`bullseye` |

Example: `CTID=210 PLAYER_NAME="Living Room" LMS_IP=192.168.1.10 ./proxmox-create-lxc.sh`

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
./squeezelite-ctl.sh set floor=-72                # squeezelite-volume FLOOR_DB
./squeezelite-ctl.sh set curve=2                  # squeezelite-volume CURVE_K (1=linear, >1=bottom-heavy)
./squeezelite-ctl.sh set name="Foo" lms=...       # multiple in one call
./squeezelite-ctl.sh edit                         # open /etc/default/squeezelite in $EDITOR
./squeezelite-ctl.sh restart
./squeezelite-ctl.sh logs -n 50                   # journalctl -u squeezelite -n 50
./squeezelite-ctl.sh logs -f                      # follow live
./squeezelite-ctl.sh minidsp source toslink       # any minidsp CLI command
CTID=210 ./squeezelite-ctl.sh ...                 # target a different CT
```

Each `set` writes the requested var into the container's
`/etc/default/squeezelite` and restarts the service. The launcher wrapper
(`/usr/local/sbin/squeezelite-launch`) reads those vars and constructs the
squeezelite argv with a bash array so player names with spaces work.

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
