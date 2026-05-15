#Requires -Version 5.1
<#
.SYNOPSIS
    Write cloud-init config to a Raspberry Pi OS boot partition (Windows).
    Flash the image first with Raspberry Pi Imager, then run this script.
    The FAT32 boot partition mounts automatically as a drive letter.

.NOTES
    Requires WSL2 or Python 3.12 for SHA-512 password hashing.
    WSL2 install: run 'wsl --install' in an admin terminal, then reboot.

.EXAMPLE
    .\inject-cloud-init.ps1 -BootDrive E: -Hostname mypi
    .\inject-cloud-init.ps1 -BootDrive E: -Hostname mypi -PiUser beartums -NasHost 192.168.1.10
    .\inject-cloud-init.ps1 -BootDrive E: -Hostname mypi -SshPubKey ~\.ssh\id_ed25519.pub
    .\inject-cloud-init.ps1 -BootDrive E: -Hostname mypi -WifiSsid HomeNet -WifiPassword secret
    .\inject-cloud-init.ps1 -BootDrive E: -Hostname mypi -SkipNas -SkipDocker
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$BootDrive,              # e.g. "E:" or "E:\"

    [string]$Hostname        = "raspberrypi",
    [string]$PiUser          = "beartums",
    [string]$PiPassword      = "",   # prompted interactively if omitted
    [string]$HashedPassword  = "",   # pre-hashed $6$ SHA-512 (skips hashing step)
    [string]$Timezone        = "America/New_York",
    [string]$SshPubKey       = "",   # path to .pub file or literal key string
    [switch]$NoSsh,

    [string]$WifiSsid        = "",
    [string]$WifiPassword    = "",

    [string]$NasHost         = "",
    [string]$NasShare        = "grifData",
    [string]$NasUser         = "",
    [string]$NasPassword     = "",
    [string]$NasCreds        = "",   # path to existing creds file

    [string]$DockerUser      = "",
    [switch]$SkipNas,
    [switch]$SkipDocker,
    [switch]$SkipDisplay
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Info  ($m) { Write-Host "[INFO]  $m" -ForegroundColor Cyan   }
function Ok    ($m) { Write-Host "[ OK ]  $m" -ForegroundColor Green  }
function Warn  ($m) { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Die   ($m) { Write-Host "[ERR]   $m" -ForegroundColor Red; exit 1 }
function Step  ($m) { Write-Host "`n---- $m ----" -ForegroundColor White }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ── Defaults ──────────────────────────────────────────────────────────────────
if ([string]::IsNullOrEmpty($DockerUser)) { $DockerUser = $PiUser }
$EnableSsh = -not $NoSsh

if (-not [string]::IsNullOrEmpty($SshPubKey) -and (Test-Path $SshPubKey -ErrorAction SilentlyContinue)) {
    $SshPubKey = (Get-Content $SshPubKey -Raw).Trim()
}

# ── Boot drive validation ─────────────────────────────────────────────────────
Step "Validating boot partition"
$BootPath = $BootDrive.TrimEnd('\') + '\'
if (-not (Test-Path $BootPath)) { Die "Path not found: $BootPath" }
if (-not (Test-Path "${BootPath}cmdline.txt")) {
    Die "cmdline.txt not found in $BootPath`n  Flash the SD card with Raspberry Pi Imager first, then re-run."
}
Ok "Boot partition: $BootPath"

# ── Password hashing ──────────────────────────────────────────────────────────
Step "Pi user credentials"

$HashedPass = ""

if (-not [string]::IsNullOrEmpty($HashedPassword)) {
    if ($HashedPassword -notmatch '^\$6\$') {
        Die "-HashedPassword must be a SHA-512 crypt hash starting with '`$6`$'"
    }
    $HashedPass = $HashedPassword
    Ok "Using provided SHA-512 hash"
} else {
    if ([string]::IsNullOrEmpty($PiPassword)) {
        $sec1 = Read-Host "Password for '$PiUser'" -AsSecureString
        $sec2 = Read-Host "Confirm password"       -AsSecureString
        $b1   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec1)
        $b2   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec2)
        $PiPassword  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b1)
        $PiPassword2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b2)
        if ($PiPassword -ne $PiPassword2) { Die "Passwords do not match" }
    }

    # Try WSL + openssl
    try {
        $hash = ($PiPassword | wsl openssl passwd -6 -stdin 2>$null)
        if ($LASTEXITCODE -eq 0 -and $hash -match '^\$6\$') {
            $HashedPass = $hash.Trim()
            Ok "Password hashed via WSL (SHA-512)"
        }
    } catch {}

    # Try Python3 (crypt module — works on Python 3.6–3.12)
    if ([string]::IsNullOrEmpty($HashedPass)) {
        try {
            $pyCode = 'import crypt,sys; pw=sys.stdin.readline().rstrip(chr(13)); print(crypt.crypt(pw, crypt.mksalt(crypt.METHOD_SHA512)))'
            $hash = ($PiPassword | python3 -c $pyCode 2>$null)
            if ($LASTEXITCODE -eq 0 -and $hash -match '^\$6\$') {
                $HashedPass = $hash.Trim()
                Ok "Password hashed via Python3 (SHA-512)"
            }
        } catch {}
    }

    if ([string]::IsNullOrEmpty($HashedPass)) {
        Die "Cannot hash password. Fix one of:`n  1. Install WSL2: run 'wsl --install' in an admin terminal, then reboot`n  2. Install Python 3.12 or earlier from python.org`n  3. Pre-hash the password and pass it as -HashedPassword '`$6`$...'"
    }
}

# ── NAS credentials ───────────────────────────────────────────────────────────
$NasCredsContent = ""

if (-not $SkipNas -and [string]::IsNullOrEmpty($NasHost)) {
    Warn "No -NasHost provided -- skipping NAS setup"
    $SkipNas = $true
}

if (-not $SkipNas) {
    Step "NAS credentials"
    if (-not [string]::IsNullOrEmpty($NasCreds)) {
        if (-not (Test-Path $NasCreds)) { Die "Credentials file not found: $NasCreds" }
        $NasCredsContent = (Get-Content $NasCreds -Raw).Replace("`r`n", "`n").Trim()
        Ok "Using credentials file: $NasCreds"
    } elseif (-not [string]::IsNullOrEmpty($NasUser)) {
        if ([string]::IsNullOrEmpty($NasPassword)) {
            $sec = Read-Host "NAS password for '$NasUser'" -AsSecureString
            $b   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            $NasPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
        }
        $NasCredsContent = "username=$NasUser`npassword=$NasPassword"
    } else {
        $NasUser = Read-Host "NAS username"
        $sec = Read-Host "NAS password" -AsSecureString
        $b   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $NasPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
        $NasCredsContent = "username=$NasUser`npassword=$NasPassword"
    }
    Ok "NAS credentials ready"
}

# ── Build user-data ───────────────────────────────────────────────────────────
Step "Generating cloud-init configuration"

$InstanceId  = "pi-provisioner-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$GeneratedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
Info "Instance ID: $InstanceId"

$UserDataSb = [System.Text.StringBuilder]::new()
function ud([string]$line) { [void]$script:UserDataSb.AppendLine($line) }

ud "#cloud-config"
ud "# Generated by inject-cloud-init.ps1  |  $GeneratedAt"
ud "# Instance: $InstanceId"
ud ""
ud "manage_resolv_conf: false"
ud ""
ud "hostname: $Hostname"
ud "manage_etc_hosts: true"
ud ""
ud "apt:"
ud "  preserve_sources_list: true"
ud "  conf: |"
ud "    Acquire {"
ud '      Check-Date "false";'
ud "    };"
ud ""
ud "timezone: $Timezone"
ud ""
ud "keyboard:"
ud "  model: pc105"
ud '  layout: "us"'
ud ""
ud "users:"
ud "  - name: $PiUser"
ud "    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo"
ud "    shell: /bin/bash"
ud "    sudo: ALL=(ALL) NOPASSWD:ALL"
ud "    lock_passwd: false"
ud "    passwd: `"$HashedPass`""
if (-not [string]::IsNullOrEmpty($SshPubKey)) {
    ud "    ssh_authorized_keys:"
    ud "      - $SshPubKey"
}
ud ""
ud "chpasswd:"
ud "  expire: false"
ud ""
ud "enable_ssh: $($EnableSsh.ToString().ToLower())"
ud "ssh_pwauth: $($EnableSsh.ToString().ToLower())"
ud ""
ud "rpi:"
ud "  interfaces:"
ud "    serial: true"
ud "    i2c: true"
ud ""
ud "packages:"
ud "  - avahi-daemon"
ud "  - i2c-tools"
if (-not $SkipNas) { ud "  - cifs-utils" }
ud ""
ud "package_update: true"
ud "package_upgrade: false"
ud ""
ud "write_files:"

# NAS credentials file
if (-not $SkipNas) {
    ud "  - path: /etc/cifs-credentials"
    ud "    owner: root:root"
    ud "    permissions: '0600'"
    ud "    content: |"
    foreach ($line in ($NasCredsContent -split "`n")) {
        ud "      $line"
    }
}

# ssd1306 display config
if (-not $SkipDisplay) {
    $showDocker = if (-not $SkipDocker) { '1' } else { '0' }
    ud "  - path: /etc/ssd1306.conf"
    ud "    owner: root:root"
    ud "    permissions: '0644'"
    ud "    content: |"
    ud "      # ssd1306 display config -- pre-seeded by inject-cloud-init.ps1"
    ud "      show_temperature=1"
    ud "      show_memory=1"
    ud "      show_disk=1"
    ud "      show_ip=1"
    ud "      show_hostname=1"
    ud "      show_clock=1"
    ud "      show_uptime=1"
    ud "      show_docker=$showDocker"
    ud "      show_network=0"
    ud "      show_wifi=0"
    ud "      show_gpu_temp=0"
    ud "      show_cpu_freq=0"
    ud "      temp_unit=fahrenheit"
    ud "      load_display=percent"
    ud "      screen_time=3"
    ud "      top_line=hostname"
    ud "      network_interfaces=eth0,wlan0"
}

# pi-provision.sh — the config vars section uses PowerShell variable expansion;
# the script body uses a single-quoted here-string so bash $ signs are literal.
$skipNasBash    = if ($SkipNas)    { 'true' } else { 'false' }
$skipDockerBash = if ($SkipDocker) { 'true' } else { 'false' }
$skipDisplayBash = if ($SkipDisplay) { 'true' } else { 'false' }

$piProvisionConfig = @"
#!/bin/bash
set -euo pipefail

# Configuration (embedded at flash time)
PI_USER="$PiUser"
TIMEZONE="$Timezone"
SKIP_NAS=$skipNasBash
NAS_HOST="$NasHost"
NAS_SHARE="$NasShare"
SKIP_DOCKER=$skipDockerBash
DOCKER_USER="$DockerUser"
SKIP_DISPLAY=$skipDisplayBash
"@

$piProvisionBody = @'

# Logging setup
LOG=/var/log/pi-provisioning.log
exec >> "$LOG" 2>&1

ts()   { date -Iseconds 2>/dev/null || date; }
log()  { echo "[$(ts)] $*"; }
ok()   { echo "[$(ts)] [ OK ] $*"; }
fail() { echo "[$(ts)] [FAIL] $*"; }
step() { echo "[$(ts)] ──────────────────────────────────────────────────"; echo "[$(ts)] $*"; }

step "pi-provision.sh starting"
log "Hostname    : $(hostname)"
log "Kernel      : $(uname -r)"
log "Uptime      : $(uptime -p 2>/dev/null || uptime)"
log "Pi user     : $PI_USER"
log "Timezone    : $TIMEZONE"
log "Skip NAS    : $SKIP_NAS"
log "Skip Docker : $SKIP_DOCKER"
log "Skip Display: $SKIP_DISPLAY"
log "Free disk   : $(df -h / | awk 'NR==2{print $4}') available"
log "Memory      : $(free -h | awk '/^Mem/{print $2}') total"

# Wait for apt lock
step "Waiting for apt lock"
MAX_WAIT=36
for i in $(seq 1 $MAX_WAIT); do
  if flock -w 1 /var/lib/dpkg/lock-frontend true 2>/dev/null; then
    ok "apt lock acquired after $i attempt(s)"
    break
  fi
  log "Waiting for dpkg lock... ($i/$MAX_WAIT)"
  sleep 5
done

# WiFi unblock
step "WiFi unblock"
rfkill unblock wifi 2>/dev/null && log "rfkill unblock wifi: done" || log "rfkill not available (skipping)"
UNBLOCKED=0
for f in /var/lib/systemd/rfkill/*:wlan; do
  if [ -f "$f" ]; then
    echo 0 > "$f"
    log "Cleared rfkill state: $f"
    UNBLOCKED=$(( UNBLOCKED + 1 ))
  fi
done
[ "$UNBLOCKED" -gt 0 ] && ok "Cleared $UNBLOCKED rfkill state file(s)" || log "No rfkill state files found"

# NAS / CIFS mount
if [[ "$SKIP_NAS" == "false" ]]; then
  step "NAS CIFS mount"
  log "Target: //${NAS_HOST}/${NAS_SHARE} -> /mnt/${NAS_SHARE}"
  MOUNT_POINT="/mnt/${NAS_SHARE}"
  mkdir -p "$MOUNT_POINT"
  log "Mount point ready: $MOUNT_POINT"
  if [ -f /etc/cifs-credentials ]; then
    log "Credentials file: /etc/cifs-credentials ($(stat -c %a /etc/cifs-credentials) perms)"
  else
    fail "Credentials file not found: /etc/cifs-credentials"
  fi
  FSTAB_LINE="//${NAS_HOST}/${NAS_SHARE}  ${MOUNT_POINT}  cifs  credentials=/etc/cifs-credentials,iocharset=utf8,vers=3.0,_netdev,nofail  0  0"
  if grep -qF "$MOUNT_POINT" /etc/fstab; then
    log "fstab entry already present -- skipping"
  else
    printf '\n# pi-provision: %s\n%s\n' "$MOUNT_POINT" "$FSTAB_LINE" >> /etc/fstab
    ok "fstab entry added for $MOUNT_POINT"
    log "Entry: $FSTAB_LINE"
  fi
  log "Attempting mount..."
  if mount "$MOUNT_POINT" 2>/dev/null || mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    ok "Mounted //${NAS_HOST}/${NAS_SHARE} -> $MOUNT_POINT"
    log "Contents (first 5): $(ls "$MOUNT_POINT" 2>/dev/null | head -5 | tr '\n' ' ' || echo "(empty or unreadable)")"
  else
    fail "Mount failed -- NAS may not be reachable yet"
    log "Hint: retry manually with: mount $MOUNT_POINT"
    log "Hint: check credentials with: smbclient -L //${NAS_HOST} -U <user>"
  fi
fi

# Docker installation
if [[ "$SKIP_DOCKER" == "false" ]]; then
  step "Docker"
  if command -v docker &>/dev/null; then
    ok "Docker already installed: $(docker --version)"
  else
    log "Downloading Docker install script from get.docker.com..."
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed: $(docker --version)"
  fi
  if docker compose version &>/dev/null 2>&1; then
    ok "Docker Compose: $(docker compose version --short 2>/dev/null || docker compose version)"
  else
    log "Docker Compose plugin missing -- installing..."
    apt-get install -y -qq docker-compose-plugin || fail "docker-compose-plugin install failed (non-fatal)"
    ok "Docker Compose plugin install attempted"
  fi
  if id "$DOCKER_USER" &>/dev/null; then
    usermod -aG docker "$DOCKER_USER" || fail "usermod -aG docker $DOCKER_USER failed (non-fatal)"
    ok "$DOCKER_USER added to docker group"
  else
    fail "User $DOCKER_USER not found -- docker group assignment skipped"
  fi
fi

# ssd1306 OLED display (beartums/U6143_ssd1306)
if [[ "$SKIP_DISPLAY" == "false" ]]; then
  step "ssd1306 OLED display"
  log "Checking i2c bus..."
  i2cdetect -y 1 2>/dev/null && log "i2cdetect complete" || log "i2cdetect failed -- i2c may not be ready yet"
  log "Downloading install script from beartums/U6143_ssd1306..."
  curl -fsSL https://raw.githubusercontent.com/beartums/U6143_ssd1306/master/install.sh -o /tmp/ssd1306-install.sh
  log "Running installer (SUDO_USER=$PI_USER)..."
  SUDO_USER="$PI_USER" bash /tmp/ssd1306-install.sh
  rm -f /tmp/ssd1306-install.sh
  log "ssd1306 install script finished"
  if systemctl is-active --quiet ssd1306-display 2>/dev/null; then
    ok "ssd1306-display service is running"
  else
    log "ssd1306-display service not running yet -- may need a reboot"
    log "Check status: systemctl status ssd1306-display"
    log "Check logs:   journalctl -u ssd1306-display -n 50"
  fi
  log "i2c bus after install:"
  i2cdetect -y 1 2>/dev/null || log "i2cdetect not available"
fi

step "pi-provision.sh complete"
log "Provisioning log : $LOG"
log "Cloud-init log   : /var/log/cloud-init-output.log"
log "Cloud-init status: /run/cloud-init/status.json"
'@

# Combine and indent each line 6 spaces for the YAML literal block
$piProvisionScript = $piProvisionConfig + $piProvisionBody
$indented = ($piProvisionScript.TrimEnd() -split "`n" | ForEach-Object { "      $_" }) -join "`n"

ud "  - path: /usr/local/sbin/pi-provision.sh"
ud "    permissions: '0755'"
ud "    owner: root:root"
ud "    content: |"
[void]$script:UserDataSb.AppendLine($indented)

ud ""
ud "runcmd:"
ud "  - [ bash, /usr/local/sbin/pi-provision.sh ]"

$UserDataContent = $script:UserDataSb.ToString().Replace("`r`n", "`n")
$UserDataFile = "${BootPath}user-data"
[System.IO.File]::WriteAllText($UserDataFile, $UserDataContent, $Utf8NoBom)
Ok "user-data written: $UserDataFile"

# ── meta-data ─────────────────────────────────────────────────────────────────
$MetaDataFile = "${BootPath}meta-data"
[System.IO.File]::WriteAllText($MetaDataFile, "instance-id: $InstanceId`n", $Utf8NoBom)
Ok "meta-data written (instance-id: $InstanceId)"

# ── cmdline.txt ───────────────────────────────────────────────────────────────
$CmdlineFile = "${BootPath}cmdline.txt"
$cmdline = ((Get-Content $CmdlineFile -Raw) -replace "`r|`n", " ").Trim()
$cmdline = ($cmdline -replace '\s*ds=nocloud;i=\S*', '').Trim()
$cmdline = "$cmdline ds=nocloud;i=$InstanceId"
[System.IO.File]::WriteAllText($CmdlineFile, "$cmdline`n", $Utf8NoBom)
Ok "cmdline.txt updated (ds=nocloud;i=$InstanceId)"

# ── config.txt — enable i2c ───────────────────────────────────────────────────
$ConfigFile = "${BootPath}config.txt"
if (Test-Path $ConfigFile) {
    $configContent = Get-Content $ConfigFile -Raw
    if ($configContent -match '(?m)^#dtparam=i2c_arm=on') {
        $configContent = $configContent -replace '(?m)^#dtparam=i2c_arm=on', 'dtparam=i2c_arm=on'
        [System.IO.File]::WriteAllText($ConfigFile, $configContent.Replace("`r`n", "`n"), $Utf8NoBom)
        Ok "i2c uncommented in config.txt"
    } elseif ($configContent -match '(?m)^dtparam=i2c_arm=on') {
        Info "i2c already enabled in config.txt"
    } else {
        $addition = "`n# Added by inject-cloud-init.ps1`ndtparam=i2c_arm=on`n"
        [System.IO.File]::WriteAllText($ConfigFile, ($configContent.Replace("`r`n", "`n") + $addition), $Utf8NoBom)
        Ok "i2c appended to config.txt"
    }
} else {
    Warn "config.txt not found -- skipping i2c config"
}

# ── network-config ────────────────────────────────────────────────────────────
$NetConfigFile = "${BootPath}network-config"
if (-not [string]::IsNullOrEmpty($WifiSsid)) {
    $wifiPasswordLine = if (-not [string]::IsNullOrEmpty($WifiPassword)) { "`n          password: `"$WifiPassword`"" } else { "" }
    $netContent = @"
# network-config -- generated by inject-cloud-init.ps1
# netplan v2 format; applied by cloud-init on first boot only.

network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      optional: true
  wifis:
    wlan0:
      dhcp4: true
      optional: true
      regulatory-domain: US
      access-points:
        "$WifiSsid":$wifiPasswordLine
"@
} else {
    $netContent = @'
# network-config -- generated by inject-cloud-init.ps1
# Uncomment and edit to configure WiFi:
#network:
#  version: 2
#  ethernets:
#    eth0:
#      dhcp4: true
#      optional: true
#  wifis:
#    wlan0:
#      dhcp4: true
#      optional: true
#      access-points:
#        "myssid":
#          password: "mypassword"
'@
}
[System.IO.File]::WriteAllText($NetConfigFile, $netContent.Replace("`r`n", "`n"), $Utf8NoBom)
Ok "network-config written"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  SD card ready -- cloud-init provisioning            ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Info "Boot drive  : $BootPath"
Info "Hostname    : $Hostname"
Info "User        : $PiUser"
Info "Timezone    : $Timezone"
Info "SSH         : $(if ($EnableSsh) { 'enabled (password auth)' } else { 'disabled' })"
Info "i2c         : enabled (config.txt + rpi.interfaces)"
if (-not [string]::IsNullOrEmpty($WifiSsid)) { Info "WiFi        : $WifiSsid" }
if (-not $SkipNas)    { Info "NAS         : //$NasHost/$NasShare -> /mnt/$NasShare" }
if (-not $SkipDocker) { Info "Docker      : will install for '$DockerUser'" }
if (-not $SkipDisplay){ Info "Display     : ssd1306 OLED (beartums/U6143_ssd1306)" }
Info "Instance ID : $InstanceId"
Write-Host ""
Info "On first boot, cloud-init will run /usr/local/sbin/pi-provision.sh"
Info "Provisioning log : /var/log/pi-provisioning.log   (on the Pi)"
Info "Cloud-init log   : /var/log/cloud-init-output.log (on the Pi)"
Write-Host ""
Warn "Eject the SD card safely before inserting it into the Pi"
