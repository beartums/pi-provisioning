# Pi Provisioning

Scripts for setting up and configuring Raspberry Pis from scratch.

Two separate workflows live here:

| Workflow | Purpose |
|----------|---------|
| [Standard Pi setup](#standard-pi-setup) | Docker + NAS mount on any Pi |
| [PiMox (Proxmox VE)](#pimox-proxmox-ve-on-arm64) | Full Proxmox hypervisor on ARM64 |

---

## Standard Pi Setup

Installs Docker + Docker Compose and mounts a NAS share (CIFS) at `/mnt/grifData`.

### Option A — Run directly on the Pi

```bash
sudo ./pi-setup.sh --nas-host 192.168.1.10
```

### Option B — Bake into the SD card before first boot

Flash with Raspberry Pi Imager, then run one of the inject scripts from your machine
before ejecting the card. On first boot the Pi configures itself automatically.

**macOS / Linux / WSL:**
```bash
./inject-firstrun.sh /Volumes/bootfs --nas-host 192.168.1.10

# Linux
./inject-firstrun.sh /media/$USER/bootfs --nas-host 192.168.1.10

# WSL (SD card is drive E: in Windows → /mnt/e in WSL)
./inject-firstrun.sh /mnt/e --nas-host 192.168.1.10
```

**Windows (PowerShell):**
```powershell
.\inject-firstrun.ps1 -BootDrive E: -NasHost 192.168.1.10
```

---

### `pi-setup.sh` — options

| Flag | Description | Default |
|------|-------------|---------|
| `--nas-host HOST` | NAS hostname or IP **(required)** | — |
| `--nas-share NAME` | Share name on the NAS | `grifData` |
| `--nas-creds FILE` | Path to existing CIFS credentials file | — |
| `--nas-user USER` | CIFS username (written to `/etc/cifs-credentials`) | prompt |
| `--nas-password PASS` | CIFS password | prompt |
| `--nas-domain DOM` | CIFS domain (AD environments) | — |
| `--mount-point PATH` | Local mount point | `/mnt/grifData` |
| `--docker-user USER` | User to add to the `docker` group | `beartums` |
| `--skip-nas` | Skip NAS setup | — |
| `--skip-docker` | Skip Docker setup | — |
| `-y`, `--yes` | Auto-approve all prompts | — |

### `inject-firstrun.sh` — options

| Flag | Description | Default |
|------|-------------|---------|
| `<boot-path>` | Path to mounted boot partition **(required, positional)** | — |
| `--nas-host HOST` | NAS hostname or IP | — |
| `--nas-share NAME` | Share name | `grifData` |
| `--nas-user USER` | CIFS username | prompt |
| `--nas-password PASS` | CIFS password | prompt |
| `--nas-creds FILE` | Path to credentials file (contents embedded) | — |
| `--docker-user USER` | User to add to docker group | `beartums` |
| `--skip-nas` | Skip NAS setup | — |
| `--skip-docker` | Skip Docker setup | — |
| `--legacy-boot` | Use `/boot` instead of `/boot/firmware` (Bullseye and older) | — |

### `inject-firstrun.ps1` — options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-BootDrive` | Drive letter of boot partition e.g. `E:` **(required)** | — |
| `-NasHost` | NAS hostname or IP | — |
| `-NasShare` | Share name | `grifData` |
| `-NasUser` | CIFS username | prompt |
| `-NasPassword` | CIFS password | prompt |
| `-NasCreds` | Path to credentials file (contents embedded) | — |
| `-DockerUser` | User to add to docker group | `beartums` |
| `-SkipNas` | Skip NAS setup | — |
| `-SkipDocker` | Skip Docker setup | — |
| `-LegacyBoot` | Use `/boot` instead of `/boot/firmware` (Bullseye) | — |

### How the injection works

Both inject scripts write `pi-setup-firstrun.sh` to the FAT32 boot partition and append
`systemd.run=.../pi-setup-firstrun.sh` to `cmdline.txt` — the official RPi first-boot mechanism.

Credentials are staged as a separate `cifs-credentials` file on the partition (not embedded
in the script) and moved to `/etc/cifs-credentials` (chmod 600) on first boot.

On first boot the Pi:
1. Waits for apt lock, runs `apt-get update`
2. Installs `cifs-utils`, moves credentials to `/etc/`, mounts the NAS
3. Installs Docker via `get.docker.com`, adds the user to the `docker` group
4. **Self-removes**: strips `systemd.run` from `cmdline.txt` and deletes the script — never runs again
5. Logs everything to `/var/log/pi-setup-firstrun.log`

> **Security note:** Credentials sit in cleartext on the FAT32 partition from flash time until
> first boot completes. Fine for a home network; keep the card secure until booted.

---

## PiMox (Proxmox VE on ARM64)

Full Proxmox VE installation on a Raspberry Pi 4/5. Two-phase setup: Phase 1 runs
interactively, Phase 2 installs Proxmox automatically on first reboot.

See **[pimox-setup-README.md](pimox-setup-README.md)** for full details.

### Quick start

```bash
sudo ./pimox-setup.sh --hostname pimox01 --ip 192.168.1.50 --gateway 192.168.1.1
```

### `pimox-setup.sh` — options

| Flag | Description | Default |
|------|-------------|---------|
| `--hostname NAME` | Hostname to assign **(required)** | — |
| `--ip ADDR` | Static IP address | Auto-detect |
| `--gateway ADDR` | Default gateway | Auto-detect |
| `--netmask MASK` | CIDR prefix length (e.g. `24`) | Auto-detect |
| `--dns ADDR` | DNS server | Auto-detect from `/etc/resolv.conf` |
| `--iface NAME` | Network interface to bridge | Auto-detect |
| `--root-password PWD` | Root password | Prompt interactively |
| `--skip-upgrade` | Skip `apt update/upgrade` | — |
| `-y`, `--yes` | Auto-approve all prompts | — |

After Phase 2 completes, access the Proxmox web UI at `https://<ip>:8006`.

Monitor Phase 2 progress on the Pi:
```bash
tail -f /var/log/pimox-install.log
journalctl -u pimox-install.service -f
```
