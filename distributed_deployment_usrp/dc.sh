#!/bin/bash
# dc.sh - docker compose with testbed.env loaded.
# The compose files take RADIO_PRB, RADIO_ANT, *_SDR_ARGS, gains, ... from the
# shell environment; a bare "docker compose up" falls back to the defaults
# (273 PRB, 2x2, addr=192.168.10.2) and the DU finds no USRP.
#   ./dc.sh -f docker-compose-edge.yml up -d du_e1
#   ./dc.sh -f docker-compose-centraloffice.yml config | grep -E "uecap|ue-nb-ant"
cd "$(dirname "$0")"
set -a; . ./testbed.env; set +a
exec docker compose "$@"
