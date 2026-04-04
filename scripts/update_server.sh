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
OUTPUT_FILE=$(mktemp /tmp/steamcmd_out_XXXXXX.txt)
trap 'rm -f "${SCRIPT_FILE}" "${OUTPUT_FILE}"' EXIT

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

MAX_RETRIES=5
RETRY_DELAY=30

for attempt in $(seq 1 $MAX_RETRIES); do
    log "Running SteamCMD (attempt ${attempt}/${MAX_RETRIES})..."
    "${STEAMCMD}" +runscript "${SCRIPT_FILE}" 2>&1 | tee "${OUTPUT_FILE}"
    EXIT=${PIPESTATUS[0]}

    # SteamCMD frequently exits 0 even on failure — check stdout for error strings
    if grep -q "ERROR!" "${OUTPUT_FILE}"; then
        log "SteamCMD reported an error (exit ${EXIT})"
    elif [ $EXIT -eq 0 ] || [ $EXIT -eq 7 ]; then
        # Exit 7 = already up to date — also fine
        log "Server install/update complete"
        exit 0
    else
        log "SteamCMD exited with code ${EXIT}"
    fi

    if [ $attempt -lt $MAX_RETRIES ]; then
        log "Retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
    fi
done

log "ERROR: SteamCMD failed after ${MAX_RETRIES} attempts"
exit 1
