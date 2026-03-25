#!/bin/bash
# mod_watcher.sh — Poll Steam for mod updates; restart the server when detected.
#
# Runs in the background alongside the PZ server. On each poll it makes a single
# batched request to GetPublishedFileDetails for all workshop items and compares
# the returned time_updated against the cached .steam_update_time timestamps that
# fetch_mods.sh writes on download. When any mod is newer it triggers a graceful
# restart via the same RCON warning → SIGTERM flow used by the scheduler.
#
# Rate-limit behaviour:
#   A single batched API call covers all mods regardless of collection size.
#   At the 10-minute default that is 144 calls/day — well within Steam's
#   100,000/day limit. On HTTP 429 the interval is doubled with ±10% jitter,
#   capped at 1 hour, then reset to normal on the next successful response.
#
# Config (set in .env):
#   MOD_UPDATE_CHECK      Enable this watcher (default: true)
#   MOD_CHECK_INTERVAL    Poll interval: Xh | Xm | Xs  (default: 10m)
#   RESTART_WARN_MINUTES  Warning window shared with restart_scheduler.sh
#   RCON_PORT / RCON_PASSWORD  For in-game countdown messages
set -euo pipefail

MOD_UPDATE_CHECK="${MOD_UPDATE_CHECK:-true}"
MOD_CHECK_INTERVAL="${MOD_CHECK_INTERVAL:-10m}"
RESTART_WARN_MINUTES="${RESTART_WARN_MINUTES:-10}"
RCON_PORT="${RCON_PORT:-27015}"
RCON_PASSWORD="${RCON_PASSWORD:-}"

PZ_GAME_ID=108600
WORKSHOP_CONTENT="/server/steamapps/workshop/content/${PZ_GAME_ID}"
WORKSHOP_IDS_FILE="/data/.workshop_ids"

log() { echo "[mod_watcher] $*"; }

# ── Parse an interval string (Xh / Xm / Xs) to seconds ───────────────────────
interval_to_seconds() {
    local s="$1"
    if   [[ "$s" =~ ^([0-9]+)h$ ]]; then echo $(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ "$s" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]} * 60  ))
    elif [[ "$s" =~ ^([0-9]+)s?$ ]]; then echo "${BASH_REMATCH[1]}"
    else
        log "ERROR: Invalid MOD_CHECK_INTERVAL '${s}' — use Xh, Xm, or Xs (e.g. 10m, 1h)"
        exit 1
    fi
}

# ── RCON helpers ──────────────────────────────────────────────────────────────
rcon_send() {
    [ -z "${RCON_PASSWORD}" ] && return 0
    python3 /app/scripts/rcon.py \
        --host 127.0.0.1 \
        --port "${RCON_PORT}" \
        --password "${RCON_PASSWORD}" \
        "$@" 2>/dev/null || true
}

server_say() {
    log "Broadcast: $1"
    rcon_send servermsg "\"$1\""
}

# ── Warning countdown then graceful shutdown ───────────────────────────────────
warn_and_restart() {
    local reason="$1"
    log "${reason} — restarting with ${RESTART_WARN_MINUTES}m warning"
    [ -n "${RCON_PASSWORD}" ] || log "(no RCON_PASSWORD — restart will be silent)"

    local warn_seconds=$(( RESTART_WARN_MINUTES * 60 ))
    local elapsed=0

    for WARN_AT in 600 300 60; do
        local warn_msg
        case $WARN_AT in
            600) warn_msg="10 minutes" ;;
            300) warn_msg="5 minutes"  ;;
            60)  warn_msg="1 minute"   ;;
        esac

        if [ "$warn_seconds" -gt "$WARN_AT" ]; then
            local target=$(( warn_seconds - WARN_AT ))
            local sleep_for=$(( target - elapsed ))
            [ "$sleep_for" -gt 0 ] && sleep "$sleep_for"
            elapsed=$target
            server_say "Server restart in ${warn_msg} (mod update available)."
        fi
    done

    local remaining=$(( warn_seconds - elapsed ))
    [ "$remaining" -gt 0 ] && sleep "$remaining"

    log "Sending SIGTERM to PID 1 (tini) for graceful shutdown..."
    server_say "Server is restarting NOW to apply mod updates. See you in a moment!"
    sleep 3
    kill -TERM 1
    sleep 10  # won't normally be reached
}

# ── Single poll: returns 0=up-to-date  1=updates-found  2=api-error ──────────
check_for_updates() {
    if [ ! -f "${WORKSHOP_IDS_FILE}" ] || [ ! -s "${WORKSHOP_IDS_FILE}" ]; then
        log "No workshop IDs on record — nothing to check"
        return 0
    fi

    mapfile -t WIDs < "${WORKSHOP_IDS_FILE}"
    [ ${#WIDs[@]} -eq 0 ] && return 0

    # Single batched request for all workshop items
    local post_body="itemcount=${#WIDs[@]}"
    for i in "${!WIDs[@]}"; do
        post_body+="&publishedfileids[${i}]=${WIDs[$i]}"
    done

    local tmp_body
    tmp_body=$(mktemp /tmp/steam_details_XXXXXX.json)
    trap 'rm -f "${tmp_body}"' RETURN

    local http_code
    http_code=$(curl -s -o "${tmp_body}" -w "%{http_code}" \
        -X POST \
        "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/" \
        -d "${post_body}" \
        --connect-timeout 15 \
        --max-time 30 2>/dev/null) || { log "WARNING: Steam API request failed (network error)"; return 2; }

    if [ "$http_code" = "429" ]; then
        log "WARNING: Steam API rate-limited (HTTP 429) — backing off"
        return 2
    elif [ "$http_code" != "200" ]; then
        log "WARNING: Steam API returned HTTP ${http_code} — backing off"
        return 2
    fi

    local updated=()
    while IFS=$'\t' read -r fid steam_time; do
        local cache_file="${WORKSHOP_CONTENT}/${fid}/.steam_update_time"
        local cached_time=0
        [ -f "$cache_file" ] && cached_time=$(cat "$cache_file")

        if [ "$steam_time" -gt "$cached_time" ] 2>/dev/null; then
            log "Update detected: workshop ${fid} (steam=${steam_time}, cached=${cached_time})"
            updated+=("$fid")
        fi
    done < <(jq -r '.response.publishedfiledetails[] | [.publishedfileid, (.time_updated // 0)] | @tsv' \
             "${tmp_body}" 2>/dev/null)

    if [ ${#updated[@]} -gt 0 ]; then
        log "${#updated[@]} updated mod(s): ${updated[*]}"
        return 1
    fi

    return 0
}

# ── Guards ────────────────────────────────────────────────────────────────────
if [ "${MOD_UPDATE_CHECK}" != "true" ]; then
    log "MOD_UPDATE_CHECK != true — exiting"
    exit 0
fi

INTERVAL_SECS=$(interval_to_seconds "${MOD_CHECK_INTERVAL}")

log "Mod update watcher starting"
log "  Poll interval : ${MOD_CHECK_INTERVAL} (${INTERVAL_SECS}s)"
log "  Warn window   : ${RESTART_WARN_MINUTES} minute(s)"
[ -n "${RCON_PASSWORD}" ] && log "  RCON          : 127.0.0.1:${RCON_PORT}"

# Give the server time to fully initialise before the first check
sleep 90

# ── Poll loop ─────────────────────────────────────────────────────────────────
MAX_BACKOFF=$(( 60 * 60 ))  # cap exponential backoff at 1 hour
current_interval=$INTERVAL_SECS

while true; do
    sleep "$current_interval"

    check_for_updates
    status=$?

    case $status in
        0)
            # All mods up to date
            log "All mods up to date (next check in ${MOD_CHECK_INTERVAL})"
            if [ "$current_interval" -ne "$INTERVAL_SECS" ]; then
                log "API healthy again — resuming normal ${MOD_CHECK_INTERVAL} interval"
            fi
            current_interval=$INTERVAL_SECS
            ;;
        1)
            # Update(s) found — warn players and restart
            warn_and_restart "Mod update(s) detected"
            ;;
        2)
            # API error or rate limit — exponential backoff with ±10% jitter
            current_interval=$(( current_interval * 2 ))
            [ "$current_interval" -gt "$MAX_BACKOFF" ] && current_interval=$MAX_BACKOFF
            local_jitter=$(( current_interval / 10 ))
            current_interval=$(( current_interval - local_jitter + RANDOM % (local_jitter * 2 + 1) ))
            log "Next check in ${current_interval}s"
            ;;
    esac
done
