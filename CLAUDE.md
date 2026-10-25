# OneK8s flex node image - notes for Claude sessions

The shared working notes for all OneK8s repos are in `onek8s/aks-terraform/CLAUDE.md`. Read that first.

This repo builds a host image for Flex Nodes for AKS (preview; Microsoft's agent
https://github.com/Azure/AKSFlexNode) that boots on Hyper-V (generation 2, Secure Boot with the Microsoft UEFI CA
template) and KVM from one disk: `image/build.sh` customizes the Ubuntu 24.04 cloud image once with virt-customize
(`image/customize.sh`, files in `image/files/`) and converts it to qcow2 and VHDX. README.md is the user's guide;
keep it current.

- **Every input is pinned with its digest in `versions.env`** (Ubuntu serial, AKSFlexNode release archive and its
  `bootstrap.sh` - the release publishes no digest for the script, ours is that of the file at the tag -, azcmagent).
  A new agent version: its `checksums.txt` and `sha256sum` of `scripts/bootstrap.sh` at the tag.
- **AKSFlexNode v0.2.0 installs under `/usr/local`**; its `main` (unreleased) moves to `/opt/unbounded/agent` and
  ships an Ignition template. Read the docs at the pinned tag, not `main`, when the two differ.
- **The join** (`onek8s-flex-node-seed` then `onek8s-flex-node-join`): settings and credentials come from the seed
  volume's `aks-flex-node/` (never through cloud-init's caches), the staged agent is installed with `file://` and its
  digest, exit 78 = a setting that cannot work (not retried), anything else retried. The image joins once
  (`/var/lib/onek8s/flex-node/joined`); a reset node is reimaged.
- **Tests**: `make lint` (shellcheck, PowerShell parse) and `make smoke` (boots the qcow2 under QEMU with OVMF Secure
  Boot and Microsoft's keys, checks over SSH). CI builds and boots every PR on GitHub's runners (KVM). A Claude
  session's sandbox has no KVM and its egress proxy is not reachable from libguestfs's appliance: the build runs in CI,
  not locally.
- **Releases** are tags `vMAJOR.MINOR.PATCH` of this repo (`release.yml`), so aks-terraform's Design tags workflow
  leaves this repo out, as azure-lab-fw.
- **Not in the design**: no requirement of the design names nodes outside Azure, and the cells' Azure CNI Pod
  Subnet with Cilium does not extend to flex nodes (a flex pool can join an existing cluster, but needs its own
  CNI; Microsoft's path is `--network-plugin none` + Unbounded-Net) and a cluster with a flex pool cannot be
  stopped. The user tests the image in a separate cluster by hand. Adding flex nodes to
  the design starts with a requirement a human adds to onek8s.github.io `requirements/0.2`.
