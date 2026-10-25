#!/bin/bash
# Boots the image's qcow2 under QEMU as a node would boot on KVM - UEFI with Secure Boot and
# Microsoft's keys (the shim path of a Hyper-V generation 2 VM), a virtio disk, a seed ISO, the guest
# agent's channel - and checks over SSH what can be checked without a cluster: cloud-init, hostname,
# disk, packages, both hypervisors' drivers and agents, the staged agent, and the join up to its
# settings check (a seed without a cluster ID must stop it with exit 78, unretried).
#
# Needs qemu-system-x86_64, OVMF (secboot + ms vars), genisoimage or xorriso, ssh, python3.
# Uses KVM when /dev/kvm is usable, else TCG (slow: about 10 minutes).
#
# Usage: test/smoke.sh dist/aks-flex-node-<version>-amd64.qcow2
# The checks run on the node: their expansions are meant for its shell.
# shellcheck disable=SC2016,SC2029
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
image="$(realpath "$1")"
work="$(mktemp -d)"
port="${SMOKE_SSH_PORT:-2222}"
name=smoke-flex-1
pid=""
cleanup() {
  [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

log() { printf 'smoke: %s\n' "$*" >&2; }
failures=0
check() {
  local what="$1"
  shift
  if "$@"; then log "ok   $what"; else log "FAIL $what"; failures=$((failures + 1)); fi
}

ssh-keygen -q -t ed25519 -N '' -f "$work/key"
cat >"$work/bootstrap.env" <<'EOF'
AKS_FLEX_NODE_AUTH=service-principal
AKS_FLEX_NODE_SP_TENANT_ID=00000000-0000-0000-0000-000000000000
AKS_FLEX_NODE_SP_CLIENT_ID=00000000-0000-0000-0000-000000000000
AKS_FLEX_NODE_SP_CLIENT_CERTIFICATE_FILE=/etc/aks-flex-node/credentials/sp-client-certificate.pem
EOF
printf 'not a certificate\r\n' >"$work/sp-client-certificate.pem"
"$root/seed/make-seed.sh" -n "$name" -k "$work/key.pub" -o "$work/seed.iso" \
  -s "$work/bootstrap.env" -c "$work/sp-client-certificate.pem"

qemu-img create -q -f qcow2 -b "$image" -F qcow2 "$work/disk.qcow2"
code=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd "$work/vars.fd"
if [[ -r /dev/kvm && -w /dev/kvm ]]; then accel=(-accel kvm -cpu host); else accel=(-accel tcg -cpu max); fi
log "booting ${accel[1]}"
qemu-system-x86_64 "${accel[@]}" -machine q35,smm=on -m 4096 -smp 4 \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$code" \
  -drive "if=pflash,format=raw,unit=1,file=$work/vars.fd" \
  -drive "if=virtio,format=qcow2,file=$work/disk.qcow2" \
  -drive "if=none,id=seed,media=cdrom,readonly=on,file=$work/seed.iso" \
  -device ide-cd,drive=seed \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${port}-:22" -device virtio-net-pci,netdev=net0 \
  -device virtio-serial -chardev "socket,id=qga0,path=$work/qga.sock,server=on,wait=off" \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -display none -serial "file:$work/serial.log" &
pid=$!

ssh_opts=(-q -i "$work/key" -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
on() { ssh "${ssh_opts[@]}" ubuntu@127.0.0.1 "$@"; }
for _ in $(seq 180); do
  on true 2>/dev/null && break
  kill -0 "$pid" || { log "QEMU exited"; tail -50 "$work/serial.log"; exit 1; }
  sleep 5
done
on true || { log "no SSH"; tail -50 "$work/serial.log"; exit 1; }
on 'sudo cloud-init status --wait' >/dev/null || true
# The join's unit retries nothing here; wait for it to settle.
for _ in $(seq 60); do
  state="$(on systemctl show -p ActiveState --value onek8s-flex-node-join)"
  [[ "$state" == failed || "$state" == active ]] && break
  sleep 5
done

check "cloud-init done" on 'cloud-init status | grep -q "status: done"'
check "Secure Boot on" on 'sudo od -An -tu1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c | grep -q "1$"'
check "hostname from meta-data" test "$(on hostname)" = "$name"
check "root file system grown (>= 30 GiB)" on 'test "$(df -B1G --output=size / | tail -1)" -ge 30'
check "machine ID set" on 'test "$(wc -c </etc/machine-id)" -eq 33'
check "host packages" on 'for c in bash curl tar jq nft systemd-nspawn machinectl flock iptables azcmagent qemu-ga hv_kvp_daemon; do command -v $c >/dev/null || { echo missing $c; exit 1; }; done'
check "no snapd" on '! command -v snap'
check "KVM guest agent answers" python3 - "$work/qga.sock" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(10)
s.connect(sys.argv[1])
s.sendall(b'{"execute":"guest-ping"}\n')
sys.exit(0 if json.loads(s.makefile().readline()) == {"return": {}} else 1)
EOF
check "Hyper-V daemons only on Hyper-V" on 'systemctl cat hv-kvp-daemon.service | grep -q "^ConditionVirtualization=microsoft"'
check "Hyper-V and virtio drivers in the initramfs" on '
  k=$(uname -r); l=$(lsinitramfs /boot/initrd.img-$k)
  for m in hv_vmbus hv_storvsc hv_netvsc hv_utils virtio_blk virtio_scsi virtio_net; do
    grep -q "/$m.ko" <<<"$l" || grep -q "/$m.ko" /lib/modules/$k/modules.builtin || { echo missing $m; exit 1; }
  done'
check "Arc agent installed, not connected" on 'azcmagent show | grep -Eq "^Agent Status +: +Disconnected"'
check "agent archive staged with its digest" on '. /opt/onek8s/aks-flex-node/release.env &&
  echo "$AKS_FLEX_NODE_ARCHIVE_SHA256  /opt/onek8s/aks-flex-node/aks-flex-node-linux-amd64.tar.gz" | sha256sum --check --status'
check "bootstrap.sh runs" on 'bash /opt/onek8s/aks-flex-node/bootstrap.sh --help | grep -q -- --fetch-bootstrap-data'
check "seed settings copied, mode 0600, no CR" on 'test "$(sudo stat -c %a /etc/onek8s/flex-node/bootstrap.env)" = 600 && ! sudo grep -q $(printf "\r") /etc/onek8s/flex-node/bootstrap.env'
check "seed credential copied, mode 0600" on 'test "$(sudo stat -c %a /etc/aks-flex-node/credentials/sp-client-certificate.pem)" = 600'
check "join stops on its settings (78, no retry)" on '
  test "$(systemctl show -p ExecMainStatus --value onek8s-flex-node-join)" = 78 &&
  test "$(systemctl show -p NRestarts --value onek8s-flex-node-join)" = 0 &&
  journalctl -b -u onek8s-flex-node-join | grep -q "AKS_FLEX_NODE_CLUSTER_RESOURCE_ID and AKS_FLEX_NODE_AGENT_POOL_NAME must be set"'
check "no agent installed" on '! test -e /etc/systemd/system/aks-flex-node-agent.service'

on 'sudo journalctl -b -u onek8s-flex-node-seed -u onek8s-flex-node-join --no-pager' >&2 || true
if ((failures)); then
  log "$failures check(s) failed"
  exit 1
fi
log "all checks passed"
