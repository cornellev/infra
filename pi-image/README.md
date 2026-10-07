# pi-image

Builds a Raspberry Pi OS (64-bit, desktop, 2026-09-15 trixie) SD card image for a Pi 4 or Pi 5.
On first boot cloud-init sets up:

- hostname, `America/New_York`, `en_US.UTF-8`, US keyboard, US Wi-Fi region
- user `cev` with the shared password, passwordless sudo, SSH password login on the LAN
- Wi-Fi: `RedRover`, plus the optional network in `.env`. Ethernet works too.
- `cev-setup.service`: installs Tailscale and joins the club tailnet as `tag:general` with
  Tailscale SSH (`tailscale ssh cev@<hostname>`), installs `ansible-core`, and runs `cev-sync`
  once. On failure it retries after 30 s, backing off to once a day. Once it succeeds, it turns off
  cloud-init (`/etc/cloud/cloud-init.disabled`) so later boots can't undo manual changes, deletes
  cloud-init's cached copy of the config, deletes the auth key, and disables itself.

## Roles and sync

`cev-sync` runs `ansible-pull`, which clones or updates this repo (it must be public) in
`/opt/cev-infra`, discards local edits there, and applies `ansible/local.yml` to this Pi only.
`cev-sync.timer` runs it on the Pi's schedule, and on the next boot if a run was missed. A change
merged to `main` reaches each Pi when it is next online. Whatever lands on `main` runs as root on
every Pi, so try changes on one bench Pi first.

Every Pi must be listed by hostname in `ansible/inventory.ini`. `make-image.sh` refuses a hostname
that isn't there, and `cev-sync` fails on one. Groups in the same file set what each Pi gets:

| Group | Effect |
|---|---|
| (every Pi) | role `base`: the packages in `roles/base/defaults/main.yml`, Tailscale auto-update, and `unattended-upgrades`, which applies Debian stable and security updates daily with no automatic reboot and skips the Raspberry Pi kernel and firmware |
| | role `sync`: `cev-sync` and its timer, daily by default |
| `can` | role `can`: the packages in `roles/can/defaults/main.yml` |
| `weekly` | syncs weekly instead of daily (`group_vars/weekly.yml`) |
| `frozen` | still pulls, but applies nothing except its sync timer, so moving it out of `frozen` unfreezes it |

Changing a Pi's groups is a PR. For an emergency freeze on the Pi itself, which skips the pull too:

```sh
sudo touch /etc/cev-sync-off   # unfreeze: sudo rm /etc/cev-sync-off
```

`journalctl -u cev-sync` shows each run.

## Rename a Pi

Rename it in `ansible/inventory.ini` first, then on the Pi:

```sh
sudo raspi-config nonint do_hostname <name>   # /etc/hostname and /etc/hosts
sudo tailscale set --hostname=<name>          # the tailnet name
```

## Build

Needs bash, curl, xz, mtools, and just (`brew install xz mtools just` or
`apt install xz-utils mtools just`).

```sh
cp .env.example .env    # then fill it in
just pi-image image <hostname>
```

The first run downloads 1.4 GB into `build/`. Each image is a full copy of the 6 GB+ base.

## Flash

Write `build/<hostname>.img` with Raspberry Pi Imager ("Use custom"), and answer **No** to OS
customisation. Yes overwrites `user-data`, `network-config`, and `cmdline.txt`.
`dd` or balenaEtcher also work.

## RedRover

RedRover only lets in registered MAC addresses. Register each Pi:

1. Boot it on ethernet or the `.env` network, or read the MAC on its screen:
   `cat /sys/class/net/wlan0/address`
2. At https://mycomputers.cit.cornell.edu/ (VPN off campus), use "Add Device with No Browser".
3. Reboot the Pi. `cev-setup` backs off to daily retries while it has no internet, and a reboot
   starts it again right away.

Cornell says a registration is valid for four months and auto-renews only if the Pi was seen on
the network in the 30 days before. A Pi left off for more than 30 days, like over the summer, can
lose its registration. It then can't reach the internet on RedRover, so it can't be fixed
remotely. Check each Pi's registration at https://mycomputers.cit.cornell.edu/ at the start of
each semester, and register it again if it expired.

## Secrets

`.env` and the rendered files in `build/<hostname>/` hold the password, Wi-Fi password, and
Tailscale OAuth client secret. So does the card's boot partition, in plain text. Once the Pi
joins the tailnet, `cev-setup` blanks the secret in `/boot/firmware/user-data` and deletes
cloud-init's cached copy. The password and Wi-Fi password stay on the boot partition.

The OAuth client secret doesn't expire. Revoke and replace it in the Tailscale admin console when
an IT lead leaves or a card is lost. Pis already on the tailnet stay on it.
