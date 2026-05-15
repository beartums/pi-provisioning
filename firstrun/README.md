# firstrun provisioning

Flash and provision a Raspberry Pi SD card using a firstrun script injected into the
boot partition. Works on **any RPi OS version** (Bullseye, Bookworm, or newer) and Ubuntu.

The firstrun script is wired to run once on first boot via `systemd.run=` in `cmdline.txt`
(RPi OS) or `runcmd` in cloud-init `user-data` (Ubuntu), then self-removes.

---

## Scripts

| Script | Platform | Purpose |
|--------|----------|---------|
| `download-and-flash.sh` | macOS / Linux | Download image, flash SD card, inject firstrun |
| `inject-firstrun.sh` | macOS / Linux / WSL | Inject firstrun into an already-flashed card |
| `inject-firstrun.ps1` | Windows (PowerShell) | Same as above, native Windows |
| `pi-setup.sh` | Raspberry Pi (run as root) | Run setup directly on a booted Pi |

---

## Option A — Download, flash, and configure in one command *(recommended)*

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

### Available distros

| Key | Description | Size |
|-----|-------------|------|
| `rpios-lite-64` | Raspberry Pi OS Lite 64-bit **(default)** | ~500 MB |
| `rpios-desktop-64` | Raspberry Pi OS Desktop 64-bit | ~1.2 GB |
| `rpios-lite-32` | Raspberry Pi OS Lite 32-bit | ~500 MB |
| `rpios-desktop-32` | Raspberry Pi OS Desktop 32-bit | ~1.1 GB |
| `ubuntu-2404` | Ubuntu Server 24.04 LTS 64-bit | ~1.1 GB |
| `ubuntu-2204` | Ubuntu Server 22.04 LTS 64-bit | ~700 MB |

Images are cached in `~/.pi-images/` and reused if less than 7 days old.

### `download-and-flash.sh` — all options

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

> The device confirmation always requires typing `yes` — it is never auto-skipped.

---

## Option B — Flash manually, then inject before first boot

Flash with Raspberry Pi Imager (or `dd`), then run an inject script against the mounted
boot partition before ejecting.

**macOS / Linux:**
```bash
./inject-firstrun.sh /Volumes/bootfs \
  --nas-host 192.168.1.10 \
  --timezone America/New_York

# Linux (boot partition auto-mounted)
./inject-firstrun.sh /media/$USER/bootfs --nas-host 192.168.1.10

# WSL (SD card is drive E: in Windows → /mnt/e in WSL)
./inject-firstrun.sh /mnt/e --nas-host 192.168.1.10
```

**Windows (PowerShell, native):**
```powershell
.\inject-firstrun.ps1 -BootDrive E: -NasHost 192.168.1.10 -Timezone America/New_York
```

### `inject-firstrun.sh` — options

| Flag | Description | Default |
|------|-------------|---------|
| `<boot-path>` | Path to mounted boot partition **(required, positional)** | — |
| `--nas-host HOST` | NAS hostname or IP | — |
| `--nas-share NAME` | Share name | `grifData` |
| `--nas-user USER` | CIFS username | Prompt |
| `--nas-password PASS` | CIFS password | Prompt |
| `--nas-creds FILE` | Path to credentials file (contents embedded) | — |
| `--docker-user USER` | User to add to docker group | `beartums` |
| `--timezone TZ` | Timezone to set | no change |
| `--skip-nas` | Skip NAS setup | — |
| `--skip-docker` | Skip Docker setup | — |
| `--legacy-boot` | Use `/boot` instead of `/boot/firmware` (Bullseye and older) | — |

### `inject-firstrun.ps1` — options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-BootDrive` | Drive letter of boot partition e.g. `E:` **(required)** | — |
| `-NasHost` | NAS hostname or IP | — |
| `-NasShare` | Share name | `grifData` |
| `-NasUser` | CIFS username | Prompt |
| `-NasPassword` | CIFS password | Prompt |
| `-NasCreds` | Path to credentials file (contents embedded) | — |
| `-DockerUser` | User to add to docker group | `beartums` |
| `-Timezone` | Timezone to set | no change |
| `-SkipNas` | Skip NAS setup | — |
| `-SkipDocker` | Skip Docker setup | — |
| `-LegacyBoot` | Use `/boot` instead of `/boot/firmware` (Bullseye) | — |

---

## Option C — Run directly on a booted Pi

```bash
sudo ./pi-setup.sh --nas-host 192.168.1.10
```

### `pi-setup.sh` — options

| Flag | Description | Default |
|------|-------------|---------|
| `--nas-host HOST` | NAS hostname or IP **(required)** | — |
| `--nas-share NAME` | Share name on the NAS | `grifData` |
| `--nas-creds FILE` | Path to existing CIFS credentials file | — |
| `--nas-user USER` | CIFS username (written to `/etc/cifs-credentials`) | Prompt |
| `--nas-password PASS` | CIFS password | Prompt |
| `--nas-domain DOM` | CIFS domain (AD environments) | — |
| `--mount-point PATH` | Local mount point | `/mnt/grifData` |
| `--docker-user USER` | User to add to the `docker` group | `beartums` |
| `--skip-nas` | Skip NAS setup | — |
| `--skip-docker` | Skip Docker setup | — |
| `-y`, `--yes` | Auto-approve all prompts | — |

---

## How the firstrun injection works

The inject scripts write `pi-setup-firstrun.sh` to the FAT32 boot partition and wire it
to run once on first boot:

- **RPi OS**: appends `systemd.run=.../pi-setup-firstrun.sh` to `cmdline.txt`
- **Ubuntu**: adds a `runcmd` entry to the cloud-init `user-data`

Credentials are staged as a separate `cifs-credentials` file on the boot partition
and moved to `/etc/cifs-credentials` (chmod 600) on first boot — never embedded in
the script text.

**On first boot the Pi automatically:**
1. Waits for the apt lock, runs `apt-get update`
2. Installs `cifs-utils`, moves credentials, adds fstab entry, mounts the NAS
3. Installs Docker via `get.docker.com`, adds the user to the `docker` group
4. Sets the timezone (if specified)
5. **Self-removes**: deletes the script and strips the boot hook — never runs again
6. Logs everything to `/var/log/pi-setup-firstrun.log`

---

## Security note

NAS credentials are staged in cleartext on the FAT32 boot partition from flash time until
first boot completes. Fine for a home network — keep the card secure until booted.
