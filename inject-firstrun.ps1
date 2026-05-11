#Requires -Version 5.1
<#
.SYNOPSIS
    Inject pi-setup steps into a freshly-flashed RPi boot partition (Windows).
    Run after flashing with Raspberry Pi Imager, before first boot.
    The FAT32 boot partition appears as a normal drive letter — no extra tools needed.

.EXAMPLE
    .\inject-firstrun.ps1 -BootDrive E: -NasHost 192.168.1.10
    .\inject-firstrun.ps1 -BootDrive E: -NasHost 192.168.1.10 -NasUser eric -NasPassword secret
    .\inject-firstrun.ps1 -BootDrive E: -NasHost 192.168.1.10 -NasCreds C:\Users\me\.nas-creds
    .\inject-firstrun.ps1 -BootDrive E: -SkipNas -DockerUser beartums
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$BootDrive,            # e.g. "E:" or "E:\"

    [string]$NasHost      = "",
    [string]$NasShare     = "grifData",
    [string]$NasUser      = "",
    [string]$NasPassword  = "",
    [string]$NasCreds     = "",    # Path to existing creds file — contents are embedded
    [string]$DockerUser   = "beartums",
    [switch]$SkipNas,
    [switch]$SkipDocker,
    [switch]$LegacyBoot              # Use /boot instead of /boot/firmware (Bullseye and older)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Info  ($m) { Write-Host "[INFO]  $m" -ForegroundColor Cyan   }
function Ok    ($m) { Write-Host "[ OK ]  $m" -ForegroundColor Green  }
function Warn  ($m) { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Die   ($m) { Write-Host "[ERR]   $m" -ForegroundColor Red; exit 1 }

# ── Normalise drive path ──────────────────────────────────────────────────────
$BootPath = $BootDrive.TrimEnd('\') + '\'
if (-not (Test-Path $BootPath)) { Die "Path not found: $BootPath" }
if (-not (Test-Path "${BootPath}cmdline.txt")) {
    Die "cmdline.txt not found in $BootPath — is this the right drive?"
}

# ── Determine Pi-side boot path ───────────────────────────────────────────────
if ($LegacyBoot) {
    $PiBoot = "/boot"
} else {
    # Try to detect Bullseye from drive label
    $label = (Get-Volume -DriveLetter ($BootDrive.TrimEnd(':').TrimEnd('\')) -ErrorAction SilentlyContinue).FileSystemLabel
    if ($label -eq "boot") {
        Warn "Volume label is 'boot' — looks like Bullseye. Using /boot (pass -LegacyBoot to suppress)"
        $PiBoot = "/boot"
    } else {
        $PiBoot = "/boot/firmware"
    }
}
Info "Pi-side boot path: $PiBoot"

# ── Credentials ───────────────────────────────────────────────────────────────
$CredsContent = ""

if (-not $SkipNas) {
    if ([string]::IsNullOrEmpty($NasHost)) { Die "-NasHost is required for NAS setup (or pass -SkipNas)" }

    if (-not [string]::IsNullOrEmpty($NasCreds)) {
        if (-not (Test-Path $NasCreds)) { Die "Credentials file not found: $NasCreds" }
        $CredsContent = Get-Content $NasCreds -Raw
        Ok "Using credentials file: $NasCreds"

    } elseif (-not [string]::IsNullOrEmpty($NasUser)) {
        if ([string]::IsNullOrEmpty($NasPassword)) {
            $secPass   = Read-Host "NAS password for ${NasUser}" -AsSecureString
            $bstr      = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
            $NasPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        }
        $CredsContent = "username=$NasUser`npassword=$NasPassword"

    } else {
        Info "No credentials provided — prompting interactively"
        $NasUser   = Read-Host "NAS username"
        $secPass   = Read-Host "NAS password" -AsSecureString
        $bstr      = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
        $NasPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        $CredsContent = "username=$NasUser`npassword=$NasPassword"
    }

    # Stage credentials on the boot partition
    $CredsContent | Set-Content -NoNewline "${BootPath}cifs-credentials" -Encoding ASCII
    Ok "Credentials staged on boot partition (will be moved to /etc on first boot)"
    Warn "Note: credentials are readable by anyone with SD card access until first boot"
}

# ── Build the firstrun script content ─────────────────────────────────────────
$NasSection = ""
if (-not $SkipNas) {
    $NasSection = @"

# ── NAS / CIFS ──────────────────────────────────────────────────────────────
echo "[`$(date -Iseconds)] Installing cifs-utils..."
apt-get install -y cifs-utils

if [ -f "`${BOOT_PT}/cifs-credentials" ]; then
  mv "`${BOOT_PT}/cifs-credentials" /etc/cifs-credentials
  chmod 600 /etc/cifs-credentials
  echo "[`$(date -Iseconds)] Credentials moved to /etc/cifs-credentials"
fi

UNC="//$NasHost/$NasShare"
MOUNT_POINT="/mnt/$NasShare"
mkdir -p "`${MOUNT_POINT}"

FSTAB_LINE="`${UNC}  `${MOUNT_POINT}  cifs  credentials=/etc/cifs-credentials,iocharset=utf8,vers=3.0,_netdev,nofail  0  0"
if ! grep -qF "`${MOUNT_POINT}" /etc/fstab; then
  echo "" >> /etc/fstab
  echo "# pi-setup: `${MOUNT_POINT}" >> /etc/fstab
  echo "`${FSTAB_LINE}" >> /etc/fstab
  echo "[`$(date -Iseconds)] fstab entry added"
fi

mount "`${MOUNT_POINT}" 2>/dev/null \
  && echo "[`$(date -Iseconds)] Mounted `${UNC} -> `${MOUNT_POINT}" \
  || echo "[`$(date -Iseconds)] WARNING: mount failed — check NAS availability"
"@
}

$DockerSection = ""
if (-not $SkipDocker) {
    $DockerSection = @"

# ── Docker ───────────────────────────────────────────────────────────────────
echo "[`$(date -Iseconds)] Installing Docker..."
curl -fsSL https://get.docker.com | sh

if docker compose version &>/dev/null 2>&1; then
  echo "[`$(date -Iseconds)] Docker Compose plugin present"
else
  apt-get install -y docker-compose-plugin
fi

if id "$DockerUser" &>/dev/null; then
  usermod -aG docker "$DockerUser"
  echo "[`$(date -Iseconds)] $DockerUser added to docker group"
else
  echo "[`$(date -Iseconds)] WARNING: user '$DockerUser' not found — skipping docker group"
fi
"@
}

$Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"

$FirstrunContent = @"
#!/bin/bash
# pi-setup-firstrun.sh — runs once on first Pi boot, then self-removes.
# Generated by inject-firstrun.ps1 on $Timestamp
set -euo pipefail
exec >> /var/log/pi-setup-firstrun.log 2>&1
echo "[`$(date -Iseconds)] -- pi-setup-firstrun.sh starting --"

BOOT_PT="$PiBoot"

# Wait for apt lock
for i in `$(seq 1 30); do
  flock -w 1 /var/lib/dpkg/lock-frontend true 2>/dev/null && break
  echo "Waiting for apt lock... (`$i/30)"
  sleep 5
done

apt-get update -y -qq
$NasSection
$DockerSection

# ── Cleanup ──────────────────────────────────────────────────────────────────
echo "[`$(date -Iseconds)] -- pi-setup-firstrun.sh complete — cleaning up --"
rm -f "`${BOOT_PT}/pi-setup-firstrun.sh"
sed -i "s| systemd\.run[^ ]*||g" "`${BOOT_PT}/cmdline.txt"
"@

# ── Write files ───────────────────────────────────────────────────────────────

# Use Unix line endings (LF) — Windows default CRLF breaks bash scripts
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("${BootPath}pi-setup-firstrun.sh", $FirstrunContent.Replace("`r`n","`n"), $Utf8NoBom)
Ok "firstrun script written: ${BootPath}pi-setup-firstrun.sh"

# ── Modify cmdline.txt ────────────────────────────────────────────────────────
$CmdlineFile = "${BootPath}cmdline.txt"
$Cmdline = (Get-Content $CmdlineFile -Raw).TrimEnd("`r","`n"," ")

$SystemdRun = "systemd.run=${PiBoot}/pi-setup-firstrun.sh"

if ($Cmdline -match "pi-setup-firstrun") {
    Warn "cmdline.txt already contains a pi-setup-firstrun entry — skipping"
} else {
    $NewCmdline = "$Cmdline $SystemdRun"
    [System.IO.File]::WriteAllText($CmdlineFile, $NewCmdline + "`n", $Utf8NoBom)
    Ok "cmdline.txt updated"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Boot partition ready                                ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Info "Drive     : $BootPath"
if (-not $SkipNas)    { Info "NAS       : //$NasHost/$NasShare -> /mnt/$NasShare" }
if (-not $SkipDocker) { Info "Docker    : will be installed for user '$DockerUser'" }
Info "Log       : /var/log/pi-setup-firstrun.log (on the Pi after first boot)"
Write-Host ""
Warn "Eject the SD card safely before inserting it into the Pi"
