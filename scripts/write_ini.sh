#!/bin/bash
# write_ini.sh — Upsert PZ_INI_* env vars into the server .ini file.
#
# On first run (no ini exists): creates the file with VERSION=1 and all keys.
# On subsequent runs: updates existing keys in place, leaves server-generated
# fields (ResetID, ServerPlayerID, etc.) untouched.
set -euo pipefail

SERVER_NAME="${SERVER_NAME:-zomboid}"
RCON_PORT="${RCON_PORT:-27015}"
SERVER_PORT="${SERVER_PORT:-16261}"
INI_FILE="/data/Server/${SERVER_NAME}.ini"
RESOLVED_MODS="${RESOLVED_MODS:-}"
RESOLVED_WORKSHOP="${RESOLVED_WORKSHOP:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [write_ini] $*"; }

mkdir -p "/data/Server"

# Initialise the file with VERSION=1 if it doesn't exist yet.
# PZ requires VERSION=1 as the first line or it ignores the config entirely.
if [ ! -f "${INI_FILE}" ]; then
    log "Creating ${INI_FILE}"
    echo "VERSION=1" > "${INI_FILE}"
fi

# Upsert a key=value pair: update the line in place if the key exists,
# append it otherwise. Uses ENVIRON[] so values with backslashes/& are safe.
upsert() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "${INI_FILE}" 2>/dev/null; then
        KEY="$key" VAL="$val" awk '
            BEGIN { k=ENVIRON["KEY"]; v=ENVIRON["VAL"] }
            index($0, k "=") == 1 { print k "=" v; next }
            { print }
        ' "${INI_FILE}" > "${INI_FILE}.tmp" && mv "${INI_FILE}.tmp" "${INI_FILE}"
    else
        printf '%s=%s\n' "$key" "$val" >> "${INI_FILE}"
    fi
}

log "Applying config to ${INI_FILE}..."

# ── Apply all PZ_INI_* env vars ───────────────────────────────────────────────
while IFS= read -r LINE; do
    KEY="${LINE#PZ_INI_}"
    INI_KEY="${KEY%%=*}"
    INI_VAL="${KEY#*=}"

    # Skip mod lists and VERSION — handled separately below
    [ "$INI_KEY" = "Mods" ]         && continue
    [ "$INI_KEY" = "WorkshopItems" ] && continue
    [ "$INI_KEY" = "VERSION" ]       && continue

    upsert "$INI_KEY" "$INI_VAL"
done < <(env | grep '^PZ_INI_' | sort)

# ── Mod lists: merge resolved (from collection) with any manually set values ──
MANUAL_MODS="${PZ_INI_Mods:-}"
MANUAL_WORKSHOP="${PZ_INI_WorkshopItems:-}"

if [ -n "${RESOLVED_MODS}" ]; then
    FINAL_MODS="${RESOLVED_MODS}"
    [ -n "${MANUAL_MODS}" ] && FINAL_MODS="${FINAL_MODS};${MANUAL_MODS}"
else
    FINAL_MODS="${MANUAL_MODS}"
fi

if [ -n "${RESOLVED_WORKSHOP}" ]; then
    FINAL_WORKSHOP="${RESOLVED_WORKSHOP}"
    [ -n "${MANUAL_WORKSHOP}" ] && FINAL_WORKSHOP="${FINAL_WORKSHOP};${MANUAL_WORKSHOP}"
else
    FINAL_WORKSHOP="${MANUAL_WORKSHOP}"
fi

upsert "Mods"          "${FINAL_MODS}"
upsert "WorkshopItems" "${FINAL_WORKSHOP}"
upsert "DefaultPort"   "${SERVER_PORT}"
upsert "RCONPort"      "${RCON_PORT}"

log "Password  : $(grep '^Password=' "${INI_FILE}" | cut -d= -f2- || echo '<not set>')"
log "MaxPlayers: $(grep '^MaxPlayers=' "${INI_FILE}" | cut -d= -f2- || echo '<not set>')"
log "Mods      : ${FINAL_MODS:-<none>}"
log "Done — $(wc -l < "${INI_FILE}") lines"
