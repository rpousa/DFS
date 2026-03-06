#!/bin/bash

# === Configuration ===
RIC_BIN="/usr/local/bin/nearRT-RIC"
RIC_CONF="/usr/local/etc/flexric/flexric.conf"
RIC_LOG="/usr/local/etc/flexric.log"
WATCHDOG_LOG="/var/log/ric_watchdog.log"
CHECK_INTERVAL=2  # seconds between checks

# === Loop forever ===
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting nearRT-RIC watchdog..." >> "$WATCHDOG_LOG"

while true; do
    # Check if process is running
    if ! pgrep -x "nearRT-RIC" > /dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - nearRT-RIC is down. Restarting..." >> "$WATCHDOG_LOG"
        nohup "$RIC_BIN" -c "$RIC_CONF" > "$RIC_LOG" 2>&1 &
        sleep 5  # give it time to start
        if pgrep -x "nearRT-RIC" > /dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - nearRT-RIC successfully restarted." >> "$WATCHDOG_LOG"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Failed to restart nearRT-RIC!" >> "$WATCHDOG_LOG"
        fi
    fi

    # Wait before next check
    sleep "$CHECK_INTERVAL"
done