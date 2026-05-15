#!/usr/bin/env bash
# pi-setup.sh — Standard Raspberry Pi setup
#   1. Mount a NAS share via CIFS at /mnt/grifData
#   2. Install Docker + Docker Compose plugin, add user to docker group
#
# Usage:
#   sudo ./pi-setup.sh --nas-host <host> [options]
#
# Options:
#   --nas-host HOST       NAS hostname or IP (required)
#   --nas-share NAME      Share name on the NAS (default: grifData)
#   --nas-creds FILE      Path to existing cifs credentials file
#   --nas-user USER       CIFS username (written to /etc/cifs-credentials)
#   --nas-password PASS   CIFS password  (written to /etc/cifs-credentials)
#   --nas-domain DOM      CIFS domain (optional, for AD environments)
#   --mount-point PATH    Local mount point (default: /mnt/grifData)
#   --docker-user USER    User to add to docker group (default: beartums)
#   --skip-nas            Skip NAS setup
#   --skip-docker         Skip Docker setup
#   -y, --yes             Auto-approve all prompts

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

# ─── Argument parsing ────────────────────────────────────────────────────────

NAS_HOST=""
NAS_SHARE="grifData"
NAS_CREDS_FILE=""
NAS_USER=""
NAS_PASSWORD=""
NAS_DOMAIN=""
MOUNT_POINT="/mnt/grifData"
DOCKER_USER="beartums"
SKIP_NAS=false
SKIP_DOCKER=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nas-host)     NAS_HOST="$2";       shift 2 ;;
    --nas-share)    NAS_SHARE="$2";      shift 2 ;;
    --nas-creds)    NAS_CREDS_FILE="$2"; shift 2 ;;
    --nas-user)     NAS_USER="$2";       shift 2 ;;
    --nas-password) NAS_PASSWORD="$2";   shift 2 ;;
    --nas-domain)   NAS_DOMAIN="$2";     shift 2 ;;
    --mount-point)  MOUNT_POINT="$2";    shift 2 ;;
    --docker-user)  DOCKER_USER="$2";    shift 2 ;;
    --skip-nas)     SKIP_NAS=true;       shift ;;
    --skip-docker)  SKIP_DOCKER=true;    shift ;;
    -y|--yes)       AUTO_YES=true;       shift ;;
    -h|--help)
      grep '^#' "$0" | grep -E '^\s*#\s' | head -20 | sed 's/^# \?//'
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ─── Preflight ───────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Run as root: sudo ./pi-setup.sh ..."

# ─── NAS / CIFS setup ────────────────────────────────────────────────────────

if [[ "$SKIP_NAS" == "false" ]]; then
  step "NAS CIFS mount"

  [[ -n "$NAS_HOST" ]] || die "--nas-host is required (e.g. --nas-host 192.168.1.10)"

  UNC="//${NAS_HOST}/${NAS_SHARE}"
  CREDS_DEST="/etc/cifs-credentials-$(echo "$NAS_SHARE" | tr '/' '-')"

  # ── Resolve credentials ──────────────────────────────────────────────────
  if [[ -n "$NAS_CREDS_FILE" ]]; then
    [[ -f "$NAS_CREDS_FILE" ]] || die "Credentials file not found: $NAS_CREDS_FILE"
    CREDS_DEST="$NAS_CREDS_FILE"
    ok "Using existing credentials file: $CREDS_DEST"

  elif [[ -n "$NAS_USER" ]]; then
    # Password passed as arg — write it out
    if [[ -z "$NAS_PASSWORD" ]]; then
      read -rsp "$(echo -e "${YELLOW}Password for ${NAS_USER}:${RESET} ")" NAS_PASSWORD
      echo
    fi

  else
    # Interactive prompt
    info "No credentials provided — prompting interactively"
    read -rp  "$(echo -e "${YELLOW}NAS username:${RESET} ")" NAS_USER
    read -rsp "$(echo -e "${YELLOW}NAS password:${RESET} ")" NAS_PASSWORD
    echo
  fi

  # Write credentials file if we have user/pass (not using a pre-existing file)
  if [[ -z "$NAS_CREDS_FILE" ]]; then
    info "Writing credentials to $CREDS_DEST"
    {
      echo "username=${NAS_USER}"
      echo "password=${NAS_PASSWORD}"
      [[ -n "$NAS_DOMAIN" ]] && echo "domain=${NAS_DOMAIN}"
    } > "$CREDS_DEST"
    chmod 600 "$CREDS_DEST"
    ok "Credentials file written: $CREDS_DEST (chmod 600)"
  fi

  # ── Install cifs-utils ───────────────────────────────────────────────────
  if ! dpkg -s cifs-utils &>/dev/null; then
    info "Installing cifs-utils..."
    apt-get update -y -qq
    apt-get install -y cifs-utils
  else
    info "cifs-utils already installed"
  fi

  # ── Create mount point ───────────────────────────────────────────────────
  if [[ ! -d "$MOUNT_POINT" ]]; then
    mkdir -p "$MOUNT_POINT"
    ok "Created mount point: $MOUNT_POINT"
  else
    info "Mount point already exists: $MOUNT_POINT"
  fi

  # ── Add fstab entry ──────────────────────────────────────────────────────
  FSTAB_ENTRY="${UNC}  ${MOUNT_POINT}  cifs  credentials=${CREDS_DEST},iocharset=utf8,vers=3.0,_netdev,nofail  0  0"
  FSTAB_MARKER="# pimox-setup: ${MOUNT_POINT}"

  if grep -qF "$MOUNT_POINT" /etc/fstab; then
    warn "An fstab entry for ${MOUNT_POINT} already exists — skipping"
  else
    {
      echo ""
      echo "${FSTAB_MARKER}"
      echo "${FSTAB_ENTRY}"
    } >> /etc/fstab
    ok "fstab entry added"
    info "  ${FSTAB_ENTRY}"
  fi

  # ── Test mount ───────────────────────────────────────────────────────────
  info "Testing mount..."
  if mount "$MOUNT_POINT" 2>/dev/null || mountpoint -q "$MOUNT_POINT"; then
    ok "Mounted successfully: ${UNC} → ${MOUNT_POINT}"
  else
    warn "Mount attempt failed — check credentials and NAS availability"
    warn "The fstab entry is saved; retry manually with: mount ${MOUNT_POINT}"
  fi
fi

# ─── Docker setup ────────────────────────────────────────────────────────────

if [[ "$SKIP_DOCKER" == "false" ]]; then
  step "Docker + Docker Compose"

  if command -v docker &>/dev/null; then
    ok "Docker already installed: $(docker --version)"
  else
    info "Installing Docker via get.docker.com..."
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed: $(docker --version)"
  fi

  # Docker Compose is bundled as a plugin with the official install.
  # Verify it's present; install the package explicitly if somehow missing.
  if docker compose version &>/dev/null 2>&1; then
    ok "Docker Compose plugin: $(docker compose version --short 2>/dev/null || docker compose version)"
  else
    info "Docker Compose plugin not found — installing docker-compose-plugin..."
    apt-get install -y docker-compose-plugin
    ok "Docker Compose plugin installed"
  fi

  # ── Add user to docker group ─────────────────────────────────────────────
  if id "$DOCKER_USER" &>/dev/null; then
    if groups "$DOCKER_USER" | grep -qw docker; then
      info "${DOCKER_USER} is already in the docker group"
    else
      usermod -aG docker "$DOCKER_USER"
      ok "${DOCKER_USER} added to docker group"
      warn "Log out and back in as ${DOCKER_USER} for the group change to take effect"
      warn "(or run: su - ${DOCKER_USER})"
    fi
  else
    warn "User '${DOCKER_USER}' not found — skipping group assignment"
    warn "Create the user first, then run: usermod -aG docker ${DOCKER_USER}"
  fi
fi

# ─── Done ────────────────────────────────────────────────────────────────────

echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  Pi setup complete                                   ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo

[[ "$SKIP_NAS"    == "false" ]] && info "NAS mount : ${MOUNT_POINT} (${UNC})"
[[ "$SKIP_DOCKER" == "false" ]] && info "Docker    : $(docker --version 2>/dev/null || echo 'installed')"
echo
