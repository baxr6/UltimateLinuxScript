#!/bin/bash

set -euo pipefail
trap "echo 'Script interrupted'; exit 1" INT TERM

### Backup CONFIG START ###
SERVERBACKUPFOLDER="/media/deano/HDD/Backup"
PCLOUDBACKUPFOLDER="/home/deano/pCloudDrive"
TMPFOLDER="/tmp"
NUMTOKEEP=5
EXCLUDE=("/lost+found" "/media" "/mnt" "/proc" "/sys" "/storage" "/virtual" "/home/deano/pCloudDrive")
readonly SERVICES=("tor" "privoxy" "squid")
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/backup-script"
### Backup CONFIG END ###

# Create log directory if it doesn't exist
sudo mkdir -p "$LOG_DIR"

# Logging function
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_DIR/script.log"
}

ensure_secure_dir() {
  local target_dir="$1"
  local dir_owner="${2:-$USER}"  # Optional second arg: owner, defaults to current user

  # Check if directory exists
  if [ ! -d "$target_dir" ]; then
    echo "Creating directory: $target_dir"
    mkdir -p "$target_dir" || {
      echo "❌ Failed to create directory: $target_dir"
      return 1
    }
  fi

  # Check write permission
  if [ ! -w "$target_dir" ]; then
    echo "❌ No write permission for: $target_dir"
    return 1
  fi

  # Set secure permissions and ownership
  chmod 700 "$target_dir"
  chown "$dir_owner":"$dir_owner" "$target_dir" 2>/dev/null || true

  echo "✅ Directory ready: $target_dir"
  return 0
}
# Ensure main backup folder
ensure_secure_dir "$SERVERBACKUPFOLDER" || exit 1

# Ensure subfolders
ensure_secure_dir "$SERVERBACKUPFOLDER/full" || exit 1
ensure_secure_dir "$SERVERBACKUPFOLDER/incremental" || exit 1

# Check if running as root (for certain operations)
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log "ERROR" "This script should not be run as root for safety reasons"
        exit 1
    fi
}

# Install whiptail if not available
if ! command -v whiptail &> /dev/null; then
    log "INFO" "Installing whiptail..."
    sudo apt install -y whiptail
fi



# Create marker file
touch "$SERVERBACKUPFOLDER/incremental/lastran.txt"

# --- Info ---
function info() {
    whiptail --title "Info" --msgbox "$1" 10 60
    log "INFO" "$1"
}

function error() {
    whiptail --title "Error" --msgbox "$1" 10 60
    log "ERROR" "$1"
}

function is_excluded() {
    local path="$1"
    for e in "${EXCLUDE[@]}"; do
        [[ "$path" == "$e" ]] && return 0
    done
    return 1
}

# --- Requirements Check ---
function check_requirements() {
    local reqs=(tar rsync sha256sum find whiptail df gsettings)
    local missing=()

    for cmd in "${reqs[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        error "Missing required commands: ${missing[*]}"
        log "ERROR" "Missing required commands: ${missing[*]}"
        return 1
    fi
    log "INFO" "All required commands are available"
}

# --- Progress bar function ---
function show_progress() {
    local current="$1"
    local total="$2"
    local message="$3"
    local percent=$((current * 100 / total))
    echo "$percent" | whiptail --gauge "$message" 6 50 0
}

# --- Backup Mount Checks ---
function p_check_backup_mount() {
    local MOUNTPOINT="$PCLOUDBACKUPFOLDER"
    
    if ! pgrep -x pcloud > /dev/null; then
        error "pCloud client is not running. Please start pCloud."
        return 1
    fi
    
    if [[ ! -d "$MOUNTPOINT" ]]; then
        error "pCloudDrive directory does not exist: $MOUNTPOINT"
        return 1
    fi
    
    if [[ ! -r "$MOUNTPOINT" ]]; then
        error "pCloudDrive is not readable: $MOUNTPOINT"
        return 1
    fi
    
    if [[ -z "$(ls -A "$MOUNTPOINT" 2>/dev/null)" ]]; then
        error "pCloudDrive appears to be empty: $MOUNTPOINT"
        return 1
    fi
    
    # Create backup directories
    mkdir -p "$MOUNTPOINT/full" "$MOUNTPOINT/incremental" || {
        error "Failed to create backup directories"
        return 1
    }
    
    if [[ ! -w "$MOUNTPOINT" ]]; then
        error "Backup folder not writable: $MOUNTPOINT"
        return 1
    fi
    
    log "INFO" "pCloud backup mount check passed"
}

function check_backup_mount() {
    local MOUNTPOINT="$SERVERBACKUPFOLDER"
    local PLACEHOLDER=".backup_placeholder"

    if [[ ! -d "$MOUNTPOINT" ]]; then
        error "Backup directory does not exist: $MOUNTPOINT"
        return 1
    fi

    if [[ ! -r "$MOUNTPOINT" ]]; then
        error "Backup directory is not readable: $MOUNTPOINT"
        return 1
    fi

    if [[ -z "$(ls -A "$MOUNTPOINT" 2>/dev/null)" ]]; then
        log "WARN" "Backup directory appears to be empty: $MOUNTPOINT"
        log "INFO" "Creating placeholder file $PLACEHOLDER"
        touch "$MOUNTPOINT/$PLACEHOLDER" || {
            error "Failed to create placeholder file in $MOUNTPOINT"
            return 1
        }
    fi

    # Create backup directories
    mkdir -p "$MOUNTPOINT/full" "$MOUNTPOINT/incremental" || {
        error "Failed to create backup directories"
        return 1
    }

    if [[ ! -w "$MOUNTPOINT" ]]; then
        error "Backup folder not writable: $MOUNTPOINT"
        return 1
    fi

    log "INFO" "Server backup mount check passed"
}


# --- Utility ---
function system_check() {
    log "INFO" "Performing system check..."
    
    # Check disk space
    local root_usage
    root_usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
    if [[ "$root_usage" -gt 90 ]]; then
        error "Root filesystem is ${root_usage}% full. Consider cleaning up before backup."
        return 1
    fi
    
    # Check for broken packages
    if ! sudo apt -f install --dry-run &>/dev/null; then
        error "System has broken packages. Fix with: sudo apt -f install"
        return 1
    fi
    
    # Check for failed services
    local failed_services
    failed_services=$(systemctl --failed --no-legend | wc -l)
    if [[ "$failed_services" -gt 0 ]]; then
        log "WARN" "$failed_services failed services detected"
    fi
    
    df -h /
    sleep 2
    log "INFO" "System check completed"
}

function update_upgrade() {
    log "INFO" "Starting system update..."
    
    if ! sudo apt update; then
        error "Failed to update package lists"
        return 1
    fi
    
    if ! sudo apt full-upgrade -y; then
        error "Failed to upgrade packages"
        return 1
    fi
    
    info "System updated successfully."
    log "INFO" "System update completed"
}

function install_essentials() {
    log "INFO" "Installing essential packages..."
    
    local essentials=(curl git vim gnome-tweaks build-essential unzip htop tree neofetch)
    
    if ! sudo apt install -y "${essentials[@]}"; then
        error "Failed to install essential packages"
        return 1
    fi
    
    info "Essential packages installed successfully."
    log "INFO" "Essential packages installation completed"
}

function install_dev_tools() {
    log "INFO" "Installing developer tools..."
    
    local dev_tools=(python3-pip nodejs npm docker.io docker-compose-v2 code)
    
    if ! sudo apt install -y "${dev_tools[@]}"; then
        error "Failed to install developer tools"
        return 1
    fi
    
    # Add user to docker group
    if ! sudo usermod -aG docker "$USER"; then
        error "Failed to add user to docker group"
        return 1
    fi
    
    info "Developer tools installed. Docker group added. Please log out and back in for Docker access."
    log "INFO" "Developer tools installation completed"
}

function configure_ufw() {
    log "INFO" "Configuring UFW firewall..."
    
    if ! sudo apt install -y ufw; then
        error "Failed to install UFW"
        return 1
    fi
    
    # Configure UFW rules
    sudo ufw --force enable
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    
    # Allow SSH (be careful with this)
    if whiptail --title "SSH Access" --yesno "Allow SSH (port 22) through firewall?" 10 60; then
        sudo ufw allow ssh
        log "INFO" "SSH access allowed through firewall"
    fi
    
    info "UFW firewall configured successfully."
    log "INFO" "UFW configuration completed"
}

function setup_flatpak() {
    log "INFO" "Setting up Flatpak..."
    
    if ! sudo apt install -y flatpak gnome-software-plugin-flatpak; then
        error "Failed to install Flatpak"
        return 1
    fi
    
    if ! flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo; then
        error "Failed to add Flathub repository"
        return 1
    fi
    
    info "Flatpak installed and configured successfully."
    log "INFO" "Flatpak setup completed"
}

function gnome_tweaks() {
    log "INFO" "Applying GNOME tweaks..."
    
    # Apply dark theme
    if ! gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark'; then
        log "WARN" "Failed to set dark theme"
    fi
    
    # Disable animations for better performance
    if ! gsettings set org.gnome.desktop.interface enable-animations false; then
        log "WARN" "Failed to disable animations"
    fi
    
    # Show battery percentage
    if ! gsettings set org.gnome.desktop.interface show-battery-percentage true; then
        log "WARN" "Failed to show battery percentage"
    fi
    
    info "GNOME tweaks applied successfully."
    log "INFO" "GNOME tweaks completed"
}

function clean_system() {
    log "INFO" "Cleaning system..."
    
    # Remove unused packages
    sudo apt autoremove -y
    
    # Clean package cache
    sudo apt clean
    
    # Clean system logs (keep last 3 days)
    sudo journalctl --vacuum-time=3d
    
    # Clean thumbnail cache
    rm -rf ~/.cache/thumbnails/*
    
    # Clean temporary files
    sudo find /tmp -type f -atime +7 -delete 2>/dev/null || true
    
    info "System cleaned successfully."
    log "INFO" "System cleaning completed"
}

function manage_services() {
    local action="$1"
    local success=true
    
    for service in "${SERVICES[@]}"; do
        if ! sudo systemctl "$action" "$service"; then
            log "ERROR" "Failed to $action service: $service"
            success=false
        else
            log "INFO" "Successfully ${action}ed service: $service"
        fi
    done
    
    if [[ "$success" == "true" ]]; then
        info "All services ${action}ed successfully."
    else
        error "Some services failed to $action. Check logs for details."
    fi
}

function start_mask_ip() {
    log "INFO" "Starting privacy services..."
    manage_services "start"
}

function stop_mask_ip() {
    log "INFO" "Stopping privacy services..."
    manage_services "stop"
}

function status_mask_ip() {
    log "INFO" "Checking service status..."
    
    local status_info=""
    for service in "${SERVICES[@]}"; do
        if systemctl is-active --quiet "$service"; then
            status_info+="$service: RUNNING\n"
        else
            status_info+="$service: STOPPED\n"
        fi
    done
    
    whiptail --title "Service Status" --msgbox "$status_info" 15 50
}

function rmOld() {
    local DIR="$1"
    local KEEP="$2"
    
    if [[ ! -d "$DIR" ]]; then
        log "ERROR" "Directory does not exist: $DIR"
        return 1
    fi
    
    cd "$DIR" || return 1
    
    # Get list of directories, excluding lastran
    mapfile -t DLIST < <(find . -maxdepth 1 -type d -name "[0-9]*" | sort -r)
    local DCOUNT=${#DLIST[@]}
    
    log "INFO" "Found $DCOUNT backup directories, keeping $KEEP"
    
    if (( DCOUNT > KEEP )); then
        for (( i=KEEP; i<DCOUNT; i++ )); do
            if [[ -d "${DLIST[i]}" ]]; then
                log "INFO" "Removing old backup: ${DLIST[i]}"
                rm -rf -- "${DLIST[i]}"
            fi
        done
    fi
}

function verify_backup() {
    local target="$1"
    
    if [[ ! -d "$target" ]]; then
        error "Backup directory does not exist: $target"
        return 1
    fi
    
    log "INFO" "Verifying backup in: $target"
    
    cd "$target" || return 1
    
    # Generate checksums
    find . -name '*.tar.bz2' -exec sha256sum {} \; > SHA256SUMS.txt
    
    # Verify checksums
    if sha256sum -c SHA256SUMS.txt > verify.log 2>&1; then
        if grep -q 'FAILED' verify.log; then
            error "Backup verification FAILED. Check verify.log in $target"
            return 1
        else
            info "Backup verified successfully."
            log "INFO" "Backup verification completed successfully"
        fi
    else
        error "Backup verification failed. Check verify.log in $target"
        return 1
    fi
}

function pBackup() {
    log "INFO" "Starting pCloud backup..."
    
    check_requirements || return 1
    system_check || return 1
    p_check_backup_mount || return 1

    local LOGFILE="${PCLOUDBACKUPFOLDER}/full/backup-$(date +%Y%m%d_%H%M%S).log"
    local START_TIME=$(date)
    
    {
        echo "=== pCloud Backup Started ==="
        echo "Start time: $START_TIME"
        echo "Target: $PCLOUDBACKUPFOLDER"
        echo "Source: /home/deano"
        echo "=========================="
        df -h "$PCLOUDBACKUPFOLDER"
        echo ""
    } | tee -a "$LOGFILE"

    # Setup folders
    mkdir -p "$PCLOUDBACKUPFOLDER/full" "$PCLOUDBACKUPFOLDER/incremental"
    touch "$PCLOUDBACKUPFOLDER/incremental/lastran.txt"

    local BDIR=$(date +"%Y%m%d_%H%M")
    local TARGETDIR="$PCLOUDBACKUPFOLDER/full/$BDIR"
    mkdir -p "$TARGETDIR"
    
    # Create restore instructions
    cat > "$TARGETDIR/restore.txt" << EOF
Restore Instructions:
1. Extract the backup: tar -xjf deano.tar.bz2 -C /
2. Fix permissions: sudo chown -R deano:deano /home/deano
3. Reboot the system
4. Verify restoration was successful

Backup created: $(date)
Source: /home/deano
EOF

    echo "Creating tar archive of /home/deano..." | tee -a "$LOGFILE"
    
    if tar --ignore-failed-read --warning=no-file-changed \
           --exclude="/home/deano/.cache" \
           --exclude="/home/deano/.local/share/Trash" \
           -cjf "$TARGETDIR/deano.tar.bz2" /home/deano; then
        echo "Backup archive created successfully" | tee -a "$LOGFILE"
    else
        echo "WARNING: Some files may have been skipped during backup" | tee -a "$LOGFILE"
    fi

    # Check backup size and cleanup if needed
    local DSIZE=$(du -sm "$TARGETDIR" | awk '{print $1}')
    echo "Backup size: ${DSIZE}MB" | tee -a "$LOGFILE"
    
    if [[ "$DSIZE" -gt 100 ]]; then  # Reasonable size for home directory
        rmOld "$PCLOUDBACKUPFOLDER/full" "$NUMTOKEEP"
        echo "Cleared old backups, keeping $NUMTOKEEP most recent" | tee -a "$LOGFILE"
    else
        echo "WARNING: Backup size seems too small (${DSIZE}MB) - please verify!" | tee -a "$LOGFILE"
    fi

    verify_backup "$TARGETDIR"
    
    echo "End time: $(date)" | tee -a "$LOGFILE"
    log "INFO" "pCloud backup completed"
}

function fullBackup() {
    log "INFO" "Starting full system backup..."
    
    check_requirements || return 1
    system_check || return 1
    check_backup_mount || return 1

    local LOGFILE="${SERVERBACKUPFOLDER}/full/backup-$(date +%Y%m%d_%H%M%S).log"
    local START_TIME=$(date)
    
    {
        echo "=== Full System Backup Started ==="
        echo "Start time: $START_TIME"
        echo "Target: $SERVERBACKUPFOLDER"
        echo "Source: / (excluding: ${EXCLUDE[*]})"
        echo "=============================="
        df -h "$SERVERBACKUPFOLDER"
        echo ""
    } | tee -a "$LOGFILE"

    # Create required folders
    mkdir -p "$SERVERBACKUPFOLDER/full" "$SERVERBACKUPFOLDER/incremental"
    touch "$SERVERBACKUPFOLDER/incremental/lastran.txt"

    # Create timestamped backup directory
    local BDIR=$(date +"%Y%m%d_%H%M")
    local TARGETDIR="$SERVERBACKUPFOLDER/full/$BDIR"
    mkdir -p "$TARGETDIR"
    
    # Create restore instructions
    cat > "$TARGETDIR/restore.txt" << EOF
Full System Restore Instructions:
1. Boot from live USB/CD
2. Mount target drive and navigate to this backup directory
3. Extract each .tar.bz2 file: tar -xjf <file> -C /mnt/target
4. Reinstall bootloader: grub-install /dev/sdX
5. Update grub: update-grub
6. Reboot into restored system

Backup created: $(date)
Files in this backup:
EOF

    # Loop through all top-level folders in /
    local FOLDERS=(/*)
    local total_folders=${#FOLDERS[@]}
    local current_folder=0
    
    for F in "${FOLDERS[@]}"; do
        current_folder=$((current_folder + 1))
        
        if ! is_excluded "$F"; then
            local NAME=$(basename "$F")
            echo "[$current_folder/$total_folders] Processing $F..." | tee -a "$LOGFILE"
            
            if sudo tar --exclude=/swapfile \
                   --exclude=/var/cache/apt/archives \
                   --exclude=/tmp/* \
                   --exclude=/var/tmp/* \
                   -cjf "$TARGETDIR/$NAME.tar.bz2" "$F" 2>>"$LOGFILE"; then
                echo "$NAME.tar.bz2 - SUCCESS" | tee -a "$LOGFILE"
                echo "$NAME.tar.bz2" >> "$TARGETDIR/restore.txt"
            else
                echo "$NAME.tar.bz2 - FAILED (check log)" | tee -a "$LOGFILE"
            fi
        else
            echo "[$current_folder/$total_folders] Skipping excluded directory: $F" | tee -a "$LOGFILE"
        fi
    done

    # Check backup size and cleanup old backups if needed
    local DSIZE=$(du -sm "$TARGETDIR" | awk '{print $1}')
    echo "Total backup size: ${DSIZE}MB" | tee -a "$LOGFILE"
    
    if [[ "$DSIZE" -gt 1000 ]]; then  # 1GB threshold
        rmOld "$SERVERBACKUPFOLDER/full" "$NUMTOKEEP"
        echo "Cleared old backups and incremental backups" | tee -a "$LOGFILE"
        rm -rf "$SERVERBACKUPFOLDER/incremental/"*
    else
        echo "WARNING: Backup size seems too small (${DSIZE}MB) - please verify!" | tee -a "$LOGFILE"
    fi

    verify_backup "$TARGETDIR"
    
    echo "End time: $(date)" | tee -a "$LOGFILE"
    log "INFO" "Full system backup completed"
}

function incrementalBackup() {
    log "INFO" "Starting incremental backup..."
    
    check_requirements || return 1
    system_check || return 1
    check_backup_mount || return 1

    local LOGFILE="${SERVERBACKUPFOLDER}/incremental/backup-$(date +%Y%m%d_%H%M%S).log"
    
    {
        echo "=== Incremental Backup Started ==="
        echo "Start time: $(date)"
        echo "Target: $SERVERBACKUPFOLDER/incremental"
        echo "=============================="
        df -h "$SERVERBACKUPFOLDER"
        echo ""
    } | tee -a "$LOGFILE"
    
    cd "$SERVERBACKUPFOLDER/incremental" || return 1
    touch runningnow.txt
    
    # If no lastran.txt exists, copy from full backup
    if [[ ! -f lastran.txt ]]; then
        if [[ -f "$SERVERBACKUPFOLDER/full/lastran.txt" ]]; then
            cp "$SERVERBACKUPFOLDER/full/lastran.txt" .
        else
            # Create a timestamp from 24 hours ago as fallback
            touch -d "yesterday" lastran.txt
        fi
    fi

    local BDIR=$(date +"%Y%m%d_%H%M%S")
    local DEST="$BDIR"
    local i=1
    
    # Ensure unique directory name
    while [[ -d "$DEST" ]]; do
        DEST="${BDIR}_$i"
        i=$((i + 1))
    done
    
    mkdir "$DEST"
    cd / || return 1

    # Process each top-level directory
    local FOLDERS=(/*)
    local files_found=false
    
    for F in "${FOLDERS[@]}"; do
        if ! is_excluded "$F"; then
            local NAME=$(basename "$F")
            echo "Checking $NAME for changes since last backup..." | tee -a "$LOGFILE"
            
            # Find files newer than last backup
            local FILELIST
            FILELIST=$(find "$F" -newer "$SERVERBACKUPFOLDER/incremental/lastran.txt" -type f 2>/dev/null | head -10000)
            
            if [[ -n "$FILELIST" ]]; then
                files_found=true
                local TMPFILE
                TMPFILE=$(mktemp)
                echo "$FILELIST" | tr '\n' '\0' > "$TMPFILE"
                
                if [[ -s "$TMPFILE" ]]; then
                    echo "Creating incremental archive for $NAME..." | tee -a "$LOGFILE"
                    
                    if sudo tar --null \
                           --exclude=/swapfile \
                           --exclude=/var/cache/apt/archives \
                           -T "$TMPFILE" \
                           -cjf "$SERVERBACKUPFOLDER/incremental/$DEST/$NAME.tar.bz2" 2>>"$LOGFILE"; then
                        echo "$NAME.tar.bz2 created successfully" | tee -a "$LOGFILE"
                    else
                        echo "WARNING: Issues creating $NAME.tar.bz2" | tee -a "$LOGFILE"
                    fi
                fi
                rm -f "$TMPFILE"
            fi
        fi
    done

    cd "$SERVERBACKUPFOLDER/incremental" || return 1
    
    if [[ "$files_found" == "true" ]]; then
        mv runningnow.txt lastran.txt
        echo "Incremental backup completed with changes" | tee -a "$LOGFILE"
        verify_backup "$SERVERBACKUPFOLDER/incremental/$DEST"
    else
        rm -rf "$DEST"
        mv runningnow.txt lastran.txt
        echo "No changes found since last backup" | tee -a "$LOGFILE"
    fi
    
    echo "End time: $(date)" | tee -a "$LOGFILE"
    log "INFO" "Incremental backup completed"
}

function rsyncIncremental() {
    log "INFO" "Starting rsync incremental backup..."
    
    check_requirements || return 1
    system_check || return 1
    check_backup_mount || return 1

    local RSYNCBASE="$SERVERBACKUPFOLDER/rsync_snapshots"
    local SRC="/"
    local SNAPDATE=$(date +"%Y%m%d_%H%M%S")
    local DEST="$RSYNCBASE/$SNAPDATE"
    local LOGFILE="$RSYNCBASE/rsync_${SNAPDATE}.log"

    sudo mkdir -p "$RSYNCBASE"
    
    # Find the most recent snapshot for hard linking
    local LASTSNAP
    LASTSNAP=$(find "$RSYNCBASE" -maxdepth 1 -type d -name "[0-9]*" | sort | tail -n 1)
    
    log "INFO" "Creating rsync snapshot: $DEST"
    
    if [[ -n "$LASTSNAP" && -d "$LASTSNAP" ]]; then
        log "INFO" "Using previous snapshot for hard linking: $LASTSNAP"
        
        sudo rsync -aAX --delete --human-readable --progress \
            --exclude={"/proc/*","/tmp/*","/mnt/*","/media/*","/dev/*","/sys/*","/run/*","/storage/*","/virtual/*"} \
            --link-dest="$LASTSNAP" \
            "$SRC" "$DEST" 2>&1 | tee "$LOGFILE"
    else
        log "INFO" "No previous snapshot found, creating initial snapshot"
        
        sudo rsync -aAX --delete --human-readable --progress \
            --exclude={"/proc/*","/tmp/*","/mnt/*","/media/*","/dev/*","/sys/*","/run/*","/storage/*","/virtual/*"} \
            "$SRC" "$DEST" 2>&1 | tee "$LOGFILE"
    fi

    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        info "Rsync incremental snapshot created successfully at $DEST"
        log "INFO" "Rsync snapshot completed successfully"
        
        # Cleanup old snapshots
        rmOld "$RSYNCBASE" "$NUMTOKEEP"
    else
        error "Rsync snapshot failed. Check log: $LOGFILE"
        log "ERROR" "Rsync snapshot failed"
        return 1
    fi
}

function restore_backup() {
    log "INFO" "Starting backup restore process..."
    
    check_requirements || return 1
    
    # Warning about restoration
    if ! whiptail --title "WARNING" --yesno "Backup restoration can overwrite system files and may cause data loss. Are you sure you want to continue?" 10 60; then
        return 0
    fi

    local TYPE
    TYPE=$(whiptail --title "Restore Type" --menu "Select backup type to restore:" 15 60 4 \
        "1" "Full Backup (.tar.bz2)" \
        "2" "Incremental Backup (.tar.bz2)" \
        "3" "Rsync Snapshot" \
        3>&1 1>&2 2>&3)

    local DIR SELECTED
    case "$TYPE" in
        1) DIR="$SERVERBACKUPFOLDER/full" ;;
        2) DIR="$SERVERBACKUPFOLDER/incremental" ;;
        3) DIR="$SERVERBACKUPFOLDER/rsync_snapshots" ;;
        *) info "Invalid selection."; return ;;
    esac

    if [[ ! -d "$DIR" ]]; then
        error "Backup directory not found: $DIR"
        return 1
    fi

    # Get list of available backups
    local BACKUPS
    BACKUPS=$(find "$DIR" -maxdepth 1 -type d -name "[0-9]*" | sort -r)
    
    if [[ -z "$BACKUPS" ]]; then
        error "No backups found in $DIR"
        return 1
    fi

    # Create menu options
    local MENU_OPTIONS=()
    local i=1
    while IFS= read -r backup; do
        local backup_name=$(basename "$backup")
        local backup_date=$(date -d "${backup_name:0:8}" "+%Y-%m-%d" 2>/dev/null || echo "Unknown")
        MENU_OPTIONS+=("$i" "$backup_name ($backup_date)")
        i=$((i + 1))
    done <<< "$BACKUPS"

    local SELECTION
    SELECTION=$(whiptail --title "Select Backup" --menu "Choose backup to restore:" 20 80 10 "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)
    
    if [[ -z "$SELECTION" ]]; then
        info "No backup selected."
        return 0
    fi

    # Get selected backup path
    SELECTED=$(echo "$BACKUPS" | sed -n "${SELECTION}p")
    local BACKUP_NAME=$(basename "$SELECTED")
    
    # Final confirmation
    if ! whiptail --title "Confirm Restore" --yesno "This will restore from backup: $BACKUP_NAME\n\nThis operation may overwrite existing files. Continue?" 12 60; then
        return 0
    fi

    log "INFO" "Starting restore from: $SELECTED"

    case "$TYPE" in
        1|2)
            cd "$SELECTED" || return 1
            for file in *.tar.bz2; do
                if [[ -f "$file" ]]; then
                    echo "Extracting $file..."
                    if sudo tar -xjf "$file" -C /; then
                        log "INFO" "Successfully extracted: $file"
                    else
                        log "ERROR" "Failed to extract: $file"
                    fi
                fi
            done
            ;;
        3)
            echo "Restoring rsync snapshot from $SELECTED..."
            if sudo rsync -aAXv --delete "$SELECTED"/ / 2>&1 | tee "/tmp/restore_rsync_${BACKUP_NAME}.log"; then
                log "INFO" "Rsync restore completed successfully"
            else
                log "ERROR" "Rsync restore failed"
                return 1
            fi
            ;;
    esac

    # Post-restore system check
    echo "Performing post-restore system check..."
    system_check
    
    info "Restore from $BACKUP_NAME completed. A system reboot is recommended."
    log "INFO" "Restore operation completed"
}

function cleanup() {
    log "INFO" "Starting cleanup process..."
    
    local temp_dir="${TMPFOLDER:-/tmp}"
    cd "$temp_dir" || return 1
    
    local cleaned=0
    
    # Clean up old PID files
    if ls *.pid &> /dev/null; then
        for pidfile in *.pid; do
            if [[ -f "$pidfile" ]]; then
                local pid=$(cat "$pidfile" 2>/dev/null)
                if [[ -n "$pid" ]] && ! ps -p "$pid" &> /dev/null; then
                    local basename=$(basename "$pidfile" .pid)
                    echo "Removing stale logs for $basename..."
                    rm -f "$basename".*
                    cleaned=$((cleaned + 1))
                fi
            fi
        done
    fi
    
    # Clean up old temporary backup files
    find "$temp_dir" -name "backup_*" -type f -mtime +7 -delete 2>/dev/null || true
    find "$temp_dir" -name "files-to-backup.*" -type f -mtime +1 -delete 2>/dev/null || true
    
    if [[ $cleaned -gt 0 ]]; then
        info "Cleaned up $cleaned stale log files."
    else
        info "No stale log files found to clean."
    fi
    
    log "INFO" "Cleanup process completed"
}

function view_logs() {
    log "INFO" "Viewing system logs..."
    
    local LOG_TYPE
    LOG_TYPE=$(whiptail --title "View Logs" --menu "Select log type:" 15 60 5 \
        "1" "Script Logs" \
        "2" "System Logs (journalctl)" \
        "3" "Backup Logs" \
        "4" "Failed Services" \
        "5" "Back to Menu" \
        3>&1 1>&2 2>&3)
    
    case "$LOG_TYPE" in
        1)
            if [[ -f "$LOG_DIR/script.log" ]]; then
                whiptail --title "Script Logs" --textbox "$LOG_DIR/script.log" 20 80
            else
                info "No script logs found."
            fi
            ;;
        2)
            local temp_log="/tmp/system_logs_$(date +%s).txt"
            journalctl --since "1 hour ago" --no-pager > "$temp_log"
            whiptail --title "System Logs (Last Hour)" --textbox "$temp_log" 20 80
            rm -f "$temp_log"
            ;;
        3)
            local backup_logs_dir
            if [[ -d "$SERVERBACKUPFOLDER/full" ]]; then
                backup_logs_dir="$SERVERBACKUPFOLDER/full"
            elif [[ -d "$PCLOUDBACKUPFOLDER/full" ]]; then
                backup_logs_dir="$PCLOUDBACKUPFOLDER/full"
            else
                info "No backup logs directory found."
                return
            fi
            
            local latest_log
            latest_log=$(find "$backup_logs_dir" -name "*.log" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
            
            if [[ -n "$latest_log" && -f "$latest_log" ]]; then
                whiptail --title "Latest Backup Log" --textbox "$latest_log" 20 80
            else
                info "No backup logs found."
            fi
            ;;
        4)
            local temp_failed="/tmp/failed_services_$(date +%s).txt"
            systemctl --failed --no-pager > "$temp_failed"
            whiptail --title "Failed Services" --textbox "$temp_failed" 20 80
            rm -f "$temp_failed"
            ;;
        5)
            return
            ;;
    esac
}

function disk_usage() {
    log "INFO" "Checking disk usage..."
    
    local temp_disk="/tmp/disk_usage_$(date +%s).txt"
    
    {
        echo "=== DISK USAGE REPORT ==="
        echo "Generated: $(date)"
        echo ""
        echo "=== FILESYSTEM USAGE ==="
        df -h
        echo ""
        echo "=== LARGEST DIRECTORIES IN / ==="
        sudo du -h --max-depth=1 / 2>/dev/null | sort -hr | head -20
        echo ""
        echo "=== LARGEST FILES IN /var/log ==="
        sudo find /var/log -type f -exec du -h {} + 2>/dev/null | sort -hr | head -10
        echo ""
        echo "=== BACKUP DIRECTORIES ==="
        if [[ -d "$SERVERBACKUPFOLDER" ]]; then
            echo "Server backup folder: $SERVERBACKUPFOLDER"
            du -h --max-depth=2 "$SERVERBACKUPFOLDER" 2>/dev/null || echo "Unable to access server backup folder"
        fi
        if [[ -d "$PCLOUDBACKUPFOLDER" ]]; then
            echo "pCloud backup folder: $PCLOUDBACKUPFOLDER"
            du -h --max-depth=2 "$PCLOUDBACKUPFOLDER" 2>/dev/null || echo "Unable to access pCloud backup folder"
        fi
    } > "$temp_disk"
    
    whiptail --title "Disk Usage Report" --textbox "$temp_disk" 25 100
    rm -f "$temp_disk"
}

function schedule_backup() {
    log "INFO" "Setting up backup scheduling..."
    
    local BACKUP_TYPE
    BACKUP_TYPE=$(whiptail --title "Schedule Backup" --menu "Select backup type to schedule:" 15 60 4 \
        "1" "Full Backup (Weekly)" \
        "2" "Incremental Backup (Daily)" \
        "3" "pCloud Backup (Daily)" \
        "4" "View/Remove Scheduled Backups" \
        3>&1 1>&2 2>&3)
    
    case "$BACKUP_TYPE" in
        1)
            local cron_entry="0 2 * * 0 $SCRIPT_DIR/$(basename "$0") --auto-full-backup"
            (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
            info "Full backup scheduled for every Sunday at 2:00 AM"
            ;;
        2)
            local cron_entry="0 3 * * * $SCRIPT_DIR/$(basename "$0") --auto-incremental-backup"
            (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
            info "Incremental backup scheduled for every day at 3:00 AM"
            ;;
        3)
            local cron_entry="0 4 * * * $SCRIPT_DIR/$(basename "$0") --auto-pcloud-backup"
            (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
            info "pCloud backup scheduled for every day at 4:00 AM"
            ;;
        4)
            local temp_cron="/tmp/current_cron_$(date +%s).txt"
            crontab -l > "$temp_cron" 2>/dev/null || echo "No scheduled jobs found" > "$temp_cron"
            whiptail --title "Current Scheduled Backups" --textbox "$temp_cron" 20 80
            rm -f "$temp_cron"
            ;;
    esac
}

# --- Submenus ---
function setup_menu() {
    while true; do
        local OPTION
        OPTION=$(whiptail --title "System Setup" --menu "Choose a setup task:" 20 70 10 \
            "1" "Update & Upgrade System" \
            "2" "Install Essential Packages" \
            "3" "Install Developer Tools" \
            "4" "Setup Flatpak + Flathub" \
            "5" "Apply GNOME Tweaks" \
            "6" "Configure Firewall (UFW)" \
            "7" "Back to Main Menu" \
            3>&1 1>&2 2>&3)
        
        case "$OPTION" in
            1) update_upgrade ;;
            2) install_essentials ;;
            3) install_dev_tools ;;
            4) setup_flatpak ;;
            5) gnome_tweaks ;;
            6) configure_ufw ;;
            7) return ;;
            *) return ;;
        esac
    done
}

function backup_menu() {
    while true; do
        local OPTION
        OPTION=$(whiptail --title "Backup Options" --menu "Choose a backup method:" 20 70 10 \
            "1" "Full System Backup" \
            "2" "pCloud Home Backup" \
            "3" "Incremental Backup" \
            "4" "Rsync Snapshot Backup" \
            "5" "Verify Latest Backup" \
            "6" "Schedule Automatic Backups" \
            "7" "Back to Main Menu" \
            3>&1 1>&2 2>&3)
        
        case "$OPTION" in
            1) fullBackup ;;
            2) pBackup ;;
            3) incrementalBackup ;;
            4) rsyncIncremental ;;
            5) 
                local latest_full
                latest_full=$(find "$SERVERBACKUPFOLDER/full" -maxdepth 1 -type d -name "[0-9]*" | sort | tail -1)
                if [[ -n "$latest_full" ]]; then
                    verify_backup "$latest_full"
                else
                    error "No full backups found to verify."
                fi
                ;;
            6) schedule_backup ;;
            7) return ;;
            *) return ;;
        esac
    done
}

function security_menu() {
    while true; do
        local OPTION
        OPTION=$(whiptail --title "Security & Privacy" --menu "Manage security settings:" 15 70 8 \
            "1" "Start Privacy Services" \
            "2" "Stop Privacy Services" \
            "3" "Check Service Status" \
            "4" "Configure Firewall" \
            "5" "View Security Logs" \
            "6" "Back to Main Menu" \
            3>&1 1>&2 2>&3)
        
        case "$OPTION" in
            1) start_mask_ip ;;
            2) stop_mask_ip ;;
            3) status_mask_ip ;;
            4) configure_ufw ;;
            5) 
                local temp_security="/tmp/security_logs_$(date +%s).txt"
                journalctl -u ufw -u tor -u privoxy -u squid --since "1 day ago" --no-pager > "$temp_security"
                whiptail --title "Security Logs" --textbox "$temp_security" 20 80
                rm -f "$temp_security"
                ;;
            6) return ;;
            *) return ;;
        esac
    done
}

function maintenance_menu() {
    while true; do
        local OPTION
        OPTION=$(whiptail --title "Maintenance" --menu "System maintenance options:" 15 70 8 \
            "1" "Clean System" \
            "2" "Clean Backup Files" \
            "3" "View System Logs" \
            "4" "Check Disk Usage" \
            "5" "System Health Check" \
            "6" "Back to Main Menu" \
            3>&1 1>&2 2>&3)
        
        case "$OPTION" in
            1) clean_system ;;
            2) cleanup ;;
            3) view_logs ;;
            4) disk_usage ;;
            5) system_check ;;
            6) return ;;
            *) return ;;
        esac
    done
}

# --- Main Menu ---
function main_menu() {
    while true; do
        local CHOICE
        CHOICE=$(whiptail --title "Deano's Ubuntu 24.04 Control Panel v2.0" --menu "Select an option:" 20 80 10 \
            "1" "System Setup & Installation" \
            "2" "Backup Management" \
            "3" "System Restoration" \
            "4" "Security & Privacy" \
            "5" "Maintenance & Logs" \
            "6" "Exit" \
            3>&1 1>&2 2>&3)
        
        case "$CHOICE" in
            1) setup_menu ;;
            2) backup_menu ;;
            3) restore_backup ;;
            4) security_menu ;;
            5) maintenance_menu ;;
            6) 
                log "INFO" "Script exiting normally"
                clear
                echo "Thanks for using Deano's Ubuntu Control Panel!"
                exit 0
                ;;
            *) 
                if whiptail --title "Exit" --yesno "Are you sure you want to exit?" 8 50; then
                    log "INFO" "Script exiting normally"
                    clear
                    exit 0
                fi
                ;;
        esac
    done
}

# --- Command Line Arguments ---
function handle_arguments() {
    case "${1:-}" in
        --auto-full-backup)
            log "INFO" "Starting automated full backup"
            fullBackup
            exit $?
            ;;
        --auto-incremental-backup)
            log "INFO" "Starting automated incremental backup"
            incrementalBackup
            exit $?
            ;;
        --auto-pcloud-backup)
            log "INFO" "Starting automated pCloud backup"
            pBackup
            exit $?
            ;;
        --system-check)
            system_check
            exit $?
            ;;
        --help|-h)
            echo "Ubuntu Management Script v2.0"
            echo ""
            echo "Usage: $0 [OPTION]"
            echo ""
            echo "Options:"
            echo "  --auto-full-backup         Run full backup (for cron)"
            echo "  --auto-incremental-backup  Run incremental backup (for cron)"
            echo "  --auto-pcloud-backup       Run pCloud backup (for cron)"
            echo "  --system-check             Run system health check"
            echo "  --help, -h                 Show this help message"
            echo ""
            echo "Without options, starts interactive menu."
            exit 0
            ;;
        "")
            # No arguments, proceed to main menu
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
}

# --- Main Execution ---
function main() {
    # Check if running as root
    check_root
    
    # Handle command line arguments
    handle_arguments "$@"
    
    # Start main menu if no arguments
    log "INFO" "Starting Ubuntu Management Script v2.0"
    echo ">>> Launching Ubuntu Control Panel..."
    main_menu
}

# Run main function with all arguments
main "$@"
