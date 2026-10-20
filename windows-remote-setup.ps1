<#
.SYNOPSIS
    One-shot remote access setup for a fresh Windows machine.

.DESCRIPTION
    Installs and configures:
      - OpenSSH Server (Windows optional feature) with automatic start
      - PowerShell as the default SSH shell
      - Optional public key authentication (administrators_authorized_keys + ACLs)
      - Tailscale (winget, falling back to the official MSI)
      - Optional firewall scoping to the tailnet only
      - Power settings that keep the machine reachable (no sleep, lid action = do nothing)

    Safe to run multiple times. The script is idempotent.

.PARAMETER PublicKey
    Public key line to install for the administrators group, for example:
    "ssh-ed25519 AAAAC3... user@host". When a valid key is supplied, password
    auth is disabled unless -AllowPasswordWithKey is also passed.

.PARAMETER Port
    SSH port. Default 22.

.PARAMETER DisablePasswordAuth
    Disable password authentication (public keys only).

.PARAMETER AllowPasswordWithKey
    Keep password authentication enabled even when -PublicKey is supplied.

.PARAMETER RestrictToTailnet
    Scope the inbound SSH firewall rule to 100.64.0.0/10 (Tailscale CGNAT range).
    WARNING: this blocks SSH from the local LAN as well.

.PARAMETER SkipTailscale
    Do not install or touch Tailscale.

.PARAMETER SkipPowerTweaks
    Do not change sleep and lid-close settings.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-remote-setup.ps1 -PublicKey "ssh-ed25519 AAAA... me@linux"

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-remote-setup.ps1 -RestrictToTailnet
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$PublicKey = '',
    [int]$Port = 22,
    [switch]$DisablePasswordAuth,
    [switch]$AllowPasswordWithKey,
    [switch]$RestrictToTailnet,
    [switch]$SkipTailscale,
    [switch]$SkipPowerTweaks
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$LogPath     = Join-Path $env:ProgramData 'remote-access-setup.log'
$SshdConfig  = Join-Path $env:ProgramData 'ssh\sshd_config'
$AdminKeys   = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message"
}

function Write-Warn {
    param([string]$Message)
    $script:Warnings.Add($Message)
    Write-Host "    [warn] $Message" -ForegroundColor Yellow
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
if (-not (Test-Administrator)) {
    Write-Host 'Requesting administrator privileges...' -ForegroundColor Yellow
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Host 'Run this script from an elevated PowerShell (self-elevation needs -File).' -ForegroundColor Red
        exit 1
    }
    $elevationArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $elevationArgs += "-$key" }
        }
        else {
            $elevationArgs += "-$key"
            $elevationArgs += ('"{0}"' -f $value)
        }
    }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($elevationArgs -join ' ') | Out-Null
    exit
}

try { Start-Transcript -Path $LogPath -Append | Out-Null } catch { }

Write-Host 'Windows remote access setup' -ForegroundColor Green
Write-Info ("Computer : {0}" -f $env:COMPUTERNAME)
Write-Info ("User     : {0}" -f $env:USERNAME)
Write-Info ("Build    : {0}" -f [Environment]::OSVersion.Version)
Write-Info ("Log      : {0}" -f $LogPath)

# ---------------------------------------------------------------------------
# Windows version sanity
# ---------------------------------------------------------------------------
if ([Environment]::OSVersion.Version.Build -lt 17763) {
    Write-Host 'Windows 10 1809 or newer is required for the OpenSSH.Server capability.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# OpenSSH Server
# ---------------------------------------------------------------------------
Write-Step 'Installing OpenSSH Server'
$capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if (-not $capability) {
    Write-Host 'OpenSSH.Server capability not found on this image.' -ForegroundColor Red
    exit 1
}

if ($capability.State -ne 'Installed') {
    Write-Info ("Installing {0} (needs internet / Windows Update)..." -f $capability.Name)
    try {
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
    }
    catch {
        Write-Warn ("Capability install failed: {0}" -f $_.Exception.Message)
    }
}
else {
    Write-Info 'Already installed.'
}

$capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($capability.State -ne 'Installed') {
    Write-Host 'OpenSSH Server is still not installed. Aborting.' -ForegroundColor Red
    Write-Host 'Manual fallback: Settings > System > Optional features > OpenSSH Server.' -ForegroundColor Yellow
    exit 1
}

Write-Step 'Configuring the sshd service'
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd
Set-Service -Name ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name ssh-agent -ErrorAction SilentlyContinue
Write-Info ("sshd: {0} / {1}" -f (Get-Service sshd).Status, (Get-Service sshd).StartType)

# ---------------------------------------------------------------------------
# Default shell
# ---------------------------------------------------------------------------
Write-Step 'Setting the default SSH shell'
$shellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$pwshPath  = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (Test-Path -LiteralPath $pwshPath) { $shellPath = $pwshPath }

if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) {
    New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -Value $shellPath -PropertyType String -Force | Out-Null
Write-Info ("DefaultShell = {0}" -f $shellPath)

# ---------------------------------------------------------------------------
# sshd_config
# ---------------------------------------------------------------------------
function Set-SshdOption {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $lines = @(Get-Content -LiteralPath $Path)
    $pattern = '^\s*#?\s*' + [regex]::Escape($Key) + '\s+.*$'
    $replaced = $false
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if (-not $replaced -and $line -match $pattern) {
            $result.Add(("{0} {1}" -f $Key, $Value))
            $replaced = $true
        }
        else {
            $result.Add($line)
        }
    }
    if (-not $replaced) { $result.Insert(0, ("{0} {1}" -f $Key, $Value)) }
    Set-Content -LiteralPath $Path -Value $result -Encoding ASCII
}

Write-Step 'Tuning sshd_config'
if (-not (Test-Path -LiteralPath $SshdConfig)) {
    Write-Host ("Missing {0}" -f $SshdConfig) -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath ($SshdConfig + '.bak'))) {
    Copy-Item -LiteralPath $SshdConfig -Destination ($SshdConfig + '.bak') -Force
    Write-Info 'Baseline backup written to sshd_config.bak'
}

$keyValid = $false
if ($PublicKey) {
    if ($PublicKey.Trim() -match '^(ssh-|ecdsa-)') {
        $keyValid = $true
    }
    else {
        Write-Warn 'The supplied key does not look like an OpenSSH public key; ignoring it.'
    }
}

$passwordAuth = 'yes'
if ($DisablePasswordAuth) { $passwordAuth = 'no' }
if ($keyValid -and -not $AllowPasswordWithKey) {
    $passwordAuth = 'no'
    Write-Info 'Valid public key supplied: password authentication will be disabled.'
}

Set-SshdOption -Path $SshdConfig -Key 'Port'                  -Value "$Port"
Set-SshdOption -Path $SshdConfig -Key 'PasswordAuthentication' -Value $passwordAuth
Set-SshdOption -Path $SshdConfig -Key 'PubkeyAuthentication'   -Value 'yes'
Set-SshdOption -Path $SshdConfig -Key 'MaxAuthTries'           -Value '3'
Set-SshdOption -Path $SshdConfig -Key 'LoginGraceTime'         -Value '30'
Write-Info ("Port={0} PasswordAuthentication={1}" -f $Port, $passwordAuth)

# ---------------------------------------------------------------------------
# Public key
# ---------------------------------------------------------------------------
if ($keyValid) {
    Write-Step 'Installing the public key for administrators'
    $keyLine = $PublicKey.Trim()
    $sshDir = Split-Path -Parent $AdminKeys
    if (-not (Test-Path -LiteralPath $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
    $existing = @()
    if (Test-Path -LiteralPath $AdminKeys) {
        $existing = @(Get-Content -LiteralPath $AdminKeys)
    }
    if ($existing -contains $keyLine) {
        Write-Info 'Key already present.'
    }
    else {
        Add-Content -LiteralPath $AdminKeys -Value $keyLine -Encoding ASCII
        Write-Info 'Key appended to administrators_authorized_keys.'
    }
    & icacls.exe $AdminKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
    Write-Info 'ACLs restricted to Administrators and SYSTEM.'
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
Write-Step "Configuring the firewall rule for port $Port"
$rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $Port -Profile Any | Out-Null
    $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
    Write-Info 'Rule created.'
}
else {
    $rule | Set-NetFirewallRule -Enabled True -Action Allow -Profile Any
    Write-Info 'Rule enabled.'
}
$rule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -LocalPort $Port

if ($RestrictToTailnet) {
    $rule | Set-NetFirewallRule -RemoteAddress '100.64.0.0/10'
    Write-Info 'Inbound SSH restricted to 100.64.0.0/10 (Tailscale only).'
}
else {
    Write-Info 'Inbound SSH allowed on all profiles (LAN included). Use -RestrictToTailnet to lock it down.'
}

# ---------------------------------------------------------------------------
# Tailscale
# ---------------------------------------------------------------------------
$tailscaleExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'

if ($SkipTailscale) {
    Write-Step 'Skipping Tailscale (-SkipTailscale)'
}
else {
    Write-Step 'Installing Tailscale'
    if (Test-Path -LiteralPath $tailscaleExe) {
        Write-Info 'Already installed.'
    }
    else {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Info 'Installing via winget...'
            try {
                & winget.exe install --id Tailscale.Tailscale -e --silent `
                    --accept-package-agreements --accept-source-agreements | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warn ("winget exited with code {0}" -f $LASTEXITCODE)
                }
            }
            catch {
                Write-Warn ("winget failed: {0}" -f $_.Exception.Message)
            }
        }
        if (-not (Test-Path -LiteralPath $tailscaleExe)) {
            Write-Info 'Falling back to the official MSI...'
            $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
            try {
                Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' `
                    -OutFile $msi -UseBasicParsing
                $msiProc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
                if ($msiProc.ExitCode -ne 0) {
                    Write-Warn ("msiexec exited with code {0}" -f $msiProc.ExitCode)
                }
            }
            catch {
                Write-Warn ("MSI install failed: {0}" -f $_.Exception.Message)
            }
        }
    }

    if (Test-Path -LiteralPath $tailscaleExe) {
        Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name Tailscale -ErrorAction SilentlyContinue
        Write-Info ("Tailscale service: {0}" -f (Get-Service Tailscale -ErrorAction SilentlyContinue).Status)
    }
    else {
        Write-Warn 'Tailscale is not installed. Install it manually, then run: tailscale up'
    }
}

# ---------------------------------------------------------------------------
# Power settings
# ---------------------------------------------------------------------------
if ($SkipPowerTweaks) {
    Write-Step 'Skipping power tweaks (-SkipPowerTweaks)'
}
else {
    Write-Step 'Keeping the machine reachable while plugged in'
    & powercfg.exe /change standby-timeout-ac 0 | Out-Null
    & powercfg.exe /change hibernate-timeout-ac 0 | Out-Null
    # Lid close: 0 = do nothing (AC and DC)
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    Write-Info 'Sleep on AC disabled, lid close = do nothing.'
    Write-Info 'Hibernate is left available. Run "powercfg /h off" if you want fast startup disabled too.'
}

# ---------------------------------------------------------------------------
# Restart and verify
# ---------------------------------------------------------------------------
Write-Step 'Restarting sshd'
Restart-Service -Name sshd -Force
Start-Sleep -Seconds 2

$svc = Get-Service sshd
Write-Info ("sshd: {0} / {1}" -f $svc.Status, $svc.StartType)

$listen = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if ($listen) { Write-Info ("Listening on TCP {0}" -f $Port) }
else { Write-Warn ("Nothing is listening on TCP {0}" -f $Port) }

$tsIp = $null
if (-not $SkipTailscale -and (Test-Path -LiteralPath $tailscaleExe)) {
    try { $tsIp = (& $tailscaleExe ip -4 2>$null | Select-Object -First 1) } catch { }
}

Write-Host ''
Write-Host '------------------------------------------------------------' -ForegroundColor Green
Write-Host ' Done.' -ForegroundColor Green
Write-Host '------------------------------------------------------------' -ForegroundColor Green
Write-Info ("Windows user : {0}" -f $env:USERNAME)
if ($tsIp) {
    Write-Info ("Tailscale IP : {0}" -f $tsIp)
}
else {
    Write-Info 'Tailscale IP : not assigned yet (login required)'
}
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
if (-not $SkipTailscale) {
    Write-Host '  1. Sign in to Tailscale (one time, opens a browser):'
    Write-Host ('     "{0}" up' -f $tailscaleExe)
    Write-Host '  2. Then from Linux:'
    Write-Host ('     ssh {0}@{1}' -f $env:USERNAME, '<tailscale-ip-or-magicdns-name>')
}
if ($passwordAuth -eq 'yes') {
    Write-Host '  3. Password auth is enabled. Prefer keys: rerun with -PublicKey "ssh-ed25519 AAAA..."'
}
Write-Host ''
if ($script:Warnings.Count -gt 0) {
    Write-Host 'Warnings:' -ForegroundColor Yellow
    foreach ($w in $script:Warnings) { Write-Host "  - $w" -ForegroundColor Yellow }
}

try { Stop-Transcript | Out-Null } catch { }

if ($svc.Status -eq 'Running') { exit 0 } else { exit 1 }
