#!/bin/bash
# update_server.sh — Install or update the PZ dedicated server via SteamCMD
set -euo pipefail

PZ_APP_ID=380870
STEAMCMD="${STEAMCMDDIR:-/opt/steamcmd}/steamcmd.sh"
BETA_BRANCH="${BETA_BRANCH:-}"
STEAM_USERNAME="${STEAM_USERNAME:-}"
STEAM_PASSWORD="${STEAM_PASSWORD:-}"

log() { echo "[update_server] $*" >&2; }

# Ensure the install dir exists and is writable before SteamCMD touches it
mkdir -p /server
chmod 755 /server

log "Install dir: $(ls -ld /server)"
log "Running as: $(id)"
log "SteamCMD: ${STEAMCMD}"

SCRIPT_FILE=$(mktemp /tmp/steamcmd_XXXXXX.txt)
trap 'rm -f "${SCRIPT_FILE}"' EXIT

{
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

log "SteamCMD script:"
cat "${SCRIPT_FILE}" >&2

log "Running SteamCMD..."
"${STEAMCMD}" +runscript "${SCRIPT_FILE}" || {
    EXIT=$?
    # Exit code 7 = already up to date — not an error
    [ $EXIT -ne 7 ] && { log "ERROR: SteamCMD exited with code $EXIT"; exit $EXIT; }
}

log "Server install/update complete"
