#!/bin/bash
# fetch_mods.sh — Fetch a Steam collection, download workshop items, parse mod IDs
#
# Outputs two lines to stdout (consumed by entrypoint.sh):
#   MODS=ModA;ModB;ModC
#   WORKSHOP=111111;222222;333333
set -euo pipefail

PZ_GAME_ID=108600
STEAMCMD="${STEAMCMDDIR:-/home/steam/steamcmd}/steamcmd.sh"
WORKSHOP_CONTENT="/server/steamapps/workshop/content/${PZ_GAME_ID}"

STEAM_COLLECTION_ID="${STEAM_COLLECTION_ID:-}"
EXTRA_WORKSHOP_IDS="${EXTRA_WORKSHOP_IDS:-}"
UPDATE_MODS="${UPDATE_MODS:-true}"
STEAM_USERNAME="${STEAM_USERNAME:-}"
STEAM_PASSWORD="${STEAM_PASSWORD:-}"

log() { echo "[fetch_mods] $*" >&2; }

# ── Step 1: Fetch collection workshop IDs from Steam API ──────────────────────
COLLECTION_WORKSHOP_IDS=()

if [ -n "${STEAM_COLLECTION_ID}" ]; then
    log "Fetching collection ${STEAM_COLLECTION_ID} from Steam API..."

    RESPONSE=$(curl -sf \
        -X POST \
        "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/" \
        -d "collectioncount=1&publishedfileids[0]=${STEAM_COLLECTION_ID}" \
        --connect-timeout 15 \
        --max-time 30)

    RESULT=$(echo "$RESPONSE" | jq -r '.response.collectiondetails[0].result')
    if [ "$RESULT" != "1" ]; then
        log "ERROR: Steam API returned result=${RESULT} for collection ${STEAM_COLLECTION_ID}" >&2
        exit 1
    fi

    # Extract only workshop items (filetype=0); skip sub-collections (filetype=2)
    mapfile -t COLLECTION_WORKSHOP_IDS < <(echo "$RESPONSE" \
        | jq -r '.response.collectiondetails[0].children[] | select(.filetype == 0) | .publishedfileid')

    log "Collection contains ${#COLLECTION_WORKSHOP_IDS[@]} workshop item(s)"
fi

# ── Step 2: Merge extra IDs ───────────────────────────────────────────────────
ALL_WORKSHOP_IDS=("${COLLECTION_WORKSHOP_IDS[@]}")

if [ -n "${EXTRA_WORKSHOP_IDS}" ]; then
    IFS=',' read -ra EXTRA_IDS <<< "${EXTRA_WORKSHOP_IDS}"
    for EID in "${EXTRA_IDS[@]}"; do
        EID=$(echo "$EID" | tr -d ' ')
        [ -n "$EID" ] && ALL_WORKSHOP_IDS+=("$EID")
    done
fi

if [ ${#ALL_WORKSHOP_IDS[@]} -eq 0 ]; then
    log "No workshop IDs to process"
    echo "MODS="
    echo "WORKSHOP="
    exit 0
fi

# ── Step 3: Download workshop items via SteamCMD ──────────────────────────────
# Use +runscript so commands survive steamcmd's self-update restart
MOD_SCRIPT_FILE=$(mktemp /tmp/steamcmd_mods_XXXXXX.txt)
trap 'rm -f "${MOD_SCRIPT_FILE}"' EXIT

{
    echo "@ShutdownOnFailedCommand 1"
    echo "@NoPromptForPassword 1"
    echo "force_install_dir /server"

    if [ -n "${STEAM_USERNAME}" ]; then
        echo "login ${STEAM_USERNAME} ${STEAM_PASSWORD}"
    else
        echo "login anonymous"
    fi

    DOWNLOAD_COUNT=0
    for WID in "${ALL_WORKSHOP_IDS[@]}"; do
        ITEM_PATH="${WORKSHOP_CONTENT}/${WID}"
        if [ -d "$ITEM_PATH" ] && [ "${UPDATE_MODS}" != "true" ]; then
            log "Skipping already-downloaded mod ${WID} (UPDATE_MODS=false)"
        else
            echo "workshop_download_item ${PZ_GAME_ID} ${WID}"
            DOWNLOAD_COUNT=$(( DOWNLOAD_COUNT + 1 ))
        fi
    done

    echo "quit"
} > "${MOD_SCRIPT_FILE}"

log "Downloading workshop item(s) via SteamCMD..."
"${STEAMCMD}" +runscript "${MOD_SCRIPT_FILE}" 2>&1 || {
    EXIT=$?
    [ $EXIT -ne 7 ] && { log "ERROR: SteamCMD exited with code $EXIT"; exit $EXIT; }
}

# ── Step 4: Parse mod.info files to get PZ mod IDs ───────────────────────────
MODS_ARRAY=()
WORKSHOP_ARRAY=()

for WID in "${ALL_WORKSHOP_IDS[@]}"; do
    ITEM_PATH="${WORKSHOP_CONTENT}/${WID}"

    if [ ! -d "$ITEM_PATH" ]; then
        log "WARNING: Workshop item ${WID} not found after download — skipping"
        continue
    fi

    WORKSHOP_ARRAY+=("$WID")

    # PZ mods can have mod.info at the workshop root OR inside mods/<Name>/mod.info
    # Prefer the mods/ subdirectory layout (new style); fall back to root mod.info.
    # Only search 3 levels deep to avoid picking up unrelated nested files.
    FOUND_ANY=false
    while IFS= read -r -d '' MODINFO_FILE; do
        # || true prevents set -e from exiting when grep finds no 'id=' line
        MOD_ID=$(grep -m1 '^id=' "$MODINFO_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '\r\n') || true
        if [ -n "$MOD_ID" ]; then
            log "  Workshop ${WID} → mod ID: ${MOD_ID}"
            MODS_ARRAY+=("$MOD_ID")
            FOUND_ANY=true
        fi
    done < <(find "$ITEM_PATH" -maxdepth 3 -name "mod.info" -print0 2>/dev/null)

    if [ "$FOUND_ANY" = false ]; then
        log "WARNING: No mod.info found in workshop item ${WID}"
    fi
done

# ── Step 5: Output results ────────────────────────────────────────────────────
# Deduplicate while preserving order, join with semicolons
dedup() {
    local -A SEEN=()
    local RESULT=()
    for ITEM in "$@"; do
        if [ -z "${SEEN[$ITEM]+_}" ]; then
            SEEN[$ITEM]=1
            RESULT+=("$ITEM")
        fi
    done
    local OLD_IFS="$IFS"
    IFS=';'
    echo "${RESULT[*]}"
    IFS="$OLD_IFS"
}

MODS_OUT=$(dedup "${MODS_ARRAY[@]+"${MODS_ARRAY[@]}"}")
WORKSHOP_OUT=$(dedup "${WORKSHOP_ARRAY[@]+"${WORKSHOP_ARRAY[@]}"}")

echo "MODS=${MODS_OUT}"
echo "WORKSHOP=${WORKSHOP_OUT}"
