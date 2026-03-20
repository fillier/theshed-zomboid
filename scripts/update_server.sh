#!/bin/bash
# update_server.sh — Install or update the PZ dedicated server via SteamCMD
#
# Uses +runscript so commands survive steamcmd's self-update restart.
set -euo pipefail

PZ_APP_ID=380870
STEAMCMD="${STEAMCMDDIR:-/home/steam/steamcmd}/steamcmd.sh"
BETA_BRANCH="${BETA_BRANCH:-}"
STEAM_USERNAME="${STEAM_USERNAME:-}"
STEAM_PASSWORD="${STEAM_PASSWORD:-}"

log() { echo "[update_server] $*"; }

SCRIPT_FILE=$(mktemp /tmp/steamcmd_XXXXXX.txt)
trap 'rm -f "${SCRIPT_FILE}"' EXIT

{
    echo "@ShutdownOnFailedCommand 1"
    echo "@NoPromptForPassword 1"
    echo "force_install_dir /server"

    if [ -n "${STEAM_USERNAME}" ]; then
        log "Logging into Steam as ${STEAM_USERNAME}"
        echo "login ${STEAM_USERNAME} ${STEAM_PASSWORD}"
    else
        log "Using anonymous Steam login"
        echo "login anonymous"
    fi

    if [ -n "${BETA_BRANCH}" ]; then
        log "Targeting beta branch: ${BETA_BRANCH}"
        echo "app_update ${PZ_APP_ID} -beta ${BETA_BRANCH} validate"
    else
        echo "app_update ${PZ_APP_ID} validate"
    fi

    echo "quit"
} > "${SCRIPT_FILE}"

log "Running SteamCMD..."
"${STEAMCMD}" +runscript "${SCRIPT_FILE}" || {
    EXIT=$?
    # Exit code 7 = already up to date — not an error
    [ $EXIT -ne 7 ] && { log "ERROR: SteamCMD exited with code $EXIT"; exit $EXIT; }
}

log "Server install/update complete"
