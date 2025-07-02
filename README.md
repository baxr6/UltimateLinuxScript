# 🛠️ Deano's Ubuntu 24.04 Setup & Backup Script

A robust and interactive Bash script for setting up and maintaining Ubuntu 24.04 systems. Includes full and incremental backup options, system tweaks, developer tool installation, GNOME settings, and more — all driven by a terminal UI using `whiptail`.

---

## 📦 Features

- **System Maintenance**
  - Update & upgrade
  - Clean system and old logs
  - Apply GNOME desktop tweaks

- **Package Installation**
  - Essential packages (`curl`, `vim`, `git`, `htop`, etc.)
  - Developer tools (`docker`, `node`, `pip`, etc.)
  - Flatpak and Flathub setup

- **Security**
  - Configure UFW firewall with sane defaults

- **Backup & Restore**
  - Full system backups (`.tar.bz2`)
  - Incremental backups based on modified files
  - Rsync snapshot backups with link-deduplication
  - SHA256 checksum-based verification
  - Restore from any backup format

- **Menu-driven Interface**
  - Easy to use, even for less experienced users
  - Whiptail-powered TUI (Text UI)

---

## ⚙️ Configuration

Located near the top of the script:

```bash
SERVERBACKUPFOLDER="/media/deano/HDD1/Backup"
TMPFOLDER="/tmp"
NUMTOKEEP=5
EXCLUDE=("/lost+found" "/media" "/mnt" "/proc" "/sys" "/storage" "/virtual")

    Ensure the SERVERBACKUPFOLDER points to your desired external or mounted backup location.

    Modify EXCLUDE to skip any folders during backup (useful for volatile or irrelevant paths).

🚀 How to Use
1. Clone and Run

git clone https://github.com/yourusername/ubuntu-setup-backup.git
cd ubuntu-setup-backup
chmod +x deano_setup.sh
./deano_setup.sh

2. Menu Options
Option	Action
1	Update & Upgrade System
2	Install Essential Packages
3	Install Developer Tools
4	Configure Firewall (UFW)
5	Setup Flatpak + Flathub
6	Apply GNOME Tweaks
7	Full Backup
8	Incremental Backup (tar)
9	Clean Backup Log Files
10	Clean System
11	Verify Last Full Backup
12	Restore System Backup
13	Rsync Incremental Snapshot
14	Exit
💾 Backup Modes
🔁 Full Backup

    Archives / directory excluding defined paths

    Each top-level folder is compressed into separate .tar.bz2 files

    Stored in:

    $SERVERBACKUPFOLDER/full/YYYYMMDD_HHMM/

➕ Incremental Backup

    Backs up files changed since last backup

    Stored in:

    $SERVERBACKUPFOLDER/incremental/YYYYMMDD_HHMMSS/

🌀 Rsync Snapshot

    Efficient, deduplicated backups using rsync

    Stored in:

    $SERVERBACKUPFOLDER/rsync_snapshots/YYYYMMDD_HHMMSS/

✅ Backup Verification

Each backup folder includes:

    SHA256SUMS.txt – checksums for all tarballs

    verify.log – result of SHA256 verification

Run Option 11 to verify the last full backup.
🔁 Restore

Option 12: Restore System Backup

Choose from:

    Full Backup

    Incremental Backup

    Rsync Snapshot

    ⚠️ Restoring overwrites system files — proceed with caution.

🧹 Cleanup

    System Cleanup: removes unused packages and old logs

    Backup Cleanup: deletes stale .pid and log files in /tmp

📁 Output Files
Full Backups

    $SERVERBACKUPFOLDER/full/YYYYMMDD_HHMM/

        .tar.bz2 files (per top-level folder)

        restore.txt, SHA256SUMS.txt, verify.log, lastran.txt

Incremental Backups

    $SERVERBACKUPFOLDER/incremental/YYYYMMDD_HHMMSS/

        .tar.bz2 of changed files

        lastran.txt, SHA256SUMS.txt, verify.log

Rsync Snapshots

    $SERVERBACKUPFOLDER/rsync_snapshots/YYYYMMDD_HHMMSS/

        Full filesystem copy (deduplicated)

Temporary Files

    /tmp/files-to-backup.*

    /tmp/*.pid

    /tmp/restore_rsync_*.log

🔧 Requirements

The script installs missing tools as needed, but requires:

    tar, rsync, find, sha256sum, df, gsettings, whiptail

    apt, flatpak, docker, node, etc.

🛡️ Disclaimer

This script modifies system files, installs software, and performs backup/restore operations. Use with caution. Always test in a safe environment.
📄 License

MIT License.
Feel free to fork, modify, and share.
👤 Author

Deano
Ubuntu enthusiast & automation hobbyist.
PRs and issues welcome!
