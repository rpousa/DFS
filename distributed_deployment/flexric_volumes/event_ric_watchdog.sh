#!/bin/bash

# === Configuration ===
RIC_BIN="/usr/local/bin/nearRT-RIC"
RIC_CONF="/usr/local/etc/flexric/flexric.conf"
RIC_LOG_DIR="/usr/local/etc/flexric_logs"
WATCHDOG_LOG="/var/log/ric_watchdog.log"
INDEX_FILE="/var/run/ric_restart_index"
XAPP_SCRIPT="/usr/local/flexric/xApp/python3/xapp_daemon.py"
XAPP_PID_FILE="/var/run/xapp_daemon.pid"
PAUSE_FILE="/tmp/ric_watchdog.pause"
CHECK_INTERVAL=2

mkdir -p "$RIC_LOG_DIR"

if [ -f "$INDEX_FILE" ]; then
    RESTART_INDEX=$(cat "$INDEX_FILE")
else
    RESTART_INDEX=0
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting nearRT-RIC watchdog (current index: $RESTART_INDEX)..." >> "$WATCHDOG_LOG"

start_xapp() {
    # Kill any existing xApp
    if [ -f "$XAPP_PID_FILE" ]; then
        local old_pid=$(cat "$XAPP_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Stopping old xApp (PID: $old_pid)..." >> "$WATCHDOG_LOG"
            kill "$old_pid" 2>/dev/null
            sleep 2
            kill -9 "$old_pid" 2>/dev/null || true
        fi
    fi

    # Wait for RIC to be fully ready
    sleep 8

    local XAPP_LOG="${RIC_LOG_DIR}/xapp_instance_${RESTART_INDEX}.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [Instance #${RESTART_INDEX}] Starting xApp daemon..." >> "$WATCHDOG_LOG"

    cd /usr/local/flexric/xApp/python3/
    nohup python3 "$XAPP_SCRIPT" > "$XAPP_LOG" 2>&1 &
    local xapp_pid=$!
    echo "$xapp_pid" > "$XAPP_PID_FILE"

    echo "$(date '+%Y-%m-%d %H:%M:%S') - [Instance #${RESTART_INDEX}] xApp started (PID: $xapp_pid, Log: $XAPP_LOG)" >> "$WATCHDOG_LOG"
}

while true; do

    if [ -f "$PAUSE_FILE" ]; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if ! pgrep -x "nearRT-RIC" > /dev/null; then
        RESTART_INDEX=$((RESTART_INDEX + 1))
        echo "$RESTART_INDEX" > "$INDEX_FILE"

        RIC_LOG="${RIC_LOG_DIR}/flexric_instance_${RESTART_INDEX}.log"

        echo "$(date '+%Y-%m-%d %H:%M:%S') - [Instance #${RESTART_INDEX}] nearRT-RIC is down. Restarting..." >> "$WATCHDOG_LOG"

        nohup stdbuf -oL -eL "$RIC_BIN" -c "$RIC_CONF" > "$RIC_LOG" 2>&1 &
        RIC_PID=$!

        sleep 5

        if pgrep -x "nearRT-RIC" > /dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [Instance #${RESTART_INDEX}] nearRT-RIC restarted (PID: $RIC_PID)." >> "$WATCHDOG_LOG"
            # Start xApp after RIC is up
            start_xapp
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [Instance #${RESTART_INDEX}] FAILED to restart nearRT-RIC!" >> "$WATCHDOG_LOG"
        fi
    fi

    # Also check if xApp died while RIC is still running
    if pgrep -x "nearRT-RIC" > /dev/null; then
        if [ -f "$XAPP_PID_FILE" ]; then
            xapp_pid=$(cat "$XAPP_PID_FILE")
            if ! kill -0 "$xapp_pid" 2>/dev/null; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - xApp died, restarting..." >> "$WATCHDOG_LOG"
                start_xapp
            fi
        else
            # No PID file means xApp was never started
            start_xapp
        fi
    fi

    sleep "$CHECK_INTERVAL"

done