#!/usr/bin/env bash
#
# Pretty update status display for Arch Linux.
# Parses /var/log/arch-update.log (written by arch-update) and checks for
# currently pending updates.  Intended for .bashrc — exits silently if the log
# doesn't exist or checkupdates is unavailable.
#
# Usage:  source this or call it directly:
#   update-check            # show last update result
#   update-check --verbose   # show last update + pending updates
#   update-check --pending   # only show pending updates

# ── Colours & symbols ────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

SYM_OK="✔"
SYM_WARN="⚠"
SYM_ERR="✘"
SYM_DEFER="⏸"
SYM_PKG="📦"
SYM_UP="⬆"
SYM_TIME="🕐"

LOG="/var/log/arch-update.log"

# ── Helpers ──────────────────────────────────────────────────────────────────

_relative_time() {
    local ts="$1"
    local epoch_ts epoch_now diff
    epoch_ts=$(date -d "$ts" '+%s' 2>/dev/null) || return
    epoch_now=$(date '+%s')
    diff=$(( epoch_now - epoch_ts ))

    if   (( diff < 60 ));    then echo "just now"
    elif (( diff < 3600 ));  then echo "$(( diff / 60 ))m ago"
    elif (( diff < 86400 )); then echo "$(( diff / 3600 ))h ago"
    elif (( diff < 604800 )); then echo "$(( diff / 86400 ))d ago"
    else echo "$(( diff / 604800 ))w ago"
    fi
}

# ── Parse last update session from log ───────────────────────────────────────

_parse_last_session() {
    [[ -r "$LOG" ]] || return 1

    local last_start last_ts outcome pkg_count critical_names
    local aur_status snapshot_info

    # Find the line number of the last "Starting daily update" entry
    last_start=$(grep -n "=== Starting daily update ===" "$LOG" | tail -1 | cut -d: -f1)
    [[ -z "$last_start" ]] && return 1

    # Extract the session block (from last start to end of file)
    local session
    session=$(tail -n +"$last_start" "$LOG")

    # Timestamp of the session start
    last_ts=$(echo "$session" | head -1 | grep -oP '^\[\K[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}')

    # Determine outcome
    if echo "$session" | grep -q "=== Update complete ==="; then
        outcome="complete"
    elif echo "$session" | grep -q "=== Update deferred ==="; then
        outcome="deferred"
    elif echo "$session" | grep -q "=== Update failed ==="; then
        outcome="failed"
    elif echo "$session" | grep -q "System is up to date"; then
        outcome="up-to-date"
    else
        outcome="in-progress"
    fi

    # Package count
    pkg_count=$(echo "$session" | grep -oP 'Pending updates \(\K[0-9]+' | head -1) || true

    # Critical packages (if deferred)
    critical_names=$(echo "$session" | grep -oP 'Critical: \K[^.]+' | head -1) || true

    # AUR status
    if echo "$session" | grep -q "AUR packages updated successfully"; then
        aur_status="ok"
    elif echo "$session" | grep -q "AUR update failed"; then
        aur_status="failed"
    else
        aur_status=""
    fi

    # Snapshot info
    snapshot_info=$(echo "$session" | grep -oP 'Pre-upgrade snapshot #\K[0-9]+' | head -1) || true

    # Export results
    _LAST_TS="$last_ts"
    _LAST_OUTCOME="$outcome"
    _LAST_PKG_COUNT="${pkg_count:-0}"
    _LAST_CRITICAL="${critical_names:-}"
    _LAST_AUR="$aur_status"
    _LAST_SNAP="${snapshot_info:-}"
}

# ── Display last update result ───────────────────────────────────────────────

_show_last_update() {
    if ! _parse_last_session; then
        printf "  ${DIM}No update history found${NC}\n"
        return
    fi

    local rel_time icon colour status_text
    rel_time=$(_relative_time "$_LAST_TS")

    case "$_LAST_OUTCOME" in
        complete)
            icon="$SYM_OK"  colour="$GREEN"  status_text="Upgrade complete"
            ;;
        deferred)
            icon="$SYM_DEFER" colour="$YELLOW" status_text="Deferred (manual upgrade required)"
            ;;
        failed)
            icon="$SYM_ERR" colour="$RED"    status_text="Upgrade failed"
            ;;
        up-to-date)
            icon="$SYM_OK"  colour="$GREEN"  status_text="System was up to date"
            ;;
        in-progress)
            icon="$SYM_WARN" colour="$YELLOW" status_text="Update may still be running"
            ;;
    esac

    printf "  ${colour}${icon} ${status_text}${NC}"
    [[ -n "$rel_time" ]] && printf "  ${DIM}${SYM_TIME} %s${NC}" "$rel_time"
    printf "\n"

    if [[ "$_LAST_PKG_COUNT" -gt 0 && "$_LAST_OUTCOME" != "up-to-date" ]]; then
        printf "    ${DIM}${SYM_PKG} %s package(s)${NC}" "$_LAST_PKG_COUNT"
        [[ -n "$_LAST_SNAP" ]] && printf "  ${DIM}snapshot #%s${NC}" "$_LAST_SNAP"
        printf "\n"
    fi

    if [[ -n "$_LAST_CRITICAL" ]]; then
        printf "    ${YELLOW}Critical: %s${NC}\n" "$_LAST_CRITICAL"
    fi

    if [[ "$_LAST_AUR" == "ok" ]]; then
        printf "    ${DIM}AUR ${GREEN}${SYM_OK}${NC}\n"
    elif [[ "$_LAST_AUR" == "failed" ]]; then
        printf "    ${DIM}AUR ${RED}${SYM_ERR} failed${NC}\n"
    fi
}

# ── Display pending updates ─────────────────────────────────────────────────

_show_pending() {
    if ! command -v checkupdates &>/dev/null; then
        printf "  ${DIM}checkupdates not available (install pacman-contrib)${NC}\n"
        return
    fi

    local pending
    pending=$(checkupdates 2>/dev/null) || true

    if [[ -z "$pending" ]]; then
        printf "  ${GREEN}${SYM_OK} No pending updates${NC}\n"
        return
    fi

    local count
    count=$(echo "$pending" | wc -l)
    printf "  ${CYAN}${SYM_UP} %s update(s) available${NC}\n" "$count"

    # Show up to 10 packages, summarise if more
    local shown=0
    while IFS= read -r line; do
        if (( shown >= 10 )); then
            printf "    ${DIM}… and %s more${NC}\n" "$(( count - shown ))"
            break
        fi
        local pkg old_ver _arrow new_ver
        read -r pkg old_ver _arrow new_ver <<< "$line"
        printf "    ${DIM}%-30s${NC} %s ${DIM}→${NC} ${WHITE}%s${NC}\n" "$pkg" "$old_ver" "$new_ver"
        (( shown++ ))
    done <<< "$pending"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    local show_last=true show_pending=false

    case "${1:-}" in
        --verbose|-v) show_pending=true  ;;
        --pending)    show_last=false; show_pending=true ;;
        --help|-h)
            echo "Usage: update-check [--verbose|--pending|--help]"
            return 0
            ;;
    esac

    printf "\n"

    if [[ "$show_last" == true ]]; then
        printf "  ${BOLD}${MAGENTA}Last Update${NC}\n"
        _show_last_update
    fi

    if [[ "$show_pending" == true ]]; then
        [[ "$show_last" == true ]] && printf "\n"
        printf "  ${BOLD}${MAGENTA}Pending Updates${NC}\n"
        _show_pending
    fi

    printf "\n"
}

main "$@"
