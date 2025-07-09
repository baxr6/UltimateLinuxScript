#!/bin/bash

set -euo pipefail
trap "echo 'Script interrupted'; exit 1" INT TERM

### Backup CONFIG START ###
SERVERBACKUPFOLDER="/media/deano/HDD/Backup"
PCLOUDBACKUPFOLDER="/home/deano/pCloudDrive"
TMPFOLDER="/tmp"
NUMTOKEEP=5
EXCLUDE=("/lost+found" "/media" "/mnt" "/proc" "/sys" "/storage" "/virtual" "/home/deano/pCloudDrive")
services=("tor" "privoxy" "squid")
### Backup CONFIG END ###

if ! command -v whiptail &> /dev/null; then
  sudo apt install -y whiptail
fi

# --- Info ---
function info() {
  whiptail --title "Info" --msgbox "$1" 10 60
}

# --- Requirements Check ---
function check_requirements() {
  local reqs=(tar rsync sha256sum find whiptail df gsettings)
  for cmd in "${reqs[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      info "Required command '$cmd' not found. Please install it."
      exit 1
    fi
  done
}

# --- Backup Mount Checks ---
function p_check_backup_mount() {
  local MOUNTPOINT="$PCLOUDBACKUPFOLDER"
  if ! pgrep -x pcloud > /dev/null; then
    info "pCloud client is not running. Please start pCloud."
    return 1
  fi
  if [[ ! -d "$MOUNTPOINT" || ! -r "$MOUNTPOINT" || -z "$(ls -A "$MOUNTPOINT" 2>/dev/null)" ]]; then
    info "pCloudDrive not mounted, inaccessible, or empty: $MOUNTPOINT"
    return 1
  fi
  mkdir -p "$MOUNTPOINT/full" "$MOUNTPOINT/incremental"
  [[ ! -w "$MOUNTPOINT" ]] && info "Backup folder not writable: $MOUNTPOINT" && return 1
}

function check_backup_mount() {
  local MOUNTPOINT="$SERVERBACKUPFOLDER"
  if [[ ! -d "$MOUNTPOINT" || ! -r "$MOUNTPOINT" || -z "$(ls -A "$MOUNTPOINT" 2>/dev/null)" ]]; then
    info "Drive not mounted, inaccessible, or empty: $MOUNTPOINT"
    return 1
  fi
  mkdir -p "$MOUNTPOINT/full" "$MOUNTPOINT/incremental"
  [[ ! -w "$MOUNTPOINT" ]] && info "Backup folder not writable: $MOUNTPOINT" && return 1
}

# --- Utility ---
function system_check() {
  df -h /
  sudo apt -f install --dry-run
  systemctl --failed
  sleep 3
}

function update_upgrade() {
  sudo apt update && sudo apt full-upgrade -y
  info "System updated."
}

function install_essentials() {
  sudo apt install -y curl git vim gnome-tweaks build-essential unzip htop
  info "Essentials installed."
}

function install_dev_tools() {
  sudo apt install -y python3-pip nodejs npm docker.io docker-compose
  sudo usermod -aG docker "$USER"
  info "Developer tools installed. Docker group set."
}

function configure_ufw() {
  sudo apt install -y ufw
  sudo ufw enable
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  info "UFW configured."
}

function setup_flatpak() {
  sudo apt install -y flatpak gnome-software-plugin-flatpak
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  info "Flatpak installed."
}

function gnome_tweaks() {
  gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark'
  gsettings set org.gnome.desktop.interface enable-animations false
  info "GNOME tweaks applied."
}

function clean_system() {
  sudo apt autoremove -y
  sudo apt clean
  sudo journalctl --vacuum-time=7d
  info "System cleaned."
}

function start_mask_ip() {
  for service in "${services[@]}"; do
    sudo systemctl start "$service"
  done
  info "All services started."
}

function stop_mask_ip() {
  for service in "${services[@]}"; do
    sudo systemctl stop "$service"
  done
  info "All services stopped."
}

function status_mask_ip() {
  for service in "${services[@]}"; do
    sudo systemctl status "$service" --no-pager --lines=1
  done
  info "Service statuses checked."
}

function rmOld() {
  local DIR="$1"
  local KEEP="$2"
  cd "$DIR" || return 1
  mapfile -t DLIST < <(ls -td */ 2>/dev/null | grep -v lastran | sed 's:/*$::')
  local DCOUNT=${#DLIST[@]}
  if (( DCOUNT > KEEP )); then
    for (( i=KEEP; i<DCOUNT; i++ )); do
      [[ -d "${DLIST[i]}" ]] && rm -rf -- "${DLIST[i]}"
    done
  fi
}

function verify_backup() {
  local target="$1"
  cd "$target"
  find . -name '*.tar.bz2' -exec sha256sum {} \; > SHA256SUMS.txt
  sha256sum -c SHA256SUMS.txt > verify.log 2>&1
  if grep -q 'FAILED' verify.log; then
    info "Backup verification FAILED. Check verify.log."
  else
    info "Backup verified successfully."
  fi
}

function pBackup {
  check_requirements
  system_check
  p_check_backup_mount || return 1

  local LOGFILE="${PCLOUDBACKUPFOLDER}/full/backup-$(date +%Y%m%d_%H%M%S).log"
  echo "Starting full backup of /home/deano..." | tee -a "$LOGFILE"
  df -h "$PCLOUDBACKUPFOLDER" | tee -a "$LOGFILE"
  local START=$(date)
  echo "Start: $START" | tee -a "$LOGFILE"

  # Setup folders
  mkdir -p "$PCLOUDBACKUPFOLDER/full"
  mkdir -p "$PCLOUDBACKUPFOLDER/incremental"
  touch "$PCLOUDBACKUPFOLDER/incremental/lastran.txt"

  local BDIR=$(date +"%Y%m%d_%H%M")
  local TARGETDIR="$PCLOUDBACKUPFOLDER/full/$BDIR"
  mkdir -p "$TARGETDIR"
  echo "Restore with: tar -xjf deano.tar.bz2 -C /" > "$TARGETDIR/restore.txt"

  echo "Tarring /home/deano..." | tee -a "$LOGFILE"
  tar --ignore-failed-read --warning=no-file-changed \
      -cjf "$TARGETDIR/deano.tar.bz2" /home/deano \
      || echo "Failed to tar /home/deano" | tee -a "$LOGFILE"

  # Check size
  local DSIZE=$(du -sm "$TARGETDIR" | awk '{print $1}')
  if [[ "$DSIZE" -gt 1000 ]]; then
    : "${NUMTOKEEP:=3}"  # Default value
    rmOld "$PCLOUDBACKUPFOLDER/full" "$NUMTOKEEP"
    echo "Clearing incremental backups..." | tee -a "$LOGFILE"
    rm -rf "$PCLOUDBACKUPFOLDER/incremental/"*
  else
    echo "Backup size < 1GB – check for issues!" | tee -a "$LOGFILE"
  fi

  verify_backup "$TARGETDIR"
}


function fullBackup {
  check_requirements
  system_check
  check_backup_mount || return 1

  local LOGFILE="${SERVERBACKUPFOLDER}/full/backup-$(date +%Y%m%d_%H%M%S).log"
  df -h "$SERVERBACKUPFOLDER"
  echo "Starting full backup..." | tee -a "$LOGFILE"
  local START=$(date)
  echo "Start: $START" | tee -a "$LOGFILE"

  mkdir -p "$SERVERBACKUPFOLDER/incremental"
  touch "$SERVERBACKUPFOLDER/incremental/lastran.txt"
  mkdir -p "$SERVERBACKUPFOLDER/full"
  cd "$SERVERBACKUPFOLDER/full"
  touch lastran.txt

  local FOLDERS=$(ls /)
  local BDIR=$(date +"%Y%m%d_%H%M")
  mkdir "$BDIR"
  echo "Make Folders: ${EXCLUDE[*]}, then untar." > "$SERVERBACKUPFOLDER/full/$BDIR/restore.txt"

  cd /
  for F in $FOLDERS; do
    CONT=1
    for E in "${EXCLUDE[@]}"; do [[ "/$F" == "$E" ]] && CONT=0; done
    if [[ "$CONT" == "1" ]]; then
      echo "Tarring $F..." | tee -a "$LOGFILE"
      tar --exclude=/swapfile --exclude=/var/cache/apt/archives -cjf "$SERVERBACKUPFOLDER/full/$BDIR/$F.tar.bz2" "$F" || {
        echo "Failed to tar $F" | tee -a "$LOGFILE"
      }
    fi
  done

  cd "$SERVERBACKUPFOLDER/full"
  DSIZE=$(du -sm "$BDIR" | awk '{print $1}')
  if [[ "$DSIZE" -gt 1000 ]]; then
    rmOld "$SERVERBACKUPFOLDER/full" "$NUMTOKEEP"
    echo "Clearing Incremental backups." | tee -a "$LOGFILE"
    rm -rf "$SERVERBACKUPFOLDER/incremental/"*
  else
    echo "Backup less than 1GB – check integrity!" | tee -a "$LOGFILE"
  fi

  verify_backup "$SERVERBACKUPFOLDER/full/$BDIR"
}

function incrementalBackup {
  check_requirements
  system_check
  check_backup_mount || return 1

  local LOGFILE="${SERVERBACKUPFOLDER}/incremental/backup-$(date +%Y%m%d_%H%M%S).log"
  df -h "$SERVERBACKUPFOLDER"
  cd "$SERVERBACKUPFOLDER/incremental"
  touch runningnow.txt
  [[ ! -f lastran.txt ]] && cp "$SERVERBACKUPFOLDER/full/lastran.txt" .

  local FOLDERS=$(ls /)
  local BDIR=$(date +"%Y%m%d_%H%M%S")
  local DEST="$BDIR"
  i=1
  while [[ -d "$DEST" ]]; do
    DEST="${BDIR}_$i"
    i=$((i + 1))
  done
  mkdir "$DEST"

  cd /
  echo "Start: $(date)" | tee -a "$LOGFILE"

  for F in $FOLDERS; do
    CONT=1
    for E in "${EXCLUDE[@]}"; do [[ "/$F" == "$E" ]] && CONT=0; done
    if [[ "$CONT" == "1" ]]; then
      echo "Checking $F for changes..." | tee -a "$LOGFILE"
      FILELIST=$(find "$F" -newer "$SERVERBACKUPFOLDER/incremental/lastran.txt" -type f 2>/dev/null)
      if [[ -n "$FILELIST" ]]; then
        TMPFILE=$(mktemp /tmp/files-to-backup.XXXXXX)
        echo "$FILELIST" | tr '\n' '\0' > "$TMPFILE"
        if [[ -s "$TMPFILE" ]]; then
          echo "Tarring $F..." | tee -a "$LOGFILE"
          tar --null --exclude=/swapfile --exclude=/var/cache/apt/archives -T "$TMPFILE" -cjf "$SERVERBACKUPFOLDER/incremental/$DEST/$F.tar.bz2"
        fi
        rm -f "$TMPFILE"
      fi
    fi
  done

  cd "$SERVERBACKUPFOLDER/incremental"
  mv runningnow.txt lastran.txt
  echo "End: $(date)" | tee -a "$LOGFILE"
  verify_backup "$SERVERBACKUPFOLDER/incremental/$DEST"
}

function rsyncIncremental() {
  check_requirements
  system_check
  check_backup_mount || return 1

  local RSYNCBASE="$SERVERBACKUPFOLDER/rsync_snapshots"
  local SRC="/"
  local SNAPDATE=$(date +"%Y%m%d_%H%M%S")
  local DEST="$RSYNCBASE/$SNAPDATE"

  mkdir -p "$RSYNCBASE"
  local LASTSNAP=$(find "$RSYNCBASE" -maxdepth 1 -type d | sort | tail -n 1)
  [[ "$LASTSNAP" == "$RSYNCBASE" ]] && LASTSNAP=""

  rsync -aAX --delete \
    --exclude={"/proc","/tmp","/mnt","/media","/dev","/sys","/run","/storage","/virtual"} \
    ${LASTSNAP:+--link-dest="$LASTSNAP"} \
    "$SRC" "$DEST"

  info "rsync incremental snapshot created at $DEST"
}

function restore_backup() {
  check_requirements
  system_check

  local TYPE
  TYPE=$(whiptail --title "Restore Type" --menu "Restore from:" 15 50 4 \
    "1" "Full Backup (.tar.bz2)" \
    "2" "Incremental Backup (.tar.bz2)" \
    "3" "rsync Snapshot" \
    3>&1 1>&2 2>&3)

  local DIR SELECTED
  case "$TYPE" in
    1) DIR="$SERVERBACKUPFOLDER/full" ;;
    2) DIR="$SERVERBACKUPFOLDER/incremental" ;;
    3) DIR="$SERVERBACKUPFOLDER/rsync_snapshots" ;;
    *) info "Invalid option."; return ;;
  esac

  local BACKUPS
  BACKUPS=$(ls -1 "$DIR" 2>/dev/null | sort)
  [[ -z "$BACKUPS" ]] && info "No backups found in $DIR." && return

  SELECTED=$(echo "$BACKUPS" | whiptail --title "Select Backup" --menu "Choose backup to restore:" 20 70 10 $(awk '{print NR, $0}' <<< "$BACKUPS") 3>&1 1>&2 2>&3)
  SELECTED=$(echo "$BACKUPS" | sed -n "${SELECTED}p")
  [[ -z "$SELECTED" ]] && info "No backup selected." && return

  whiptail --title "Confirm Restore" --yesno "This will overwrite system files from: $SELECTED. Proceed?" 10 60 || return

  case "$TYPE" in
    1|2)
      cd "$DIR/$SELECTED"
      for file in *.tar.bz2; do
        echo "Extracting $file to /"
        sudo tar xfj "$file" -C /
      done
      ;;
    3)
      echo "Restoring rsync snapshot from $DIR/$SELECTED..."
      sudo rsync -aAXv --delete "$DIR/$SELECTED"/ / | tee "/tmp/restore_rsync_${SELECTED}.log"
      ;;
  esac

  system_check
  info "Restore from $SELECTED completed. A reboot may be required."
}

function cleanup() {
  cd "${TMPFOLDER:-/tmp}"
  if ls *.pid &> /dev/null; then
    for p in *.pid; do
      if ! ps -p "$(cat "$p")" &> /dev/null; then
        backupfile=$(basename "$p" .pid)
        echo "Removing logs for $backupfile."
        rm "$backupfile".*
      fi
    done
  else
    echo "No logs to clear."
  fi
}
# --- Submenus ---
function setup_menu() {
  local OPTION=$(whiptail --title "System Setup" --menu "Choose a setup task:" 20 70 10 \
    "1" "Update & Upgrade System" \
    "2" "Install Essential Packages" \
    "3" "Install Developer Tools" \
    "4" "Setup Flatpak + Flathub" \
    "5" "Apply GNOME Tweaks" \
    "6" "Back to Main Menu" \
    3>&1 1>&2 2>&3)
  case "$OPTION" in
    1) update_upgrade ;;
    2) install_essentials ;;
    3) install_dev_tools ;;
    4) setup_flatpak ;;
    5) gnome_tweaks ;;
    6) return ;;
  esac
}

function backup_menu() {
  local OPTION=$(whiptail --title "Backup Options" --menu "Choose a backup method:" 20 70 10 \
    "1" "Full Backup (Local)" \
    "2" "pCloud Full Backup" \
    "3" "Incremental Backup (tar)" \
    "4" "Rsync Snapshot Backup" \
    "5" "Verify Last Full Backup" \
    "6" "Back to Main Menu" \
    3>&1 1>&2 2>&3)
  case "$OPTION" in
    1) fullBackup ;;
    2) pBackup ;;
    3) incrementalBackup ;;
    4) rsyncIncremental ;;
    5) verify_backup "$SERVERBACKUPFOLDER/full/$(ls "$SERVERBACKUPFOLDER/full" | sort | tail -n 1)" ;;
    6) return ;;
  esac
}

function security_menu() {
  local OPTION=$(whiptail --title "Security & Privacy" --menu "Manage network privacy:" 15 60 8 \
    "1" "Start Mask IP (tor/privoxy/squid)" \
    "2" "Stop Mask IP" \
    "3" "Status of Services" \
    "4" "Configure Firewall (UFW)" \
    "5" "Back to Main Menu" \
    3>&1 1>&2 2>&3)
  case "$OPTION" in
    1) start_mask_ip ;;
    2) stop_mask_ip ;;
    3) status_mask_ip ;;
    4) configure_ufw ;;
    5) return ;;
  esac
}

function maintenance_menu() {
  local OPTION=$(whiptail --title "Maintenance" --menu "System and backup maintenance:" 15 60 8 \
    "1" "Clean Backup Log Files" \
    "2" "Clean System (autoremove, logs)" \
    "3" "Back to Main Menu" \
    3>&1 1>&2 2>&3)
  case "$OPTION" in
    1) cleanup ;;
    2) clean_system ;;
    3) return ;;
  esac
}

# --- Main Menu ---
function main_menu() {
  while true; do
    CHOICE=$(whiptail --title "Deano's Ubuntu 24.04 Control Panel" --menu "Main Menu:" 20 70 10 \
      "1" "System Setup" \
      "2" "Backup Options" \
      "3" "Restore System" \
      "4" "Security & Privacy" \
      "5" "Maintenance & Cleanup" \
      "6" "Exit" \
      3>&1 1>&2 2>&3)
    case "$CHOICE" in
      1) setup_menu ;;
      2) backup_menu ;;
      3) restore_backup ;;
      4) security_menu ;;
      5) maintenance_menu ;;
      6) clear; exit ;;
      *) info "Invalid option." ;;
    esac
  done
}

# Start main menu
main_menu
