#!/bin/bash

# === Configuration ===
RIC_BIN="/usr/local/bin/nearRT-RIC"
RIC_CONF="/usr/local/etc/flexric/flexric.conf"
RIC_LOG_DIR="/usr/local/etc/flexric_logs"
WATCHDOG_LOG="/var/log/ric_watchdog.log"
INDEX_FILE="/var/run/ric_restart_index"
CHECK_INTERVAL=2  # seconds between checks

# === Initialize ===
mkdir -p "$RIC_LOG_DIR"

# Load or initialize the restart index
if [ -f "$INDEX_FILE" ]; then
    RESTART_INDEX=$(cat "$INDEX_FILE")
else
    RESTART_INDEX=0
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting nearRT-RIC watchdog (current index: $RESTART_INDEX)..." >> "$WATCHDOG_LOG"

# === Loop forever ===
while true; do
    # Check if process is running
    if ! pgrep -x "nearRT-RIC" > /dev/null; then
        RESTART_INDEX=$((RESTART_INDEX + 1))

        # Persist the index to disk so it survives watchdog restarts
        echo "$RESTART_INDEX" > "$INDEX_FILE"

        # Create per-instance log file
        RIC_LOG="${RIC_LOG_DIR}/flexric_instance_${RESTART_INDEX}.log"

        echo "$(date '+%Y-%m-%d %H:%M:%S') - [Instance #${RESTART_INDEX}] nearRT-RIC is down. Restarting..." >> "$WATCHDOG_LOG"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [Instance #${RESTART_INDEX}] Log file: ${RIC_LOG}" >> "$WATCHDOG_LOG"

        # Start nearRT-RIC with instance-specific log
        nohup "$RIC_BIN" -c "$RIC_CONF" > "$RIC_LOG" 2>&1 &
        RIC_PID=$!

        sleep 5  # give it time to start

        if pgrep -x "nearRT-RIC" > /dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [Instance #${RESTART_INDEX}] nearRT-RIC successfully restarted (PID: $RIC_PID)." >> "$WATCHDOG_LOG"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [Instance #${RESTART_INDEX}] FAILED to restart nearRT-RIC!" >> "$WATCHDOG_LOG"
        fi
    fi

    # Wait before next check
    sleep "$CHECK_INTERVAL"
done
