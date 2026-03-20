#!/bin/bash
# update_server.sh — Install or update the PZ dedicated server via SteamCMD
set -euo pipefail

PZ_APP_ID=380870
STEAMCMD=/home/steam/steamcmd/steamcmd.sh
BETA_BRANCH="${BETA_BRANCH:-}"
STEAM_USERNAME="${STEAM_USERNAME:-}"
STEAM_PASSWORD="${STEAM_PASSWORD:-}"

log() { echo "[update_server] $*"; }

# Determine login method
if [ -n "${STEAM_USERNAME}" ]; then
    LOGIN_ARGS=("+login" "${STEAM_USERNAME}" "${STEAM_PASSWORD}")
    log "Logging into Steam as ${STEAM_USERNAME}"
else
    LOGIN_ARGS=("+login" "anonymous")
    log "Using anonymous Steam login"
fi

# Build update args — conditional beta branch
UPDATE_ARGS=("+app_update" "${PZ_APP_ID}")
if [ -n "${BETA_BRANCH}" ]; then
    log "Targeting beta branch: ${BETA_BRANCH}"
    UPDATE_ARGS+=("-beta" "${BETA_BRANCH}")
fi
UPDATE_ARGS+=("validate")

log "Running SteamCMD..."
"${STEAMCMD}" \
    +force_install_dir /server \
    "${LOGIN_ARGS[@]}" \
    "${UPDATE_ARGS[@]}" \
    +quit

# SteamCMD exits 7 when "no update needed but already validated" — treat as success
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ] && [ $EXIT_CODE -ne 7 ]; then
    echo "[update_server] ERROR: SteamCMD exited with code $EXIT_CODE" >&2
    exit $EXIT_CODE
fi

log "Server install/update complete"
