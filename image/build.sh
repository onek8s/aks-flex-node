#!/bin/bash
# Builds the OneK8s flex node image from the pinned inputs in versions.env:
#   dist/aks-flex-node-<version>-amd64.qcow2  KVM (compressed qcow2)
#   dist/aks-flex-node-<version>-amd64.vhdx   Hyper-V (dynamic VHDX, generation 2)
#   dist/aks-flex-node-<version>-amd64.packages  dpkg list of the image
#   dist/SHA256SUMS
# One disk is customized once and converted twice, so both formats hold the same bytes.
#
# Needs root (libguestfs reads the host kernel), qemu-img, libguestfs-tools (virt-resize,
# virt-customize, virt-cat, virt-sparsify) and curl. KVM speeds libguestfs up but is not required.
#
# Usage: sudo image/build.sh [version]   (default: git describe)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=versions.env
. "$root/versions.env"

version="${1:-$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo dev)}"
name="aks-flex-node-${version}-amd64"
cache="$root/.cache"
work="$root/.work"
dist="$root/dist"

log() { printf 'build: %s\n' "$*" >&2; }

# fetch URL FILE SHA256: downloads once into the cache and refuses a file whose digest differs.
fetch() {
  local url="$1" file="$cache/$2" sha="$3"
  if [[ ! -f "$file" ]] || ! echo "$sha  $file" | sha256sum --check --status; then
    log "downloading $url"
    curl -fsSL --retry 3 -o "$file.part" "$url"
    mv -f "$file.part" "$file"
  fi
  echo "$sha  $file" | sha256sum --check --strict --quiet || { log "digest mismatch: $url"; exit 1; }
}

mkdir -p "$cache" "$dist"
rm -rf "$work"
mkdir -p "$work/stage"

fetch "$UBUNTU_IMAGE_URL" "ubuntu-${UBUNTU_SERIAL}-amd64.img" "$UBUNTU_IMAGE_SHA256"
fetch "https://github.com/Azure/AKSFlexNode/releases/download/${AKS_FLEX_NODE_VERSION}/aks-flex-node-linux-amd64.tar.gz" \
  "aks-flex-node-${AKS_FLEX_NODE_VERSION}-linux-amd64.tar.gz" "$AKS_FLEX_NODE_ARCHIVE_SHA256"
fetch "https://raw.githubusercontent.com/Azure/AKSFlexNode/${AKS_FLEX_NODE_VERSION}/scripts/bootstrap.sh" \
  "aks-flex-node-${AKS_FLEX_NODE_VERSION}-bootstrap.sh" "$AKS_FLEX_NODE_BOOTSTRAP_SHA256"

# What customize.sh puts into the image.
cp "$root/versions.env" "$root/image/customize.sh" "$work/stage/"
cp "$cache/aks-flex-node-${AKS_FLEX_NODE_VERSION}-linux-amd64.tar.gz" "$work/stage/aks-flex-node-linux-amd64.tar.gz"
cp "$cache/aks-flex-node-${AKS_FLEX_NODE_VERSION}-bootstrap.sh" "$work/stage/bootstrap.sh"
echo "IMAGE_VERSION=${version}" >"$work/stage/image.env"
tar -C "$root/image/files" --owner=0 --group=0 --sort=name -cf "$work/stage/files.tar" .
tar -C "$work" --owner=0 --group=0 -cf "$work/stage.tar" stage

log "customizing $name"
# The cloud image's root file system has too little room for the packages: grow it to the disk.
qemu-img create -q -f qcow2 "$work/disk.qcow2" "$DISK_SIZE"
virt-resize --quiet --expand /dev/sda1 "$cache/ubuntu-${UBUNTU_SERIAL}-amd64.img" "$work/disk.qcow2"
# virt-customize sizes its appliance small; apt and update-initramfs want more.
virt-customize -a "$work/disk.qcow2" --smp 2 --memsize 2048 --no-logfile \
  --upload "$work/stage.tar:/tmp/onek8s-stage.tar" \
  --run-command 'tar -xf /tmp/onek8s-stage.tar -C /tmp && rm -f /tmp/onek8s-stage.tar' \
  --run-command 'bash /tmp/stage/customize.sh' \
  --run-command 'rm -rf /tmp/stage'
virt-cat -a "$work/disk.qcow2" /usr/share/onek8s/packages.tsv >"$dist/$name.packages"
virt-sparsify --in-place "$work/disk.qcow2"

log "converting"
rm -f "$dist/$name.qcow2" "$dist/$name.vhdx"
qemu-img convert -c -O qcow2 "$work/disk.qcow2" "$dist/$name.qcow2"
qemu-img convert -O vhdx -o subformat=dynamic "$work/disk.qcow2" "$dist/$name.vhdx"
rm -rf "$work"

(cd "$dist" && sha256sum "$name".* >SHA256SUMS)
cat "$dist/SHA256SUMS"
