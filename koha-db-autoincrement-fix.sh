#!/bin/bash
# koha-db-autoincrement-fix.sh
set -u

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <instance> [--delete=yes]" >&2
    exit 2
fi

INSTANCE="$1"
DELETE_MODE="${2:-}"

if [ -n "$DELETE_MODE" ] && [ "$DELETE_MODE" != "--delete=yes" ]; then
    echo "Error: second arg must be --delete=yes (or omitted)." >&2
    exit 2
fi

if ! koha-list | grep -qFx "$INSTANCE"; then
    echo "Error: '$INSTANCE' is not a known Koha instance." >&2
    exit 2
fi

PAIRS=(
    "borrowers    deletedborrowers    borrowernumber"
    "biblio       deletedbiblio       biblionumber"
    "biblioitems  deletedbiblioitems  biblioitemnumber"
    "items        deleteditems        itemnumber"
    "issues       old_issues          issue_id"
    "reserves     old_reserves        reserve_id"
)

run_sql() {
    koha-mysql "$INSTANCE" -N -B -e "$1"
}

# Smoke test: can we actually query the database?
# koha-mysql needs to read /etc/koha/sites/<instance>/koha-conf.xml,
# which is typically mode 0640 and not world-readable.
if ! echo "SELECT 1;" | koha-mysql "$INSTANCE" -N -B >/dev/null 2>&1; then
    echo "Error: cannot query database for instance '$INSTANCE'." >&2
    echo "This script must be run as root (koha-conf.xml is not world-readable)." >&2
    echo "Try:" >&2
    echo "  sudo $0 $*" >&2
    exit 1
fi

detect_db_service() {
    for s in mariadb mysql mysqld; do
        if systemctl list-unit-files "${s}.service" --no-legend 2>/dev/null \
                | grep -q "^${s}.service"; then
            echo "$s"
            return
        fi
    done
    echo "mariadb"
}

check_ai_fix() {
    local sh="/etc/koha/koha-mysql-init.sh"
    local sql="/etc/koha/koha-mysql-init.sql"
    local svc="/etc/systemd/system/koha-mysql-init.service"
    local db_svc
    db_svc=$(detect_db_service)

    echo
    echo "=== auto_increment fix status ==="

    if [ ! -f "$sh" ] || [ ! -f "$sql" ] || [ ! -f "$svc" ]; then
        echo "KohaAloha auto_increment fix is NOT installed."
        echo "Without it, deleted IDs can resurface on the next ${db_svc} restart"
        echo "and the collisions will come back."
        echo
        echo "Install:"
        echo "  git clone https://github.com/KohaAloha/koha-mysql-init"
        echo "  sudo cp -a koha-mysql-init/koha-mysql-init.sh      /etc/koha/"
        echo "  sudo cp -a koha-mysql-init/koha-mysql-init.sql     /etc/koha/"
        echo "  sudo cp -a koha-mysql-init/koha-mysql-init.service /etc/systemd/system/"
        echo "  sudo systemctl daemon-reload"
        echo "  sudo systemctl enable koha-mysql-init.service"
        echo "  sudo systemctl restart ${db_svc}"
        echo
        echo "Ref: https://wiki.koha-community.org/wiki/DBMS_auto_increment_fix"
        return
    fi

    echo "KohaAloha auto_increment fix is installed."

    if systemctl is-enabled --quiet koha-mysql-init.service 2>/dev/null; then
        echo "koha-mysql-init.service is enabled."
        echo
        echo "Restart the database to run the fix and bump AUTO_INCREMENT past MAX:"
        echo "  sudo systemctl restart ${db_svc}"
        echo
        echo "Then verify with:"
        echo "  sudo journalctl -u koha-mysql-init.service -n 20"
    else
        echo "koha-mysql-init.service is NOT enabled. Enable it:"
        echo "  sudo systemctl daemon-reload"
        echo "  sudo systemctl enable koha-mysql-init.service"
        echo "  sudo systemctl restart ${db_svc}"
    fi
}

DBNAME=$(run_sql "SELECT DATABASE();")

echo "=== Instance: $INSTANCE ==="
printf "%-14s %-24s %s\n" \
    "Table" "Deleted/old counterpart" "IDs in both tables"
echo "----------------------------------------------------------------------------"

declare -A FOUND_IDS
TOTAL_COLLISIONS=0

for row in "${PAIRS[@]}"; do
    read -r LIVE ARCH PK <<< "$row"

    IDS=$(run_sql \
        "SELECT l.$PK FROM $LIVE l JOIN $ARCH a ON l.$PK = a.$PK ORDER BY l.$PK;" \
        | paste -sd,)

    if [ -z "$IDS" ]; then
        printf "%-14s %-24s %s\n" "$LIVE" "$ARCH" "none"
        continue
    fi

    N=$(echo "$IDS" | tr ',' '\n' | wc -l)
    TOTAL_COLLISIONS=$((TOTAL_COLLISIONS + N))
    FOUND_IDS["$ARCH|$PK"]="$IDS"

    printf "%-14s %-24s %s\n" "$LIVE" "$ARCH" "$N: $IDS"
done

echo

if [ "$TOTAL_COLLISIONS" -eq 0 ]; then
    echo "No collisions found."
    check_ai_fix
    exit 0
fi

if [ "$DELETE_MODE" != "--delete=yes" ]; then
    echo "$TOTAL_COLLISIONS collision(s) reported above."
    echo "Re-run with --delete=yes to dump and remove them."
    check_ai_fix
    exit 0
fi

TS=$(date +%Y%m%d-%H%M%S)
DUMP="./${INSTANCE}_collisions_${TS}.sql"

{
    echo "-- Koha collision dump"
    echo "-- Instance : $INSTANCE"
    echo "-- Database : $DBNAME"
    echo "-- Timestamp: $TS"
    echo "-- Source   : rows in deleted/old tables whose PK also exists in the live table"
    echo "-- Replay   : koha-mysql $INSTANCE < $(basename "$DUMP")"
    echo "USE \`$DBNAME\`;"
    echo "SET FOREIGN_KEY_CHECKS=0;"
    echo
} > "$DUMP"

TOTAL_DELETED=0
for key in "${!FOUND_IDS[@]}"; do
    ARCH="${key%|*}"
    PK="${key#*|}"
    IDS="${FOUND_IDS[$key]}"
    N=$(echo "$IDS" | tr ',' '\n' | wc -l)

    echo "-- ---------- $ARCH ($N rows, PK=$PK) ----------" >> "$DUMP"

    mysqldump --defaults-file=/etc/mysql/koha-common.cnf \
        --no-create-info --skip-extended-insert --skip-comments \
        --complete-insert --skip-add-locks --no-tablespaces \
        "$DBNAME" "$ARCH" --where="$PK IN ($IDS)" \
        >> "$DUMP"

    echo >> "$DUMP"

    run_sql "DELETE FROM $ARCH WHERE $PK IN ($IDS);" >/dev/null
    TOTAL_DELETED=$((TOTAL_DELETED + N))
done

echo "Dump written: $DUMP ($(stat -c%s "$DUMP") bytes)"
echo "Deleted $TOTAL_DELETED row(s) from deleted/old tables."

check_ai_fix
