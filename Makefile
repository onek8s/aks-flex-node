VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
SHELL_SCRIPTS := image/build.sh image/customize.sh seed/make-seed.sh kvm/create-vm.sh test/smoke.sh \
	image/files/usr/local/libexec/onek8s/flex-node-seed image/files/usr/local/libexec/onek8s/flex-node-join

.PHONY: image smoke lint
image: ## dist/aks-flex-node-$(VERSION)-amd64.{qcow2,vhdx}
	sudo image/build.sh $(VERSION)

smoke: ## boots the qcow2 under QEMU and checks it
	test/smoke.sh dist/aks-flex-node-$(VERSION)-amd64.qcow2

lint: ## shellcheck, PowerShell parse
	shellcheck -x $(SHELL_SCRIPTS)
	pwsh -NoProfile -Command '$$e = $$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$(CURDIR)/hyperv/New-FlexNodeVM.ps1", [ref]$$null, [ref]$$e); if ($$e) { $$e; exit 1 }'
