#!/usr/bin/env bash
# Shared helpers. This file is sourced; do not execute it directly.

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

validate_name() {
  [[ $2 =~ ^[A-Za-z0-9_]+$ ]] || die "$1 must contain only ASCII letters, digits, and underscore: $2"
}

read_secret() {
  local prompt=$1 var_name=$2 value
  read -r -s -p "$prompt" value </dev/tty || die "Unable to read password from terminal"
  printf '\n' >/dev/tty
  [[ -n $value ]] || die "Password must not be empty"
  [[ $value != *$'\n'* && $value != *$'\r'* ]] || die "Password must not contain a newline"
  printf -v "$var_name" '%s' "$value"
}

container_env() {
  local container=$1 key=$2
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null |
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}'
}

# Password is read from the first stdin line and never appears in argv.
container_mysql() {
  local container=$1; shift
  docker exec -i "$container" sh -c \
    'IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec mysql "$@"' sh "$@"
}

container_mysqldump() {
  local container=$1; shift
  docker exec -i "$container" sh -c \
    'IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec mysqldump "$@"' sh "$@"
}

sql_literal() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/''/g"; }
