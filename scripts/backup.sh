#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: backup.sh [--force-weekly | --daily-only]

Create one atomic daily snapshot of every non-system database. On Sunday the
completed daily snapshot is copied as a weekly snapshot. Retention is 7 daily
and 4 weekly successful snapshots.
EOF
}
weekly_mode=auto
while (($#)); do
  case $1 in
    --force-weekly) weekly_mode=force; shift;;
    --daily-only) weekly_mode=off; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done
for cmd in docker gzip flock sha256sum cp find sort tee awk tail date; do need "$cmd"; done

daily_dir=$REPO_DIR/backups/daily
weekly_dir=$REPO_DIR/backups/weekly
log_file=$REPO_DIR/backups/backup.log
prune_snapshots() {
  local dir=$1 keep=$2 item old_list
  local -a old=()
  old_list=$(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*.part' -printf '%f\n' | sort -r | tail -n "+$((keep + 1))")
  if [[ -n $old_list ]]; then mapfile -t old <<<"$old_list"; fi
  for item in "${old[@]}"; do
    [[ $item =~ ^[0-9]{8}_[0-9]{6}$ ]] || { log "Skipping unexpected retention entry: $dir/$item"; continue; }
    rm -rf -- "$dir/$item"
    log "Pruned old snapshot: $dir/$item"
  done
}
mkdir -p -- "$daily_dir" "$weekly_dir"
touch "$log_file"; chmod 600 "$log_file"
exec > >(tee -a "$log_file") 2>&1

exec 9>"$REPO_DIR/backups/.backup.lock"
flock -n 9 || die "Another backup is already running"
[[ $(docker inspect --format '{{.State.Running}}' common-mysql 2>/dev/null || true) == true ]] || die "common-mysql is not running"
health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' common-mysql)
[[ $health == healthy ]] || die "common-mysql is not healthy (status: $health)"
root_password=$(container_env common-mysql MYSQL_ROOT_PASSWORD)
[[ -n $root_password ]] || die "MYSQL_ROOT_PASSWORD is not available in common-mysql environment"
printf '%s\n' "$root_password" | container_mysql common-mysql -u root -N -B -e 'SELECT 1' >/dev/null

timestamp=$(date '+%Y%m%d_%H%M%S')
part="$daily_dir/.${timestamp}.part"
final="$daily_dir/$timestamp"
weekly_part=
mkdir -m 700 -- "$part"
cleanup() { local rc=$1; if ((rc)); then rm -rf -- "$part"; [[ -z $weekly_part ]] || rm -rf -- "$weekly_part"; log "Backup FAILED (exit $rc)"; fi; exit "$rc"; }
trap 'cleanup $?' EXIT
log "Backup started: $timestamp"

database_list=$(printf '%s\n' "$root_password" | container_mysql common-mysql -u root -N -B -e \
  "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys') ORDER BY SCHEMA_NAME")
databases=()
if [[ -n $database_list ]]; then mapfile -t databases <<<"$database_list"; fi
if ((${#databases[@]} == 0)); then log 'No application databases found; creating an empty successful snapshot manifest'; fi
printf 'created_at=%s\nmysql_container=common-mysql\n' "$(date --iso-8601=seconds)" >"$part/manifest.txt"
for db in "${databases[@]}"; do
  validate_name database "$db"
  log "Dumping database: $db"
  outfile="$part/$db.sql.gz"
  printf '%s\n' "$root_password" | container_mysqldump common-mysql -u root \
    --single-transaction --quick --hex-blob --routines --events --triggers \
    --set-gtid-purged=OFF --no-tablespaces --default-character-set=utf8mb4 "$db" |
    gzip -9 >"$outfile"
  [[ -s $outfile ]] || die "Backup dump is empty: $db"
  gzip -t "$outfile"
  checksum=$(sha256sum "$outfile" | awk '{print $1}')
  printf 'database=%s file=%s sha256=%s\n' "$db" "$(basename -- "$outfile")" "$checksum" >>"$part/manifest.txt"
done
chmod 600 "$part"/*
mv -- "$part" "$final"
log "Daily backup completed: $final"
prune_snapshots "$daily_dir" 7

if [[ $weekly_mode == force || ( $weekly_mode == auto && $(date '+%u') == 7 ) ]]; then
  weekly_part="$weekly_dir/.${timestamp}.part"
  cp -a -- "$final" "$weekly_part"
  mv -- "$weekly_part" "$weekly_dir/$timestamp"
  weekly_part=
  log "Weekly snapshot completed: $weekly_dir/$timestamp"
fi
prune_snapshots "$weekly_dir" 4
unset root_password
log 'Backup SUCCESS'
trap - EXIT
