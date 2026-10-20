# ssh-bootstrap

One-shot SSH access setup for Windows and Linux machines, reachable from anywhere through a Tailscale tailnet. No router port forwarding, no public port exposure.

Two scripts, one per platform:

| File | Platform | What it does |
|---|---|---|
| `windows-remote-setup.ps1` | Windows 10 1809+ / 11 | Installs OpenSSH Server, sets PowerShell as the default shell, configures `sshd_config`, optional public key, firewall rule, Tailscale, and power settings that keep the machine reachable |
| `linux-remote-setup.sh` | CachyOS / Arch | Installs `tailscale` and `openssh`, enables `sshd` and `tailscaled`, allows SSH on `tailscale0` only, checks Tailscale login, prints the address to use |

Both scripts are idempotent: running them again is safe and does not duplicate configuration.

## Windows

Run from PowerShell. No git, no clone, no saved file.

```powershell
& ([scriptblock]::Create((iwr -UseBasicParsing https://raw.githubusercontent.com/kmanisk/ssh-bootstrap/main/windows-remote-setup.ps1).Content))
```

With a public key (password authentication is then disabled automatically):

```powershell
& ([scriptblock]::Create((iwr -UseBasicParsing https://raw.githubusercontent.com/kmanisk/ssh-bootstrap/main/windows-remote-setup.ps1).Content)) -PublicKey 'ssh-ed25519 AAAAC3Nza... user@linux'
```

Elevation behaves like this:

- Already elevated (`Administrator: Windows PowerShell`): the script runs directly, no second window.
- Normal prompt: the script relaunches itself through UAC.
- Loaded from memory with `iwr` (the form above): the elevated instance downloads the same URL again and runs there.

If you prefer a saved file (useful for the log path and for `-File`), the equivalent one-liner is:

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/kmanisk/ssh-bootstrap/main/windows-remote-setup.ps1 -OutFile $env:TEMP\win-setup.ps1; & $env:TEMP\win-setup.ps1
```

Older PowerShell 5.1 builds may negotiate an outdated TLS version. If the download fails, prefix the command with
`[Net.ServicePointManager]::SecurityProtocol='Tls12';`.

### Parameters

| Parameter | Description |
|---|---|
| `-PublicKey "<key line>"` | Installs the key in `C:\ProgramData\ssh\administrators_authorized_keys` with the required ACLs. Disables password auth unless `-AllowPasswordWithKey` is passed |
| `-AllowPasswordWithKey` | Keeps password authentication enabled even when a key is supplied |
| `-DisablePasswordAuth` | Public keys only |
| `-Port <n>` | SSH port, default 22. The firewall rule is updated to match |
| `-RestrictToTailnet` | Restricts inbound SSH to `100.64.0.0/10`. Blocks LAN access too; enable only after Tailscale is signed in |
| `-SkipTailscale` | Do not install or modify Tailscale |
| `-SkipPowerTweaks` | Do not change sleep and lid-close settings |

Log file: `C:\ProgramData\remote-access-setup.log`.

The script backs up `sshd_config` to `sshd_config.bak` on first run and edits directives without touching the `Match Group administrators` block.

## Linux

```bash
curl -fsSL https://raw.githubusercontent.com/kmanisk/ssh-bootstrap/main/linux-remote-setup.sh | sudo bash
```

With flags:

```bash
curl -fsSL https://raw.githubusercontent.com/kmanisk/ssh-bootstrap/main/linux-remote-setup.sh | sudo bash -s -- --allow-lan
```

Or as a saved file (the script then re-executes itself with `sudo`, so plain `bash linux-setup.sh` works too):

```bash
curl -fsSL https://raw.githubusercontent.com/kmanisk/ssh-bootstrap/main/linux-remote-setup.sh -o /tmp/linux-setup.sh && bash /tmp/linux-setup.sh
```

When the script is piped into `bash`, it cannot re-execute itself (there is no file path), so it must already run as root. That is why the one-liner uses `sudo bash`.

Flags:

| Flag | Description |
|---|---|
| `--allow-lan` | Also allows TCP/22 on all interfaces, not just `tailscale0` |
| `--tailscale-ssh` | Also enables Tailscale SSH (keyless, identity based) |

## After both scripts

1. Sign in to Tailscale on both machines with the same account. This is the only interactive step:
   - Windows: `& "C:\Program Files\Tailscale\tailscale.exe" up`
   - Linux: `sudo tailscale up`
2. Check addresses:

   ```bash
   tailscale status
   ```

3. Connect:
   - Linux to Windows: `ssh <windows-user>@<windows-tailscale-ip>`
   - Windows to Linux: `ssh <linux-user>@<linux-tailscale-ip>`
   - Files: `scp file.txt <windows-user>@<windows-tailscale-ip>:C:/Users/<user>/Desktop/`

## Security notes

- Tailscale traffic is end-to-end encrypted and only devices on the tailnet can reach the SSH port. Nothing is exposed to the public internet.
- Prefer public key authentication. Password authentication over an internet-reachable port is a brute-force target.
- `-RestrictToTailnet` and the default Linux setup allow SSH only on the Tailscale interface. Keep it that way unless LAN access is needed.
- Do not run `tailscale funnel` for SSH. It publishes the service to the public internet.
- The scripts contain no secrets. Keys are passed at runtime, never stored in this repository.

## Requirements

- Windows: Windows 10 1809 or newer, internet access for the optional feature and Tailscale install.
- Linux: CachyOS or another Arch-based distribution with `pacman`, `systemd`, and optionally `ufw` or `firewalld`.
