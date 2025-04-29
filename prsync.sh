#!/bin/bash

set -euo pipefail

# Default values
CORES=$(nproc)
SHOW_HELP=false

# === Usage function ===
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Sync files from source to destination with parallel staging.

Options:
  -s, --source      Source directory (required)
  -d, --destination Destination directory (required)
  -c, --cores       Number of CPU cores to use (default: all cores)
  -h, --help        Show this help message

Example:
  $0 -s /path/to/source -d /path/to/dest -c 4
EOF
  exit 1
}

# === Parse arguments ===
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--source)
      SRC_DIR="$2"
      shift 2
      ;;
    -d|--destination)
      DEST_DIR="$2"
      shift 2
      ;;
    -c|--cores)
      CORES="$2"
      shift 2
      ;;
    -h|--help)
      SHOW_HELP=true
      shift
      ;;
    *)
      echo "Error: Unknown option $1"
      usage
      ;;
  esac
done

# === Validation ===
if $SHOW_HELP; then
  usage
fi

if [[ -z "${SRC_DIR:-}" || -z "${DEST_DIR:-}" ]]; then
  echo "Error: Both source and destination directories must be specified"
  usage
fi

if ! [[ "$CORES" =~ ^[0-9]+$ ]] || (( CORES < 1 )); then
  echo "Error: Cores must be a positive integer"
  usage
fi

# Remove trailing slashes
SRC_DIR="${SRC_DIR%/}"
DEST_DIR="${DEST_DIR%/}"

# === Configuration ===
STAGING_DIR="staging"
OLD_DIR="$STAGING_DIR/old"
NEW_DIR="$STAGING_DIR/new"
CHANGED_LIST="$STAGING_DIR/changed_files.txt"

# === Cleanup ===
echo "Cleaning up previous staging..."
rm -rf "$STAGING_DIR"
mkdir -p "$OLD_DIR" "$NEW_DIR"

# === STEP 1: Detect changes ===
echo "Detecting changes between:"
echo "  Source:      $SRC_DIR/"
echo "  Destination: $DEST_DIR/"
echo "  Using cores: $CORES"

mkdir -p "$DEST_DIR"
rsync -aiv --dry-run --exclude-from="exclude.txt" --out-format="%n" "$SRC_DIR/" "$DEST_DIR/" \
| grep -v '^sending incremental file list$' \
| awk '!/\/$/ && !/^sent / && !/^received / && !/^total size / && !/^speedup /' > "$CHANGED_LIST"

if [[ ! -s "$CHANGED_LIST" ]]; then
  echo "No changes detected. Exiting."
  exit 0
fi

# === STEP 2: Parallel staging ===
echo "Staging files (using $CORES cores)..."

process_file() {
  local file="$1"
  local src="$SRC_DIR/$file"
  local dest="$DEST_DIR/$file"
  
  # Create parent directories
  mkdir -p "$OLD_DIR/$(dirname "$file")" "$NEW_DIR/$(dirname "$file")"

  # Backup old file if exists
  if [[ -f "$dest" ]]; then
    if cp -p "$dest" "$OLD_DIR/$file"; then
      echo "Backed up old: $file"
    else
      echo "Warning: Failed to backup $file" >&2
    fi
  fi

  # Stage new file
  if cp -p "$src" "$NEW_DIR/$file"; then
    echo "Staged new: $file"
  else
    echo "Error: Failed to stage $file" >&2
    return 1
  fi
}

export -f process_file
export SRC_DIR DEST_DIR OLD_DIR NEW_DIR

# Process files in parallel
xargs -P "$CORES" -I {} bash -c 'process_file "$@"' _ {} < "$CHANGED_LIST"

# === STEP 3: Deploy changes ===
echo "Deploying staged files to destination..."
rsync -av "$NEW_DIR/" "$DEST_DIR/"

echo "Sync complete ✅"
echo "Old versions stored in: $OLD_DIR"
