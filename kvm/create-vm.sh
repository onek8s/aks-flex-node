#!/bin/bash
# Creates and starts a flex node on a KVM host with libvirt (virt-install): UEFI with Secure Boot,
# a virtio disk copied from the release's qcow2 and grown to its size, the seed ISO as a CD-ROM,
# the QEMU guest agent's channel and a serial console.
#
# Usage: kvm/create-vm.sh -n NAME -i aks-flex-node-<version>-amd64.qcow2 -s SEED.iso
#                         [-m MEMORY_MIB (8192)] [-c VCPUS (4)] [-d DISK_SIZE (64G)]
#                         [-w NETWORK (network=default; bridge=br0 for a bridge)]
#                         [-p POOL_DIR (/var/lib/libvirt/images)]
set -euo pipefail

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

name="" image="" seed="" memory=8192 vcpus=4 disk=64G network=network=default pool=/var/lib/libvirt/images
while getopts "n:i:s:m:c:d:w:p:h" opt; do
  case "$opt" in
    n) name="$OPTARG" ;;
    i) image="$OPTARG" ;;
    s) seed="$OPTARG" ;;
    m) memory="$OPTARG" ;;
    c) vcpus="$OPTARG" ;;
    d) disk="$OPTARG" ;;
    w) network="$OPTARG" ;;
    p) pool="$OPTARG" ;;
    *) usage ;;
  esac
done
[[ -n "$name" && -n "$image" && -n "$seed" ]] || usage

qemu-img convert -O qcow2 "$image" "$pool/$name.qcow2"
qemu-img resize -q "$pool/$name.qcow2" "$disk"
install -m 0600 "$seed" "$pool/$name-seed.iso"

virt-install \
  --name "$name" \
  --osinfo ubuntu24.04 \
  --memory "$memory" \
  --vcpus "$vcpus" \
  --cpu host-passthrough \
  --machine q35 \
  --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=yes \
  --disk "path=$pool/$name.qcow2,bus=virtio,discard=unmap" \
  --disk "path=$pool/$name-seed.iso,device=cdrom,bus=sata,readonly=on" \
  --network "$network,model=virtio" \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --graphics none \
  --console pty,target.type=serial \
  --import \
  --noautoconsole

echo "create-vm: $name started; console: virsh console $name; join: journalctl -u onek8s-flex-node-join"
