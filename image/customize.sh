#!/bin/bash
# Runs inside the image (virt-customize, from /tmp/stage): makes an Ubuntu 24.04 cloud image a
# flex node image for Hyper-V and KVM. See README.md "What the image holds".
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

stage=/tmp/stage
# shellcheck source=versions.env
. "$stage/versions.env"
# shellcheck disable=SC1091
. "$stage/image.env"

# Units, cloud-init settings, the join script, initramfs modules.
tar -xf "$stage/files.tar" -C / --no-same-owner --no-overwrite-dir

# Microsoft's package repository, for the Azure Connected Machine agent; the key is checked against
# Microsoft's published fingerprint.
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc -o /tmp/microsoft.asc
gpg --show-keys --with-colons /tmp/microsoft.asc | grep -qx 'fpr:::::::::BC528686B50D79E339D3721CEB3E94ADBE1229CF:'
gpg --dearmor </tmp/microsoft.asc >/usr/share/keyrings/microsoft-prod.gpg
rm -f /tmp/microsoft.asc
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/24.04/prod noble main' \
  >/etc/apt/sources.list.d/microsoft-prod.list

apt-get update
# The image is current when it is built; dist/<name>.packages records what that meant.
apt-get -y full-upgrade
# - what bootstrap.sh and the agent use on the host: bash, curl, tar, jq, nftables,
#   systemd-container (systemd-nspawn, machinectl), util-linux (flock), iptables;
# - KVM: qemu-guest-agent, which starts only when the VM has its virtio channel;
# - Hyper-V: hv_kvp_daemon, hv_vss_daemon, hv_fcopy_daemon (linux-cloud-tools), which start only on
#   Hyper-V (ConditionVirtualization=microsoft); the drivers are in the kernel's modules;
# - Azure Arc: azcmagent, installed and not connected (a host connects at its first boot).
apt-get install -y --no-install-recommends \
  bash ca-certificates curl tar jq nftables systemd-container util-linux iptables \
  qemu-guest-agent linux-cloud-tools-virtual \
  "azcmagent=${AZCMAGENT_VERSION}"
apt-mark hold azcmagent
# Not a node's: snapd and its seeded snaps.
apt-get -y purge --auto-remove snapd
apt-get -y autoremove --purge

# Both hypervisors' storage and network drivers in the initramfs (files/usr/share/initramfs-tools/modules.d).
update-initramfs -u -k all

# The AKS Flex Node agent and its bootstrap script, from the release pinned in versions.env; the
# join script installs them from here (file://), so a node does not download the agent.
install -d -m 0755 /opt/onek8s/aks-flex-node
install -m 0644 "$stage/aks-flex-node-linux-amd64.tar.gz" /opt/onek8s/aks-flex-node/
install -m 0755 "$stage/bootstrap.sh" /opt/onek8s/aks-flex-node/
cat >/opt/onek8s/aks-flex-node/release.env <<EOF
IMAGE_VERSION=${IMAGE_VERSION}
AKS_FLEX_NODE_VERSION=${AKS_FLEX_NODE_VERSION}
AKS_FLEX_NODE_ARCHIVE_SHA256=${AKS_FLEX_NODE_ARCHIVE_SHA256}
EOF
install -d -m 0755 /usr/share/onek8s
dpkg-query -W -f '${Package}\t${Version}\n' >/usr/share/onek8s/packages.tsv

systemctl enable onek8s-flex-node-seed.service onek8s-flex-node-join.service
# Every node gets its own identity at its first boot: machine ID, SSH host keys, cloud-init instance.
apt-get clean
rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*
cloud-init clean --logs --seed --machine-id
rm -f /var/lib/dbus/machine-id
