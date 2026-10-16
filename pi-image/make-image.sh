#!/usr/bin/env bash
# writes build/<hostname>.img, raspberry pi os desktop with cloud-init first-boot setup
set -euo pipefail

host=${1:?usage: make-image.sh <hostname>}
cd "$(dirname "$0")"
if ! grep -qx "$host" ansible/inventory.ini; then
    echo "add $host to ansible/inventory.ini first" >&2
    exit 1
fi
source .env
: "${PASSWORD:?set PASSWORD in .env}" "${TS_AUTHKEY:?set TS_AUTHKEY in .env}"

url=https://downloads.raspberrypi.com/raspios_arm64/images/raspios_arm64-2026-09-15/2026-09-15-raspios-trixie-arm64.img.xz
sha256=61d95799550aac32788bb3cacc3d471dcc860f8053ce989dec4aecc388b799dd

mkdir -p build
if [ ! -f build/base.img ]; then
    if [ ! -f build/base.img.xz ]; then
        curl -fL -o build/base.img.xz.part "$url"
        mv build/base.img.xz.part build/base.img.xz
    fi
    echo "$sha256  build/base.img.xz" | shasum -a 256 -c
    xz -dcv build/base.img.xz >build/base.img.tmp
    mv build/base.img.tmp build/base.img
fi

img=build/$host.img
dd if=build/base.img of="$img" bs=4194304 status=progress
# partition 1 (the fat boot partition) start lba sits at byte 454 of the mbr
offset=$(($(od -An -t u4 -j 454 -N 4 "$img" | tr -d ' ') * 512))
fat="$img@@$offset"
id="cev-$host-$(date +%s)"

# yaml single-quoted string
q() { printf "'%s'" "${1//\'/\'\'}"; }

out=build/$host
mkdir -p "$out"
locale=en_US.UTF-8

env_wifi=
if [ -n "${WIFI_SSID:-}" ]; then
    env_wifi=$(
        cat <<EOF
  - path: $(q "/etc/NetworkManager/system-connections/$WIFI_SSID.nmconnection")
    permissions: '0600'
    content: |
      [connection]
      id=$WIFI_SSID
      type=wifi
      autoconnect-priority=1

      [wifi]
      ssid=$WIFI_SSID
      mode=infrastructure

      [wifi-security]
      key-mgmt=wpa-psk
      psk=${WIFI_PSK:?set WIFI_PSK in .env}

      [ipv4]
      method=auto

      [ipv6]
      method=ignore
EOF
    )
fi

cat >"$out/user-data" <<EOF
#cloud-config
manage_resolv_conf: false

hostname: $(q "$host")
manage_etc_hosts: true

# the locale module runs after the desktop starts, so the first session would keep the image's en_GB
# bootcmd runs before the desktop
bootcmd:
  - [cloud-init-per, once, cev-locale, sh, -c, "echo '$locale UTF-8' >/etc/locale.gen && locale-gen && update-locale LANG=$locale"]

timezone: America/New_York
locale: $locale
keyboard:
  model: pc105
  layout: us

user:
  name: cev
  shell: /bin/bash
  lock_passwd: false
  plain_text_passwd: $(q "$PASSWORD")
  sudo: ALL=(ALL) NOPASSWD:ALL

ssh_pwauth: true

write_files:
  - path: /etc/cev-setup.env
    permissions: '0600'
    content: |
      TS_AUTHKEY='$TS_AUTHKEY'
  - path: /usr/local/sbin/cev-setup
    permissions: '0755'
    content: |
      #!/bin/sh
      set -e
      [ ! -e /etc/cev-setup.env ] || . /etc/cev-setup.env
      export DEBIAN_FRONTEND=noninteractive
      # a power cut can leave package lists empty, and apt keeps an existing list without checking it
      find /var/lib/apt/lists -maxdepth 1 -type f -size 0 ! -name lock -delete
      # a pi 4 boots with the image's date, and apt rejects every signature until the clock syncs
      timeout 300 sh -c 'until [ "\$(timedatectl show -p NTPSynchronized --value)" = yes ]; do sleep 2; done' ||
        { echo "clock not synced after 5 min" >&2; exit 1; }
      command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
      # a rerun of tailscale up fails once the sync playbook has changed a tailscale setting
      tailscale status >/dev/null 2>&1 ||
        tailscale up --auth-key="\$TS_AUTHKEY" --advertise-tags=tag:general --ssh --hostname="\$(hostname)"
      sed -i "s/^\( *TS_AUTHKEY=\).*/\1''/" /boot/firmware/user-data
      command -v ansible-pull >/dev/null || {
        apt-get -o DPkg::Lock::Timeout=600 update
        apt-get -o DPkg::Lock::Timeout=600 install -y --no-install-recommends ansible-core git
      }
      /usr/local/sbin/cev-sync
      # stops cloud-init's per-boot modules, which rewrite /etc/hosts with the image's hostname
      touch /etc/cloud/cloud-init.disabled
      # cloud-init's cached copy of this user-data holds the auth key
      rm -rf /var/lib/cloud/instances
      systemctl disable cev-setup.service
      rm -f /etc/cev-setup.env
  # the sync role installs the same file, first boot needs it before that role has run
  - path: /usr/local/sbin/cev-sync
    permissions: '0755'
    content: |
$(sed 's/^/      /' ansible/roles/sync/files/cev-sync)
  # retries until the pi has internet, e.g. after its mac is registered on redrover
  - path: /etc/systemd/system/cev-setup.service
    content: |
      [Unit]
      Description=Join Tailscale and apply cornellev/infra
      Wants=network-online.target
      After=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/cev-setup
      TimeoutStartSec=1h
      Restart=on-failure
      RestartSec=30
      RestartSteps=10
      RestartMaxDelaySec=1d

      [Install]
      WantedBy=multi-user.target
  # wi-fi is networkmanager keyfiles, not netplan
  # raspberry pi's networkmanager rewrites /etc/netplan on every start, and a power cut then can empty it
  # see raspberrypi/trixie-feedback#99
  - path: /etc/NetworkManager/system-connections/RedRover.nmconnection
    permissions: '0600'
    content: |
      [connection]
      id=RedRover
      type=wifi

      [wifi]
      ssid=RedRover
      mode=infrastructure

      [ipv4]
      method=auto

      [ipv6]
      method=ignore
$env_wifi

runcmd:
  # networkmanager may have loaded its profiles before write_files ran
  - [nmcli, connection, reload]
  # sets the region and unblocks wi-fi, which the image ships blocked
  - [raspi-config, nonint, do_wifi_country, US]
  # a new file survives a power cut only once flushed
  - [sync]
  - [systemctl, enable, --now, ssh]
  - [sh, -c, "echo 'cev ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/010_cev-nopasswd && chmod 0440 /etc/sudoers.d/010_cev-nopasswd"]
  - [systemctl, enable, --now, --no-block, cev-setup.service]
EOF

echo "instance-id: $id" >"$out/meta-data"
# network-config=disabled keeps cloud-init from writing netplan
# networkmanager's default wired profile covers eth0
printf '%s ds=nocloud;i=%s network-config=disabled\n' "$(mtype -i "$fat" ::cmdline.txt | tr -d '\r\n')" "$id" >"$out/cmdline.txt"

for f in user-data meta-data cmdline.txt; do
    mcopy -o -i "$fat" "$out/$f" "::$f"
done
echo "wrote $img"
