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
MEMORY="${MEMORY:-8192m}"
RESTART_SCHEDULE="${RESTART_SCHEDULE:-}"
RESTART_WARN_MINUTES="${RESTART_WARN_MINUTES:-10}"
RCON_PASSWORD="${RCON_PASSWORD:-}"

PZ_BIN="/server/start-server.sh"
CONFIG_DIR="/data"
SERVER_CONFIG_DIR="${CONFIG_DIR}/Server"

# ── Link ~/Zomboid to the data volume ──────────────────────────────────────────
# PZ writes saves, logs, and player data to ~/Zomboid regardless of -configdir.
# Symlink it to CONFIG_DIR so all data lands on the mounted /data volume and
# persists across container restarts.
PZ_ZOMBOID_DIR="/home/pzuser/Zomboid"
mkdir -p "$(dirname "${PZ_ZOMBOID_DIR}")"
if [ -d "${PZ_ZOMBOID_DIR}" ] && [ ! -L "${PZ_ZOMBOID_DIR}" ]; then
    log "Migrating ${PZ_ZOMBOID_DIR} → ${CONFIG_DIR} (one-time)..."
    cp -rp "${PZ_ZOMBOID_DIR}/." "${CONFIG_DIR}/" 2>/dev/null || true
    rm -rf "${PZ_ZOMBOID_DIR}"
fi
ln -sf "${CONFIG_DIR}" "${PZ_ZOMBOID_DIR}"

# ── Step 1: Install / Update Server ───────────────────────────────────────────
if [ ! -f "$PZ_BIN" ] || [ "${UPDATE_ON_START}" = "true" ]; then
    log "Installing / updating Project Zomboid dedicated server..."
    /app/scripts/update_server.sh
else
    log "Skipping server update (UPDATE_ON_START=false and server already installed)"
fi

# ── Step 1b: Configure JVM Memory ─────────────────────────────────────────────
# PZ reads heap settings from ProjectZomboid64.json. Patch it after every
# install/update so the MEMORY env var is always applied.
PZ_JSON="/server/ProjectZomboid64.json"
if [ -f "${PZ_JSON}" ]; then
    jq --arg xmx "-Xmx${MEMORY}" --arg xms "-Xms${MEMORY}" \
        '.vmArgs |= map(if startswith("-Xmx") then $xmx elif startswith("-Xms") then $xms else . end)' \
        "${PZ_JSON}" > "${PZ_JSON}.tmp" && mv "${PZ_JSON}.tmp" "${PZ_JSON}"
    log "JVM memory: ${MEMORY} (Xms + Xmx)"
else
    log "WARNING: ${PZ_JSON} not found — memory setting skipped"
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

# ── Step 2b: Configure RCON password ───────────────────────────────────────────
# If RCON_PASSWORD is set, write it into the server ini so RCON actually works.
if [ -n "${RCON_PASSWORD}" ]; then
    export PZ_INI_RCONPassword="${RCON_PASSWORD}"
fi

# ── Step 3: Write Config Files ─────────────────────────────────────────────────
log "Writing server config files..."
mkdir -p "${SERVER_CONFIG_DIR}"

/app/scripts/write_ini.sh
/app/scripts/write_sandbox.sh

# ── Step 4: Start restart scheduler (if configured) ───────────────────────────
if [ -n "${RESTART_SCHEDULE}" ]; then
    log "Starting restart scheduler (schedule: ${RESTART_SCHEDULE}, warn: ${RESTART_WARN_MINUTES}m)..."
    /app/scripts/restart_scheduler.sh &
fi

# ── Step 5: Start Server ───────────────────────────────────────────────────────
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
