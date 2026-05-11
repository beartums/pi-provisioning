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
Three ways to provision, in order of convenience:

### Option A — Download, flash, and configure in one command *(recommended)*

Downloads the OS image, flashes the SD card, configures user/SSH/timezone, and injects
the NAS + Docker firstrun — all from your Mac or Linux machine. No Raspberry Pi Imager needed.

```bash
# Interactive — choose distro from a menu, prompts for anything not specified
./download-and-flash.sh --nas-host 192.168.1.10

# Fully scripted
./download-and-flash.sh \
  --distro rpios-lite-64 \
  --device /dev/disk4 \
  --pi-user beartums --pi-password secret \
  --timezone America/New_York \
  --nas-host 192.168.1.10 --nas-user eric --nas-password secret
```

**Available distros** (pass key to `--distro`, or pick from the interactive menu):

| Key | Description | Size |
|-----|-------------|------|
| `rpios-lite-64` | Raspberry Pi OS Lite 64-bit **(default)** | ~500 MB |
| `rpios-desktop-64` | Raspberry Pi OS Desktop 64-bit | ~1.2 GB |
| `rpios-lite-32` | Raspberry Pi OS Lite 32-bit | ~500 MB |
| `rpios-desktop-32` | Raspberry Pi OS Desktop 32-bit | ~1.1 GB |
| `ubuntu-2404` | Ubuntu Server 24.04 LTS 64-bit | ~1.1 GB |
| `ubuntu-2204` | Ubuntu Server 22.04 LTS 64-bit | ~700 MB |

Images are cached in `~/.pi-images/` and reused if less than 7 days old.

**Configuration applied at flash time:**
- RPi OS: `userconf.txt` (user + hashed password), empty `ssh` file (enables sshd)
- Ubuntu: `user-data` cloud-init (user, SSH, timezone)
- Both: `pi-setup-firstrun.sh` injected into the boot partition for NAS + Docker setup

#### `download-and-flash.sh` — all options

| Flag | Description | Default |
|------|-------------|---------|
| `--device DEV` | SD card device (e.g. `/dev/disk4`, `/dev/sdb`) | Interactive list |
| `--distro ID` | Distro key or menu number | Interactive menu |
| `--pi-user USER` | Username to create on the Pi | `beartums` |
| `--pi-password PASS` | Password for that user | Prompt |
| `--timezone TZ` | Timezone (e.g. `America/New_York`) | `America/New_York` |
| `--no-ssh` | Skip SSH configuration | — |
| `--cache-dir DIR` | Image cache directory | `~/.pi-images` |
| `--no-cache` | Force re-download | — |
| `--nas-host HOST` | NAS hostname or IP | — |
| `--nas-share NAME` | NAS share name | `grifData` |
| `--nas-user USER` | CIFS username | Prompt |
| `--nas-password PASS` | CIFS password | Prompt |
| `--nas-creds FILE` | Path to CIFS credentials file | — |
| `--docker-user USER` | User to add to docker group | same as `--pi-user` |
| `--skip-nas` | Skip NAS setup | — |
| `--skip-docker` | Skip Docker setup | — |
| `-y`, `--yes` | Auto-approve non-destructive prompts | — |

> **Note:** The device confirmation always requires typing `yes` — it is never auto-skipped.

---

### Option B — Flash manually, then inject before first boot

Flash with Raspberry Pi Imager (or `dd`), then run one of the inject scripts before ejecting.

**macOS / Linux / WSL:**
```bash
./inject-firstrun.sh /Volumes/bootfs \
  --nas-host 192.168.1.10 \
  --timezone America/New_York

# Linux
./inject-firstrun.sh /media/$USER/bootfs --nas-host 192.168.1.10

# WSL (SD card is drive E: in Windows → /mnt/e in WSL)
./inject-firstrun.sh /mnt/e --nas-host 192.168.1.10
```

**Windows (PowerShell, native):**
```powershell
.\inject-firstrun.ps1 -BootDrive E: -NasHost 192.168.1.10 -Timezone America/New_York
```

#### `inject-firstrun.sh` — options

| Flag | Description | Default |
|------|-------------|---------|
| `<boot-path>` | Path to mounted boot partition **(required, positional)** | — |
| `--nas-host HOST` | NAS hostname or IP | — |
| `--nas-share NAME` | Share name | `grifData` |
| `--nas-user USER` | CIFS username | prompt |
| `--nas-password PASS` | CIFS password | prompt |
| `--nas-creds FILE` | Path to credentials file (contents embedded) | — |
| `--docker-user USER` | User to add to docker group | `beartums` |
| `--timezone TZ` | Timezone to set (e.g. `America/New_York`) | no change |
| `--skip-nas` | Skip NAS setup | — |
| `--skip-docker` | Skip Docker setup | — |
| `--legacy-boot` | Use `/boot` instead of `/boot/firmware` (Bullseye and older) | — |

#### `inject-firstrun.ps1` — options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-BootDrive` | Drive letter of boot partition e.g. `E:` **(required)** | — |
| `-NasHost` | NAS hostname or IP | — |
| `-NasShare` | Share name | `grifData` |
| `-NasUser` | CIFS username | prompt |
| `-NasPassword` | CIFS password | prompt |
| `-NasCreds` | Path to credentials file (contents embedded) | — |
| `-DockerUser` | User to add to docker group | `beartums` |
| `-Timezone` | Timezone to set (e.g. `America/New_York`) | no change |
| `-SkipNas` | Skip NAS setup | — |
| `-SkipDocker` | Skip Docker setup | — |
| `-LegacyBoot` | Use `/boot` instead of `/boot/firmware` (Bullseye) | — |

---

### Option C — Run directly on a running Pi

```bash
sudo ./pi-setup.sh --nas-host 192.168.1.10
```

#### `pi-setup.sh` — options

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

---

### How the firstrun injection works

The inject scripts (and `download-and-flash.sh`) write `pi-setup-firstrun.sh` to the FAT32
boot partition and wire it to run once on first boot:
- **RPi OS**: appends `systemd.run=.../pi-setup-firstrun.sh` to `cmdline.txt`
- **Ubuntu**: adds a `runcmd` entry to the cloud-init `user-data`

Credentials are staged as a separate `cifs-credentials` file (not embedded in the script text)
and moved to `/etc/cifs-credentials` (chmod 600) on first boot.

**On first boot the Pi automatically:**
1. Waits for the apt lock, runs `apt-get update`
2. Installs `cifs-utils`, moves credentials to `/etc/`, adds fstab entry, mounts the NAS
3. Installs Docker via `get.docker.com`, adds the user to the `docker` group
4. Sets the timezone (if specified)
5. **Self-removes**: deletes the script and strips the boot hook — never runs again
6. Logs everything to `/var/log/pi-setup-firstrun.log`

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
