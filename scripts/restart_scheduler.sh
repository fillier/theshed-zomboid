#!/bin/bash
# restart_scheduler.sh — Send in-game warnings and restart the PZ server on a schedule.
#
# Runs in the background during server operation. When the restart time arrives it
# sends countdown warnings via RCON then sends SIGTERM to PID 1 (tini), which
# propagates to the PZ process for a graceful shutdown. Docker's restart policy
# then brings the container (and this scheduler) back up.
#
# Config (set in .env):
#   RESTART_SCHEDULE      Daily time "HH:MM"  OR  interval "Xh" / "Xm"
#   RESTART_WARN_MINUTES  Minutes of warning before restart  (default: 10)
#   RCON_PORT             Port to reach the RCON interface    (default: 27015)
#   RCON_PASSWORD         Password for RCON access            (required for warnings)
set -euo pipefail

RESTART_SCHEDULE="${RESTART_SCHEDULE:-}"
RESTART_WARN_MINUTES="${RESTART_WARN_MINUTES:-10}"
RCON_PORT="${RCON_PORT:-27015}"
RCON_PASSWORD="${RCON_PASSWORD:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scheduler] $*"; }

# ── Parse schedule and return seconds until next restart ──────────────────────
next_restart_seconds() {
    local schedule="$1"
    local now
    now=$(date +%s)

    # Interval format: Xh (hours) or Xm (minutes)
    if [[ "$schedule" =~ ^([0-9]+)h$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 3600 ))
        return
    fi
    if [[ "$schedule" =~ ^([0-9]+)m$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 60 ))
        return
    fi

    # Daily time format: HH:MM  (respects TZ env var if set)
    if [[ "$schedule" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        local h="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}"
        local target
        target=$(date -d "today ${h}:${m}" +%s 2>/dev/null) || {
            log "ERROR: 'date' could not parse time '${h}:${m}' — check your TZ setting"
            exit 1
        }
        # If that time has already passed today, schedule for tomorrow
        [ "$target" -le "$now" ] && target=$(date -d "tomorrow ${h}:${m}" +%s)
        echo $(( target - now ))
        return
    fi

    log "ERROR: Unrecognised RESTART_SCHEDULE format '${schedule}'"
    log "  Valid formats: HH:MM (daily, e.g. 04:00) | Xh (every X hours) | Xm (every X minutes)"
    exit 1
}

# ── Send an RCON command — failures are non-fatal ─────────────────────────────
rcon_send() {
    if [ -z "${RCON_PASSWORD}" ]; then
        return 0
    fi
    python3 /app/scripts/rcon.py \
        --host 127.0.0.1 \
        --port "${RCON_PORT}" \
        --password "${RCON_PASSWORD}" \
        "$@" 2>/dev/null || true
}

# Send a visible in-game server message
server_say() {
    local msg="$1"
    log "Broadcast: ${msg}"
    rcon_send servermsg "\"${msg}\""
}

# ── Graceful shutdown ─────────────────────────────────────────────────────────
do_restart() {
    log "Initiating graceful restart..."
    server_say "Server is restarting NOW. See you in a moment!"
    sleep 3
    PID_FILE=/data/.pz_server.pid
    if [ -f "${PID_FILE}" ]; then
        log "Sending SIGTERM to PZ server (PID $(cat "${PID_FILE}"))..."
        kill -TERM "$(cat "${PID_FILE}")"
    else
        log "WARNING: PID file not found — cannot signal server"
    fi
}

# ── Guards ────────────────────────────────────────────────────────────────────
if [ -z "${RESTART_SCHEDULE}" ]; then
    log "RESTART_SCHEDULE not set — scheduler exiting"
    exit 0
fi

if [ -z "${RCON_PASSWORD}" ]; then
    log "WARNING: RCON_PASSWORD not set — restart will happen silently (no in-game warnings)"
fi

log "Schedule  : ${RESTART_SCHEDULE}"
log "Warn time : ${RESTART_WARN_MINUTES} minute(s) before restart"
[ -n "${RCON_PASSWORD}" ] && log "RCON      : 127.0.0.1:${RCON_PORT}"

# Give the server time to fully start before the first schedule calculation
sleep 60

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
    SECS=$(next_restart_seconds "${RESTART_SCHEDULE}")
    RESTART_AT=$(date -d "+${SECS} seconds" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
                 || date -r $(( $(date +%s) + SECS )) '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                 || echo "in ${SECS}s")
    log "Next restart at ${RESTART_AT} (${SECS}s from now)"

    WARN_SECONDS=$(( RESTART_WARN_MINUTES * 60 ))

    if [ "$SECS" -le 0 ]; then
        do_restart
        break
    fi

    if [ "$SECS" -le "$WARN_SECONDS" ]; then
        # Already inside the warning window — go straight to sleep-until-restart
        sleep "$SECS"
        do_restart
        break
    fi

    # Sleep until we enter the warning window
    sleep $(( SECS - WARN_SECONDS ))

    # ── Warning countdown ──────────────────────────────────────────────────────
    # Warn at 10 min, 5 min, and 1 min before restart — skip any that don't fit
    # the configured RESTART_WARN_MINUTES window.
    ELAPSED=0

    for WARN_AT in 600 300 60; do
        WARN_MSG=""
        case $WARN_AT in
            600) WARN_MSG="10 minutes" ;;
            300) WARN_MSG="5 minutes"  ;;
            60)  WARN_MSG="1 minute"   ;;
        esac

        if [ "$WARN_SECONDS" -gt "$WARN_AT" ]; then
            TARGET=$(( WARN_SECONDS - WARN_AT ))
            SLEEP_FOR=$(( TARGET - ELAPSED ))
            if [ "$SLEEP_FOR" -gt 0 ]; then
                sleep "$SLEEP_FOR"
                ELAPSED=$TARGET
            fi
            server_say "Server restart in ${WARN_MSG}."
        fi
    done

    # Sleep the final 60 seconds (or whatever remains after the last warning)
    REMAINING=$(( WARN_SECONDS - ELAPSED ))
    [ "$REMAINING" -gt 0 ] && sleep "$REMAINING"

    do_restart

    # After signaling the server, Docker tears down the container which will
    # also terminate this script. Sleep briefly as a safety net.
    sleep 10
done
