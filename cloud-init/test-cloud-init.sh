#!/usr/bin/env bash
# test-cloud-init.sh — test harness for download-and-flash-cloud-init.sh
#
# Two modes:
#   Static-only  (--validate-only)  – checks YAML validity and required fields.
#                                     Works anywhere bash + python3 run.
#   QEMU boot    (default)          – boots the generated config in an Ubuntu
#                                     24.04 ARM64 VM, waits for SSH, verifies
#                                     provisioning over SSH.
#
# Platform requirements:
#   --validate-only  any platform with bash ≥ 4 and python3
#   QEMU boot        macOS (Apple Silicon, uses HVF) or Linux ARM64 (uses KVM)
#                    x86-64 hosts can run --validate-only but not the boot test
#                    (TCG software emulation of ARM64 is prohibitively slow)
#
# macOS setup:   brew install qemu
# Linux setup:   apt install qemu-system-arm qemu-efi-aarch64 ovmf xorriso
#                   (Fedora/RHEL: dnf install qemu-system-aarch64 edk2-aarch64 xorriso)
#
# Usage:
#   ./test-cloud-init.sh [options]
#
# Options:
#   --pi-user USER       Username to create in the VM (default: testuser)
#   --hostname NAME      VM hostname (default: ci-test-pi)
#   --nas-host HOST      NAS host for CIFS config test (default: 192.168.88.99)
#   --skip-nas           Skip NAS setup entirely
#   --skip-docker        Skip Docker install (faster test, saves ~5 min)
#   --skip-display       Skip ssd1306 display install
#   --validate-only      YAML + static checks only; skip QEMU boot entirely
#   --keep               Leave QEMU running after the test (for manual inspection)
#   --work-dir DIR       Scratch dir (default: auto temp dir, auto-cleaned)
#   --cache-dir DIR      Image cache directory (default: ~/.pi-images)
#   --port PORT          SSH host port for QEMU forwarding (default: 2222)
#   --timeout SECS       SSH wait + provisioning timeout (default: 300)
#
# Example – fast static check (CI-friendly, no downloads needed):
#   ./test-cloud-init.sh --validate-only --skip-docker --skip-display
#
# Example – full QEMU integration test (macOS/Linux ARM64 only):
#   ./test-cloud-init.sh --skip-display

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()  { echo -e "${CYAN}[info]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[ ok ]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[warn]${RESET}  $*"; }
step()  { echo -e "\n${BOLD}──── $* ────${RESET}"; }
die()   { echo -e "${RED}[err]${RESET}   $*" >&2; exit 1; }

# ─── Defaults ──────────────────────────────────────────────────────────────────
PI_USER="testuser"
PI_HOSTNAME="ci-test-pi"
PI_PASSWORD="testpass"
NAS_HOST="192.168.88.99"
NAS_USER="testnas"
NAS_PASSWORD="testnas"
SKIP_NAS=false
SKIP_DOCKER=false
SKIP_DISPLAY=false
VALIDATE_ONLY=false
KEEP_VM=false
WORK_DIR=""
CACHE_DIR="$HOME/.pi-images"
SSH_PORT=2222
TIMEOUT=300

# ─── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pi-user)       PI_USER="$2";       shift 2 ;;
    --hostname)      PI_HOSTNAME="$2";   shift 2 ;;
    --nas-host)      NAS_HOST="$2";      shift 2 ;;
    --skip-nas)      SKIP_NAS=true;      shift ;;
    --skip-docker)   SKIP_DOCKER=true;   shift ;;
    --skip-display)  SKIP_DISPLAY=true;  shift ;;
    --validate-only) VALIDATE_ONLY=true; shift ;;
    --keep)          KEEP_VM=true;       shift ;;
    --work-dir)      WORK_DIR="$2";      shift 2 ;;
    --cache-dir)     CACHE_DIR="$2";     shift 2 ;;
    --port)          SSH_PORT="$2";      shift 2 ;;
    --timeout)       TIMEOUT="$2";       shift 2 ;;
    -h|--help) grep '^#' "$0" | head -60 | sed 's/^# \?//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ─── Setup ─────────────────────────────────────────────────────────────────────
HOST_OS=$(uname -s)
HOST_ARCH=$(uname -m)

AUTO_WORK_DIR=false
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR=$(mktemp -d /tmp/ci-pi-XXXXX)
  AUTO_WORK_DIR=true
fi
mkdir -p "$WORK_DIR" "$CACHE_DIR"

QEMU_PID=""

cleanup() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
  fi
  if [[ "$AUTO_WORK_DIR" == "true" && "$KEEP_VM" == "false" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

# ─── Results tracking ──────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0
RESULTS=()

record() {
  local status="$1" name="$2" detail="${3:-}"
  RESULTS+=("$status|$name|$detail")
  case "$status" in
    PASS) echo -e "  ${GREEN}[PASS]${RESET} $name"; PASS=$((PASS + 1)) ;;
    FAIL) echo -e "  ${RED}[FAIL]${RESET} $name${detail:+: $detail}"; FAIL=$((FAIL + 1)) ;;
    SKIP) echo -e "  ${YELLOW}[SKIP]${RESET} $name${detail:+: $detail}"; SKIP=$((SKIP + 1)) ;;
  esac
}

check_file_contains() {
  local name="$1" pattern="$2" file="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "pattern '${pattern}' not found in $(basename "$file")"
  fi
}

check_yaml_valid() {
  local name="$1" file="$2"
  if python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
    record PASS "$name"
  elif ruby -e "require 'yaml'; YAML.safe_load(File.read('$file'))" 2>/dev/null; then
    record PASS "$name"
  else
    record FAIL "$name" "YAML parse failed"
  fi
}

# ─── PHASE 1: generate cloud-init files ────────────────────────────────────────
step "Generating cloud-init configuration (--boot-path)"

BOOT_PATH="$WORK_DIR/boot"
mkdir -p "$BOOT_PATH"

# Stub files required by download-and-flash-cloud-init.sh --boot-path validation
printf 'console=serial0,115200 console=tty1 root=PARTUUID=00000000-02 rootfstype=ext4 rootwait\n' \
  > "$BOOT_PATH/cmdline.txt"
printf '# stub config.txt for test\n' > "$BOOT_PATH/config.txt"

# Generate a fresh SSH key pair for this test run
SSH_KEY="$WORK_DIR/test_key"
ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "ci-test" -q
SSH_PUBKEY=$(cat "${SSH_KEY}.pub")
info "Generated test SSH key: ${SSH_KEY}.pub"

FLASH_ARGS=(
  --boot-path   "$BOOT_PATH"
  --hostname    "$PI_HOSTNAME"
  --pi-user     "$PI_USER"
  --pi-password "$PI_PASSWORD"
  --timezone    "America/New_York"
  --ssh-pubkey  "$SSH_PUBKEY"
  --yes
)
[[ "$SKIP_NAS" == "true" ]] \
  && FLASH_ARGS+=(--skip-nas) \
  || FLASH_ARGS+=(--nas-host "$NAS_HOST" --nas-user "$NAS_USER" --nas-password "$NAS_PASSWORD")
[[ "$SKIP_DOCKER" == "true" ]]  && FLASH_ARGS+=(--skip-docker)
[[ "$SKIP_DISPLAY" == "true" ]] && FLASH_ARGS+=(--skip-display)

"$SCRIPT_DIR/download-and-flash-cloud-init.sh" "${FLASH_ARGS[@]}"

# Inject a pre-generated SSH host key so sshd uses a known key from boot.
# Speeds up first-boot sshd startup and lets us connect immediately.
HOST_KEY="$WORK_DIR/ssh_host_ed25519_key"
ssh-keygen -t ed25519 -f "$HOST_KEY" -N "" -q
cat >> "$BOOT_PATH/user-data" << YAML

ssh_keys:
  ed25519_private: |
$(sed 's/^/    /' "$HOST_KEY")
  ed25519_public: $(cat "${HOST_KEY}.pub")
YAML
info "Injected pre-generated SSH host key into user-data"


# ─── PHASE 2: static validation ────────────────────────────────────────────────
step "Static validation"

check_yaml_valid    "user-data is valid YAML"                 "$BOOT_PATH/user-data"
check_yaml_valid    "meta-data is valid YAML"                 "$BOOT_PATH/meta-data"
check_file_contains "cmdline.txt has ds=nocloud"              "ds=nocloud"       "$BOOT_PATH/cmdline.txt"
check_file_contains "user-data has hostname"                  "hostname: $PI_HOSTNAME" "$BOOT_PATH/user-data"
check_file_contains "user-data has pi user"                   "name: $PI_USER"   "$BOOT_PATH/user-data"
check_file_contains "user-data has NOPASSWD sudo"             "NOPASSWD:ALL"     "$BOOT_PATH/user-data"
check_file_contains "user-data has SSH key"                   "ssh_authorized_keys" "$BOOT_PATH/user-data"
check_file_contains "user-data installs avahi-daemon"         "avahi-daemon"     "$BOOT_PATH/user-data"
check_file_contains "user-data installs i2c-tools"            "i2c-tools"        "$BOOT_PATH/user-data"
check_file_contains "config.txt enables i2c"                  "i2c_arm=on"       "$BOOT_PATH/config.txt"
check_file_contains "user-data has pi-provision.sh"           "pi-provision.sh"  "$BOOT_PATH/user-data"
check_file_contains "user-data runs pi-provision.sh"          "runcmd"           "$BOOT_PATH/user-data"

if [[ "$SKIP_NAS" == "false" ]]; then
  check_file_contains "user-data has NAS host"                "$NAS_HOST"        "$BOOT_PATH/user-data"
  check_file_contains "user-data installs cifs-utils"         "cifs-utils"       "$BOOT_PATH/user-data"
  check_file_contains "user-data has cifs-credentials"        "cifs-credentials" "$BOOT_PATH/user-data"
else
  record SKIP "NAS checks" "--skip-nas"
fi

if [[ "$SKIP_DOCKER" == "false" ]]; then
  check_file_contains "user-data has Docker setup"            "get.docker.com"   "$BOOT_PATH/user-data"
else
  record SKIP "Docker check" "--skip-docker"
fi

if [[ "$SKIP_DISPLAY" == "false" ]]; then
  check_file_contains "user-data has ssd1306 install"         "U6143_ssd1306"    "$BOOT_PATH/user-data"
  check_file_contains "user-data pre-seeds ssd1306.conf"      "ssd1306.conf"     "$BOOT_PATH/user-data"
else
  record SKIP "Display check" "--skip-display"
fi

if [[ "$VALIDATE_ONLY" == "true" ]]; then
  info "Skipping QEMU boot (--validate-only)"
else

# ─── QEMU boot test ─ Ubuntu 24.04 ARM64 ───────────────────────────────────────
# Requires: macOS (Apple Silicon, HVF) or Linux ARM64 (KVM)

# ─── Dependency check ──────────────────────────────────────────────────────────
step "Checking dependencies"
MISSING=()
for cmd in qemu-system-aarch64 qemu-img ssh ssh-keygen; do
  command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done

if [[ "$HOST_OS" == "Darwin" ]]; then
  :  # hdiutil and python3 are built-in
elif [[ "$HOST_OS" == "Linux" ]]; then
  for cmd in xorriso python3; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
  done
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo -e "  ${RED}[FAIL]${RESET} Missing tools: ${MISSING[*]}"
  if [[ "$HOST_OS" == "Darwin" ]]; then
    die "Install missing tools:  brew install qemu"
  else
    die "Install missing tools:  sudo apt install qemu-system-arm qemu-efi-aarch64 xorriso"
  fi
fi
ok "All dependencies present"

# ─── Acceleration ──────────────────────────────────────────────────────────────
if [[ "$HOST_OS" == "Darwin" ]]; then
  QEMU_ACCEL="-accel hvf"
elif [[ -e /dev/kvm ]]; then
  QEMU_ACCEL="-accel kvm"
else
  QEMU_ACCEL="-accel tcg"
  warn "No hardware acceleration available (HVF/KVM). Boot will be very slow."
fi

# ARM64 host strongly recommended for the QEMU test; warn otherwise.
if [[ "$HOST_ARCH" != "arm64" && "$HOST_ARCH" != "aarch64" ]]; then
  warn "Host arch is $HOST_ARCH — ARM64 VM emulation via TCG will be very slow."
  warn "Consider running --validate-only on this machine."
fi

# ─── UEFI firmware ─────────────────────────────────────────────────────────────
BIOS=""
for candidate in \
  "$(brew --prefix qemu 2>/dev/null)/share/qemu/edk2-aarch64-code.fd" \
  "/opt/homebrew/share/qemu/edk2-aarch64-code.fd" \
  "/usr/local/share/qemu/edk2-aarch64-code.fd" \
  "/usr/share/qemu/edk2-aarch64-code.fd" \
  "/usr/share/AAVMF/AAVMF_CODE.fd" \
  "/usr/share/edk2/aarch64/QEMU_EFI.fd" \
  "/usr/share/edk2-ovmf/aarch64/OVMF_CODE.fd"
do
  [[ -f "$candidate" ]] && BIOS="$candidate" && break
done
[[ -n "$BIOS" ]] || die "UEFI firmware (edk2-aarch64-code.fd) not found.
  macOS:  brew install qemu
  Ubuntu: sudo apt install qemu-efi-aarch64
  Fedora: sudo dnf install edk2-aarch64"

# ─── PHASE 3: download Ubuntu 24.04 ARM64 cloud image ─────────────────────────
CACHE_KEY="ubuntu-2404-cloudimg"
IMG_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
CACHE_IMG="$CACHE_DIR/${CACHE_KEY}.img"

step "Preparing QEMU base image (ubuntu-2404)"
if [[ ! -f "$CACHE_IMG" ]]; then
  info "Downloading Ubuntu 24.04 ARM64 cloud image (~600 MB)..."
  curl -L --progress-bar -o "$CACHE_IMG" "$IMG_URL"
  ok "Downloaded: $CACHE_IMG"
else
  ok "Using cached image: $CACHE_IMG"
fi

# qcow2 overlay — copy-on-write; leaves base image pristine
TEST_IMG="$WORK_DIR/ubuntu-test.qcow2"
info "Creating qcow2 overlay..."
qemu-img create -f qcow2 -b "$CACHE_IMG" -F qcow2 "$TEST_IMG" -q
# Resize to 12 G — cloud-init auto-expands via growpart; Docker needs ~3 GB extra
qemu-img resize "$TEST_IMG" 12G -q 2>/dev/null || qemu-img resize "$TEST_IMG" 12G
ok "Created: $TEST_IMG (backing: $CACHE_IMG, resized to 12 G)"

# ─── PHASE 4: build cloud-init seed ISO ────────────────────────────────────────
step "Building cloud-init seed ISO"

SEED_DIR="$WORK_DIR/cidata"
SEED_ISO="$WORK_DIR/seed.iso"
mkdir -p "$SEED_DIR"

cp "$BOOT_PATH/user-data"      "$SEED_DIR/user-data"
cp "$BOOT_PATH/meta-data"      "$SEED_DIR/meta-data"
cp "$BOOT_PATH/network-config" "$SEED_DIR/network-config"

INSTANCE_ID=$(grep 'instance-id:' "$BOOT_PATH/meta-data" | awk '{print $2}')
info "Instance ID: $INSTANCE_ID"

if [[ "$HOST_OS" == "Darwin" ]]; then
  hdiutil makehybrid -iso -joliet -default-volume-name cidata -o "$SEED_ISO" "$SEED_DIR" -quiet
elif command -v xorriso &>/dev/null; then
  xorriso -as mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock "$SEED_DIR" 2>/dev/null
elif command -v genisoimage &>/dev/null; then
  genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock "$SEED_DIR" 2>/dev/null
else
  die "No ISO tool found. Install xorriso:  sudo apt install xorriso  (or genisoimage)"
fi
ok "Seed ISO: $SEED_ISO"

# ─── PHASE 5: boot QEMU ────────────────────────────────────────────────────────
step "Booting QEMU (ubuntu-2404)"

SERIAL_LOG="$WORK_DIR/serial.log"

# Release any leftover process holding the SSH port
if [[ "$HOST_OS" == "Darwin" ]]; then
  lsof -ti tcp:"$SSH_PORT" 2>/dev/null | xargs kill 2>/dev/null || true
elif command -v fuser &>/dev/null; then
  fuser -k "${SSH_PORT}/tcp" 2>/dev/null || true
fi

QEMU_CMD=(
  qemu-system-aarch64
  -M virt,highmem=on $QEMU_ACCEL -cpu host
  -m 2G -smp 2
  -drive if=pflash,format=raw,file="$BIOS",readonly=on
  -drive file="$TEST_IMG",if=virtio,format=qcow2
  -drive file="$SEED_ISO",if=virtio,format=raw,readonly=on
  -device virtio-net-pci,netdev=net0
  -netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}"-:22
  -nographic
  -serial file:"$SERIAL_LOG"
  -monitor none
)

info "Starting QEMU..."
"${QEMU_CMD[@]}" > /dev/null 2>&1 &
QEMU_PID=$!
info "QEMU PID: $QEMU_PID  |  serial log: $SERIAL_LOG"
info "To connect manually: ssh -i $SSH_KEY -p $SSH_PORT ${PI_USER}@localhost"

# ─── PHASE 6: wait for SSH ─────────────────────────────────────────────────────
step "Waiting for SSH (timeout: ${TIMEOUT}s)"

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes
          -o LogLevel=ERROR -i "$SSH_KEY" -p "$SSH_PORT")
SSH_UP=false
WAITED=0
while [[ $WAITED -lt $TIMEOUT ]]; do
  if ssh "${SSH_OPTS[@]}" "${PI_USER}@localhost" true 2>/dev/null; then
    SSH_UP=true
    ok "SSH ready after ${WAITED}s"
    break
  fi
  kill -0 "$QEMU_PID" 2>/dev/null || { record FAIL "QEMU process alive"; break; }
  sleep 5
  WAITED=$((WAITED + 5))
  [[ $((WAITED % 30)) -eq 0 ]] && info "Still waiting... (${WAITED}s)"
done

if [[ "$SSH_UP" == "false" ]]; then
  record FAIL "SSH reachable within ${TIMEOUT}s"
  info "Serial console tail:"
  if [[ -s "$SERIAL_LOG" ]]; then
    tail -40 "$SERIAL_LOG" | cat
  else
    echo "  (no serial output captured)"
  fi
else
  record PASS "SSH reachable within ${TIMEOUT}s"

  # ─── PHASE 7: wait for cloud-init to finish ────────────────────────────────
  step "Waiting for cloud-init to finish (provisioning runs in runcmd)"
  CI_TIMEOUT=$((TIMEOUT - WAITED))
  [[ $CI_TIMEOUT -lt 60 ]] && CI_TIMEOUT=60
  info "Running: cloud-init status --wait  (up to ${CI_TIMEOUT}s remaining)"
  if ssh "${SSH_OPTS[@]}" "${PI_USER}@localhost" \
      "sudo cloud-init status --wait --long" 2>/dev/null; then
    ok "cloud-init finished"
  else
    CI_STATUS=$(ssh "${SSH_OPTS[@]}" "${PI_USER}@localhost" \
      "sudo cloud-init status 2>/dev/null || echo 'unknown'" 2>/dev/null || echo "ssh failed")
    warn "cloud-init status: $CI_STATUS — continuing with verification"
  fi

  # ─── PHASE 8: SSH verification ─────────────────────────────────────────────
  step "Verifying provisioning over SSH"

  ssh_run() { ssh "${SSH_OPTS[@]}" "${PI_USER}@localhost" "$@" 2>/dev/null; }

  check_ssh() {
    local name="$1"; shift
    if ssh_run "$@" &>/dev/null; then record PASS "$name"
    else                               record FAIL "$name"
    fi
  }

  check_ssh "pi-provisioning.log exists"  "test -f /var/log/pi-provisioning.log"
  check_ssh "pi-provision.sh completed"   \
    "grep -q 'pi-provision.sh complete' /var/log/pi-provisioning.log"
  check_ssh "user has sudo group"         "id -nG $PI_USER | grep -qw sudo"

  if [[ "$SKIP_DOCKER" == "false" ]]; then
    check_ssh "docker is installed"       "command -v docker"
    check_ssh "user is in docker group"   "id -nG $PI_USER | grep -qw docker"
  else
    record SKIP "Docker installed" "--skip-docker"
  fi

  if [[ "$SKIP_NAS" == "false" ]]; then
    check_ssh "/etc/fstab has NAS entry"  "grep -q '$NAS_HOST' /etc/fstab"
    check_ssh "cifs-credentials exists"   "test -f /etc/cifs-credentials"
    check_ssh "cifs-credentials is 0600"  \
      "test \$(stat -c '%a' /etc/cifs-credentials) = 600"
  else
    record SKIP "NAS fstab + creds" "--skip-nas"
  fi

  if [[ "$SKIP_DISPLAY" == "false" ]]; then
    check_ssh "ssd1306-display service registered" \
      "systemctl list-unit-files ssd1306-display.service 2>/dev/null | grep -q ssd1306"
    check_ssh "ssd1306.conf exists" "test -f /etc/ssd1306.conf"
  else
    record SKIP "ssd1306 checks" "--skip-display"
  fi

  info "--- /var/log/pi-provisioning.log ---"
  ssh_run "cat /var/log/pi-provisioning.log" | sed 's/^/    /' || true
  info "--- end ---"

fi  # SSH_UP

if [[ "$KEEP_VM" == "true" ]]; then
  ok "VM kept running — QEMU PID $QEMU_PID"
  ok "  SSH: ssh -i $SSH_KEY -p $SSH_PORT ${PI_USER}@localhost"
  QEMU_PID=""  # prevent cleanup from killing it
fi

fi  # VALIDATE_ONLY

# ─── Report ────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
printf   "${BOLD}  Results: ${GREEN}%d passed${RESET}  ${RED}%d failed${RESET}  ${YELLOW}%d skipped${RESET}\n" \
  "$PASS" "$FAIL" "$SKIP"
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
if [[ $FAIL -gt 0 ]]; then
  echo
  echo -e "${RED}Failed checks:${RESET}"
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r status name detail <<< "$r"
    [[ "$status" == "FAIL" ]] && echo -e "  ${RED}✗${RESET} $name${detail:+ ($detail)}"
  done
fi
echo
[[ "$AUTO_WORK_DIR" == "true" && "$KEEP_VM" == "false" ]] \
  && info "Work dir cleaned up: $WORK_DIR" \
  || info "Work dir preserved:  $WORK_DIR"

[[ $FAIL -gt 0 ]] && exit 1 || exit 0
