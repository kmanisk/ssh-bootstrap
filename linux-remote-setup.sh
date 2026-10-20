#!/usr/bin/env bash
# linux-remote-setup.sh
#
# One-shot SSH access setup for a CachyOS / Arch Linux machine.
# Companion to windows-remote-setup.ps1.
#
# What it does:
#   1. Installs tailscale and openssh (idempotent)
#   2. Enables and starts sshd and tailscaled
#   3. Allows SSH only on the tailscale0 interface through ufw (or firewalld)
#   4. Signs in to Tailscale if needed
#   5. Prints the addresses to use from the other machine
#
# Usage:
#   ./linux-remote-setup.sh [--allow-lan] [--tailscale-ssh]
#
#   --allow-lan      also allow SSH on the local network (opens tcp/22)
#   --tailscale-ssh  enable Tailscale SSH (keyless, identity based) in addition to sshd
#
# Run as a normal user; the script re-executes itself with sudo.

set -euo pipefail

ALLOW_LAN=0
TAILSCALE_SSH=0

for arg in "$@"; do
    case "$arg" in
        --allow-lan)     ALLOW_LAN=1 ;;
        --tailscale-ssh) TAILSCALE_SSH=1 ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    [warn] %s\n' "$*" >&2; }

log "Checking the distribution"
if ! command -v pacman >/dev/null 2>&1; then
    echo "This script targets Arch-based systems (pacman not found)." >&2
    exit 1
fi
info "pacman found"

log "Installing tailscale and openssh"
pacman -S --needed --noconfirm tailscale openssh

log "Enabling services"
systemctl enable --now tailscaled
systemctl enable --now sshd
info "sshd:    $(systemctl is-active sshd)"
info "tailscaled: $(systemctl is-active tailscaled)"

log "Configuring the firewall"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow in on tailscale0 to any port 22 proto tcp >/dev/null
    info "ufw: tcp/22 allowed on tailscale0"
    if [ "$ALLOW_LAN" -eq 1 ]; then
        ufw allow 22/tcp >/dev/null
        info "ufw: tcp/22 allowed on all interfaces (--allow-lan)"
    fi
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null
    info "firewalld: tailscale0 added to the trusted zone"
    if [ "$ALLOW_LAN" -eq 1 ]; then
        firewall-cmd --permanent --add-service=ssh >/dev/null
        firewall-cmd --reload >/dev/null
        info "firewalld: ssh service allowed (--allow-lan)"
    fi
else
    warn "No active ufw/firewalld detected. If another firewall is running, allow tcp/22 on tailscale0."
fi

log "Checking Tailscale login"
TS_STATE="$(tailscale status --json 2>/dev/null | grep -oP '"BackendState":\s*"\K[^"]+' | head -1 || true)"
if [ "$TS_STATE" != "Running" ]; then
    info "Not signed in yet. A login URL will be printed below."
    if [ "$TAILSCALE_SSH" -eq 1 ]; then
        tailscale up --ssh
    else
        tailscale up
    fi
elif [ "$TAILSCALE_SSH" -eq 1 ]; then
    tailscale up --ssh
else
    info "Already signed in."
fi

log "Summary"
TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
info "hostname     : $(hostname)"
info "user         : $(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")"
if [ -n "$TS_IP" ]; then
    info "tailscale ip : $TS_IP"
else
    info "tailscale ip : not assigned yet"
fi
info "sshd         : $(systemctl is-enabled sshd) / $(systemctl is-active sshd)"
printf '\n'
printf 'From the other machine:\n'
if [ -n "$TS_IP" ]; then
    printf '  ssh %s@%s\n' "$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")" "$TS_IP"
else
    printf '  ssh %s@<tailscale-ip>\n' "$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")"
fi
printf '\n'
