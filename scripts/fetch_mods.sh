#!/bin/bash
# fetch_mods.sh — Fetch a Steam collection, download workshop items, parse mod IDs
#
# Outputs two lines to stdout (consumed by entrypoint.sh):
#   MODS=ModA;ModB;ModC
#   WORKSHOP=111111;222222;333333
set -euo pipefail

PZ_GAME_ID=108600
STEAMCMD="${STEAMCMDDIR:-/opt/steamcmd}/steamcmd.sh"
WORKSHOP_CONTENT="/server/steamapps/workshop/content/${PZ_GAME_ID}"

STEAM_COLLECTION_ID="${STEAM_COLLECTION_ID:-}"
EXTRA_WORKSHOP_IDS="${EXTRA_WORKSHOP_IDS:-}"
UPDATE_MODS="${UPDATE_MODS:-true}"
STEAM_USERNAME="${STEAM_USERNAME:-}"
STEAM_PASSWORD="${STEAM_PASSWORD:-}"

log() { echo "[fetch_mods] $*" >&2; }

# Show the exact failing command if anything goes wrong
trap 'log "ERROR at line ${LINENO}: ${BASH_COMMAND}"' ERR

# ── Append an item to a semicolon-separated string if not already present ─────
append_unique() {
    local list="$1" item="$2"
    case ";${list};" in
        *";${item};"*) echo "$list" ;;          # already present
        *) echo "${list:+${list};}${item}" ;;   # append
    esac
}

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
        log "ERROR: Steam API returned result=${RESULT} for collection ${STEAM_COLLECTION_ID}"
        exit 1
    fi

    # Extract only workshop items (filetype=0); skip sub-collections (filetype=2)
    mapfile -t COLLECTION_WORKSHOP_IDS < <(echo "$RESPONSE" \
        | jq -r '.response.collectiondetails[0].children[] | select(.filetype == 0) | .publishedfileid')

    log "Collection contains ${#COLLECTION_WORKSHOP_IDS[@]} workshop item(s)"
fi

# ── Step 2: Merge extra IDs ───────────────────────────────────────────────────
ALL_WORKSHOP_IDS=("${COLLECTION_WORKSHOP_IDS[@]+"${COLLECTION_WORKSHOP_IDS[@]}"}")

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

# ── Step 3: Determine which mods need downloading ─────────────────────────────
TO_DOWNLOAD=()
declare -A STEAM_UPDATE_TIMES

if [ "${UPDATE_MODS}" = "false" ]; then
    # Skip any mod whose directory already exists — fastest restart mode
    for WID in "${ALL_WORKSHOP_IDS[@]}"; do
        ITEM_PATH="${WORKSHOP_CONTENT}/${WID}"
        if [ -d "$ITEM_PATH" ]; then
            log "Skipping ${WID} — already present (UPDATE_MODS=false)"
        else
            TO_DOWNLOAD+=("$WID")
        fi
    done

elif [ "${UPDATE_MODS}" = "force" ]; then
    # Re-download everything unconditionally
    log "Force re-downloading all ${#ALL_WORKSHOP_IDS[@]} mod(s) (UPDATE_MODS=force)"
    TO_DOWNLOAD=("${ALL_WORKSHOP_IDS[@]}")

else
    # Smart update: fetch Steam timestamps, only download new or updated mods
    log "Checking Steam update timestamps for ${#ALL_WORKSHOP_IDS[@]} mod(s)..."

    # Build POST body for a single batched request
    DETAIL_BODY="itemcount=${#ALL_WORKSHOP_IDS[@]}"
    for i in "${!ALL_WORKSHOP_IDS[@]}"; do
        DETAIL_BODY+="&publishedfileids[${i}]=${ALL_WORKSHOP_IDS[$i]}"
    done

    DETAILS=$(curl -sf -X POST \
        "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
        -d "${DETAIL_BODY}" \
        --connect-timeout 15 \
        --max-time 30 2>/dev/null) || DETAILS=""

    if [ -n "$DETAILS" ]; then
        while IFS=$'\t' read -r fid tupdate; do
            STEAM_UPDATE_TIMES["$fid"]="$tupdate"
        done < <(echo "$DETAILS" \
            | jq -r '.response.publishedfiledetails[] | [.publishedfileid, (.time_updated // 0)] | @tsv')
    else
        log "WARNING: Could not reach Steam API for update times — will download all mods"
    fi

    for WID in "${ALL_WORKSHOP_IDS[@]}"; do
        ITEM_PATH="${WORKSHOP_CONTENT}/${WID}"
        CACHE_FILE="${ITEM_PATH}/.steam_update_time"
        STEAM_TIME="${STEAM_UPDATE_TIMES[$WID]:-0}"

        if [ ! -d "$ITEM_PATH" ]; then
            log "Mod ${WID}: not present — queuing download"
            TO_DOWNLOAD+=("$WID")
        elif [ ! -f "$CACHE_FILE" ]; then
            log "Mod ${WID}: no update cache — queuing download"
            TO_DOWNLOAD+=("$WID")
        elif [ "$STEAM_TIME" -gt "$(cat "$CACHE_FILE")" ] 2>/dev/null; then
            log "Mod ${WID}: update available (steam=${STEAM_TIME} > cached=$(cat "$CACHE_FILE")) — queuing"
            TO_DOWNLOAD+=("$WID")
        else
            log "Mod ${WID}: up to date (steam_time=${STEAM_TIME})"
        fi
    done
fi

# ── Step 4: Download workshop items via SteamCMD ──────────────────────────────
MOD_SCRIPT_FILE=$(mktemp /tmp/steamcmd_mods_XXXXXX.txt)
trap 'rm -f "${MOD_SCRIPT_FILE}"' EXIT

if [ ${#TO_DOWNLOAD[@]} -gt 0 ]; then
    log "Downloading ${#TO_DOWNLOAD[@]} of ${#ALL_WORKSHOP_IDS[@]} workshop item(s) via SteamCMD..."

    {
        # No @ShutdownOnFailedCommand here — a single failed mod download shouldn't
        # abort the rest. SteamCMD will report errors but continue.
        echo "@NoPromptForPassword 1"
        echo "force_install_dir /server"

        if [ -n "${STEAM_USERNAME}" ]; then
            echo "login ${STEAM_USERNAME} ${STEAM_PASSWORD}"
        else
            echo "login anonymous"
        fi

        for WID in "${TO_DOWNLOAD[@]}"; do
            echo "workshop_download_item ${PZ_GAME_ID} ${WID}"
        done

        echo "quit"
    } > "${MOD_SCRIPT_FILE}"

    "${STEAMCMD}" +runscript "${MOD_SCRIPT_FILE}" 1>&2 2>&1 || {
        EXIT=$?
        [ $EXIT -ne 7 ] && { log "ERROR: SteamCMD exited with code $EXIT"; exit $EXIT; }
    }

    # Cache the Steam update timestamp so future runs skip unchanged mods
    for WID in "${TO_DOWNLOAD[@]}"; do
        ITEM_PATH="${WORKSHOP_CONTENT}/${WID}"
        STEAM_TIME="${STEAM_UPDATE_TIMES[$WID]:-}"
        if [ -d "$ITEM_PATH" ] && [ -n "$STEAM_TIME" ] && [ "$STEAM_TIME" != "0" ]; then
            echo "$STEAM_TIME" > "${ITEM_PATH}/.steam_update_time"
        fi
    done
else
    log "All mods are up to date — skipping SteamCMD"
fi

# ── Step 5: Parse mod.info files to get PZ mod IDs ───────────────────────────
MODS_OUT=""
WORKSHOP_OUT=""

for WID in "${ALL_WORKSHOP_IDS[@]}"; do
    ITEM_PATH="${WORKSHOP_CONTENT}/${WID}"

    if [ ! -d "$ITEM_PATH" ]; then
        log "WARNING: Workshop item ${WID} not found after download — skipping"
        continue
    fi

    WORKSHOP_OUT=$(append_unique "$WORKSHOP_OUT" "$WID")

    # Use `while read < <(find)` (redirect, not pipe) so the loop body runs in
    # the current shell and variable assignments persist. A pipe (`find | while`)
    # would run the loop in a subshell and lose any assignments.
    FOUND_ANY=false
    while IFS= read -r -d '' MODINFO_FILE; do
        # || true: grep exits 1 when no match found; don't let that kill the script
        MOD_ID=$(grep -m1 '^id=' "$MODINFO_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '\r\n') || true
        if [ -n "$MOD_ID" ]; then
            BEFORE="$MODS_OUT"
            MODS_OUT=$(append_unique "$MODS_OUT" "$MOD_ID")
            # Only log on first discovery (append_unique is a no-op for dupes)
            [ "$MODS_OUT" != "$BEFORE" ] && log "  Workshop ${WID} → mod ID: ${MOD_ID}"
            FOUND_ANY=true
        fi
    done < <(find "$ITEM_PATH" -name "mod.info" -print0 2>/dev/null)

    if [ "$FOUND_ANY" = false ]; then
        log "WARNING: No mod.info found in workshop item ${WID}"
        log "  Contents: $(find "$ITEM_PATH" -maxdepth 3 | sed "s|${ITEM_PATH}/||" | head -20 | tr '\n' ' ')"
    fi
done

# ── Step 6: Output results ────────────────────────────────────────────────────
echo "MODS=${MODS_OUT}"
echo "WORKSHOP=${WORKSHOP_OUT}"
