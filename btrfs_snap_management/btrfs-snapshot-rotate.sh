#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
DEV="/dev/nvme1n1p4"                 # your Btrfs partition
ROOT_SUBVOL="var/lib/machines"       # your real / is this subvolume
TOP_MNT="/mnt/btrfs-top"             # temp mount for subvolid=5
SNAP_DIR="${TOP_MNT}/snapshots"      # where snapshots live (top-level)
LOG="/var/log/btrfs-snapshots.log"

# Pin any snapshots you NEVER want pruned:
# (use exact directory names under ${SNAP_DIR})
PINNED_SNAPSHOTS=("root-20251010")   # your golden base

# ====== HELPERS ======
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

mount_top() {
  sudo mkdir -p "$TOP_MNT"
  if ! mountpoint -q "$TOP_MNT"; then
    sudo mount -o subvolid=5 "$DEV" "$TOP_MNT"
  fi
}

umount_top() {
  if mountpoint -q "$TOP_MNT"; then
    sudo umount "$TOP_MNT"
  fi
}

is_pinned() {
  local name="$1"
  for p in "${PINNED_SNAPSHOTS[@]}"; do
    [[ "$name" == "$p" ]] && return 0
  done
  return 1
}

# ====== MAIN ======
mount_top
trap umount_top EXIT

sudo mkdir -p "$SNAP_DIR"

# 1) Create today’s read-only snapshot
TODAY="$(date +%Y%m%d)"
SNAP_NAME="root-${TODAY}"
SNAP_PATH="${SNAP_DIR}/${SNAP_NAME}"

if [[ -e "$SNAP_PATH" ]]; then
  log "Snapshot ${SNAP_NAME} already exists; skipping creation."
else
  log "Creating snapshot ${SNAP_NAME}…"
  sudo btrfs subvolume snapshot -r "${TOP_MNT}/${ROOT_SUBVOL}" "$SNAP_PATH"
  log "Created ${SNAP_PATH}"
fi

# 2) Prune policy:
#    - Keep all snapshots whose month == current month
#    - For previous months, delete all snapshots EXCEPT pinned ones
CUR_MONTH="$(date +%Y%m)"
log "Pruning snapshots not in current month (${CUR_MONTH}) and not pinned…"

# List snapshot dirs like root-YYYYMMDD
# skip non-matching names just in case
shopt -s nullglob
for path in "${SNAP_DIR}"/root-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
  base="$(basename "$path")"                # e.g., root-20251010
  snapdate="${base#root-}"                  # e.g., 20251010
  snapmonth="${snapdate:0:6}"               # e.g., 202510

  if [[ "$snapmonth" == "$CUR_MONTH" ]]; then
    # keep all snapshots from current month
    continue
  fi

  # if pinned, skip
  if is_pinned "$base"; then
    log "Pinned snapshot kept: $base"
    continue
  fi

  # safe delete old snapshot
  log "Deleting old snapshot: $base"
  sudo btrfs subvolume delete "$path" || log "WARNING: delete failed for $base"
done
shopt -u nullglob

log "Done."
