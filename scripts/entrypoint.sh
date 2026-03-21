#!/bin/bash
# entrypoint.sh — Project Zomboid dedicated server startup orchestration
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# ── Privilege setup ────────────────────────────────────────────────────────────
# Runs once as root to create the target user/group and fix volume ownership,
# then re-execs this script as that user. All subsequent steps run unprivileged.
if [ "$(id -u)" = "0" ]; then
    PUID="${PUID:-1000}"
    PGID="${PGID:-1000}"

    log "Setting up user uid=${PUID} gid=${PGID}..."

    # Create group with the requested GID if it doesn't already exist
    if ! getent group "${PGID}" >/dev/null 2>&1; then
        groupadd --gid "${PGID}" pzgroup
    fi

    # Create user with the requested UID if it doesn't already exist
    if ! getent passwd "${PUID}" >/dev/null 2>&1; then
        useradd --uid "${PUID}" --gid "${PGID}" \
                --home-dir /home/pzuser --create-home \
                --shell /bin/bash pzuser
    fi

    # If the server was previously run as root (or a different UID), the steamapps
    # subtree will be owned by that old user. SteamCMD running as the new UID
    # can't write into it, so workshop mods end up in the wrong place.
    # Detect this and do a one-time recursive chown to fix ownership.
    for DIR in /server /data; do
        EXISTING_OWNER=$(stat -c '%u' "${DIR}" 2>/dev/null || echo "")
        if [ -n "$EXISTING_OWNER" ] && [ "$EXISTING_OWNER" != "${PUID}" ]; then
            log "Fixing ownership of ${DIR} (uid was ${EXISTING_OWNER}, changing to ${PUID} — may take a moment)..."
            chown -R "${PUID}:${PGID}" "${DIR}"
        else
            chown "${PUID}:${PGID}" "${DIR}"
        fi
    done

    log "Dropping to uid=${PUID} gid=${PGID}"
    exec gosu "${PUID}:${PGID}" "$0" "$@"
fi

# ── Defaults ───────────────────────────────────────────────────────────────────
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
    MOD_RESULTS=$(/app/scripts/fetch_mods.sh)
    MODS_LIST=$(echo "$MOD_RESULTS" | grep '^MODS=' | cut -d= -f2- || true)
    WORKSHOP_LIST=$(echo "$MOD_RESULTS" | grep '^WORKSHOP=' | cut -d= -f2- || true)
    log "Mod IDs  : ${MODS_LIST:-<none>}"
    log "Workshop : ${WORKSHOP_LIST:-<none>}"
else
    log "No Steam collection or extra workshop IDs configured — skipping mod fetch"
    MODS_LIST="${PZ_INI_Mods:-}"
    WORKSHOP_LIST="${PZ_INI_WorkshopItems:-}"
fi

export RESOLVED_MODS="$MODS_LIST"
export RESOLVED_WORKSHOP="$WORKSHOP_LIST"

# ── Step 3: Write Config Files ─────────────────────────────────────────────────
log "Writing server config files..."
mkdir -p "${SERVER_CONFIG_DIR}"

/app/scripts/write_ini.sh
/app/scripts/write_sandbox.sh

# ── Step 4: Start Server ───────────────────────────────────────────────────────
log "Starting Project Zomboid server '${SERVER_NAME}' on port ${SERVER_PORT}..."
log "  Running as : $(id)"
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
