# Pi Provisioning

Scripts for flashing, configuring, and setting up Raspberry Pis from scratch.

Two provisioning approaches and one post-boot setup tool live here:

| Folder / Script | Purpose |
|-----------------|---------|
| [`cloud-init/`](cloud-init/README.md) | Flash + provision using RPi OS Bookworm's native cloud-init |
| [`firstrun/`](firstrun/README.md) | Flash + provision by injecting a firstrun script (all RPi OS versions, Ubuntu) |
| [`pimox-setup.sh`](#pimox-proxmox-ve-on-arm64) | Install Proxmox VE on a running Pi (run post-boot via SSH) |

---

## cloud-init provisioning

> **Recommended for RPi OS Bookworm+.** Everything is configured at flash time; no SSH
> needed to complete setup.

Generates `user-data`, `meta-data`, `network-config` and updates `config.txt` from scratch.
On first boot, cloud-init creates the user, enables SSH and i2c, installs packages, then runs
a provisioning script that handles NAS, Docker, and the ssd1306 OLED display.

```bash
cd cloud-init
./download-and-flash-cloud-init.sh \
  --hostname mypi \
  --pi-user beartums \
  --nas-host 192.168.1.10 \
  --timezone America/New_York
```

See **[cloud-init/README.md](cloud-init/README.md)** for full option reference and details.

---

## firstrun provisioning

> Compatible with all RPi OS versions (Bullseye, Bookworm) and Ubuntu. Works on
> macOS, Linux, WSL, and Windows.

Injects a `pi-setup-firstrun.sh` script into the FAT32 boot partition. On first boot the
Pi runs it once (NAS mount, Docker install, timezone), then self-removes.

```bash
cd firstrun

# Option A: download + flash + inject in one command
./download-and-flash.sh --nas-host 192.168.1.10

# Option B: inject into an already-flashed card
./inject-firstrun.sh /Volumes/bootfs --nas-host 192.168.1.10

# Option C: run directly on a booted Pi
sudo ./pi-setup.sh --nas-host 192.168.1.10
```

See **[firstrun/README.md](firstrun/README.md)** for full option reference and details.

---

## PiMox (Proxmox VE on ARM64)

Installs Proxmox VE on a Raspberry Pi 4/5 running Debian/RPi OS Bookworm.
Run this on a Pi that's already booted — not at flash time.

```bash
sudo ./pimox-setup.sh --hostname pimox01 --ip 192.168.1.50 --gateway 192.168.1.1
```

Two-phase install: Phase 1 configures the system and registers a post-reboot service;
Phase 2 installs Proxmox VE automatically on the next boot.

After Phase 2 completes, access the web UI at `https://<ip>:8006`.

```bash
# Monitor Phase 2 on the Pi
tail -f /var/log/pimox-install.log
journalctl -u pimox-install.service -f
```

See **[pimox-setup-README.md](pimox-setup-README.md)** for full details and options.
