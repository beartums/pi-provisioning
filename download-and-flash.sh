#!/usr/bin/env bash
# download-and-flash.sh — Download, flash, and fully configure a Raspberry Pi SD card.
# Runs on macOS or Linux. After flashing, boots the Pi fully configured.
#
# Usage:
#   ./download-and-flash.sh [options]
#
# Options:
#   --device DEV          SD card device (e.g. /dev/disk4, /dev/sdb — auto-list if omitted)
#   --distro ID           Distro key or menu number (skips interactive menu)
#   --pi-user USER        Username to create on the Pi (default: beartums)
#   --pi-password PASS    Password for that user (prompt if omitted)
#   --timezone TZ         Timezone (default: America/New_York)
#   --no-ssh              Skip SSH configuration
#   --cache-dir DIR       Image cache directory (default: ~/.pi-images)
#   --no-cache            Force re-download even if cached image exists
#   --nas-host HOST       NAS hostname or IP
#   --nas-share NAME      NAS share name (default: grifData)
#   --nas-user USER       CIFS username
#   --nas-password PASS   CIFS password
#   --nas-creds FILE      Path to CIFS credentials file
#   --docker-user USER    User to add to docker group (default: same as --pi-user)
#   --skip-nas            Skip NAS mount setup
#   --skip-docker         Skip Docker setup
#   -y, --yes             Auto-approve non-destructive prompts (device confirm always shown)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
step()  { echo -e "\n${BOLD}──── $* ────${RESET}"; }
die()   { echo -e "${RED}[ERR]${RESET}   $*" >&2; exit 1; }

confirm() {
  [[ "$AUTO_YES" == "true" ]] && return 0
  read -rp "$(echo -e "${YELLOW}${1:-Continue?} [y/N]${RESET} ")" ans
  [[ "${ans,,}" == "y" ]]
}

# ─── Distro definitions ───────────────────────────────────────────────────────
# Format: "key|label|url|size|type"
# type: rpios | ubuntu
DISTROS=(
  "rpios-lite-64|Raspberry Pi OS Lite 64-bit (recommended)|https://downloads.raspberrypi.com/raspios_lite_arm64_latest|~500 MB|rpios"
  "rpios-desktop-64|Raspberry Pi OS Desktop 64-bit|https://downloads.raspberrypi.com/raspios_arm64_latest|~1.2 GB|rpios"
  "rpios-lite-32|Raspberry Pi OS Lite 32-bit|https://downloads.raspberrypi.com/raspios_lite_armhf_latest|~500 MB|rpios"
  "rpios-desktop-32|Raspberry Pi OS Desktop 32-bit|https://downloads.raspberrypi.com/raspios_armhf_latest|~1.1 GB|rpios"
  "ubuntu-2404|Ubuntu Server 24.04 LTS 64-bit|https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.2-preinstalled-server-arm64+raspi.img.xz|~1.1 GB|ubuntu"
  "ubuntu-2204|Ubuntu Server 22.04 LTS 64-bit|https://cdimage.ubuntu.com/releases/22.04/release/ubuntu-22.04.5-preinstalled-server-arm64+raspi.img.xz|~700 MB|ubuntu"
)

distro_field() { echo "${DISTROS[$1]}" | cut -d'|' -f"$2"; }  # 1=key 2=label 3=url 4=size 5=type

# ─── Arg parsing ──────────────────────────────────────────────────────────────

DEVICE=""
DISTRO_ARG=""
PI_USER="beartums"
PI_PASSWORD=""
TIMEZONE="America/New_York"
ENABLE_SSH=true
CACHE_DIR="$HOME/.pi-images"
NO_CACHE=false
NAS_HOST=""
NAS_SHARE="grifData"
NAS_USER=""
NAS_PASSWORD=""
NAS_CREDS=""
DOCKER_USER=""
SKIP_NAS=false
SKIP_DOCKER=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)       DEVICE="$2";       shift 2 ;;
    --distro)       DISTRO_ARG="$2";   shift 2 ;;
    --pi-user)      PI_USER="$2";      shift 2 ;;
    --pi-password)  PI_PASSWORD="$2";  shift 2 ;;
    --timezone)     TIMEZONE="$2";     shift 2 ;;
    --no-ssh)       ENABLE_SSH=false;  shift ;;
    --cache-dir)    CACHE_DIR="$2";    shift 2 ;;
    --no-cache)     NO_CACHE=true;     shift ;;
    --nas-host)     NAS_HOST="$2";     shift 2 ;;
    --nas-share)    NAS_SHARE="$2";    shift 2 ;;
    --nas-user)     NAS_USER="$2";     shift 2 ;;
    --nas-password) NAS_PASSWORD="$2"; shift 2 ;;
    --nas-creds)    NAS_CREDS="$2";    shift 2 ;;
    --docker-user)  DOCKER_USER="$2";  shift 2 ;;
    --skip-nas)     SKIP_NAS=true;     shift ;;
    --skip-docker)  SKIP_DOCKER=true;  shift ;;
    -y|--yes)       AUTO_YES=true;     shift ;;
    -h|--help) grep '^#' "$0" | grep -E '^\s*#\s' | head -25 | sed 's/^# \?//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -z "$DOCKER_USER" ]] && DOCKER_USER="$PI_USER"

# ─── OS detection ─────────────────────────────────────────────────────────────

HOST_OS=$(uname -s)
[[ "$HOST_OS" == "Darwin" || "$HOST_OS" == "Linux" ]] \
  || die "Unsupported host OS: $HOST_OS (use inject-firstrun.ps1 on Windows)"

# ─── Dependencies ─────────────────────────────────────────────────────────────

step "Checking dependencies"
MISSING=()
for cmd in curl dd openssl; do
  command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
command -v xz &>/dev/null || MISSING+=("xz")
[[ ${#MISSING[@]} -eq 0 ]] || die "Missing required tools: ${MISSING[*]}"
ok "All dependencies present"

# ─── Distro selection ─────────────────────────────────────────────────────────

step "Distribution"

DISTRO_IDX=-1

if [[ -n "$DISTRO_ARG" ]]; then
  # Accept number (1-based) or key
  if [[ "$DISTRO_ARG" =~ ^[0-9]+$ ]]; then
    DISTRO_IDX=$(( DISTRO_ARG - 1 ))
  else
    for i in "${!DISTROS[@]}"; do
      [[ "$(distro_field $i 1)" == "$DISTRO_ARG" ]] && { DISTRO_IDX=$i; break; }
    done
  fi
  [[ $DISTRO_IDX -ge 0 && $DISTRO_IDX -lt ${#DISTROS[@]} ]] \
    || die "Unknown distro: $DISTRO_ARG  (use a number 1-${#DISTROS[@]} or a key)"
else
  echo
  echo "  Available distributions:"
  echo
  for i in "${!DISTROS[@]}"; do
    KEY=$(distro_field $i 1); LABEL=$(distro_field $i 2); SIZE=$(distro_field $i 4)
    DEFAULT=""; [[ "$KEY" == "rpios-lite-64" ]] && DEFAULT=" ${GREEN}← default${RESET}"
    printf "  ${BOLD}%d)${RESET} %-45s %s%b\n" "$((i+1))" "$LABEL" "$SIZE" "$DEFAULT"
  done
  echo
  read -rp "$(echo -e "${YELLOW}Choose a distro [1]:${RESET} ")" CHOICE
  CHOICE="${CHOICE:-1}"
  [[ "$CHOICE" =~ ^[0-9]+$ ]] || die "Invalid selection"
  DISTRO_IDX=$(( CHOICE - 1 ))
  [[ $DISTRO_IDX -ge 0 && $DISTRO_IDX -lt ${#DISTROS[@]} ]] \
    || die "Selection out of range"
fi

DISTRO_KEY=$(distro_field $DISTRO_IDX 1)
DISTRO_LABEL=$(distro_field $DISTRO_IDX 2)
DISTRO_URL=$(distro_field $DISTRO_IDX 3)
DISTRO_TYPE=$(distro_field $DISTRO_IDX 5)
ok "Selected: $DISTRO_LABEL"

# ─── Credentials for Pi user ──────────────────────────────────────────────────

step "Pi user credentials"

if [[ -z "$PI_PASSWORD" ]]; then
  read -rsp "$(echo -e "${YELLOW}Password for '${PI_USER}':${RESET} ")" PI_PASSWORD; echo
  read -rsp "$(echo -e "${YELLOW}Confirm password:${RESET} ")" PI_PASS2; echo
  [[ "$PI_PASSWORD" == "$PI_PASS2" ]] || die "Passwords do not match"
fi

# Hash the password (SHA-512 crypt, compatible with userconf.txt and cloud-init)
HASHED_PASS=$(openssl passwd -6 "$PI_PASSWORD")
ok "Password hashed"

# ─── Image download ───────────────────────────────────────────────────────────

step "Image download"

mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/${DISTRO_KEY}.img.xz"
IMG_FILE="$CACHE_DIR/${DISTRO_KEY}.img"

if [[ "$NO_CACHE" == "false" && -f "$CACHE_FILE" ]]; then
  AGE_DAYS=$(( ( $(date +%s) - $(date -r "$CACHE_FILE" +%s 2>/dev/null || echo 0) ) / 86400 ))
  if [[ $AGE_DAYS -lt 7 ]]; then
    ok "Using cached image (${AGE_DAYS}d old): $CACHE_FILE"
  else
    warn "Cached image is ${AGE_DAYS} days old — re-downloading"
    rm -f "$CACHE_FILE" "$IMG_FILE"
  fi
fi

if [[ ! -f "$CACHE_FILE" ]]; then
  info "Downloading $DISTRO_LABEL..."
  info "  URL: $DISTRO_URL"
  curl -L --progress-bar -o "$CACHE_FILE" "$DISTRO_URL"
  ok "Download complete: $CACHE_FILE"
fi

if [[ ! -f "$IMG_FILE" ]]; then
  info "Decompressing image..."
  xz -dk "$CACHE_FILE"   # -k keeps the .xz, -d decompresses
  # xz outputs to same directory stripping .xz
  XZ_OUT="${CACHE_FILE%.xz}"
  [[ "$XZ_OUT" != "$IMG_FILE" ]] && mv "$XZ_OUT" "$IMG_FILE"
  ok "Decompressed: $IMG_FILE"
else
  info "Decompressed image already exists: $IMG_FILE"
fi

# ─── Device selection ─────────────────────────────────────────────────────────

step "SD card device"

if [[ -z "$DEVICE" ]]; then
  echo
  if [[ "$HOST_OS" == "Darwin" ]]; then
    echo "  Detected external disks:"
    echo
    diskutil list external physical 2>/dev/null | grep -E "^/dev/disk|SIZE|GB|MB" | \
      awk '/^\/dev\/disk/{dev=$1} /GB|MB/{printf "  %-12s %s %s\n", dev, $1, $2}' | sort -u || \
      diskutil list external physical 2>/dev/null | head -30
    echo
    read -rp "$(echo -e "${YELLOW}Enter device (e.g. /dev/disk4):${RESET} ")" DEVICE
  else
    echo "  Detected removable/SD devices:"
    echo
    lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -E "usb|sd[a-z]$|mmcblk" || \
      lsblk -d -o NAME,SIZE,MODEL | tail -n +2
    echo
    read -rp "$(echo -e "${YELLOW}Enter device (e.g. /dev/sdb):${RESET} ")" DEVICE
  fi
fi

[[ -n "$DEVICE" ]] || die "No device specified"

# Safety: refuse to flash if the device looks like a fixed disk
if [[ "$HOST_OS" == "Darwin" ]]; then
  IS_INTERNAL=$(diskutil info "$DEVICE" 2>/dev/null | grep -i "internal" | grep -i "yes" || true)
  [[ -z "$IS_INTERNAL" ]] || die "Device $DEVICE appears to be an internal disk — aborting"
  DEVICE_INFO=$(diskutil info "$DEVICE" 2>/dev/null | grep -E "Device Node|Media Name|Total Size" | sed 's/^[[:space:]]*//')
else
  [[ -b "$DEVICE" ]] || die "$DEVICE is not a block device"
  DEVICE_INFO=$(lsblk -d -o NAME,SIZE,MODEL "$DEVICE" 2>/dev/null || echo "$DEVICE")
fi

echo
warn "About to flash ${BOLD}${DEVICE}${RESET}${YELLOW} with ${DISTRO_LABEL}"
echo -e "  $DEVICE_INFO"
echo
# Device confirmation is never auto-skipped — always require explicit yes
read -rp "$(echo -e "${RED}Type 'yes' to confirm (this will erase the device):${RESET} ")" CONFIRM_DEV
[[ "$CONFIRM_DEV" == "yes" ]] || die "Aborted"

# ─── Flash ────────────────────────────────────────────────────────────────────

step "Flashing"

if [[ "$HOST_OS" == "Darwin" ]]; then
  DISK_NUM=$(echo "$DEVICE" | grep -oE '[0-9]+$')
  RAW_DEV="/dev/rdisk${DISK_NUM}"
  diskutil unmountDisk "$DEVICE" || true
  info "Writing to $RAW_DEV (this will take a few minutes)..."
  sudo dd if="$IMG_FILE" of="$RAW_DEV" bs=4m status=progress 2>&1 || \
    sudo dd if="$IMG_FILE" of="$RAW_DEV" bs=4m          # fallback: older dd without status
  sync
  ok "Flash complete"
  info "Mounting partitions..."
  diskutil mountDisk "$DEVICE" 2>/dev/null || true
  sleep 2
  BOOT_PATH=$(find /Volumes -maxdepth 2 -name "cmdline.txt" 2>/dev/null | head -1 | xargs -I{} dirname {} || true)
else
  info "Writing to $DEVICE (this will take a few minutes)..."
  sudo dd if="$IMG_FILE" of="$DEVICE" bs=4M status=progress conv=fsync
  sync
  ok "Flash complete"
  sudo partprobe "$DEVICE" 2>/dev/null || true
  sleep 2
  BOOT_PART="${DEVICE}1"
  [[ -b "${DEVICE}p1" ]] && BOOT_PART="${DEVICE}p1"  # mmcblk style
  BOOT_PATH="/mnt/pi-boot-$$"
  sudo mkdir -p "$BOOT_PATH"
  sudo mount "$BOOT_PART" "$BOOT_PATH"
fi

[[ -n "$BOOT_PATH" && -d "$BOOT_PATH" ]] || die "Could not find/mount boot partition"
[[ -f "$BOOT_PATH/cmdline.txt" ]]        || die "cmdline.txt not found in $BOOT_PATH"
ok "Boot partition at: $BOOT_PATH"

# ─── User + SSH configuration ─────────────────────────────────────────────────

step "Configuring user, SSH, and timezone"

if [[ "$DISTRO_TYPE" == "rpios" ]]; then

  # userconf.txt: "username:hashed_password" — RPi OS reads this on first boot
  echo "${PI_USER}:${HASHED_PASS}" > "$BOOT_PATH/userconf.txt"
  ok "User config written: ${PI_USER}"

  # SSH: empty 'ssh' file in boot partition enables sshd on first boot
  if [[ "$ENABLE_SSH" == "true" ]]; then
    touch "$BOOT_PATH/ssh"
    ok "SSH enabled (password auth is on by default in RPi OS)"
  fi

  # Timezone + SSH hardening go into the firstrun script (see inject step below)

elif [[ "$DISTRO_TYPE" == "ubuntu" ]]; then

  # Ubuntu uses cloud-init. Write user-data to the boot (FAT32) partition.
  SSH_PWAUTH="true"
  [[ "$ENABLE_SSH" == "false" ]] && SSH_PWAUTH="false"

  cat > "$BOOT_PATH/user-data" <<EOF
#cloud-config
# Generated by download-and-flash.sh

hostname: ubuntu-pi
manage_etc_hosts: true

users:
  - name: ${PI_USER}
    groups: [adm, sudo, dialout, cdrom, audio, plugdev]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    hashed_passwd: "${HASHED_PASS}"

chpasswd:
  expire: false

ssh_pwauth: ${SSH_PWAUTH}

timezone: ${TIMEZONE}

package_update: true
package_upgrade: false
EOF
  ok "cloud-init user-data written: ${PI_USER}"
  info "Timezone set in cloud-init: $TIMEZONE"
  info "Note: NAS/Docker will still be handled via firstrun on Ubuntu"
fi

# ─── Inject firstrun (NAS + Docker + timezone for RPi OS) ────────────────────

step "Injecting firstrun setup"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INJECT_SCRIPT="$SCRIPT_DIR/inject-firstrun.sh"

[[ -x "$INJECT_SCRIPT" ]] || die "inject-firstrun.sh not found or not executable at $SCRIPT_DIR"

INJECT_ARGS=("$BOOT_PATH" --timezone "$TIMEZONE" --docker-user "$DOCKER_USER")

[[ "$SKIP_NAS"    == "true" ]] && INJECT_ARGS+=(--skip-nas)
[[ "$SKIP_DOCKER" == "true" ]] && INJECT_ARGS+=(--skip-docker)
[[ -n "$NAS_HOST"     ]] && INJECT_ARGS+=(--nas-host     "$NAS_HOST")
[[ -n "$NAS_SHARE"    ]] && INJECT_ARGS+=(--nas-share    "$NAS_SHARE")
[[ -n "$NAS_USER"     ]] && INJECT_ARGS+=(--nas-user     "$NAS_USER")
[[ -n "$NAS_PASSWORD" ]] && INJECT_ARGS+=(--nas-password "$NAS_PASSWORD")
[[ -n "$NAS_CREDS"    ]] && INJECT_ARGS+=(--nas-creds    "$NAS_CREDS")

# Detect legacy boot path
[[ "$(basename "$BOOT_PATH")" == "boot" ]] && INJECT_ARGS+=(--legacy-boot)

"$INJECT_SCRIPT" "${INJECT_ARGS[@]}"

# For Ubuntu, also wire the firstrun script into cloud-init runcmd
if [[ "$DISTRO_TYPE" == "ubuntu" && -f "$BOOT_PATH/pi-setup-firstrun.sh" ]]; then
  cat >> "$BOOT_PATH/user-data" <<'EOF'

runcmd:
  - [ bash, /boot/firmware/pi-setup-firstrun.sh ]
EOF
  # Remove the systemd.run entry inject-firstrun.sh added to cmdline.txt — Ubuntu uses runcmd instead
  sed -i "s| systemd\.run[^ ]*||g" "$BOOT_PATH/cmdline.txt" 2>/dev/null || true
  ok "Firstrun wired into cloud-init runcmd (Ubuntu)"
fi

# ─── Unmount ──────────────────────────────────────────────────────────────────

step "Unmounting"

if [[ "$HOST_OS" == "Darwin" ]]; then
  diskutil unmountDisk "$DEVICE" 2>/dev/null || true
  ok "Unmounted — safe to eject"
else
  sudo umount "$BOOT_PATH" 2>/dev/null || true
  sudo rmdir "$BOOT_PATH"  2>/dev/null || true
  sudo eject "$DEVICE"     2>/dev/null || true
  ok "Unmounted and ejected"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  SD card ready to boot                               ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo
info "Distro    : $DISTRO_LABEL"
info "User      : $PI_USER"
info "Timezone  : $TIMEZONE"
[[ "$ENABLE_SSH" == "true" ]] && info "SSH       : enabled (password auth)"
[[ "$SKIP_NAS"   == "false" && -n "$NAS_HOST" ]] && info "NAS       : //${NAS_HOST}/${NAS_SHARE} → /mnt/${NAS_SHARE}"
[[ "$SKIP_DOCKER" == "false" ]] && info "Docker    : will install for user '${DOCKER_USER}'"
info "Setup log : /var/log/pi-setup-firstrun.log (on the Pi after first boot)"
echo
