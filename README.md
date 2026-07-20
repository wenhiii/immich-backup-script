# 📸 Immich Automated & Secure Backup Script

A battle-tested, zero-downtime-risk Bash backup script for [Immich](https://immich.app/). It synchronizes your photos, videos, and Postgres database dumps safely using `rsync` while verifying container status and disk space.

---

## ✨ Key Features

* **🛡️ Container Safety Check:** Verifies Immich containers are stopped before copying to avoid database corruption or inconsistent backups.
* **💾 Mount Point Verification:** Ensures the backup disk is actually mounted to prevent backing up into an unmounted root filesystem.
* **🧮 Space Guard:** Calculates required space before initiating the copy.
* **🔄 Safe Rsync Sync:** Uses `rsync` with `--delete` for efficient, bandwidth-friendly differential backups.
* **🤖 Optional Auto-Docker Management:** Can automatically run `docker compose down` and `up -d` if configured.
* **📬 Telegram Notifications:** Get alerted on success or failure directly on your phone.
* **🧹 Log Rotation:** Automatically cleans up logs older than $N$ days.
* **🧪 Dry-Run Mode:** Test your setup safely with `--dry-run` without touching real data.

---

## 🚀 Quick Start

### 1. Clone the repository
```bash
git clone https://github.com/wenhiii/immich-backup-script.git
cd immich-backup-script
```

### 2. Make it executable
```bash
chmod +x backup_immich.sh
```

### 3. Configuration
Open `backup_immich.sh` in your editor and configure the variables in the **CONFIGURATION ZONE**:

```bash
SOURCES=(
    "/path/to/your/immich/upload_location"
    # "/path/to/your/immich/postgres_data" # Optional
)
DESTINATION="/path/to/your/destination_disk/backups_immich"
DESTINATION_MOUNT_POINT="/path/to/the/root/of/destination_disk"
LOGS_FOLDER="/path/where/logs/will/be/saved"
```

---

## 🧪 Usage

### Test mode (Dry-run)
Simulates the entire process without writing or deleting any files:
```bash
./backup_immich.sh --dry-run
```

### Manual Run
Stop Immich first, run the script, then bring it back up:
```bash
docker compose down
./backup_immich.sh
docker compose up -d
```

### Automated Run (Cron)
If you enable `MANAGE_DOCKER_AUTOMATICALLY="true"`, you can add it to your root or user crontab for automatic backups:

```cron
# Run every night at 3:00 AM
0 3 * * * /path/to/backup_immich.sh >/dev/null 2>&1
```

---

## ⚠️ Disclaimer
Always test your restoration process. A backup is only as good as its restore test!
