#!/bin/bash
#=============================================================================
# Task Monitor Daemon
# 
# Ensures there is always at least one pending task due within 23 hours.
# Shows a persistent modal dialog when no such tasks exist.
#
# Features:
# - Checks every 5 minutes (configurable via CHECK_INTERVAL)
# - Dialog covers 70% of screen and cannot be closed without adding a valid task
# - Dialog is always on top (GNOME)
# - Dialog follows workspace changes
# - Avoids duplicate dialogs within 5 minutes
#=============================================================================

set -u

# Configuration
CHECK_INTERVAL=${CHECK_INTERVAL:-300}     # 5 minutes in seconds
TASK_HORIZON="now+23h"                     # Task due time horizon
WINDOW_TITLE="⚠️ 任务提醒"
WORKSPACE_CHECK_INTERVAL=1                 # Check workspace every 1 second

# State
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/task_monitor_daemon"
LOCK_FILE="${STATE_DIR}/daemon.lock"
DIALOG_START_FILE="${STATE_DIR}/dialog_start"
ZENITY_PID=""
DIALOG_WIDTH=1000
DIALOG_HEIGHT=700

#-----------------------------------------------------------------------------
# Initialization
#-----------------------------------------------------------------------------

init() {
    mkdir -p "$STATE_DIR"
    
    # Check for existing instance
    if [[ -f "$LOCK_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            echo "Daemon already running (PID: $old_pid)"
            exit 1
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
}

#-----------------------------------------------------------------------------
# Logging
#-----------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

#-----------------------------------------------------------------------------
# Screen & Window Functions
#-----------------------------------------------------------------------------

get_dialog_dimensions() {
    local dims
    if command -v xdpyinfo &>/dev/null; then
        dims=$(xdpyinfo 2>/dev/null | grep -E '^\s*dimensions:' | head -1 | awk '{print $2}')
        if [[ -n "$dims" ]]; then
            local w h
            w=${dims%x*}
            h=${dims#*x}
            DIALOG_WIDTH=$((w * 70 / 100))
            DIALOG_HEIGHT=$((h * 70 / 100))
        fi
    fi
    log "Dialog dimensions: ${DIALOG_WIDTH}x${DIALOG_HEIGHT}"
}

get_current_workspace() {
    if command -v wmctrl &>/dev/null; then
        wmctrl -d 2>/dev/null | awk '/\*/{print $1; exit}' || echo "0"
    else
        echo "0"
    fi
}


set_window_always_on_top() {
    local max_attempts=10
    local attempt=0

    # -------- Wayland (GNOME) --------
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && \
       [[ "${XDG_CURRENT_DESKTOP:-}" =~ GNOME ]]; then

        # GNOME Shell Eval is best-effort only
        if command -v gdbus >/dev/null 2>&1; then
            log "Wayland/GNOME detected, trying GNOME Shell (best-effort)"

            # Try once or twice only — retries won't bypass Mutter policy
            while (( attempt < 2 )); do
                if gdbus call --session \
                    --dest org.gnome.Shell \
                    --object-path /org/gnome/Shell \
                    --method org.gnome.Shell.Eval \
                    "try {
                        let w = global.display.focus_window;
                        if (w) {
                            w.make_above();
                            true;
                        } else {
                            false;
                        }
                     } catch (e) { false; }" \
                     2>/dev/null | grep -q true; then

                    log "Window set to always-on-top (Wayland/GNOME, best-effort)"
                    return 0
                fi
                sleep 0.3
                ((attempt++))
            done
        fi

        log "Wayland/GNOME: always-on-top not permitted (expected behavior)"
        return 1
    fi

    # -------- X11 --------
    if command -v wmctrl >/dev/null 2>&1; then
        while (( attempt < max_attempts )); do
            if wmctrl -r "$WINDOW_TITLE" -b add,above 2>/dev/null; then
                log "Window set to always-on-top (X11)"
                return 0
            fi
            sleep 0.2
            ((attempt++))
        done
    fi

    log "Warning: Could not set window always-on-top"
    return 1
}

#-----------------------------------------------------------------------------
# Task Functions
#-----------------------------------------------------------------------------

check_tasks_count() {
    local count
    count=$(task due.before:"$TASK_HORIZON" status:pending -OVERDUE count 2>/dev/null || echo "0")
    # Remove non-numeric characters
    count=${count//[^0-9]/}
    echo "${count:-0}"
}

has_valid_tasks() {
    [[ $(check_tasks_count) -gt 0 ]]
}

add_task() {
    local task_input="$1"
    
    if [[ -z "$task_input" ]]; then
        return 1
    fi
    
    # Try to add the task
    if task add $task_input 2>&1; then
        log "Task command executed: $task_input"
        return 0
    else
        log "Task add failed: $task_input"
        return 1
    fi
}

#-----------------------------------------------------------------------------
# Dialog Functions
#-----------------------------------------------------------------------------

kill_zenity() {
    if [[ -n "$ZENITY_PID" ]] && kill -0 "$ZENITY_PID" 2>/dev/null; then
        kill "$ZENITY_PID" 2>/dev/null
        wait "$ZENITY_PID" 2>/dev/null || true
    fi
    ZENITY_PID=""
}

is_dialog_recently_started() {
    if [[ -f "$DIALOG_START_FILE" ]]; then
        local start_time now elapsed
        start_time=$(cat "$DIALOG_START_FILE" 2>/dev/null || echo "0")
        now=$(date +%s)
        elapsed=$((now - start_time))
        # If dialog started less than CHECK_INTERVAL ago, consider it recent
        if ((elapsed < CHECK_INTERVAL)); then
            return 0
        fi
    fi
    return 1
}

mark_dialog_started() {
    date +%s > "$DIALOG_START_FILE"
}

clear_dialog_state() {
    rm -f "$DIALOG_START_FILE"
}

show_success_notification() {
    zenity --info \
        --title="✓ 成功" \
        --text="任务已成功添加！" \
        --timeout=3 \
        --width=300 \
        2>/dev/null || true
}

show_warning_no_due_date() {
    zenity --warning \
        --title="⚠️ 提示" \
        --text="任务已添加，但到期时间不在未来 23 小时内。

请确保任务包含正确的到期时间：
  • due:today — 今天到期
  • due:tomorrow — 明天到期
  • due:2h — 2小时后到期
  • due:eod — 今天结束前

请重新添加一个在 23 小时内到期的任务。" \
        --width=450 \
        2>/dev/null || true
}

show_error_add_failed() {
    zenity --error \
        --title="❌ 错误" \
        --text="添加任务失败，请检查格式后重试。

正确格式示例：
  完成报告 due:today
  开会 due:tomorrow
  提交文档 due:eod" \
        --width=400 \
        2>/dev/null || true
}
DIALOG_SCRIPT="$HOME/.taskList/window.py"

# Enhanced dialog loop with 5-minute prevention
run_dialog_loop() {
    log "Starting dialog (PyQt6)..."
    mark_dialog_started

    # Track last user input time
    local last_input_time=$(date +%s)

    while true; do
        if has_valid_tasks; then
            log "Valid tasks found, skipping dialog"
            clear_dialog_state
            return 0
        fi

        # Check if dialog should be restarted (5-minute rule)
        local now=$(date +%s)
        local elapsed=$((now - last_input_time))

        if [[ "$elapsed" -ge 300 ]]; then  # 5 minutes
            log "More than 5 minutes since last input, not restarting dialog"
            clear_dialog_state
            return 0
        fi

        QT_QPA_PLATFORM=xcb python3 "$DIALOG_SCRIPT"

        # Check if dialog was closed by user (file exists means dialog was active)
        if [[ -f "$DIALOG_START_FILE" ]]; then
            # Update last input time
            last_input_time=$(date +%s)
        fi

        if has_valid_tasks; then
            log "Tasks found after dialog"
            clear_dialog_state
            return 0
        fi

        log "Dialog closed without valid task, reopening..."
        sleep 0.5
    done
}
#-----------------------------------------------------------------------------
# Cleanup
#-----------------------------------------------------------------------------

cleanup() {
    log "Daemon shutting down..."
    kill_zenity
    rm -f "$LOCK_FILE"
    rm -f "$DIALOG_START_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP EXIT

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------

main() {
    log "=========================================="
    log "Task Monitor Daemon starting..."
    log "=========================================="
    
    init
    get_dialog_dimensions
    
    log "Configuration:"
    log "  CHECK_INTERVAL: ${CHECK_INTERVAL}s ($(( CHECK_INTERVAL / 60 )) minutes)"
    log "  TASK_HORIZON: ${TASK_HORIZON}"
    log "  STATE_DIR: ${STATE_DIR}"
    
    # Main monitoring loop
    while true; do
        local task_count
        task_count=$(check_tasks_count)
        log "Checking tasks: $task_count task(s) due within 23h (excluding overdue)"
        
        if [[ "$task_count" -eq 0 ]]; then
            # No valid tasks - need to show dialog
            if is_dialog_recently_started; then
                log "Dialog was recently shown, skipping (5-minute rule)"
            else
                log "No tasks within 23h horizon, showing dialog..."
                run_dialog_loop
            fi
        else
            # Tasks exist, clear any dialog state
            clear_dialog_state
            log "Tasks present, all good"
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
