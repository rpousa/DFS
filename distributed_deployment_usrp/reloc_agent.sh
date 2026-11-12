#!/bin/bash
# Start / stop the relocation log agent on this machine (feeds the Grafana
# "CU-UP relocation" dashboard through reloc-ctl on the core).
#
#   ./reloc_agent.sh start cucp          # core
#   ./reloc_agent.sh start cuup_co       # centraloffice
#   ./reloc_agent.sh start cuup_e        # edge
#   ./reloc_agent.sh stop
#   ./reloc_agent.sh status
#
# RELOC_CTL overrides where reloc-ctl listens (default the core, 192.168.1.210:8095).
set -u
cd "$(dirname "$0")"
CTL="${RELOC_CTL:-http://192.168.1.210:8095}"
PIDFILE="logs/reloc_log_agent.pid"
LOG="logs/reloc_log_agent.log"
mkdir -p logs

stop() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        # its docker logs -f children
        pkill -f "docker logs -f --since 1s" 2>/dev/null
        echo "reloc log agent stopped"
    fi
    rm -f "$PIDFILE"
}

case "${1:-}" in
    start)
        shift
        [ $# -ge 1 ] || { echo "usage: $0 start CONTAINER [CONTAINER...]"; exit 1; }
        stop >/dev/null
        nohup python3 reloc_log_agent.py --ctl "$CTL" "$@" >> "$LOG" 2>&1 &
        echo $! > "$PIDFILE"
        echo "reloc log agent following $* -> $CTL (log: $LOG)"
        ;;
    stop) stop ;;
    status)
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "running (pid $(cat "$PIDFILE"))"; tail -3 "$LOG"
        else
            echo "not running"
        fi
        ;;
    *) echo "usage: $0 start CONTAINER... | stop | status"; exit 1 ;;
esac
