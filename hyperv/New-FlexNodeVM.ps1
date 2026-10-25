<#
.SYNOPSIS
Creates and starts a OneK8s flex node on Hyper-V.

.DESCRIPTION
A generation 2 VM with Secure Boot (Microsoft UEFI Certificate Authority template), static memory,
no automatic checkpoints, the guest service interface, COM1 on a named pipe for the serial console,
and two disks: a copy of the release's VHDX grown to -DiskSizeGB, and the seed - either the ISO
given as -SeedIso (seed/make-seed.sh) or a small FAT VHDX labelled CIDATA that this script writes
from -SshPublicKey, -Settings, -Credential and -NetworkConfig (cloud-init NoCloud reads both).

Run it as an administrator on a host with the Hyper-V PowerShell module.

.EXAMPLE
.\New-FlexNodeVM.ps1 -Name flex-hv-1 -Image .\aks-flex-node-v0.1.0-amd64.vhdx -SwitchName External `
  -SshPublicKey $HOME\.ssh\id_ed25519.pub -Settings .\bootstrap.env -Credential .\sp-client-certificate.pem
#>
[CmdletBinding()]
param(
    # The VM's and the Kubernetes node's name: a lowercase DNS label, unique in the cluster.
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')] [string] $Name,
    # The release's .vhdx (unzipped).
    [Parameter(Mandatory)] [string] $Image,
    [Parameter(Mandatory)] [string] $SwitchName,
    [string] $Path = (Get-VMHost).VirtualHardDiskPath,
    [int] $ProcessorCount = 4,
    [long] $MemoryGB = 8,
    [long] $DiskSizeGB = 64,
    # A seed ISO from seed/make-seed.sh; otherwise the seed is written from the parameters below.
    [string] $SeedIso,
    [string] $SshPublicKey,
    # aks-flex-node/bootstrap.env (seed/bootstrap.env.example).
    [string] $Settings,
    # Credential files named in the settings, copied to /etc/aks-flex-node/credentials/.
    [string[]] $Credential = @(),
    # Optional netplan v2 (seed/network-config.example).
    [string] $NetworkConfig
)
$ErrorActionPreference = 'Stop'

if (-not $SeedIso -and -not $SshPublicKey) { throw 'Give -SeedIso, or -SshPublicKey (with -Settings to join).' }
$dir = Join-Path $Path $Name
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$osDisk = Join-Path $dir "$Name.vhdx"
if (Test-Path $osDisk) { throw "$osDisk exists" }

Copy-Item -Path $Image -Destination $osDisk
Resize-VHD -Path $osDisk -SizeBytes ($DiskSizeGB * 1GB)

# Writes text with LF line ends and no byte order mark, as cloud-init and systemd read it.
function Write-UnixText([string] $File, [string] $Text) {
    [IO.File]::WriteAllText($File, ($Text -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}

if (-not $SeedIso) {
    $seedDisk = Join-Path $dir "$Name-seed.vhdx"
    New-VHD -Path $seedDisk -SizeBytes 64MB -Dynamic | Out-Null
    $disk = Mount-VHD -Path $seedDisk -Passthru | Get-Disk
    try {
        $disk | Initialize-Disk -PartitionStyle MBR
        $volume = $disk | New-Partition -UseMaximumSize -AssignDriveLetter |
            Format-Volume -FileSystem FAT -NewFileSystemLabel CIDATA -Confirm:$false
        $root = "$($volume.DriveLetter):\"
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
        Write-UnixText (Join-Path $root 'meta-data') "instance-id: $Name-$stamp`nlocal-hostname: $Name`n"
        $keys = Get-Content $SshPublicKey | Where-Object { $_.Trim() } | ForEach-Object { "  - $_" }
        Write-UnixText (Join-Path $root 'user-data') ("#cloud-config`nssh_authorized_keys:`n" + ($keys -join "`n") + "`n")
        if ($NetworkConfig) { Write-UnixText (Join-Path $root 'network-config') (Get-Content -Raw $NetworkConfig) }
        if ($Settings) {
            $flex = New-Item -ItemType Directory -Path (Join-Path $root 'aks-flex-node')
            Write-UnixText (Join-Path $flex 'bootstrap.env') (Get-Content -Raw $Settings)
            foreach ($file in $Credential) { Copy-Item -Path $file -Destination $flex }
        }
    } finally {
        Dismount-VHD -Path $seedDisk
    }
}

$vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) -VHDPath $osDisk `
    -SwitchName $SwitchName -Path $Path
# The kubelet sizes the node from its memory at start: no dynamic memory.
Set-VM -VM $vm -ProcessorCount $ProcessorCount -StaticMemory -AutomaticCheckpointsEnabled $false `
    -AutomaticStopAction ShutDown
# Ubuntu's shim is signed by Microsoft's third-party UEFI CA.
Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
Enable-VMIntegrationService -VM $vm -Name 'Guest Service Interface'
Set-VMComPort -VM $vm -Number 1 -Path "\\.\pipe\$Name-com1"
if ($SeedIso) {
    $seedCopy = Join-Path $dir "$Name-seed.iso"
    Copy-Item -Path $SeedIso -Destination $seedCopy
    Add-VMDvdDrive -VM $vm -Path $seedCopy
} else {
    Add-VMHardDiskDrive -VM $vm -Path $seedDisk
}
Start-VM -VM $vm
Write-Host "$Name started. Serial console: \\.\pipe\$Name-com1 (PuTTY, serial). Join: journalctl -u onek8s-flex-node-join"
Write-Host 'Remove the seed once the node has joined: it can hold a credential.'
