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
    xz -dc build/base.img.xz >build/base.img.tmp
    mv build/base.img.tmp build/base.img
fi

img=build/$host.img
cp build/base.img "$img"
# partition 1 (the fat boot partition) start lba sits at byte 454 of the mbr
offset=$(($(od -An -t u4 -j 454 -N 4 "$img" | tr -d ' ') * 512))
fat="$img@@$offset"
id="cev-$host-$(date +%s)"

# yaml single-quoted string
q() { printf "'%s'" "${1//\'/\'\'}"; }

out=build/$host
mkdir -p "$out"

cat >"$out/user-data" <<EOF
#cloud-config
manage_resolv_conf: false

hostname: $(q "$host")
manage_etc_hosts: true

apt:
  preserve_sources_list: true
  conf: |
    Acquire {
      Check-Date "false";
    };

timezone: America/New_York
locale: en_US.UTF-8
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

runcmd:
  - [systemctl, enable, --now, ssh]
  - [sh, -c, "echo 'cev ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/010_cev-nopasswd && chmod 0440 /etc/sudoers.d/010_cev-nopasswd"]
  - [systemctl, enable, --now, --no-block, cev-setup.service]
EOF

cat >"$out/network-config" <<EOF
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      dhcp6: true
      optional: true
  wifis:
    wlan0:
      dhcp4: true
      regulatory-domain: "US"
      access-points:
        "RedRover":
          auth:
            key-management: none
EOF
if [ -n "${WIFI_SSID:-}" ]; then
    cat >>"$out/network-config" <<EOF
        $(q "$WIFI_SSID"):
          password: $(q "${WIFI_PSK:?set WIFI_PSK in .env}")
EOF
fi
echo "      optional: true" >>"$out/network-config"

echo "instance-id: $id" >"$out/meta-data"
printf '%s ds=nocloud;i=%s\n' "$(mtype -i "$fat" ::cmdline.txt | tr -d '\r\n')" "$id" >"$out/cmdline.txt"

for f in user-data network-config meta-data cmdline.txt; do
    mcopy -o -i "$fat" "$out/$f" "::$f"
done
echo "wrote $img"
