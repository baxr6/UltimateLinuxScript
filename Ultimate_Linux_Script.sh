#!/bin/bash

set -euo pipefail
trap "echo 'Script interrupted'; exit 1" INT TERM

### Backup CONFIG START ###
SERVERBACKUPFOLDER="/media/deano/HDD1/Backup"
TMPFOLDER="/tmp"
NUMTOKEEP=5
EXCLUDE=("/lost+found" "/media" "/mnt" "/proc" "/sys" "/storage" "/virtual")
### Backup CONFIG END ###

if ! command -v whiptail &> /dev/null; then
  sudo apt install -y whiptail
fi

function info() {
  whiptail --title "Info" --msgbox "$1" 10 60
}

function check_requirements() {
  local reqs=(tar rsync sha256sum find whiptail df gsettings)
  for cmd in "${reqs[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      info "Required command '$cmd' not found. Please install it."
      exit 1
    fi
  done
}

function check_backup_mount() {
  local PARENTMOUNT
  PARENTMOUNT=$(dirname "$SERVERBACKUPFOLDER")
  if ! mountpoint -q "$PARENTMOUNT"; then
    info "Parent drive is not mounted. Expected mount at: $PARENTMOUNT"
    return 1
  fi
  if [[ ! -d "$SERVERBACKUPFOLDER" ]]; then
    mkdir -p "$SERVERBACKUPFOLDER" || {
      info "Failed to create backup folder at $SERVERBACKUPFOLDER"
      return 1
    }
  fi
  if [[ ! -w "$SERVERBACKUPFOLDER" ]]; then
    info "Backup folder exists but is not writable: $SERVERBACKUPFOLDER"
    return 1
  fi
}

function system_check() {
  echo "Running system health checks..."
  df -h /
  sudo apt -f install --dry-run
  systemctl --failed
  sleep 3
}

function update_upgrade() {
  sudo apt update && sudo apt full-upgrade -y
  info "System updated successfully."
}

function install_essentials() {
  info "Installing curl git vim gnome-tweaks build-essential unzip htop."
  sudo apt install -y curl git vim gnome-tweaks build-essential unzip htop
  info "Essential packages installed."
}

function install_dev_tools() {
  sudo apt install -y python3-pip nodejs npm docker.io docker-compose
  sudo usermod -aG docker "$USER"
  info "Developer tools installed. Docker group added (reboot may be needed)."
}

function configure_ufw() {
  sudo apt install -y ufw
  sudo ufw enable
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  info "UFW configured with default deny/allow."
}

function setup_flatpak() {
  sudo apt install -y flatpak gnome-software-plugin-flatpak
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  info "Flatpak and Flathub installed."
}

function gnome_tweaks() {
  gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark'
  gsettings set org.gnome.desktop.interface enable-animations false
  info "GNOME tweaks applied (dark theme, no animations)."
}

function clean_system() {
  sudo apt autoremove -y
  sudo apt clean
  sudo journalctl --vacuum-time=7d
  info "System cleaned up."
}

function rmOld {
  local DIR="$1"
  local KEEP="$2"
  cd "$DIR" || return 1
  mapfile -t DLIST < <(ls -td */ 2>/dev/null | grep -v lastran | sed 's:/*$::')
  local DCOUNT=${#DLIST[@]}
  if (( DCOUNT > KEEP )); then
    for (( i=KEEP; i<DCOUNT; i++ )); do
      if [[ -d "${DLIST[i]}" && "${DLIST[i]}" != "" ]]; then
        echo "Removing ${DLIST[i]}"
        rm -rf -- "${DLIST[i]}"
      fi
    done
  fi
}

function verify_backup() {
  local target="$1"
  echo "Verifying backup in: $target"
  cd "$target"
  find . -name '*.tar.bz2' -exec sha256sum {} \; > SHA256SUMS.txt
  sha256sum -c SHA256SUMS.txt > verify.log
  info "Backup verification completed. Check verify.log for details."
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

# Menu loop
while true; do
  OPTION=$(whiptail --title "Deano's Ubuntu 24.04 Setup Menu" --menu "Choose an option:" 20 70 12 \
    "1" "Update & Upgrade System" \
    "2" "Install Essential Packages" \
    "3" "Install Developer Tools" \
    "4" "Configure Firewall (UFW)" \
    "5" "Setup Flatpak + Flathub" \
    "6" "Apply GNOME Tweaks" \
    "7" "Full Backup" \
    "8" "Incremental Backup (tar)" \
    "9" "Clean Backup Log Files" \
    "10" "Clean System" \
    "11" "Verify Last Full Backup" \
    "12" "Restore System Backup" \
    "13" "Rsync Incremental Snapshot" \
    "14" "Exit" \
    3>&1 1>&2 2>&3)

  case "$OPTION" in
    1) update_upgrade ;;
    2) install_essentials ;;
    3) install_dev_tools ;;
    4) configure_ufw ;;
    5) setup_flatpak ;;
    6) gnome_tweaks ;;
    7) fullBackup ;;
    8) incrementalBackup ;;
    9) cleanup ;;
    10) clean_system ;;
    11) verify_backup "$SERVERBACKUPFOLDER/full/$(ls "$SERVERBACKUPFOLDER/full" | sort | tail -n 1)" ;;
    12) restore_backup ;;
    13) rsyncIncremental ;;
    14) clear; exit ;;
    *) info "Invalid option." ;;
  esac
done

