# aks-flex-node

A node image for [Flex Nodes for AKS](https://learn.microsoft.com/en-us/azure/aks/flex-nodes-for-aks-overview)
(preview): a virtual machine on **Hyper-V** or **KVM** that joins an AKS cluster's flex node pool at
its first boot. One build makes one disk and converts it twice, so both hypervisors run the same
bytes:

| Release asset | For |
|---|---|
| `aks-flex-node-<version>-amd64.vhdx.zip` | Hyper-V, generation 2 (UEFI, Secure Boot) |
| `aks-flex-node-<version>-amd64.qcow2` | KVM (libvirt, Proxmox, plain QEMU) |
| `aks-flex-node-<version>-amd64.packages` | every package of the image and its version |
| `SHA256SUMS` | digests of the above |

Flex Nodes is a preview (no SLA). The agent that joins the node is Microsoft's open-source
[AKSFlexNode](https://github.com/Azure/AKSFlexNode): it runs the kubelet and containerd in a
systemd-nspawn machine on the host and keeps it as the pool's Machine resource asks. This image is
the host around it.

## What the image holds

- **Ubuntu 24.04 LTS** server cloud image, the OS AKSFlexNode validates, updated when it is built,
  root file system grown to 32 GiB (the agent wants 8 GiB free under `/var/lib`). No snapd.
- **What the agent needs on the host**: bash, curl, tar, jq, nftables, systemd-container, util-linux,
  iptables.
- **The agent, staged**: the release archive and `bootstrap.sh` of the AKSFlexNode version in
  [`versions.env`](versions.env), with their digests, in `/opt/onek8s/aks-flex-node/`. A node
  installs the agent from there; it downloads only what the pool's bootstrap data names (the worker's
  root file system and Kubernetes components).
- **Both hypervisors**: the Hyper-V (`hv_vmbus`, `hv_storvsc`, `hv_netvsc`, `hv_utils`) and virtio
  drivers in the initramfs; Hyper-V's KVP, VSS and file copy daemons (start only on Hyper-V); the QEMU
  guest agent (starts only when the VM has its virtio channel).
- **Azure Arc**: the Connected Machine agent (`azcmagent`), installed and not connected.
- **The first-boot join**: `onek8s-flex-node-seed.service` and `onek8s-flex-node-join.service`
  (below). cloud-init reads only a NoCloud seed or a config drive.
- No identity of its own: machine ID, SSH host keys and cloud-init state are made at the first boot.
  No password: SSH keys only, for the `ubuntu` user.

Every input is pinned with its digest in [`versions.env`](versions.env); change a version together
with its digest.

## Before the first node: the cluster

The cluster side is Microsoft's procedure (AKSFlexNode's
[operator guide](https://github.com/Azure/AKSFlexNode/blob/main/docs/usage/getting-started.md),
Microsoft Learn's [prepare the cluster](https://learn.microsoft.com/en-us/azure/aks/prepare-aks-cluster-for-flex-nodes)):

1. Register `Microsoft.ContainerService/AKSFlexNodePreview` and `PutMachinePreview`; `aks-preview`
   22.0.0b8 or later; an AKS release `v20260904` or later in the cluster's region.
2. A cluster **without a network plugin** (`az aks create ... --network-plugin none`) and
   [Unbounded-Net](https://github.com/Azure/unbounded) for pod networking on both sides: the AKS
   CNIs do not run on flex nodes in the preview.
3. A flex pool: `az aks nodepool add ... --vm-set-type FlexNodes --mode User`.
4. Private layer 3 routing both ways between the AKS node network and the flex nodes' network (VPN,
   ExpressRoute, peering), with node, pod and service ranges that do not overlap; the API server
   calls back to each kubelet.
5. An identity per host with **Azure Kubernetes Service Flex Node Agent Role**
   (`8f139b0f-7eaf-460b-a9da-5b1246d9ed0d`) on the pool (`.../managedClusters/<c>/agentPools/<pool>`):
   - a **service principal** with a certificate, for a Hyper-V or KVM host without Arc:
     `az ad sp create-for-rbac --name <name> --create-cert` gives a PEM with the private key;
   - or **Azure Arc**, Microsoft's recommendation outside Azure: the host connects at its first boot
     (an onboarding service principal with *Azure Connected Machine Onboarding*), then the Arc
     machine's identity gets the role.

A node reaches the AKS API server, `management.azure.com`, `login.microsoftonline.com` and what the
pool's bootstrap data names (the worker's root file system and Kubernetes components from Microsoft's
registries), with Arc also the [Arc endpoints](https://learn.microsoft.com/en-us/azure/azure-arc/servers/network-requirements).

## A node's seed

A node gets its name, SSH key and join settings from its seed volume, cloud-init's NoCloud volume
(label `cidata`):

| File | |
|---|---|
| `meta-data` | `instance-id` and `local-hostname`: the Kubernetes node name, unique, lowercase |
| `user-data` | the SSH public key of `ubuntu` |
| `network-config` | optional, netplan v2 for a static address ([example](seed/network-config.example)); DHCP without it |
| `aks-flex-node/bootstrap.env` | the join settings ([example](seed/bootstrap.env.example)): cluster resource ID, pool, identity |
| `aks-flex-node/<file>` | a credential named in the settings, e.g. `sp-client-certificate.pem` |

The settings are [AKSFlexNode `bootstrap.sh`](https://github.com/Azure/AKSFlexNode/blob/main/scripts/bootstrap.sh)'s
`AKS_FLEX_NODE_*` variables, plus `ONEK8S_ARC_*` to connect the host to Arc first. The settings and
credentials are copied straight from the volume (`/etc/onek8s/flex-node/`,
`/etc/aks-flex-node/credentials/`, mode 0600), never through cloud-init's caches. **Remove the seed
once the node has joined**: it may hold a credential.

[`seed/make-seed.sh`](seed/make-seed.sh) makes the ISO on Linux; on Hyper-V
[`New-FlexNodeVM.ps1`](hyperv/New-FlexNodeVM.ps1) writes the same files to a small FAT VHDX
(label `CIDATA`) and needs no ISO tool.

```bash
cp seed/bootstrap.env.example bootstrap.env   # fill in the cluster, pool and identity
seed/make-seed.sh -n flex-kvm-1 -k ~/.ssh/id_ed25519.pub -o flex-kvm-1-seed.iso \
  -s bootstrap.env -c sp-client-certificate.pem
```

## Hyper-V

Windows Server 2019 or later, or Windows 10/11 with Hyper-V, in an elevated PowerShell:

```powershell
Expand-Archive aks-flex-node-<version>-amd64.vhdx.zip -DestinationPath .
.\hyperv\New-FlexNodeVM.ps1 -Name flex-hv-1 -Image .\aks-flex-node-<version>-amd64.vhdx `
  -SwitchName <virtual switch> -SshPublicKey $HOME\.ssh\id_ed25519.pub `
  -Settings .\bootstrap.env -Credential .\sp-client-certificate.pem
```

The script creates a generation 2 VM: Secure Boot with the **Microsoft UEFI Certificate Authority**
template (Ubuntu's shim; the default *Microsoft Windows* template does not boot Linux), 4 vCPUs,
8 GiB **static** memory (the kubelet sizes the node from its memory at start), the OS disk grown to
64 GiB, no automatic checkpoints, the guest service interface, COM1 on `\\.\pipe\<name>-com1`, and
the seed disk. `-SeedIso` attaches an ISO from `make-seed.sh` as a DVD instead. To do it by hand:
those settings, the VHDX as the first disk, and the seed as a second disk or DVD.

The virtual switch must reach the AKS node network (layer 3, both ways). Once joined, remove the
seed: `Get-VMHardDiskDrive -VMName flex-hv-1 | Where-Object Path -like '*-seed.vhdx' | Remove-VMHardDiskDrive`.

## KVM

With libvirt (`virt-install` 4 or later, OVMF with Secure Boot):

```bash
kvm/create-vm.sh -n flex-kvm-1 -i aks-flex-node-<version>-amd64.qcow2 -s flex-kvm-1-seed.iso \
  -w bridge=br0
```

[`kvm/create-vm.sh`](kvm/create-vm.sh) copies the qcow2 into the pool and grows it to 64 GiB, then
creates a q35 VM with UEFI Secure Boot, `host-passthrough` CPU, 4 vCPUs and 8 GiB, a virtio disk
and NIC, the seed as a CD-ROM, the QEMU guest agent's channel and a serial console
(`virsh console flex-kvm-1`). Once joined: `virsh change-media flex-kvm-1 sda --eject`.

Plain QEMU works the same way (see [`test/smoke.sh`](test/smoke.sh)); on Proxmox import the qcow2
(`qm importdisk`), use OVMF with pre-enrolled keys and add the seed ISO as a CD-ROM (Proxmox's own
cloud-init drive works for `user-data`/`meta-data`, but cannot carry `aks-flex-node/`: write the
settings with `write_files` to `/etc/onek8s/flex-node/bootstrap.env` instead).

## The first boot

1. cloud-init sets the hostname, the SSH key and the network from the seed.
2. `onek8s-flex-node-seed` copies `aks-flex-node/` from the seed volume. Without it the node only
   boots: nothing joins.
3. `onek8s-flex-node-join` checks the hostname and settings, connects to Arc when asked, and runs the
   staged `bootstrap.sh`: fresh bootstrap data from the pool (its token lives an hour), the agent
   from `/opt/onek8s/aks-flex-node`, preflight, the Machine resource, the nspawn worker, and
   `aks-flex-node-agent.service`. A setting that cannot work stops it (exit 78); anything else is
   retried with a delay growing to 5 minutes, for up to 30 minutes an attempt - an Arc identity
   without its role yet, the network not up.
4. Joined: `/var/lib/onek8s/flex-node/joined`, the settings are deleted; the agent keeps its
   configuration and credential under `/etc/aks-flex-node`.

```bash
journalctl -u onek8s-flex-node-join          # the join
journalctl -u aks-flex-node-agent             # the agent
kubectl get nodes -o wide                     # from the admin side
az aks machine list -g <rg> --cluster-name <cluster> --nodepool-name <pool> -o table
```

## Lifecycle

- **Remove a node**: `kubectl drain`, then on the host `aks-flex-node reset`, then delete the Node
  and the Machine ([Microsoft's steps](https://learn.microsoft.com/en-us/azure/aks/manage-and-remove-flex-nodes)).
- **Rejoin**: reimage - a new VM from the image and a fresh seed. The image joins once; a reset host
  does not join again on its own.
- **Agent upgrades** come from the pool (AgentUpgrade); a new image only changes what a new node
  starts with.
- **OS updates**: Ubuntu's unattended security upgrades stay on and never reboot. Kernel updates need
  a reboot: cordon and drain first. Or replace nodes with a newer image.

## Build

```bash
sudo apt-get install libguestfs-tools qemu-utils qemu-system-x86 ovmf genisoimage
make image     # sudo image/build.sh -> dist/
make smoke     # boots the qcow2 under QEMU with Secure Boot and checks it
make lint      # shellcheck, PowerShell parse
```

[`image/build.sh`](image/build.sh) downloads the pinned inputs into `.cache/` (checked by digest),
grows the cloud image, runs [`image/customize.sh`](image/customize.sh) in it with virt-customize,
and converts the disk to a compressed qcow2 and a dynamic VHDX. [`test/smoke.sh`](test/smoke.sh)
checks what needs no cluster: Secure Boot, cloud-init, hostname, disk, packages, both hypervisors'
drivers and agents, the staged agent, and the join up to its settings check.

CI (`ci.yml`) lints, builds and boots every pull request; `release.yml` does the same for a tag
`vMAJOR.MINOR.PATCH` and publishes the release. Hyper-V itself is not in CI: the VHDX is the same
disk, and the Hyper-V drivers and daemons are checked in it.

## Limits

- amd64 only for now (Flex Nodes also takes arm64).
- Not yet joined to a cluster from this repository: the OneK8s cells run Azure CNI Pod Subnet with
  Cilium, and a flex pool needs a cluster without a network plugin and Unbounded-Net.
- No offline bootstrap: the worker's root file system and components are downloaded at the join.
