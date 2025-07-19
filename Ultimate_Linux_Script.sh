#!/usr/bin/env bash
# ==============================================================================
# Deano's Ubuntu 24.04 Control Panel v2.1
# ==============================================================================
# CHANGE LOG (v2.1)
# ------------------------------------------------------------------------------
# * Fix #1: Unified log path + fallback logic actually works; single $LOG_FILE is
#   used everywhere. No unconditional sudo mkdir that overrides fallback.
# * Fix #3: Cron scheduling is now idempotent. A managed block in the user's
#   crontab is replaced (not blindly appended) when scheduling backups.
# * Fix #4: Incremental backup no longer truncates file list at 10,000 entries.
#   Uses find -print0 piped to tar --null safely; handles huge file sets.
# * Fix #5: Backup verification scaled. Checksums generated once at backup time;
#   later verification re-uses stored sums. Auto modes default to quick verify.
# * Fix #6: Robust cleanup on EXIT / INT / TERM. Partial dirs flagged + removed;
#   temp files tracked.
# * Correct pCloud directory: /home/deano/pCloudDrive.
# * EXCLUDE automatically incorporates configured backup targets to avoid
#   recursive backups.
# * Noninteractive mode detection: if running via --auto-* (cron) or no TTY,
#   all whiptail dialogs are suppressed; messages logged only.
# * sudo preflight for auto modes (avoids cron hang on password prompt).
# * Switched scripted package ops to apt-get (safer in noninteractive modes).
# * Added --noninteractive CLI flag.
# * Added --compressor=[zstd|xz|bz2|gz|none] for future flexibility; default zstd
#   when available, else bzip2 fallback (keeps old behaviour if zstd missing).
# * Tar operations include --one-file-system and expanded excludes.
# * Safer ensure_secure_dir (optional perms arg; sudo aware; no forced chmod for
#   mountpoints unless requested).
# * Service management checks if unit exists before action.
# * Improved disk usage threshold heuristics (warn if <25% of last backup size).
# * Centralised INTERACTIVE + QUIET flags; info()/error() respect mode.
# * Many shellcheck cleanups: quoting, arrays, local vars, subshell safety.
# ------------------------------------------------------------------------------
# NOTE: This script assumes Bash 4+.
# ============================================================================== 

set -euo pipefail
IFS=$'\n\t'
umask 077

# ------------------------------------------------------------------------------
# Trap / cleanup infrastructure
# ------------------------------------------------------------------------------
_tmp_paths=()   # tracked temp paths for auto-clean
_partial_paths=() # tracked partially-created backup dirs

register_tmp() { _tmp_paths+=("$1"); }
register_partial() { _partial_paths+=("$1"); }

cleanup_tempfiles() {
  local p
  for p in "${_tmp_paths[@]:-}"; do
    [[ -e $p ]] && rm -rf -- "$p" || true
  done
  for p in "${_partial_paths[@]:-}"; do
    # If directory exists but seems incomplete (flag file present), remove.
    [[ -d $p && -f "$p/.INCOMPLETE" ]] && rm -rf -- "$p" || true
  done
}

trap 'cleanup_tempfiles; echo "Script interrupted" >&2; exit 1' INT TERM
trap 'cleanup_tempfiles' EXIT

# ------------------------------------------------------------------------------
# CONFIG START
# ------------------------------------------------------------------------------
SERVERBACKUPFOLDER="/media/deano/Other/Backup"
PCLOUDBACKUPFOLDER="/home/deano/pCloudDrive"   # corrected per user
TMPFOLDER="/tmp"
NUMTOKEEP=5
# static excludes (top-level)
# DO NOT include backup targets here directly; appended below dynamically.
EXCLUDE_STATIC=("/lost+found" "/media" "/mnt" "/proc" "/sys" "/storage" "/virtual" "/home/deano/pCloudDrive")
readonly SERVICES_DEFAULT=("tor" "privoxy" "squid")
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Preferred primary log dir
SYS_LOG_DIR="/var/log/backup-script"
# Fallback log dir in user home
USER_LOG_DIR="$HOME/.local/share/backup-script"
# ------------------------------------------------------------------------------
# CONFIG END
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Global runtime flags (auto-settable via CLI)
# ------------------------------------------------------------------------------
INTERACTIVE=true   # toggled false for cron/auto/non-tty
QUIET=false        # suppress stdout chatter (logs still written)
VERIFY_MODE="full" # full|quick|none
COMPRESSOR="auto"  # auto|zstd|xz|bz2|gz|none (auto picks best available)
SERVICES=("${SERVICES_DEFAULT[@]}")

# detect tty early
if [[ ! -t 1 ]]; then
  INTERACTIVE=false
fi

# ------------------------------------------------------------------------------
# Logging setup
# ------------------------------------------------------------------------------
LOG_FILE=""   # will be set by log_init()

log_init() {
  local candidate="$SYS_LOG_DIR"
  local logfile

  # Try system log dir
  if { [[ -d $candidate ]] || sudo mkdir -p "$candidate" 2>/dev/null; } \
     && sudo chown "$USER":"$USER" "$candidate" 2>/dev/null; then
    logfile="$candidate/script.log"
  else
    # fallback to user
    mkdir -p "$USER_LOG_DIR"
    logfile="$USER_LOG_DIR/script.log"
  fi

  # final guarantee
  touch "$logfile" 2>/dev/null || { echo "FATAL: cannot write to log $logfile" >&2; exit 1; }
  LOG_FILE="$logfile"
}

log() {
  local level="$1"; shift || true
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE" >&2
}

info_msg() {
  # internal helper to unify interactive + log
  local message="$1"
  log INFO "$message"
  if $INTERACTIVE; then
    whiptail --title "Info" --msgbox "$message" 10 60 || true
  else
    $QUIET || echo "INFO: $message"
  fi
}

error_msg() {
  local message="$1"
  log ERROR "$message"
  if $INTERACTIVE; then
    whiptail --title "Error" --msgbox "$message" 10 60 || true
  else
    echo "ERROR: $message" >&2
  fi
}

# Backward compatibility wrappers (old function names)
info()  { info_msg  "$1"; }
error() { error_msg "$1"; }

# ------------------------------------------------------------------------------
# Utility: ensure directory exists & is writable
# Usage: ensure_secure_dir <dir> [owner] [perms]
# If perms omitted, do NOT chmod (avoid breaking mountpoint perms).
# ------------------------------------------------------------------------------
ensure_secure_dir() {
  local target_dir="$1"; shift || true
  local dir_owner="${1:-$USER}"; shift || true
  local perms="${1:-}"

  if [[ ! -d $target_dir ]]; then
    log INFO "Creating directory: $target_dir"
    mkdir -p "$target_dir" 2>/dev/null || sudo mkdir -p "$target_dir" || {
      error_msg "Failed to create directory: $target_dir"; return 1; }
  fi

  if [[ ! -w $target_dir ]]; then
    # try fix
    sudo chown "$dir_owner":"$dir_owner" "$target_dir" 2>/dev/null || true
    if [[ ! -w $target_dir ]]; then
      error_msg "No write permission for: $target_dir"; return 1; fi
  fi

  if [[ -n $perms ]]; then
    chmod "$perms" "$target_dir" 2>/dev/null || sudo chmod "$perms" "$target_dir" || true
  fi

  log INFO "Directory ready: $target_dir"
  return 0
}

# ------------------------------------------------------------------------------
# Environment sanity checks
# ------------------------------------------------------------------------------
check_root() {
  if [[ $EUID -eq 0 ]]; then
    log ERROR "This script should not be run as root for safety reasons."; exit 1; fi
}

sudo_preflight() {
  # ensure we can sudo non-interactively (cron safe)
  if ! sudo -n true 2>/dev/null; then
    if $INTERACTIVE; then
      log INFO "Caching sudo credentials..."
      sudo -v || { error_msg "sudo authentication failed"; return 1; }
    else
      log ERROR "sudo password required but no tty available"; return 1
    fi
  fi
  # keep-alive background if interactive long run? skipped for simplicity.
}

# ------------------------------------------------------------------------------
# Requirements
# ------------------------------------------------------------------------------
check_requirements() {
  local reqs=(tar rsync sha256sum find df gsettings awk stat)
  local missing=()
  local cmd
  for cmd in "${reqs[@]}"; do command -v "$cmd" &>/dev/null || missing+=("$cmd"); done
  if ((${#missing[@]})); then
    error_msg "Missing required commands: ${missing[*]}"; return 1; fi
  log INFO "All required commands are available."
}

# ------------------------------------------------------------------------------
# Progress gauge (interactive only)
# ------------------------------------------------------------------------------
show_progress() {
  $INTERACTIVE || return 0
  local current="$1" total="$2" message="$3"
  local percent=$((current * 100 / total))
  echo "$percent" | whiptail --gauge "$message" 6 50 0 || true
}

# ------------------------------------------------------------------------------
# Backup mount checks
# ------------------------------------------------------------------------------
# The dynamic exclude array is regenerated when called so runtime changes apply.
regen_excludes() {
  # user-configurable excludes + dynamic (backup dirs themselves)
  local dyn=("$PCLOUDBACKUPFOLDER" "$SERVERBACKUPFOLDER")
  EXCLUDE=("${EXCLUDE_STATIC[@]}" "${dyn[@]}")
}

p_check_backup_mount() {
  local MOUNTPOINT="$PCLOUDBACKUPFOLDER"
  regen_excludes

  if ! pgrep -x pcloud >/dev/null 2>&1; then
    error_msg "pCloud client is not running. Please start pCloud."; return 1; fi
  if [[ ! -d $MOUNTPOINT ]]; then
    error_msg "pCloudDrive directory does not exist: $MOUNTPOINT"; return 1; fi
  if [[ ! -r $MOUNTPOINT ]]; then
    error_msg "pCloudDrive not readable: $MOUNTPOINT"; return 1; fi
  if [[ -z $(ls -A "$MOUNTPOINT" 2>/dev/null) ]]; then
    error_msg "pCloudDrive appears empty: $MOUNTPOINT"; return 1; fi

  mkdir -p "$MOUNTPOINT/full" "$MOUNTPOINT/incremental" || { error_msg "Failed to create pCloud backup dirs"; return 1; }
  if [[ ! -w $MOUNTPOINT ]]; then
    error_msg "pCloud backup folder not writable: $MOUNTPOINT"; return 1; fi
  log INFO "pCloud backup mount check passed."
}

check_backup_mount() {
  local MOUNTPOINT="$SERVERBACKUPFOLDER"; local PLACEHOLDER=".backup_placeholder"
  regen_excludes

  if [[ ! -d $MOUNTPOINT ]]; then
    error_msg "Backup directory does not exist: $MOUNTPOINT"; return 1; fi
  if [[ ! -r $MOUNTPOINT ]]; then
    error_msg "Backup directory not readable: $MOUNTPOINT"; return 1; fi
  if [[ -z $(ls -A "$MOUNTPOINT" 2>/dev/null) ]]; then
    log INFO "Backup directory appears empty: $MOUNTPOINT; creating placeholder."
    touch "$MOUNTPOINT/$PLACEHOLDER" || { error_msg "Failed to create placeholder"; return 1; }
  fi
  mkdir -p "$MOUNTPOINT/full" "$MOUNTPOINT/incremental" || { error_msg "Failed to create backup subdirs"; return 1; }
  [[ -w $MOUNTPOINT ]] || { error_msg "Backup folder not writable: $MOUNTPOINT"; return 1; }
  log INFO "Server backup mount check passed."
}

# ------------------------------------------------------------------------------
# System health checks
# ------------------------------------------------------------------------------
system_check() {
  log INFO "Performing system check..."

  # disk space root
  local root_usage
  root_usage=$(df -P / | awk 'NR==2{gsub("%","",$5);print $5}')
  if [[ $root_usage =~ ^[0-9]+$ ]] && (( root_usage > 90 )); then
    error_msg "Root filesystem is ${root_usage}% full. Consider cleanup before backup."; return 1
  fi

  # broken packages (dry-run)
  if ! sudo apt-get -f install --dry-run -y &>/dev/null; then
    error_msg "System has broken packages. Run: sudo apt-get -f install"; return 1
  fi

  # failed services count
  local failed_services
  failed_services=$(systemctl --failed --no-legend | wc -l || echo 0)
  if (( failed_services > 0 )); then
    log WARN "$failed_services failed services detected."; fi

  df -h / || true
  sleep 1
  log INFO "System check completed."
}

# ------------------------------------------------------------------------------
# Package operations (script safe)
# ------------------------------------------------------------------------------
update_upgrade() {
  log INFO "Starting system update..."
  sudo_preflight || return 1
  if ! sudo apt-get update; then error_msg "Failed apt-get update"; return 1; fi
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade; then error_msg "Failed apt-get full-upgrade"; return 1; fi
  info_msg "System updated successfully."; log INFO "System update completed."
}

install_essentials() {
  log INFO "Installing essential packages..."
  sudo_preflight || return 1
  local essentials=(curl git vim gnome-tweaks build-essential unzip htop tree neofetch)
  if ! sudo apt-get install -y "${essentials[@]}"; then error_msg "Failed to install essentials"; return 1; fi
  info_msg "Essential packages installed."; log INFO "Essentials installation completed."
}

install_dev_tools() {
  log INFO "Installing developer tools..."
  sudo_preflight || return 1
  local dev_tools=(python3-pip nodejs npm docker.io docker-compose-v2 code)
  if ! sudo apt-get install -y "${dev_tools[@]}"; then error_msg "Failed to install developer tools"; return 1; fi
  if ! sudo usermod -aG docker "$USER"; then error_msg "Failed to add user to docker group"; return 1; fi
  info_msg "Developer tools installed. Log out/in for Docker group."; log INFO "Developer tools installation completed."
}

configure_ufw() {
  log INFO "Configuring UFW firewall..."
  sudo_preflight || return 1
  sudo apt-get install -y ufw || { error_msg "Failed to install UFW"; return 1; }
  sudo ufw --force enable || true
  sudo ufw default deny incoming || true
  sudo ufw default allow outgoing || true
  if $INTERACTIVE; then
    if whiptail --title "SSH Access" --yesno "Allow SSH (port 22) through firewall?" 10 60; then
      sudo ufw allow ssh || true
      log INFO "SSH access allowed."; fi
  else
    sudo ufw allow ssh || true
  fi
  info_msg "UFW firewall configured."; log INFO "UFW configuration completed."
}

setup_flatpak() {
  log INFO "Setting up Flatpak..."
  sudo_preflight || return 1
  sudo apt-get install -y flatpak gnome-software-plugin-flatpak || { error_msg "Failed to install Flatpak"; return 1; }
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || { error_msg "Failed to add Flathub"; return 1; }
  info_msg "Flatpak installed & configured."; log INFO "Flatpak setup completed."
}

gnome_tweaks() {
  log INFO "Applying GNOME tweaks..."
  gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark' 2>/dev/null || log WARN "Failed to set dark theme"
  gsettings set org.gnome.desktop.interface enable-animations false 2>/dev/null || log WARN "Failed to disable animations"
  gsettings set org.gnome.desktop.interface show-battery-percentage true 2>/dev/null || log WARN "Failed to show battery percentage"
  info_msg "GNOME tweaks applied."; log INFO "GNOME tweaks completed."
}

clean_system() {
  log INFO "Cleaning system..."
  sudo_preflight || return 1
  sudo apt-get autoremove -y || true
  sudo apt-get clean || true
  sudo journalctl --vacuum-time=3d || true
  rm -rf "$HOME/.cache/thumbnails"/* 2>/dev/null || true
  sudo find /tmp -type f -atime +7 -delete 2>/dev/null || true
  info_msg "System cleaned."; log INFO "System cleaning completed."
}

# ------------------------------------------------------------------------------
# Privacy / service management
# ------------------------------------------------------------------------------
service_exists() { systemctl list-unit-files "$1.service" >/dev/null 2>&1; }

manage_services() {
  local action="$1"; shift || true
  local success=true svc
  for svc in "${SERVICES[@]}"; do
    if service_exists "$svc"; then
      if ! sudo systemctl "$action" "$svc"; then log ERROR "Failed to $action $svc"; success=false; else log INFO "$svc: ${action}ed"; fi
    else
      log WARN "Service not installed: $svc"; fi
  done
  if $success; then info_msg "All services ${action}ed."; else error_msg "Some services failed to $action."; fi
}

start_mask_ip() { log INFO "Starting privacy services..."; manage_services start; }
stop_mask_ip()  { log INFO "Stopping privacy services..."; manage_services stop;  }
status_mask_ip(){
  log INFO "Checking service status..."
  local status_info="" svc
  for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then status_info+="$svc: RUNNING\n"; else status_info+="$svc: STOPPED\n"; fi
  done
  if $INTERACTIVE; then whiptail --title "Service Status" --msgbox "$status_info" 15 50 || true; else echo -e "$status_info"; fi
}

# ------------------------------------------------------------------------------
# Helper: remove old items, keep N most recent (numerically sorted)
# ------------------------------------------------------------------------------
rmOld() {
  local DIR="$1"; local KEEP="$2"
  [[ -d $DIR ]] || { log ERROR "Directory does not exist: $DIR"; return 1; }
  mapfile -t DLIST < <(find "$DIR" -maxdepth 1 -mindepth 1 -type d -printf '%P\n' | grep -E '^[0-9]{8}' | sort -r)
  local DCOUNT=${#DLIST[@]}
  log INFO "Found $DCOUNT backup directories in $DIR; keeping $KEEP."
  local i
  if (( DCOUNT > KEEP )); then
    for (( i=KEEP; i<DCOUNT; i++ )); do
      log INFO "Removing old backup: ${DLIST[i]}"
      rm -rf -- "$DIR/${DLIST[i]}"
    done
  fi
}

# ------------------------------------------------------------------------------
# Checksum helpers
# ------------------------------------------------------------------------------
# At backup creation we create SHA256SUMS.txt once.
# Later verify_backup() reads and checks; quick mode samples 5 files.
# ------------------------------------------------------------------------------
create_checksums() {
  local target="$1"; shift || true
  ( cd "$target" && find . -type f -name '*.tar.*' -print0 | sort -z | xargs -0 sha256sum ) >"$target/SHA256SUMS.txt" 2>/dev/null || true
}

verify_backup() {
  local target="$1"; shift || true
  local mode="${1:-$VERIFY_MODE}"
  [[ -d $target ]] || { error_msg "Backup dir missing: $target"; return 1; }
  log INFO "Verifying backup in: $target (mode=$mode)"

  local sums="$target/SHA256SUMS.txt"
  if [[ ! -f $sums ]]; then
    log WARN "No stored checksums; generating now (may be slow)."
    create_checksums "$target"
  fi

  case "$mode" in
    none) log INFO "Verification skipped by mode."; return 0;;
    quick)
      # sample up to 5 random files present in sums
      local sample_files
      sample_files=$(shuf -n 5 "$sums" 2>/dev/null || head -n 5 "$sums")
      local tmp="$(mktemp)"; register_tmp "$tmp"
      printf '%s\n' "$sample_files" >"$tmp"
      if (cd "$target" && sha256sum -c "$tmp" >/dev/null 2>&1); then
        info_msg "Backup quick-verified OK."; return 0
      else
        error_msg "Quick verification failed; run full verify."; return 1
      fi
      ;;
    full|*)
      if (cd "$target" && sha256sum -c "$sums" >"$target/verify.log" 2>&1); then
        if grep -q 'FAILED' "$target/verify.log"; then
          error_msg "Backup verification FAILED. See verify.log."; return 1
        else
          info_msg "Backup verified successfully."; log INFO "Backup verification OK."; return 0
        fi
      else
        error_msg "Backup verification error. See verify.log."; return 1
      fi
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Compressor selection
# ------------------------------------------------------------------------------
# Returns tar flags in global TAR_COMP_FLAGS + extension in TAR_EXT
# ------------------------------------------------------------------------------
TAR_COMP_FLAGS=()
TAR_EXT=".tar"

select_compressor() {
  local c="$COMPRESSOR"
  if [[ $c == auto ]]; then
    if command -v zstd >/dev/null 2>&1; then c=zstd
    elif command -v xz >/dev/null 2>&1; then c=xz
    elif command -v bzip2 >/dev/null 2>&1; then c=bz2
    elif command -v gzip >/dev/null 2>&1; then c=gz
    else c=none; fi
  fi
  case "$c" in
    zstd) TAR_COMP_FLAGS=(--zstd); TAR_EXT=".tar.zst";;
    xz)   TAR_COMP_FLAGS=(-J);     TAR_EXT=".tar.xz";;
    bz2)  TAR_COMP_FLAGS=(-j);     TAR_EXT=".tar.bz2";;
    gz)   TAR_COMP_FLAGS=(-z);     TAR_EXT=".tar.gz";;
    none) TAR_COMP_FLAGS=();       TAR_EXT=".tar";;
    *)    TAR_COMP_FLAGS=(-j);     TAR_EXT=".tar.bz2";;
  esac
}

# ------------------------------------------------------------------------------
# Tar exclude builder
# ------------------------------------------------------------------------------
build_tar_excludes() {
  regen_excludes
  local e opts=()
  for e in "${EXCLUDE[@]}"; do opts+=("--exclude=$e"); done
  opts+=("--exclude=/swapfile" "--exclude=/var/cache/apt/archives" "--exclude=/tmp/*" "--exclude=/var/tmp/*")
  printf '%s\n' "${opts[@]}"
}

# ------------------------------------------------------------------------------
# pCloud Home Backup
# ------------------------------------------------------------------------------
pBackup() {
  log INFO "Starting pCloud backup..."
  check_requirements || return 1
  system_check || return 1
  p_check_backup_mount || return 1
  sudo_preflight || return 1

  select_compressor
  local LOGFILE="${PCLOUDBACKUPFOLDER}/full/backup-$(date +%Y%m%d_%H%M%S).log"
  local START_TIME=$(date)
  {
    echo "=== pCloud Backup Started ==="; echo "Start time: $START_TIME";
    echo "Target: $PCLOUDBACKUPFOLDER"; echo "Source: /home/deano"; df -h "$PCLOUDBACKUPFOLDER"; } | tee -a "$LOGFILE"

  mkdir -p "$PCLOUDBACKUPFOLDER/full" "$PCLOUDBACKUPFOLDER/incremental"
  touch "$PCLOUDBACKUPFOLDER/incremental/lastran.txt"

  local BDIR; BDIR=$(date +"%Y%m%d_%H%M")
  local TARGETDIR="$PCLOUDBACKUPFOLDER/full/$BDIR"; mkdir -p "$TARGETDIR"
  register_partial "$TARGETDIR"; touch "$TARGETDIR/.INCOMPLETE"

  cat >"$TARGETDIR/restore.txt" <<EOF
Restore Instructions:
1. Extract the backup: tar -x -f deano${TAR_EXT} -C /
2. Fix permissions: sudo chown -R deano:deano /home/deano
3. Reboot the system
4. Verify restoration was successful

Backup created: $(date)
Source: /home/deano
EOF

  echo "Creating archive of /home/deano..." | tee -a "$LOGFILE"
  local excl; mapfile -t excl < <(build_tar_excludes)
  if sudo tar --one-file-system --ignore-failed-read --warning=no-file-changed \
    --exclude="/home/deano/.cache" \
    --exclude="/home/deano/.local/share/Trash" \
    "${excl[@]}" \
    -c -f "$TARGETDIR/deano${TAR_EXT}" "${TAR_COMP_FLAGS[@]}" /home/deano 2>>"$LOGFILE"; then
      echo "Backup archive created successfully" | tee -a "$LOGFILE"
    else
      echo "WARNING: Some files may have been skipped during backup" | tee -a "$LOGFILE"
  fi

  # finalize
  rm -f "$TARGETDIR/.INCOMPLETE"
  local DSIZE; DSIZE=$(du -sm "$TARGETDIR" | awk '{print $1}')
  echo "Backup size: ${DSIZE}MB" | tee -a "$LOGFILE"

  # heuristics vs last backup size
  local last_size_file="$PCLOUDBACKUPFOLDER/.last_full_size"
  if [[ -f $last_size_file ]]; then
    local last_size; last_size=$(cat "$last_size_file" 2>/dev/null || echo 0)
    if (( DSIZE < last_size / 4 )); then
      echo "WARNING: Backup size <25% of previous (${last_size}MB); please verify!" | tee -a "$LOGFILE"
    fi
  fi
  echo "$DSIZE" >"$last_size_file"

  rmOld "$PCLOUDBACKUPFOLDER/full" "$NUMTOKEEP"
  echo "Cleared old backups, keeping $NUMTOKEEP most recent" | tee -a "$LOGFILE"

  create_checksums "$TARGETDIR"
  verify_backup "$TARGETDIR" quick

  echo "End time: $(date)" | tee -a "$LOGFILE"
  log INFO "pCloud backup completed."
}

# ------------------------------------------------------------------------------
# Full System Backup
# ------------------------------------------------------------------------------
fullBackup() {
  log INFO "Starting full system backup..."
  check_requirements || return 1
  system_check || return 1
  check_backup_mount || return 1
  sudo_preflight || return 1

  select_compressor
  local LOGFILE="${SERVERBACKUPFOLDER}/full/backup-$(date +%Y%m%d_%H%M%S).log"
  local START_TIME=$(date)
  {
    echo "=== Full System Backup Started ===";
    echo "Start time: $START_TIME";
    echo "Target: $SERVERBACKUPFOLDER";
    echo "Source: / (exclusions applied)";
    df -h "$SERVERBACKFOLDER" 2>/dev/null || df -h; } | tee -a "$LOGFILE"

  mkdir -p "$SERVERBACKUPFOLDER/full" "$SERVERBACKUPFOLDER/incremental";
  touch "$SERVERBACKUPFOLDER/incremental/lastran.txt"

  local BDIR; BDIR=$(date +"%Y%m%d_%H%M");
  local TARGETDIR="$SERVERBACKUPFOLDER/full/$BDIR"; mkdir -p "$TARGETDIR";
  register_partial "$TARGETDIR"; touch "$TARGETDIR/.INCOMPLETE"

  cat >"$TARGETDIR/restore.txt" <<EOF
Full System Restore Instructions:
1. Boot from live media & mount target root under /mnt/target.
2. Extract each archive: tar -x -f <file> -C /mnt/target
3. Reinstall bootloader: grub-install /dev/sdX; update-grub in chroot.
4. Reboot.

Backup created: $(date)
Files in this backup:
EOF

  local excl; mapfile -t excl < <(build_tar_excludes)
  local F
  local FOLDERS=(/*)
  local total_folders=${#FOLDERS[@]}
  local current_folder=0
  for F in "${FOLDERS[@]}"; do
    current_folder=$((current_folder + 1))
    # skip if excluded (exact match only)
    local skip=false e
    for e in "${EXCLUDE[@]}"; do [[ $F == "$e" ]] && { skip=true; break; }; done
    if $skip; then
      echo "[$current_folder/$total_folders] Skipping excluded directory: $F" | tee -a "$LOGFILE"; continue; fi
    local NAME; NAME=$(basename "$F")
    echo "[$current_folder/$total_folders] Processing $F..." | tee -a "$LOGFILE"
    if sudo tar --one-file-system --ignore-failed-read --warning=no-file-changed \
      "${excl[@]}" \
      -c -f "$TARGETDIR/$NAME${TAR_EXT}" "${TAR_COMP_FLAGS[@]}" "$F" 2>>"$LOGFILE"; then
        echo "$NAME${TAR_EXT} - SUCCESS" | tee -a "$LOGFILE"
        echo "$NAME${TAR_EXT}" >>"$TARGETDIR/restore.txt"
      else
        echo "$NAME${TAR_EXT} - FAILED (see log)" | tee -a "$LOGFILE"
    fi
  done

  rm -f "$TARGETDIR/.INCOMPLETE"
  local DSIZE; DSIZE=$(du -sm "$TARGETDIR" | awk '{print $1}')
  echo "Total backup size: ${DSIZE}MB" | tee -a "$LOGFILE"

  local last_size_file="$SERVERBACKUPFOLDER/.last_full_size"
  if [[ -f $last_size_file ]]; then
    local last_size; last_size=$(cat "$last_size_file" 2>/dev/null || echo 0)
    if (( DSIZE < last_size / 4 )); then
      echo "WARNING: Backup size <25% of previous (${last_size}MB); please verify!" | tee -a "$LOGFILE"
    fi
  fi
  echo "$DSIZE" >"$last_size_file"

  if (( DSIZE > 1000 )); then
    rmOld "$SERVERBACKUPFOLDER/full" "$NUMTOKEEP"
    echo "Cleared old full backups; also clearing incremental backups" | tee -a "$LOGFILE"
    rm -rf "$SERVERBACKUPFOLDER/incremental"/* || true
  else
    echo "WARNING: Full backup size seems small (${DSIZE}MB)" | tee -a "$LOGFILE"
  fi

  create_checksums "$TARGETDIR"
  verify_backup "$TARGETDIR" quick

  echo "End time: $(date)" | tee -a "$LOGFILE"
  log INFO "Full system backup completed."
}

# ------------------------------------------------------------------------------
# Incremental Backup (tar-based)
# ------------------------------------------------------------------------------
incrementalBackup() {
  log INFO "Starting incremental backup..."
  check_requirements || return 1
  system_check || return 1
  check_backup_mount || return 1
  sudo_preflight || return 1

  local LOGFILE="${SERVERBACKUPFOLDER}/incremental/backup-$(date +%Y%m%d_%H%M%S).log"
  {
    echo "=== Incremental Backup Started ===";
    echo "Start time: $(date)";
    echo "Target: $SERVERBACKUPFOLDER/incremental";
    df -h "$SERVERBACKUPFOLDER"; } | tee -a "$LOGFILE"

  cd "$SERVERBACKUPFOLDER/incremental" || return 1
  touch runningnow.txt

  # baseline timestamp file
  if [[ ! -f lastran.txt ]]; then
    if [[ -f "$SERVERBACKUPFOLDER/full/lastran.txt" ]]; then cp "$SERVERBACKUPFOLDER/full/lastran.txt" lastran.txt; else touch -d "yesterday" lastran.txt; fi
  fi

  local BDIR; BDIR=$(date +"%Y%m%d_%H%M%S")
  local DEST="$SERVERBACKUPFOLDER/incremental/$BDIR"; mkdir "$DEST"
  register_partial "$DEST"; touch "$DEST/.INCOMPLETE"

  local F FOLDERS=(/*)
  local files_found=false
  local excl; mapfile -t excl < <(build_tar_excludes)

  for F in "${FOLDERS[@]}"; do
    # skip excluded
    local skip=false e
    for e in "${EXCLUDE[@]}"; do [[ $F == "$e" ]] && { skip=true; break; }; done
    $skip && continue

    local NAME; NAME=$(basename "$F")
    echo "Checking $NAME for changes since last backup..." | tee -a "$LOGFILE"

    # We build a file list of changed files using find -newer
    # and pipe directly to tar to avoid truncation.
    # Use process substitution to feed --null list; watch for huge lists.
    # shellcheck disable=SC2086
    if changed_count=$(find "$F" -type f -newer "$SERVERBACKUPFOLDER/incremental/lastran.txt" -print0 | tee >(wc -c >/dev/null) >/dev/null); then
      : # noop; we can't capture count easily with -print0; we'll test by building list below
    fi

    # Actually produce archive if there are changed files.
    # We'll test with -newer output count via mapfile -t (inefficient for huge trees) -> better: rely on tar return.
    # We'll create a temp list to check emptiness.
    local tmp_list; tmp_list=$(mktemp); register_tmp "$tmp_list"
    # produce newline list just to check emptiness quickly (safe; names w/ NL rare; tradeoff acceptable)
    find "$F" -type f -newer "$SERVERBACKUPFOLDER/incremental/lastran.txt" -print >"$tmp_list" 2>/dev/null || true
    if [[ -s $tmp_list ]]; then
      files_found=true
      echo "Creating incremental archive for $NAME..." | tee -a "$LOGFILE"
      # Tar from NUL stream; we generate NUL via find again to avoid newline path issues.
      if sudo tar --ignore-failed-read --warning=no-file-changed "${excl[@]}" \
        --null -T <(find "$F" -type f -newer "$SERVERBACKUPFOLDER/incremental/lastran.txt" -print0) \
        -c -f "$DEST/$NAME${TAR_EXT}" "${TAR_COMP_FLAGS[@]}" 2>>"$LOGFILE"; then
          echo "$NAME${TAR_EXT} created successfully" | tee -a "$LOGFILE"
        else
          echo "WARNING: Issues creating $NAME${TAR_EXT}" | tee -a "$LOGFILE"
      fi
    fi
  done

  rm -f "$DEST/.INCOMPLETE"
  if $files_found; then
    mv "$SERVERBACKUPFOLDER/incremental/runningnow.txt" "$SERVERBACKUPFOLDER/incremental/lastran.txt"
    echo "Incremental backup completed with changes" | tee -a "$LOGFILE"
    create_checksums "$DEST"
    verify_backup "$DEST" quick
  else
    rm -rf "$DEST"
    mv "$SERVERBACKUPFOLDER/incremental/runningnow.txt" "$SERVERBACKUPFOLDER/incremental/lastran.txt"
    echo "No changes found since last backup" | tee -a "$LOGFILE"
  fi

  echo "End time: $(date)" | tee -a "$LOGFILE"
  log INFO "Incremental backup completed."
}

# ------------------------------------------------------------------------------
# Rsync snapshot incremental (hardlink farm)
# ------------------------------------------------------------------------------
rsyncIncremental() {
  log INFO "Starting rsync incremental backup..."
  check_requirements || return 1
  system_check || return 1
  check_backup_mount || return 1
  sudo_preflight || return 1

  local RSYNCBASE="$SERVERBACKUPFOLDER/rsync_snapshots"
  local SRC="/"
  local SNAPDATE; SNAPDATE=$(date +"%Y%m%d_%H%M%S")
  local DEST="$RSYNCBASE/$SNAPDATE"
  local LOGFILE="$RSYNCBASE/rsync_${SNAPDATE}.log"
  sudo mkdir -p "$RSYNCBASE" "$DEST"
  register_partial "$DEST"; touch "$DEST/.INCOMPLETE"

  local LASTSNAP
  LASTSNAP=$(find "$RSYNCBASE" -maxdepth 1 -mindepth 1 -type d -printf '%P\n' | grep -E '^[0-9]{8}' | sort | tail -n 1)
  if [[ -n $LASTSNAP && -d $RSYNCBASE/$LASTSNAP ]]; then
    log INFO "Using previous snapshot for hard linking: $LASTSNAP"
    sudo rsync -aAXH --delete --human-readable --progress \
      --exclude="/proc/*" --exclude="/tmp/*" --exclude="/mnt/*" --exclude="/media/*" \
      --exclude="/dev/*" --exclude="/sys/*" --exclude="/run/*" --exclude="/storage/*" --exclude="/virtual/*" \
      --link-dest="$RSYNCBASE/$LASTSNAP" \
      "$SRC" "$DEST" 2>&1 | tee "$LOGFILE"
  else
    log INFO "No previous snapshot found; creating initial snapshot"
    sudo rsync -aAXH --delete --human-readable --progress \
      --exclude="/proc/*" --exclude="/tmp/*" --exclude="/mnt/*" --exclude="/media/*" \
      --exclude="/dev/*" --exclude="/sys/*" --exclude="/run/*" --exclude="/storage/*" --exclude="/virtual/*" \
      "$SRC" "$DEST" 2>&1 | tee "$LOGFILE"
  fi

  rm -f "$DEST/.INCOMPLETE"
  if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    info_msg "Rsync snapshot created: $DEST"
    log INFO "Rsync snapshot completed successfully."
    rmOld "$RSYNCBASE" "$NUMTOKEEP"
  else
    error_msg "Rsync snapshot failed. See log: $LOGFILE"; log ERROR "Rsync snapshot failed."; return 1
  fi
}

# ------------------------------------------------------------------------------
# Restore operations
# ------------------------------------------------------------------------------
restore_backup() {
  log INFO "Starting backup restore process..."
  check_requirements || return 1

  if $INTERACTIVE; then
    if ! whiptail --title "WARNING" --yesno "Backup restoration can overwrite system files and may cause data loss. Continue?" 10 60; then return 0; fi
  else
    log WARN "Noninteractive restore requested; proceeding cautiously.";
  fi

  local TYPE
  if $INTERACTIVE; then
    TYPE=$(whiptail --title "Restore Type" --menu "Select backup type to restore:" 15 60 4 \
      "1" "Full Backup" \
      "2" "Incremental Backup" \
      "3" "Rsync Snapshot" 3>&1 1>&2 2>&3)
  else
    TYPE=1  # default full
  fi
  local DIR
  case "$TYPE" in
    1) DIR="$SERVERBACKUPFOLDER/full";;
    2) DIR="$SERVERBACKUPFOLDER/incremental";;
    3) DIR="$SERVERBACKUPFOLDER/rsync_snapshots";;
    *) info_msg "Invalid selection."; return 0;;
  esac

  [[ -d $DIR ]] || { error_msg "Backup directory not found: $DIR"; return 1; }

  local BACKUPS backup
  mapfile -t BACKUPS < <(find "$DIR" -maxdepth 1 -mindepth 1 -type d -printf '%P\n' | grep -E '^[0-9]{8}' | sort -r)
  ((${#BACKUPS[@]})) || { error_msg "No backups found in $DIR"; return 1; }

  local SELECTION
  if $INTERACTIVE; then
    # build menu entries
    local MENU_OPTIONS=() i=1 b backup_date
    for b in "${BACKUPS[@]}"; do
      backup_date=$(date -d "${b:0:8}" '+%Y-%m-%d' 2>/dev/null || echo "Unknown")
      MENU_OPTIONS+=("$i" "$b ($backup_date)"); ((i++))
    done
    SELECTION=$(whiptail --title "Select Backup" --menu "Choose backup to restore:" 20 80 10 "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)
    [[ -n $SELECTION ]] || { info_msg "No backup selected."; return 0; }
    backup="${BACKUPS[$((SELECTION-1))]}"
  else
    backup="${BACKUPS[0]}"  # newest
  fi

  local SELECTED="$DIR/$backup"; local BACKUP_NAME="$backup"

  if $INTERACTIVE; then
    if ! whiptail --title "Confirm Restore" --yesno "Restore from: $BACKUP_NAME? This may overwrite existing files." 12 60; then return 0; fi
  fi

  log INFO "Restoring from: $SELECTED"
  case "$TYPE" in
    1|2)
      ( cd "$SELECTED" && for file in *${TAR_EXT}; do [[ -f $file ]] || continue; echo "Extracting $file..."; sudo tar -x -f "$file" -C /; done )
      ;;
    3)
      log INFO "Restoring rsync snapshot from $SELECTED..."
      sudo rsync -aAXHv --delete "$SELECTED"/ / 2>&1 | tee "/tmp/restore_rsync_${BACKUP_NAME}.log"
      ;;
  esac
  system_check || true
  info_msg "Restore from $BACKUP_NAME completed. Reboot recommended."
  log INFO "Restore operation completed."
}

# ------------------------------------------------------------------------------
# Cleanup Maintenance (logs, tmp backups)
# ------------------------------------------------------------------------------
cleanup() {
  log INFO "Starting cleanup process..."
  local temp_dir="${TMPFOLDER:-/tmp}"; local cleaned=0
  ( cd "$temp_dir" 2>/dev/null || return 0
    shopt -s nullglob
    local pidfile pid basename
    for pidfile in *.pid; do
      [[ -f $pidfile ]] || continue
      pid=$(<"$pidfile")
      if [[ -n $pid ]] && ! ps -p "$pid" &>/dev/null; then
        basename="${pidfile%.pid}"
        log INFO "Removing stale logs for $basename..."
        rm -f "$basename".* 2>/dev/null || true
        ((cleaned++))
      fi
    done
    shopt -u nullglob
  )
  find "$temp_dir" -name 'backup_*' -type f -mtime +7 -delete 2>/dev/null || true
  find "$temp_dir" -name 'files-to-backup.*' -type f -mtime +1 -delete 2>/dev/null || true
  if (( cleaned > 0 )); then info_msg "Cleaned up $cleaned stale log files."; else info_msg "No stale log files found."; fi
  log INFO "Cleanup process completed."
}

# ------------------------------------------------------------------------------
# View logs & reports
# ------------------------------------------------------------------------------
view_logs() {
  log INFO "Viewing logs..."
  local LOG_TYPE
  if $INTERACTIVE; then
    LOG_TYPE=$(whiptail --title "View Logs" --menu "Select log type:" 15 60 5 \
      "1" "Script Logs" \
      "2" "System Logs (journalctl)" \
      "3" "Backup Logs" \
      "4" "Failed Services" \
      "5" "Back" 3>&1 1>&2 2>&3) || return 0
  else
    LOG_TYPE=1
  fi
  case "$LOG_TYPE" in
    1)
      if [[ -f $LOG_FILE ]]; then
        if $INTERACTIVE; then whiptail --title "Script Logs" --textbox "$LOG_FILE" 20 80 || true; else cat "$LOG_FILE"; fi
      else info_msg "No script logs found."; fi;;
    2)
      local temp_log; temp_log=$(mktemp); register_tmp "$temp_log"
      journalctl --since "1 hour ago" --no-pager >"$temp_log"
      if $INTERACTIVE; then whiptail --title "System Logs (Last Hour)" --textbox "$temp_log" 20 80 || true; else cat "$temp_log"; fi;;
    3)
      local backup_logs_dir="" latest_log
      if [[ -d "$SERVERBACKUPFOLDER/full" ]]; then backup_logs_dir="$SERVERBACKUPFOLDER/full"; elif [[ -d "$PCLOUDBACKUPFOLDER/full" ]]; then backup_logs_dir="$PCLOUDBACKUPFOLDER/full"; fi
      if [[ -n $backup_logs_dir ]]; then
        latest_log=$(find "$backup_logs_dir" -name '*.log' -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
        if [[ -n $latest_log && -f $latest_log ]]; then
          if $INTERACTIVE; then whiptail --title "Latest Backup Log" --textbox "$latest_log" 20 80 || true; else cat "$latest_log"; fi
        else info_msg "No backup logs found."; fi
      else info_msg "No backup logs directory found."; fi;;
    4)
      local temp_failed; temp_failed=$(mktemp); register_tmp "$temp_failed"
      systemctl --failed --no-pager >"$temp_failed" || true
      if $INTERACTIVE; then whiptail --title "Failed Services" --textbox "$temp_failed" 20 80 || true; else cat "$temp_failed"; fi;;
    5) return;;
  esac
}

# ------------------------------------------------------------------------------
# Disk usage report
# ------------------------------------------------------------------------------
disk_usage() {
  log INFO "Checking disk usage..."
  local temp_disk; temp_disk=$(mktemp); register_tmp "$temp_disk"
  {
    echo "=== DISK USAGE REPORT ==="; echo "Generated: $(date)"; echo
    echo "=== FILESYSTEM USAGE ==="; df -h; echo
    echo "=== LARGEST DIRECTORIES IN / ==="; sudo du -h --max-depth=1 / 2>/dev/null | sort -hr | head -20; echo
    echo "=== LARGEST FILES IN /var/log ==="; sudo find /var/log -type f -exec du -h {} + 2>/dev/null | sort -hr | head -10; echo
    echo "=== BACKUP DIRECTORIES ===";
    if [[ -d $SERVERBACKUPFOLDER ]]; then echo "Server backup folder: $SERVERBACKUPFOLDER"; du -h --max-depth=2 "$SERVERBACKUPFOLDER" 2>/dev/null || echo "(inaccessible)"; fi
    if [[ -d $PCLOUDBACKUPFOLDER ]]; then echo "pCloud backup folder: $PCLOUDBACKUPFOLDER"; du -h --max-depth=2 "$PCLOUDBACKUPFOLDER" 2>/dev/null || echo "(inaccessible)"; fi
  } >"$temp_disk"
  if $INTERACTIVE; then whiptail --title "Disk Usage Report" --textbox "$temp_disk" 25 100 || true; else cat "$temp_disk"; fi
  rm -f "$temp_disk"
}

# ------------------------------------------------------------------------------
# Cron scheduling (idempotent managed block)
# ------------------------------------------------------------------------------
CRON_BEGIN="# BEGIN DEANO_CONTROL_PANEL"
CRON_END="# END DEANO_CONTROL_PANEL"

update_crontab_block() {
  local new_block="$1"; shift || true
  local current; current=$(crontab -l 2>/dev/null || true)
  # remove existing block
  current=$(printf '%s\n' "$current" | sed "/^$CRON_BEGIN$/,/^$CRON_END$/d")
  { printf '%s\n' "$current"; echo "$CRON_BEGIN"; printf '%s\n' "$new_block"; echo "$CRON_END"; } | crontab -
}

schedule_backup() {
  log INFO "Setting up backup scheduling..."
  local BACKUP_TYPE
  if $INTERACTIVE; then
    BACKUP_TYPE=$(whiptail --title "Schedule Backup" --menu "Select backup type:" 15 60 5 \
      "1" "Full Backup (Weekly)" \
      "2" "Incremental Backup (Daily)" \
      "3" "pCloud Backup (Daily)" \
      "4" "View/Remove Scheduled Backups" 3>&1 1>&2 2>&3) || return 0
  else
    BACKUP_TYPE=4
  fi
  local cron_entry=""; local script="$SCRIPT_DIR/$(basename "$0")"
  case "$BACKUP_TYPE" in
    1) cron_entry="0 2 * * 0 $script --auto-full-backup --noninteractive"; info_msg "Full backup scheduled Sundays 02:00.";;
    2) cron_entry="0 3 * * * $script --auto-incremental-backup --noninteractive"; info_msg "Incremental backup scheduled daily 03:00.";;
    3) cron_entry="0 4 * * * $script --auto-pcloud-backup --noninteractive"; info_msg "pCloud backup scheduled daily 04:00.";;
    4)
      # show current block; allow removal
      local ct; ct=$(crontab -l 2>/dev/null || echo "(none)")
      if $INTERACTIVE; then whiptail --title "Current Crontab" --msgbox "$ct" 25 80 || true; fi
      if $INTERACTIVE && whiptail --title "Remove Schedules" --yesno "Remove all scheduled backups?" 10 60; then
        update_crontab_block ""; info_msg "Scheduled backups removed."; fi
      return 0;;
  esac
  update_crontab_block "$cron_entry"
}

# ------------------------------------------------------------------------------
# Submenus
# ------------------------------------------------------------------------------
setup_menu() {
  while true; do
    local OPTION
    if $INTERACTIVE; then
      OPTION=$(whiptail --title "System Setup" --menu "Choose a setup task:" 20 70 10 \
        "1" "Update & Upgrade System" \
        "2" "Install Essential Packages" \
        "3" "Install Developer Tools" \
        "4" "Setup Flatpak + Flathub" \
        "5" "Apply GNOME Tweaks" \
        "6" "Configure Firewall (UFW)" \
        "7" "Back" 3>&1 1>&2 2>&3) || return 0
    else OPTION=7; fi
    case "$OPTION" in
      1) update_upgrade;;
      2) install_essentials;;
      3) install_dev_tools;;
      4) setup_flatpak;;
      5) gnome_tweaks;;
      6) configure_ufw;;
      7) return;;
      *) return;;
    esac
  done
}

backup_menu() {
  while true; do
    local OPTION
    if $INTERACTIVE; then
      OPTION=$(whiptail --title "Backup Options" --menu "Choose a backup method:" 20 70 10 \
        "1" "Full System Backup" \
        "2" "pCloud Home Backup" \
        "3" "Incremental Backup" \
        "4" "Rsync Snapshot Backup" \
        "5" "Verify Latest Backup" \
        "6" "Schedule Automatic Backups" \
        "7" "Back" 3>&1 1>&2 2>&3) || return 0
    else OPTION=7; fi
    case "$OPTION" in
      1) fullBackup;;
      2) pBackup;;
      3) incrementalBackup;;
      4) rsyncIncremental;;
      5)
        local latest_full
        latest_full=$(find "$SERVERBACKUPFOLDER/full" -maxdepth 1 -mindepth 1 -type d -printf '%P\n' | sort | tail -1)
        if [[ -n $latest_full ]]; then
          verify_backup "$SERVERBACKUPFOLDER/full/$latest_full" full
        else
          error_msg "No full backups found to verify."; fi;;
      6) schedule_backup;;
      7) return;;
      *) return;;
    esac
  done
}

security_menu() {
  while true; do
    local OPTION
    if $INTERACTIVE; then
      OPTION=$(whiptail --title "Security & Privacy" --menu "Manage security settings:" 15 70 8 \
        "1" "Start Privacy Services" \
        "2" "Stop Privacy Services" \
        "3" "Check Service Status" \
        "4" "Configure Firewall" \
        "5" "View Security Logs" \
        "6" "Back" 3>&1 1>&2 2>&3) || return 0
    else OPTION=6; fi
    case "$OPTION" in
      1) start_mask_ip;;
      2) stop_mask_ip;;
      3) status_mask_ip;;
      4) configure_ufw;;
      5)
        local temp_security; temp_security=$(mktemp); register_tmp "$temp_security"
        journalctl -u ufw -u tor -u privoxy -u squid --since "1 day ago" --no-pager >"$temp_security"
        if $INTERACTIVE; then whiptail --title "Security Logs" --textbox "$temp_security" 20 80 || true; else cat "$temp_security"; fi;;
      6) return;;
      *) return;;
    esac
  done
}

maintenance_menu() {
  while true; do
    local OPTION
    if $INTERACTIVE; then
      OPTION=$(whiptail --title "Maintenance" --menu "System maintenance options:" 15 70 8 \
        "1" "Clean System" \
        "2" "Clean Backup Files" \
        "3" "View System Logs" \
        "4" "Check Disk Usage" \
        "5" "System Health Check" \
        "6" "Back" 3>&1 1>&2 2>&3) || return 0
    else OPTION=6; fi
    case "$OPTION" in
      1) clean_system;;
      2) cleanup;;
      3) view_logs;;
      4) disk_usage;;
      5) system_check;;
      6) return;;
      *) return;;
    esac
  done
}

# ------------------------------------------------------------------------------
# Main Menu
# ------------------------------------------------------------------------------
main_menu() {
  while true; do
    local CHOICE
    if $INTERACTIVE; then
      CHOICE=$(whiptail --title "Deano's Ubuntu 24.04 Control Panel v2.1" --menu "Select an option:" 20 80 10 \
        "1" "System Setup & Installation" \
        "2" "Backup Management" \
        "3" "System Restoration" \
        "4" "Security & Privacy" \
        "5" "Maintenance & Logs" \
        "6" "Exit" 3>&1 1>&2 2>&3) || CHOICE=6
    else CHOICE=6; fi
    case "$CHOICE" in
      1) setup_menu;;
      2) backup_menu;;
      3) restore_backup;;
      4) security_menu;;
      5) maintenance_menu;;
      6)
        log INFO "Script exiting normally"; $INTERACTIVE && clear || true
        echo "Thanks for using Deano's Ubuntu Control Panel!"; exit 0;;
      *)
        if $INTERACTIVE && whiptail --title "Exit" --yesno "Are you sure you want to exit?" 8 50; then
          log INFO "Script exiting normally"; clear; exit 0; fi;;
    esac
  done
}

# ------------------------------------------------------------------------------
# CLI argument handling
# ------------------------------------------------------------------------------
handle_arguments() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --auto-full-backup)          INTERACTIVE=false; VERIFY_MODE=quick; auto_mode=full;;
      --auto-incremental-backup)   INTERACTIVE=false; VERIFY_MODE=quick; auto_mode=inc;;
      --auto-pcloud-backup)        INTERACTIVE=false; VERIFY_MODE=quick; auto_mode=pcloud;;
      --system-check)              auto_mode=check;;
      --noninteractive)            INTERACTIVE=false;;
      --quiet)                     QUIET=true;;
      --verify=*)                  VERIFY_MODE="${arg#*=}";;
      --compressor=*)              COMPRESSOR="${arg#*=}";;
      --services=*)                IFS=',' read -r -a SERVICES <<<"${arg#*=}";;
      --help|-h)
        cat <<USAGE
Ubuntu Management Script v2.1
Usage: $0 [OPTIONS]
  --auto-full-backup           Run full backup (noninteractive; cron)
  --auto-incremental-backup    Run incremental backup (noninteractive)
  --auto-pcloud-backup         Run pCloud home backup (noninteractive)
  --system-check               Run system health check & exit
  --noninteractive             Suppress all whiptail dialogs
  --quiet                      Reduce stdout chatter
  --verify=<full|quick|none>   Verification mode override
  --compressor=<auto|zstd|xz|bz2|gz|none>  Compression engine
  --services=s1,s2,...         Override default privacy services list
  --help                       Show this help
Without options, starts interactive menu.
USAGE
        exit 0;;
      *) log WARN "Unknown option: $arg";;
    esac
  done
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
main() {
  log_init
  check_root
  handle_arguments "$@"
  log INFO "Starting Ubuntu Management Script v2.1 (INTERACTIVE=$INTERACTIVE)"

  case "${auto_mode:-}" in
    full)   fullBackup; exit $?;;
    inc)    incrementalBackup; exit $?;;
    pcloud) pBackup; exit $?;;
    check)  system_check; exit $?;;
    "")    ;; # fallthrough to interactive menu
  esac

  # interactive menu
  echo ">>> Launching Ubuntu Control Panel..."
  main_menu
}

main "$@"
