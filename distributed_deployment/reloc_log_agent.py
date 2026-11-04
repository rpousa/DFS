#!/usr/bin/env python3
"""reloc_log_agent: follow CU-CP / CU-UP container logs on this machine and send
the gNB-CU-UP relocation events to reloc-ctl on the core (for Grafana).

  python3 reloc_log_agent.py [--ctl http://192.168.0.200:8095] CONTAINER [CONTAINER...]

Core:          cucp       (procedure steps, "complete in X ms")
Centraloffice: cuup_co    (source / target side of forwarding)
Edge:          cuup_e

Started in the background by the deploy scripts (reloc_agent.sh). Python 3
standard library only; needs the docker CLI. A container that is not running yet
is retried every few seconds, and a container that restarts is picked up again.
"""

import argparse
import json
import re
import subprocess
import sys
import threading
import time
import urllib.request

# The first field of an OAI log line with the "time" option is a monotonic
# timestamp in seconds; durations are taken from it, not from the receive time.
RE_T = re.compile(r"^\s*(\d+\.\d+)\s")
# "5449123.784096 [NR_RRC] I " in front of the message
RE_PREFIX = re.compile(r"^\s*\d+\.\d+\s+\[\w+\]\s+\w\s+")

PATTERNS = [
    # CU-CP (rrc_gNB_cuup_reloc.c)
    ("start", re.compile(
        r"UE (\d+): moving (\d+) PDU session\(s\) from gNB-CU-UP ID (\d+) \(assoc_id \d+\) to gNB-CU-UP ID (\d+) "
        r"\(assoc_id \d+\)(, with data forwarding)?")),
    ("target_ready", re.compile(r"UE (\d+): target gNB-CU-UP assoc_id \d+ holds the bearers(?: \((\d+) forwarding endpoint)?")),
    ("du_switched", re.compile(r"UE (\d+): the DU sends uplink to gNB-CU-UP assoc_id (\d+)")),
    ("pdcp_status", re.compile(r"UE (\d+): source gNB-CU-UP reported the PDCP status of (\d+) DRB")),
    ("path_switch", re.compile(r"UE (\d+): target gNB-CU-UP is serving the bearers, announcing")),
    ("complete", re.compile(r"UE (\d+): change of gNB-CU-UP complete, now served by gNB-CU-UP ID (\d+)")),
    ("drain", re.compile(r"UE (\d+): releasing the source gNB-CU-UP in (\d+) ms")),
    ("source_release", re.compile(r"UE (\d+): release bearer context on CU-UP assoc_id (\d+)")),
    ("given_up", re.compile(r"UE (\d+): change of gNB-CU-UP .* given up while (.*)")),
    # CU-UP (nr_pdcp_oai_api.c, cucp_cuup_handler.c)
    ("src_relay", re.compile(r"UE (\w+) DRB (\d+): downlink stops at COUNT (\S+), relaying")),
    ("tgt_count", re.compile(r"UE (\w+) DRB (\d+): downlink continues from COUNT (\S+), (\d+) forwarded SDU")),
    ("fwd_done", re.compile(
        r"UE (\w+) DRB (\d+): downlink forwarding over \((.*?)\): (\d+) SDUs forwarded by the source, "
        r"(\d+) held from the new path for ([\d.]+) ms")),
    ("cuup_release", re.compile(r"\[E1AP\]\s+I releasing UE (\d+)")),
]


def post(ctl, ev):
    data = json.dumps(ev).encode()
    req = urllib.request.Request(f"{ctl}/event", data=data, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=3).read()
    except Exception as e:
        print(f"reloc_log_agent: could not reach {ctl}: {e}", file=sys.stderr, flush=True)


def follow(container, ctl):
    t_start = {}  # UE -> log time of "moving ..."
    while True:
        try:
            p = subprocess.Popen(
                ["docker", "logs", "-f", "--since", "1s", container],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                errors="ignore",
            )
        except OSError as e:
            print(f"reloc_log_agent: docker: {e}", file=sys.stderr, flush=True)
            time.sleep(5)
            continue
        for line in p.stdout:
            for kind, rx in PATTERNS:
                m = rx.search(line)
                if not m:
                    continue
                g = m.groups()
                tm = RE_T.match(line)
                t_log = float(tm.group(1)) if tm else None
                ev = {"source": container, "kind": kind, "text": RE_PREFIX.sub("", line).strip()[-300:], "t_log": t_log}
                if kind == "start":
                    ev.update(ue=int(g[0]), sessions=int(g[1]), from_cuup=int(g[2]), to_cuup=int(g[3]),
                              forwarding=bool(g[4]))
                    ev["text"] = (f"UE {g[0]}: moving {g[1]} PDU session(s) {g[2]} -> {g[3]}"
                                  + (" with data forwarding" if g[4] else ""))
                    if t_log is not None:
                        t_start[g[0]] = t_log
                elif kind == "complete":
                    ev.update(ue=int(g[0]), to_cuup=int(g[1]))
                    if t_log is not None and g[0] in t_start:
                        ev["ms"] = round((t_log - t_start.pop(g[0])) * 1000.0, 2)
                    ev["text"] = f"UE {g[0]}: complete, now on {g[1]}" + (f" in {ev['ms']} ms" if "ms" in ev else "")
                elif kind == "fwd_done":
                    ev.update(ue=g[0], drb=int(g[1]), reason=g[2], forwarded=int(g[3]), held=int(g[4]),
                              held_ms=float(g[5]))
                    ev["text"] = (f"UE {g[0]} DRB {g[1]}: forwarding over ({g[2]}), {g[3]} forwarded, "
                                  f"{g[4]} held for {g[5]} ms")
                elif kind == "target_ready" and g[1] is not None:
                    ev["text"] = f"UE {g[0]}: target holds the bearers, {g[1]} forwarding endpoint(s)"
                elif kind == "drain":
                    ev["text"] = f"UE {g[0]}: source released in {g[1]} ms"
                post(ctl, ev)
                break
        p.wait()
        time.sleep(3)  # container not running yet, or restarted


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ctl", default="http://192.168.0.200:8095")
    ap.add_argument("containers", nargs="+")
    a = ap.parse_args()
    for c in a.containers:
        threading.Thread(target=follow, args=(c, a.ctl), daemon=True).start()
    print(f"reloc_log_agent: following {', '.join(a.containers)} -> {a.ctl}", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
