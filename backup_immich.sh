#!/usr/bin/env bash

# ==============================================================================
# IMMICH BACKUP SCRIPT — photos + database (PROFESSIONAL VERSION)
# ==============================================================================
#
# Intended workflow (the one you already use):
#   1) Stop Immich manually      -> docker compose down   (or "stop")
#   2) Run this script           -> ./backup_immich.sh
#   3) Bring it back up          -> docker compose up -d
#
# The script CHECKS that no Immich containers remain running before copying
# anything. If it detects any running, it aborts without touching the
# destination, to avoid risking an inconsistent backup.
#
# WHY THE SOURCE IS NO LONGER JUST THE PHOTOS FOLDER:
# Immich saves your photos/videos on disk (UPLOAD_LOCATION), but the albums,
# faces, dates, and other metadata live in a Postgres database — Immich
# does not "scan" the folder to reconstruct them. That's why Immich generates
# only a daily database dump inside UPLOAD_LOCATION/backups
# (Administration > Settings > Backup, enabled by default, keeps the
# last 14). By backing up the entire UPLOAD_LOCATION folder you take
# photos + database dump in a single copy, without using pg_dump.
# Source: https://docs.immich.app/administration/backup-and-restore/
# ==============================================================================

# ------------------------------------------------------------------------------
# ⚙️ CONFIGURATION ZONE - MODIFY ONLY HERE
# ------------------------------------------------------------------------------

# 1. SOURCES TO BACKUP
#    Path to your UPLOAD_LOCATION (the folder containing library/, upload/,
#    profile/, thumbs/, backups/...). Without a trailing slash "/".
SOURCES=(
    "/path/to/your/immich/upload_location"

    # Optional: if in your .env you define DB_DATA_LOCATION (folder with the
    # "raw" Postgres files), you can add it as an extra copy.
    # It's not strictly necessary if you already have automatic dumps enabled.
    # "/path/to/your/immich/postgres_data"

    # Optional: the folder with your docker-compose.yml and .env, so you can
    # rebuild the exact deployment from scratch if needed.
    # "/path/to/your/immich/compose_project"
)

# 2. DESTINATION (base folder where the backup will be saved)
DESTINATION="/path/to/your/destination_disk/backups_immich"

# 3. DESTINATION MOUNT POINT (security measure)
DESTINATION_MOUNT_POINT="/path/to/the/root/of/destination_disk"

# 4. LOGS FOLDER
LOGS_FOLDER="/path/where/logs/will/be/saved"

# 5. LOG RETENTION DAYS
LOG_RETENTION_DAYS=30

# 6. PATTERN TO DETECT RUNNING IMMICH CONTAINERS
#    The script aborts if it finds an "Up" container whose name contains
#    this text. Adjust if your containers are named differently.
IMMICH_CONTAINER_PATTERN="immich"

# 7. CHECK FREE SPACE ON DESTINATION BEFORE COPYING
#    Recommended "true". If your library is huge (several TB) and calculating
#    the size takes too long, you can set it to "false".
CHECK_DISK_SPACE="true"

# 8. AUTOMATIC DOCKER MANAGEMENT (OPTIONAL, disabled by default)
#    "false" = you continue stopping/starting Docker yourself, as now.
#    "true"  = the script itself does "down" before copying and "up -d" when
#              finished (useful if one day you want to run it from a cron
#              without manual intervention). Fill in COMPOSE_FILE if enabled.
MANAGE_DOCKER_AUTOMATICALLY="false"
COMPOSE_FILE="/path/to/your/immich/docker-compose.yml"

# 9. OPTIONAL: Telegram Alerts
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
NOTIFY_ON_SUCCESS="true"   # also notifies when everything goes well (so you know
                           # the Telegram alert itself is still working)


# ------------------------------------------------------------------------------
# ⚠️ DO NOT MODIFY ANYTHING BELOW THIS LINE ⚠️
# ------------------------------------------------------------------------------

# MAXIMUM SECURITY IN BASH
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ARGUMENTS: --dry-run (simulation, touches nothing real) / -h --help
DRY_RUN="false"
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [--dry-run]"
        echo "  --dry-run   Simulates the entire process without actually copying, deleting, or touching Docker."
        exit 0
        ;;
    --dry-run)
        DRY_RUN="true"
        ;;
    "")
        ;;
    *)
        echo "Unknown argument: ${1}" >&2
        echo "Usage: $0 [--dry-run]" >&2
        exit 1
        ;;
esac

# Convert path configuration variables to read-only constants
readonly SOURCES
readonly DIR_DESTINATION="$DESTINATION"
readonly DEST_ROOT="$DESTINATION_MOUNT_POINT"
readonly DIR_LOGS="$LOGS_FOLDER"
readonly RETENTION="$LOG_RETENTION_DAYS"
readonly LOG_FILE="${DIR_LOGS}/backup_$(date +%F).log"
readonly LOCK_FILE="/tmp/backup_immich.lock"
readonly START_TIME=$(date +%s)

DOCKER_STOPPED_BY_SCRIPT="false"

# LOGGING AND NOTIFICATION FUNCTIONS
mkdir -p "$DIR_LOGS"

log_info() {
    local message="$1"
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] ${message}" | tee -a "$LOG_FILE"
}

log_error() {
    local message="$1"
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] ${message}" | tee -a "$LOG_FILE" >&2

    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="⚠️ IMMICH BACKUP: ${message}" > /dev/null || true
    fi
}

notify_success() {
    local message="$1"
    if [ "$NOTIFY_ON_SUCCESS" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="✅ IMMICH BACKUP: ${message}" > /dev/null || true
    fi
}

# UNEXPECTED ERROR CAPTURE (TRAP)
# If the script itself stopped Docker (automatic mode) and something fails
# halfway through, try to bring it back up so you aren't left without Immich.
emergency_cleanup() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        log_error "The backup stopped unexpectedly (exit code: $exit_code)."
        if [ "$DOCKER_STOPPED_BY_SCRIPT" = "true" ]; then
            log_error "Attempting to bring Immich back up after the failure..."
            docker compose -f "$COMPOSE_FILE" up -d >> "$LOG_FILE" 2>&1 \
                || log_error "Could not bring Immich up automatically. Do it manually: docker compose up -d"
        fi
    fi
}
trap emergency_cleanup EXIT

# PREVENT SIMULTANEOUS EXECUTIONS (LOCK)
exec 9> "$LOCK_FILE"
if ! flock -n 9; then
    log_error "The script is already running. Aborting to prevent collisions."
    exit 1
fi

# ==========================================
# MAIN FLOW
# ==========================================
echo -e "\n========================================================" >> "$LOG_FILE"
log_info "Starting Immich backup process..."
[ "$DRY_RUN" = "true" ] && log_info "DRY-RUN MODE (--dry-run): nothing will actually be copied, deleted, or touch Docker."

if [ "${#SOURCES[@]}" -eq 0 ]; then
    log_error "There are no paths configured in SOURCES. Edit the configuration zone before continuing."
    exit 1
fi

# ---- (OPTIONAL) STOP DOCKER AUTOMATICALLY ----
if [ "$MANAGE_DOCKER_AUTOMATICALLY" = "true" ]; then
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[SIMULATION] Immich would be stopped with: docker compose -f $COMPOSE_FILE down"
    else
        log_info "Stopping Immich via docker compose (automatic management enabled)..."
        docker compose -f "$COMPOSE_FILE" down >> "$LOG_FILE" 2>&1
        DOCKER_STOPPED_BY_SCRIPT="true"
    fi
fi

# ---- SECURITY: NO IMMICH CONTAINER SHOULD BE RUNNING ----
if [ "$MANAGE_DOCKER_AUTOMATICALLY" = "true" ] && [ "$DRY_RUN" = "true" ]; then
    log_info "[SIMULATION] Skipping the stopped containers check (in a real run, the 'down' above would have handled it)."
else
    log_info "Checking that no Immich containers remain running..."
    if ! DOCKER_PS_OUTPUT="$(docker ps --format '{{.Names}}' 2>&1)"; then
        log_error "Could not query Docker (daemon active? permissions?). Details: $DOCKER_PS_OUTPUT"
        exit 1
    fi
    RUNNING_CONTAINERS="$(printf '%s\n' "$DOCKER_PS_OUTPUT" | grep -i "$IMMICH_CONTAINER_PATTERN" || true)"
    if [ -n "$RUNNING_CONTAINERS" ]; then
        log_error "There are still Immich containers running: $RUNNING_CONTAINERS. Stop them before continuing (docker compose down)."
        exit 1
    fi
    log_info "Confirmed: no Immich containers are running. It is safe to copy."
fi

# ---- ENVIRONMENT CHECKS ----
log_info "Verifying destination mount point..."
if ! mountpoint -q "$DEST_ROOT"; then
    log_error "The destination disk ($DEST_ROOT) is not mounted. Aborting."
    exit 1
fi

log_info "Verifying that the source folders exist and are not empty..."
for src in "${SOURCES[@]}"; do
    src="${src%/}"
    if [ ! -d "$src" ]; then
        log_error "The source folder ($src) does not exist. Aborting."
        exit 1
    fi
    if [ -z "$(find "$src" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        log_error "The source folder ($src) is empty. Aborting so destination is not deleted."
        exit 1
    fi
done

mkdir -p "$DIR_DESTINATION"

if [ "$CHECK_DISK_SPACE" = "true" ]; then
    log_info "Calculating required and available space..."
    REQUIRED_BYTES=0
    for src in "${SOURCES[@]}"; do
        src="${src%/}"
        SIZE="$(du -sb "$src" | cut -f1)"
        REQUIRED_BYTES=$((REQUIRED_BYTES + SIZE))
    done
    AVAILABLE_BYTES="$(df --output=avail -B1 "$DEST_ROOT" | tail -n1 | tr -d ' ')"
    if [ "$REQUIRED_BYTES" -gt "$AVAILABLE_BYTES" ]; then
        log_error "Insufficient space on destination. Required: ~$(numfmt --to=iec "$REQUIRED_BYTES"), available: $(numfmt --to=iec "$AVAILABLE_BYTES")."
        exit 1
    fi
    log_info "Space checked: ~$(numfmt --to=iec "$REQUIRED_BYTES") required and $(numfmt --to=iec "$AVAILABLE_BYTES") available."
fi

# ---- DATA COPY ----
log_info "Systems verified. Starting synchronization with rsync..."

RSYNC_OPTS=(-avh --partial --delete --numeric-ids)
[ "$DRY_RUN" = "true" ] && RSYNC_OPTS+=(--dry-run)

for src in "${SOURCES[@]}"; do
    src="${src%/}"
    RSYNC_CODE=0
    log_info "Copying: $src"
    rsync "${RSYNC_OPTS[@]}" "$src" "$DIR_DESTINATION" >> "$LOG_FILE" 2>&1 || RSYNC_CODE=$?

    if [ "$RSYNC_CODE" -eq 0 ]; then
        log_info "Synchronization of '$src' completed successfully."
    elif [ "$RSYNC_CODE" -eq 24 ]; then
        log_info "Synchronization of '$src' completed (code 24: temporary files vanished during copy, not a real error)."
    else
        log_error "rsync failed copying '$src' (code $RSYNC_CODE). Check the log."
        exit "$RSYNC_CODE"
    fi
done

# ---- (OPTIONAL) BRING DOCKER BACK UP AUTOMATICALLY ----
if [ "$MANAGE_DOCKER_AUTOMATICALLY" = "true" ]; then
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[SIMULATION] Immich would be brought back up with: docker compose -f $COMPOSE_FILE up -d"
    else
        log_info "Bringing Immich back up via docker compose..."
        docker compose -f "$COMPOSE_FILE" up -d >> "$LOG_FILE" 2>&1
        DOCKER_STOPPED_BY_SCRIPT="false"
    fi
fi

# ---- OLD LOGS CLEANUP ----
log_info "Cleaning logs older than $RETENTION days..."
find "$DIR_LOGS" -type f -name "backup_*.log" -mtime +"$RETENTION" -delete

# ---- FINAL SUMMARY ----
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log_info "Backup successfully completed in $((DURATION / 60)) min $((DURATION % 60)) s."
notify_success "Backup completed in $((DURATION / 60)) min $((DURATION % 60)) s."

if [ "$MANAGE_DOCKER_AUTOMATICALLY" = "false" ]; then
    log_info "You can now start Immich again (docker compose up -d)."
fi

exit 0
