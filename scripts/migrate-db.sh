#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/migrate-db.sh --compose FILE [--compose FILE ...] --service NAME --target-db DB [options]

Required:
  --compose FILE       Existing application's Compose file.
                       May be specified multiple times; files are applied in the given order.
  --service NAME       MySQL service name in that Compose project
  --target-db DB       New database name on common-mysql

Options:
  --source-db DB       Source DB (auto-detected from MYSQL_DATABASE if omitted)
  --source-user USER   Source user (MYSQL_USER, otherwise root, if omitted)
  --target-user USER   New user (defaults to --target-db)
  --yes                Skip the final non-secret confirmation
  -h, --help           Show this help

Passwords are never accepted as command-line options. Missing source credentials
and the new target-user password are read invisibly from the terminal.

Multiple Compose files:
  ./scripts/migrate-db.sh \
    --compose /path/to/compose.yaml \
    --compose /path/to/compose.production.yaml \
    --service db --target-db example_db
EOF
}

COMPOSE_FILES=()
COMPOSE_ARGS=()
service= source_db= source_user= target_db= target_user= assume_yes=0
while (($#)); do
  case $1 in
    --compose) COMPOSE_FILES+=("${2:?}"); shift 2;;
    --service) service=${2:?}; shift 2;;
    --source-db) source_db=${2:?}; shift 2;;
    --source-user) source_user=${2:?}; shift 2;;
    --target-db) target_db=${2:?}; shift 2;;
    --target-user) target_user=${2:?}; shift 2;;
    --yes) assume_yes=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done
(( ${#COMPOSE_FILES[@]} > 0 )) && [[ -n $service && -n $target_db ]] || { usage >&2; exit 2; }
[[ -n $target_user ]] || target_user=$target_db
validate_name target-db "$target_db"; validate_name target-user "$target_user"
(( ${#target_db} <= 64 )) || die "target-db exceeds MySQL's 64-character limit"
(( ${#target_user} <= 32 )) || die "target-user exceeds MySQL's 32-character limit"
[[ -z $source_db ]] || validate_name source-db "$source_db"

for compose_file in "${COMPOSE_FILES[@]}"; do
  [[ -f $compose_file ]] || die "Compose file not found: $compose_file"
done
for i in "${!COMPOSE_FILES[@]}"; do
  compose_file=${COMPOSE_FILES[$i]}
  COMPOSE_FILES[$i]=$(cd -- "$(dirname -- "$compose_file")" && pwd)/$(basename -- "$compose_file")
  COMPOSE_ARGS+=("-f" "${COMPOSE_FILES[$i]}")
done
compose_dir=$(dirname -- "${COMPOSE_FILES[0]}")

for cmd in docker gzip date tee awk sed sort diff mktemp grep; do need "$cmd"; done
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"

docker inspect common-mysql >/dev/null 2>&1 || die "common-mysql does not exist; start it first"
[[ $(docker inspect --format '{{.State.Running}}' common-mysql) == true ]] || die "common-mysql is not running"
health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' common-mysql)
[[ $health == healthy ]] || die "common-mysql is not healthy (status: $health)"

docker compose --project-directory "$compose_dir" "${COMPOSE_ARGS[@]}" config --services | grep -Fx -- "$service" >/dev/null ||
  die "Service '$service' is not defined in the specified Compose files"
source_container=$(docker compose --project-directory "$compose_dir" "${COMPOSE_ARGS[@]}" ps -q "$service")
[[ -n $source_container ]] || die "Source service '$service' is not running"
[[ $(docker inspect --format '{{.State.Running}}' "$source_container") == true ]] || die "Source container is not running"

if [[ -z $source_db ]]; then source_db=$(container_env "$source_container" MYSQL_DATABASE); fi
if [[ -z $source_db ]]; then
  read -r -p 'Source database name: ' source_db </dev/tty
fi
validate_name source-db "$source_db"
if [[ -z $source_user ]]; then
  source_user=$(container_env "$source_container" MYSQL_USER)
  [[ -n $source_user ]] || source_user=root
fi
validate_name source-user "$source_user"

if [[ $source_user == root ]]; then
  source_password=$(container_env "$source_container" MYSQL_ROOT_PASSWORD)
else
  source_password=$(container_env "$source_container" MYSQL_PASSWORD)
fi
[[ -n $source_password ]] || read_secret 'Source database password: ' source_password
common_root_password=$(container_env common-mysql MYSQL_ROOT_PASSWORD)
[[ -n $common_root_password ]] || read_secret 'Common MySQL root password: ' common_root_password

printf '%s\n' "$source_password" | container_mysql "$source_container" -u "$source_user" -N -B -e "SELECT 1" >/dev/null || die "Cannot connect to source MySQL"
source_exists=$(printf '%s\n' "$source_password" | container_mysql "$source_container" -u "$source_user" -N -B -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_literal "$source_db")'")
[[ $source_exists == 1 ]] || die "Source database does not exist or is not visible: $source_db"
printf '%s\n' "$common_root_password" | container_mysql common-mysql -u root -N -B -e "SELECT 1" >/dev/null || die "Cannot connect to common-mysql as root"

target_exists=$(printf '%s\n' "$common_root_password" | container_mysql common-mysql -u root -N -B -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_literal "$target_db")'")
if [[ $target_exists != 0 ]]; then
  printf "ERROR: Database '%s' already exists.\nMigration aborted.\nNo existing database was modified.\n" "$target_db" >&2
  exit 1
fi
user_exists=$(printf '%s\n' "$common_root_password" | container_mysql common-mysql -u root -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='$(sql_literal "$target_user")' AND Host='%'")
[[ $user_exists == 0 ]] || die "User '$target_user'@'%' already exists. No existing resource was modified."

read_secret 'Target database password: ' target_password
read_secret 'Confirm password: ' target_password_confirm
[[ $target_password == "$target_password_confirm" ]] || die "Passwords do not match"
unset target_password_confirm

printf 'Migration plan:\n  source: %s (%s), service=%s, database=%s, user=%s\n  target: common-mysql, database=%s, user=%s@%%\n' \
  "${COMPOSE_FILES[*]}" "$source_container" "$service" "$source_db" "$source_user" "$target_db" "$target_user"
if ((!assume_yes)); then
  read -r -p 'Proceed with dump and migration? [y/N] ' answer </dev/tty
  [[ $answer == y || $answer == Y ]] || die "Cancelled; no target resource was created"
fi

timestamp=$(date '+%Y%m%d_%H%M%S')
migration_dir="$REPO_DIR/migrations/${timestamp}_${target_db}"
mkdir -m 700 -- "$migration_dir"
migration_log="$migration_dir/migration.log"
touch "$migration_log"; chmod 600 "$migration_log"
exec > >(tee -a "$migration_log") 2>&1
log "Migration started"

created_db=0 created_user=0 import_complete=0
rollback_new_resources() {
  local rc=$1
  if ((rc != 0 && import_complete == 0)); then
    log "Failure before import completed; removing only resources created by this run"
    set +e
    if ((created_db)); then
      printf '%s\n' "$common_root_password" | container_mysql common-mysql -u root -e "DROP DATABASE IF EXISTS \`$target_db\`;" >/dev/null
    fi
    if ((created_user)); then
      printf '%s\n' "$common_root_password" | container_mysql common-mysql -u root -e "DROP USER IF EXISTS '$target_user'@'%';" >/dev/null
    fi
    set -e
    log "Migration aborted. The source was not modified."
  fi
  exit "$rc"
}
trap 'rollback_new_resources $?' EXIT

source_version=$(printf '%s\n' "$source_password" | container_mysql "$source_container" -u "$source_user" -N -B -e 'SELECT VERSION()')
source_tables=$(printf '%s\n' "$source_password" | container_mysql "$source_container" -u "$source_user" -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$(sql_literal "$source_db")' AND TABLE_TYPE='BASE TABLE'")
{
  printf 'captured_at=%s\ncompose=%s\nservice=%s\ncontainer=%s\nmysql_version=%s\ndatabase=%s\nuser=%s\nbase_tables=%s\n' \
    "$(date --iso-8601=seconds)" "${COMPOSE_FILES[*]}" "$service" "$source_container" "$source_version" "$source_db" "$source_user" "$source_tables"
} >"$migration_dir/source-summary.txt"

dump_part="$migration_dir/dump.sql.gz.part"
log "Creating logical dump"
printf '%s\n' "$source_password" | container_mysqldump "$source_container" -u "$source_user" \
  --single-transaction --quick --hex-blob --routines --events --triggers \
  --set-gtid-purged=OFF --no-tablespaces --default-character-set=utf8mb4 \
  "$source_db" | gzip -9 >"$dump_part"
[[ -s $dump_part ]] || die "Dump is empty"
gzip -t "$dump_part" || die "Dump gzip validation failed"
mv -- "$dump_part" "$migration_dir/dump.sql.gz"
chmod 600 "$migration_dir/dump.sql.gz"
log "Dump completed and validated"

escaped_target_password=$(sql_literal "$target_password")
{
  printf '%s\n' "$common_root_password"
  printf "CREATE DATABASE \`%s\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;\n" "$target_db"
} | container_mysql common-mysql -u root
created_db=1
{
  printf '%s\n' "$common_root_password"
  printf "CREATE USER '%s'@'%%' IDENTIFIED BY '%s'; GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\n" \
    "$target_user" "$escaped_target_password" "$target_db" "$target_user"
} | container_mysql common-mysql -u root
created_user=1
unset escaped_target_password target_password

log "Importing dump into the newly created database"
{
  printf '%s\n' "$common_root_password"
  gzip -dc "$migration_dir/dump.sql.gz"
} | container_mysql common-mysql -u root "$target_db"
import_complete=1
log "Import completed"

exec 3<<<"$source_password"
exec 4<<<"$common_root_password"
verify_compose_args=()
for compose_file in "${COMPOSE_FILES[@]}"; do verify_compose_args+=(--compose "$compose_file"); done
if "$SCRIPT_DIR/verify-db.sh" "${verify_compose_args[@]}" --service "$service" --source-db "$source_db" \
  --target-db "$target_db" --source-user "$source_user" --output-dir "$migration_dir" \
  --source-password-fd 3 --target-password-fd 4; then
  verification=PASSED
else
  verification=FAILED
fi
exec 3<&- 4<&-
unset source_password

target_version=$(printf '%s\n' "$common_root_password" | container_mysql common-mysql -u root -N -B -e 'SELECT VERSION()')
{
  printf 'completed_at=%s\ncontainer=common-mysql\nmysql_version=%s\ndatabase=%s\nuser=%s@%%\nverification=%s\n' \
    "$(date --iso-8601=seconds)" "$target_version" "$target_db" "$target_user" "$verification"
} >"$migration_dir/target-summary.txt"
chmod 600 "$migration_dir"/*.txt "$migration_dir"/*.tsv 2>/dev/null || true

if [[ $verification != PASSED ]]; then
  log "Migration verification: FAILED. Target data is retained for investigation; source is unchanged."
  log "Do not switch the application. See $migration_dir/verification.txt"
  exit 1
fi

log "Migration verification: PASSED"
printf '\nManual application switch information (this script changes nothing outside common-db):\n'
printf '  host: common-mysql\n  port: 3306\n  database: %s\n  user: %s\n  Docker network: common-db-network\n' "$target_db" "$target_user"
printf '  password: the value entered interactively (not logged)\n'
printf 'Migration artifacts: %s\n' "$migration_dir"
log "Migration completed successfully"
trap - EXIT
