#!/bin/bash
# Makes a node's seed ISO (NoCloud, volume label cidata) for KVM, or for Hyper-V as a DVD:
#   meta-data                  instance-id and local-hostname (the Kubernetes node name)
#   user-data                  the default user's (ubuntu) SSH key
#   network-config             optional: netplan v2, for a static address
#   aks-flex-node/bootstrap.env  the join settings (bootstrap.env.example)
#   aks-flex-node/<file>       credentials named in them, copied to /etc/aks-flex-node/credentials/
# Hyper-V without an ISO tool: hyperv/New-FlexNodeVM.ps1 writes the same files to a FAT VHDX.
#
# Usage: seed/make-seed.sh -n NAME -k SSH_PUBLIC_KEY -o SEED.iso [-s bootstrap.env]
#                          [-c CREDENTIAL]... [-N network-config]
set -euo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

name="" key="" out="" settings="" network=""
credentials=()
while getopts "n:k:o:s:c:N:h" opt; do
  case "$opt" in
    n) name="$OPTARG" ;;
    k) key="$OPTARG" ;;
    o) out="$OPTARG" ;;
    s) settings="$OPTARG" ;;
    c) credentials+=("$OPTARG") ;;
    N) network="$OPTARG" ;;
    *) usage ;;
  esac
done
[[ -n "$name" && -n "$key" && -n "$out" ]] || usage
[[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "make-seed: $name is not a lowercase DNS label" >&2; exit 2; }

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
chmod 0700 "$dir"

cat >"$dir/meta-data" <<EOF
instance-id: ${name}-$(date -u +%Y%m%d%H%M%S)
local-hostname: ${name}
EOF
{
  echo "#cloud-config"
  echo "ssh_authorized_keys:"
  while IFS= read -r line; do
    [[ -n "$line" ]] && printf '  - %s\n' "$line"
  done <"$key"
} >"$dir/user-data"
[[ -z "$network" ]] || cp "$network" "$dir/network-config"
if [[ -n "$settings" ]]; then
  mkdir "$dir/aks-flex-node"
  cp "$settings" "$dir/aks-flex-node/bootstrap.env"
  for file in "${credentials[@]}"; do
    cp "$file" "$dir/aks-flex-node/"
  done
fi

if command -v genisoimage >/dev/null; then
  mkiso=(genisoimage)
elif command -v xorriso >/dev/null; then
  mkiso=(xorriso -as mkisofs)
else
  echo "make-seed: needs genisoimage or xorriso" >&2
  exit 1
fi
"${mkiso[@]}" -quiet -output "$out" -volid cidata -joliet -rock "$dir"
chmod 0600 "$out"
echo "make-seed: $out for $name"
