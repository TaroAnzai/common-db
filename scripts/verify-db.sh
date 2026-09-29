#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: verify-db.sh --compose FILE [--compose FILE ...] --service NAME --source-db DB --target-db DB [options]

Compare source and common-mysql using exact row counts and object counts.
Options:
  --compose FILE              Source Compose file (repeatable; applied in order)
  --service NAME              Source MySQL service
  --source-db DB              Source database name
  --target-db DB              Target database name
  --source-user USER          Source user (auto-detected when omitted)
  --output-dir DIR            Write verification.tsv and verification.txt
  --source-password-fd FD     Read source password from inherited FD
  --target-password-fd FD     Read common root password from inherited FD
  -h, --help                  Show this help

Passwords are prompted invisibly unless an inherited FD is supplied. Password
FD options are intended for migrate-db.sh and avoid command-line secrets.
EOF
}

COMPOSE_FILES=()
COMPOSE_ARGS=()
service= source_db= target_db= source_user= output_dir=
source_fd= target_fd=
while (($#)); do
  case $1 in
    --compose) COMPOSE_FILES+=("${2:?}"); shift 2;;
    --service) service=${2:?}; shift 2;;
    --source-db) source_db=${2:?}; shift 2;;
    --target-db) target_db=${2:?}; shift 2;;
    --source-user) source_user=${2:?}; shift 2;;
    --output-dir) output_dir=${2:?}; shift 2;;
    --source-password-fd) source_fd=${2:?}; shift 2;;
    --target-password-fd) target_fd=${2:?}; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done
(( ${#COMPOSE_FILES[@]} > 0 )) && [[ -n $service && -n $source_db && -n $target_db ]] || { usage >&2; exit 2; }
validate_name source-db "$source_db"; validate_name target-db "$target_db"
for cmd in docker awk sort diff sed mktemp tee; do need "$cmd"; done
for compose_file in "${COMPOSE_FILES[@]}"; do
  [[ -f $compose_file ]] || die "Compose file not found: $compose_file"
done
for i in "${!COMPOSE_FILES[@]}"; do
  compose_file=${COMPOSE_FILES[$i]}
  COMPOSE_FILES[$i]=$(cd -- "$(dirname -- "$compose_file")" && pwd)/$(basename -- "$compose_file")
  COMPOSE_ARGS+=("-f" "${COMPOSE_FILES[$i]}")
done
compose_dir=$(dirname -- "${COMPOSE_FILES[0]}")
source_container=$(docker compose --project-directory "$compose_dir" "${COMPOSE_ARGS[@]}" ps -q "$service")
[[ -n $source_container ]] || die "Source service is not running: $service"
[[ $(docker inspect --format '{{.State.Running}}' common-mysql 2>/dev/null || true) == true ]] || die "common-mysql is not running"

if [[ -z $source_user ]]; then
  source_user=$(container_env "$source_container" MYSQL_USER)
  if [[ -z $source_user ]]; then source_user=root; fi
fi
if [[ -n $source_fd ]]; then IFS= read -r source_password <&"$source_fd"; else read_secret 'Source database password: ' source_password; fi
if [[ -n $target_fd ]]; then IFS= read -r target_password <&"$target_fd"; else read_secret 'Common MySQL root password: ' target_password; fi

source_exists=$(printf '%s\n' "$source_password" | container_mysql "$source_container" -u "$source_user" -N -B -e \
  "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_literal "$source_db")'")
[[ $source_exists == 1 ]] || die "Source database does not exist or is not visible: $source_db"
target_exists=$(printf '%s\n' "$target_password" | container_mysql common-mysql -u root -N -B -e \
  "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_literal "$target_db")'")
[[ $target_exists == 1 ]] || die "Target database does not exist: $target_db"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
src=$tmp_dir/source.tsv; dst=$tmp_dir/target.tsv

inventory() {
  local container=$1 user=$2 password=$3 db=$4 out=$5 table table_q count table_list
  printf '%s\n' "$password" | container_mysql "$container" -u "$user" -N -B -e \
    "SELECT CONCAT('OBJECT',CHAR(9),TABLE_TYPE,CHAR(9),COUNT(*)) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$(sql_literal "$db")' GROUP BY TABLE_TYPE ORDER BY TABLE_TYPE" >"$out"
  table_list=$(printf '%s\n' "$password" | container_mysql "$container" -u "$user" -N -B -e \
    "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$(sql_literal "$db")' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME")
  if [[ -n $table_list ]]; then
    while IFS= read -r table; do
      table_q=${table//\`/\`\`}
      count=$(printf '%s\n' "$password" | container_mysql "$container" -u "$user" -N -B "$db" -e "SELECT COUNT(*) FROM \`$table_q\`")
      printf 'TABLE\t%s\t%s\n' "$table" "$count" >>"$out"
    done <<<"$table_list"
  fi
  printf '%s\n' "$password" | container_mysql "$container" -u "$user" -N -B -e \
    "SELECT CONCAT('ROUTINE',CHAR(9),ROUTINE_TYPE,CHAR(9),COUNT(*)) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='$(sql_literal "$db")' GROUP BY ROUTINE_TYPE ORDER BY ROUTINE_TYPE; SELECT CONCAT('TRIGGER',CHAR(9),'ALL',CHAR(9),COUNT(*)) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='$(sql_literal "$db")'; SELECT CONCAT('EVENT',CHAR(9),'ALL',CHAR(9),COUNT(*)) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='$(sql_literal "$db")';" >>"$out"
  sort -o "$out" "$out"
}

inventory "$source_container" "$source_user" "$source_password" "$source_db" "$src"
inventory common-mysql root "$target_password" "$target_db" "$dst"
unset source_password target_password

if [[ -n $output_dir ]]; then
  mkdir -p -- "$output_dir"
  { printf 'side\ttype\tname_or_type\tcount\n'; sed 's/^/source\t/' "$src"; sed 's/^/target\t/' "$dst"; } >"$output_dir/verification.tsv"
fi
if diff -u "$src" "$dst" >"$tmp_dir/diff.txt"; then
  result='Migration verification: PASSED'; status=0
else
  result='Migration verification: FAILED'; status=1
fi
{
  printf '%s\n' "$result"
  printf 'Source: %s / %s (%s)\nTarget: common-mysql / %s\n' "$service" "$source_db" "$source_user" "$target_db"
  if ((status)); then printf '\nDifferences:\n'; cat "$tmp_dir/diff.txt"; fi
} | if [[ -n $output_dir ]]; then tee "$output_dir/verification.txt"; else cat; fi
exit "$status"
