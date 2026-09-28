.PHONY: check compose-check syntax-check shellcheck

check: compose-check syntax-check shellcheck

compose-check:
	@MYSQL_ROOT_PASSWORD=compose-validation-only docker compose config --quiet

syntax-check:
	@bash -n scripts/*.sh

shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { echo "ERROR: shellcheck is not installed. Install it (for example: sudo apt install shellcheck)." >&2; exit 1; }
	@shellcheck -x scripts/*.sh
