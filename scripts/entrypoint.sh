#!/bin/bash
# entrypoint.sh — Project Zomboid dedicated server startup orchestration
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SERVER_NAME="${SERVER_NAME:-zomboid}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme}"
SERVER_PORT="${SERVER_PORT:-16261}"
SERVER_PORT_2="${SERVER_PORT_2:-$(( SERVER_PORT + 1 ))}"
RCON_PORT="${RCON_PORT:-27015}"
UPDATE_ON_START="${UPDATE_ON_START:-true}"
UPDATE_MODS="${UPDATE_MODS:-true}"
BETA_BRANCH="${BETA_BRANCH:-}"
STEAM_COLLECTION_ID="${STEAM_COLLECTION_ID:-}"
EXTRA_WORKSHOP_IDS="${EXTRA_WORKSHOP_IDS:-}"

PZ_BIN="/server/start-server.sh"
CONFIG_DIR="/data"
SERVER_CONFIG_DIR="${CONFIG_DIR}/Server"

log() { echo "[entrypoint] $*"; }

# ── Step 1: Install / Update Server ───────────────────────────────────────────
if [ ! -f "$PZ_BIN" ] || [ "${UPDATE_ON_START}" = "true" ]; then
    log "Installing / updating Project Zomboid dedicated server..."
    /app/scripts/update_server.sh
else
    log "Skipping server update (UPDATE_ON_START=false and server already installed)"
fi

# ── Step 2: Fetch and Download Mods ───────────────────────────────────────────
MODS_LIST=""
WORKSHOP_LIST=""

if [ -n "${STEAM_COLLECTION_ID}" ] || [ -n "${EXTRA_WORKSHOP_IDS}" ]; then
    log "Resolving mods..."
    # fetch_mods.sh writes two temp files and prints the paths
    MOD_RESULTS=$(/app/scripts/fetch_mods.sh)
    MODS_LIST=$(echo "$MOD_RESULTS" | grep '^MODS=' | cut -d= -f2-)
    WORKSHOP_LIST=$(echo "$MOD_RESULTS" | grep '^WORKSHOP=' | cut -d= -f2-)
    log "Mods resolved: $(echo "$MODS_LIST" | tr ';' '\n' | wc -l | tr -d ' ') mod(s)"
else
    log "No Steam collection or extra workshop IDs configured — skipping mod fetch"
    # Fall through to any manually set PZ_INI_Mods / PZ_INI_WorkshopItems values
    MODS_LIST="${PZ_INI_Mods:-}"
    WORKSHOP_LIST="${PZ_INI_WorkshopItems:-}"
fi

# Export resolved lists so the config scripts can pick them up
export RESOLVED_MODS="$MODS_LIST"
export RESOLVED_WORKSHOP="$WORKSHOP_LIST"

# ── Step 3: Write Config Files ─────────────────────────────────────────────────
log "Writing server config files..."
mkdir -p "${SERVER_CONFIG_DIR}"

/app/scripts/write_ini.sh
/app/scripts/write_sandbox.sh

# ── Step 4: Start Server ───────────────────────────────────────────────────────
log "Starting Project Zomboid server '${SERVER_NAME}' on port ${SERVER_PORT}..."
log "  Config dir : ${CONFIG_DIR}"
log "  Port       : ${SERVER_PORT} / ${SERVER_PORT_2} (UDP)"
log "  RCON       : ${RCON_PORT} (TCP)"
[ -n "$STEAM_COLLECTION_ID" ] && log "  Collection : ${STEAM_COLLECTION_ID}"
[ -n "$MODS_LIST" ]           && log "  Mods       : ${MODS_LIST}"

exec "${PZ_BIN}" \
    -servername "${SERVER_NAME}" \
    -adminpassword "${ADMIN_PASSWORD}" \
    -configdir "${CONFIG_DIR}" \
    -port "${SERVER_PORT}" \
    -udpport "${SERVER_PORT_2}"
