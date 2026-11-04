#!/usr/bin/env python3
"""reloc-ctl: control and live state of the gNB-CU-UP relocation, for Grafana.

Runs inside the flexric container on the core (python3 standard library only).

* Starts / stops the trigger xApp (xapp_cuup_reloc_trigger) with the settings
  chosen on the Grafana dashboard. Exactly one instance runs at any time: every
  start first kills whatever trigger is running, so two triggers can never move
  the UE back and forth.
* Follows the trigger's log and records the run: armed -> fired -> acked ->
  complete (CU-CP) / switched (KPM), plus the per-slice progress towards firing.
* Receives events from reloc_log_agent.py (CU-CP and CU-UP logs on the three
  machines): procedure steps, procedure time, forwarding statistics.
* Works out, from the KPM database, which gNB-CU-UP carries each UE's downlink
  and keeps a node/edge table for the Grafana node graph.

Everything Grafana shows comes from reloc_ctl.db, next to the KPM xapp_db on the
shared volume.

HTTP (port RELOC_CTL_PORT, default 8085 in the container; published on the core as 8095):
  GET|POST /arm      start the trigger (Grafana dashboard link: var-* parameters)
  GET|POST /now      relocate on the next report (fires at once)
  GET|POST /stop     stop the trigger
  POST     /event    event from reloc_log_agent.py (JSON)
  GET      /status   JSON state, for debugging
  GET      /health
GET actions redirect back to the dashboard, so a dashboard link acts as a button.
"""

import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import traceback
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

PORT = int(os.environ.get("RELOC_CTL_PORT", "8085"))
XAPP_BIN = os.environ.get("RELOC_XAPP_BIN", "/usr/local/flexric/xApp/c/cuup_reloc/xapp_cuup_reloc_trigger")
FLEXRIC_CONF = os.environ.get("RELOC_FLEXRIC_CONF", "/usr/local/etc/flexric/flexric.conf")
LOG_DIR = os.environ.get("RELOC_LOG_DIR", "/usr/local/etc/flexric_logs")
KPM_DB = os.environ.get("RELOC_KPM_DB", "/usr/local/xappdb/xapp_db")
CTL_DB = os.environ.get("RELOC_CTL_DB", "/usr/local/xappdb/reloc_ctl.db")
# gNB-CU-UP ID -> name, for the dashboard
CUUP_NAMES = dict(
    (int(k), v)
    for k, v in (
        x.split("=", 1) for x in os.environ.get("RELOC_CUUP_NAMES", "3585=cuup_co,3586=cuup_e").split(",") if "=" in x
    )
)
DASH_PATH = os.environ.get("RELOC_DASH_PATH", "/d/reloc-ctl/cu-up-relocation")
SLICE_NAMES = {1: "eMBB", 2: "URLLC", 3: "mIoT", 4: "V2X", 5: "HMTC"}
# window over which a CU-UP must have carried downlink to count as serving
SERVING_WINDOW_S = float(os.environ.get("RELOC_SERVING_WINDOW_S", "3"))
XAPP_DEFAULTS = {"RELOC_TIMEOUT_S": "900", "RELOC_LINGER_S": "120"}

lock = threading.RLock()
proc = None  # trigger xApp started by us
proc_run_id = None


def log(msg):
    print(time.strftime("%F %T"), msg, flush=True)


# ---------------------------------------------------------------- database ---

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs(
  id INTEGER PRIMARY KEY, started REAL, mode TEXT, ue INT, sst INT, target_cuup INT,
  metric TEXT, cmp TEXT, threshold REAL, consecutive INT, guard TEXT,
  state TEXT, fired REAL, acked REAL, complete REAL, switched REAL, ended REAL,
  from_cuup INT, to_cuup INT, procedure_ms REAL, forwarding TEXT, fwd_sdus INT, held_sdus INT,
  held_ms REAL, note TEXT, logfile TEXT);
CREATE TABLE IF NOT EXISTS events(
  id INTEGER PRIMARY KEY, tstamp REAL, run_id INT, source TEXT, kind TEXT, text TEXT);
CREATE TABLE IF NOT EXISTS progress(
  ue INT, sst INT, metric TEXT, value REAL, streak INT, needed INT, tstamp REAL, PRIMARY KEY(ue, sst));
CREATE TABLE IF NOT EXISTS serving(
  ue TEXT PRIMARY KEY, cuup INT, since REAL, dl_mbps REAL, slices TEXT, tstamp REAL);
CREATE TABLE IF NOT EXISTS cuups(id INT PRIMARY KEY, name TEXT, last_seen REAL);
CREATE TABLE IF NOT EXISTS nodes(
  id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, mainstat TEXT, secondarystat TEXT, color TEXT,
  detail__role TEXT);
CREATE TABLE IF NOT EXISTS edges(
  id TEXT PRIMARY KEY, source TEXT, target TEXT, mainstat TEXT, color TEXT, thickness REAL,
  strokedasharray TEXT);
"""


@contextmanager
def db():
    c = sqlite3.connect(CTL_DB, timeout=5, isolation_level=None)
    c.row_factory = sqlite3.Row
    try:
        yield c
    finally:
        c.close()


def init_db():
    os.makedirs(os.path.dirname(CTL_DB), exist_ok=True)
    with db() as c:
        c.executescript(SCHEMA)
        # a run left open by a previous instance of this service is over
        c.execute(
            "UPDATE runs SET state='stopped', ended=?, note=COALESCE(note,'')||' service restarted' "
            "WHERE ended IS NULL",
            (time.time(),),
        )
    with db() as c:
        for cid, name in CUUP_NAMES.items():
            c.execute("INSERT OR IGNORE INTO cuups(id, name, last_seen) VALUES(?,?,0)", (cid, name))
    try:
        os.chmod(CTL_DB, 0o644)
    except OSError:
        pass


def add_event(run_id, source, kind, text):
    with db() as c:
        c.execute(
            "INSERT INTO events(tstamp, run_id, source, kind, text) VALUES(?,?,?,?,?)",
            (time.time(), run_id, source, kind, text),
        )
    log(f"[{source}] {kind}: {text}")


def update_run(run_id, **kv):
    if run_id is None or not kv:
        return
    cols = ", ".join(f"{k}=?" for k in kv)
    with db() as c:
        c.execute(f"UPDATE runs SET {cols} WHERE id=?", (*kv.values(), run_id))


def get_run(run_id):
    with db() as c:
        r = c.execute("SELECT * FROM runs WHERE id=?", (run_id,)).fetchone()
    return dict(r) if r else None


def active_run(max_age_s=600):
    """The run a CU-CP / CU-UP event belongs to: the newest one not finished."""
    with db() as c:
        r = c.execute(
            "SELECT * FROM runs WHERE started > ? AND state NOT IN ('stopped','failed','timeout','given up') "
            "ORDER BY id DESC LIMIT 1",
            (time.time() - max_age_s,),
        ).fetchone()
    return dict(r) if r else None


# ------------------------------------------------------- trigger processes ---


def trigger_pids():
    """Every running trigger xApp in this container, ours or not."""
    pids = []
    me = os.getpid()
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == me:
            continue
        try:
            with open(f"/proc/{d}/cmdline", "rb") as f:
                cmd = f.read().split(b"\0")
        except OSError:
            continue
        if cmd and os.path.basename(cmd[0].decode(errors="ignore")) == os.path.basename(XAPP_BIN):
            pids.append(int(d))
    return pids


def kill_triggers(reason):
    global proc, proc_run_id
    pids = trigger_pids()
    if proc is not None and proc.poll() is None and proc.pid not in pids:
        pids.append(proc.pid)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGINT)
        except OSError:
            pass
    def alive():
        out = []
        for p in pids:
            try:
                with open(f"/proc/{p}/stat") as f:
                    if f.read().split(")")[-1].split()[0] != "Z":
                        out.append(p)
            except OSError:
                pass
        return out

    deadline = time.time() + 3
    while time.time() < deadline and alive():
        if proc is not None:
            proc.poll()  # reap our own child
        time.sleep(0.1)
    for pid in alive():
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    if proc is not None:
        try:
            proc.wait(timeout=2)
        except Exception:
            pass
    if proc_run_id is not None:
        r = get_run(proc_run_id)
        if r and r["ended"] is None:
            update_run(proc_run_id, ended=time.time(), state="stopped" if r["state"] == "armed" else r["state"])
            add_event(proc_run_id, "reloc-ctl", "stopped", reason)
    proc, proc_run_id = None, None
    return len(pids)


def start_trigger(mode, ue, sst, target, metric, cmp, threshold, consecutive, guard, guard_cmp, guard_threshold):
    global proc, proc_run_id
    with lock:
        n = kill_triggers("replaced by a new run")
        now = time.time()
        with db() as c:
            cur = c.execute(
                "INSERT INTO runs(started, mode, ue, sst, target_cuup, metric, cmp, threshold, consecutive, guard, state) "
                "VALUES(?,?,?,?,?,?,?,?,?,?, 'armed')",
                (now, mode, ue, sst, target, metric, cmp, threshold, consecutive,
                 f"{guard} {guard_cmp} {guard_threshold}" if guard else None),
            )
            run_id = cur.lastrowid
            c.execute("DELETE FROM progress")
        logfile = os.path.join(LOG_DIR, f"reloc_ctl_run_{run_id}.log")
        update_run(run_id, logfile=logfile)
        env = dict(os.environ)
        env.update(XAPP_DEFAULTS)
        env.update(
            RELOC_METRIC=metric,
            RELOC_CMP=cmp,
            RELOC_THRESHOLD=str(threshold),
            RELOC_CONSECUTIVE=str(consecutive),
            RELOC_UE=str(ue or 0),
            RELOC_SST=str(sst or 0),
            RELOC_TARGET_CUUP=str(target if target is not None else -1),
        )
        for k in ("RELOC_GUARD_METRIC", "RELOC_GUARD_CMP", "RELOC_GUARD_THRESHOLD"):
            env.pop(k, None)
        if guard:
            env.update(RELOC_GUARD_METRIC=guard, RELOC_GUARD_CMP=guard_cmp, RELOC_GUARD_THRESHOLD=str(guard_threshold))
        os.makedirs(LOG_DIR, exist_ok=True)
        out = open(logfile, "w")
        cmd = [XAPP_BIN, "-c", FLEXRIC_CONF, "-d", "/tmp/", "-n", f"reloc_ctl_run_{run_id}_db"]
        try:
            proc = subprocess.Popen(cmd, env=env, stdout=out, stderr=subprocess.STDOUT, cwd="/tmp")
        except OSError as e:
            update_run(run_id, state="failed", ended=time.time(), note=str(e))
            add_event(run_id, "reloc-ctl", "failed", f"could not start the trigger: {e}")
            return run_id
        proc_run_id = run_id
        desc = (
            f"{mode}: UE {ue or 'any'}, slice {SLICE_NAMES.get(sst, sst) if sst else 'any'}, "
            f"{metric} {'>' if cmp == 'gt' else '<'} {threshold} x{consecutive}, target "
            f"{CUUP_NAMES.get(target, target) if target not in (None, -1) else 'any other'}"
            + (f", guard {guard} {guard_cmp} {guard_threshold}" if guard else "")
            + (f" (stopped {n} running trigger)" if n else "")
        )
        add_event(run_id, "reloc-ctl", "armed", desc)
        threading.Thread(target=follow_trigger, args=(run_id, logfile, proc), daemon=True).start()
        return run_id


RE_PROGRESS = re.compile(r"\[RELOC\] UE (\d+) SST (\d+) (\S+) = (-?[\d.]+).*?-> (\d+)/(\d+)")
RE_FIRED = re.compile(r"\[RELOC\] UE (\d+): (\S+) = (-?[\d.]+), .* -> gNB-CU-UP Change")


def follow_trigger(run_id, logfile, p):
    """Turn the trigger's log into run state and per-slice progress."""
    pos = 0
    seen_done = False
    while True:
        try:
            with open(logfile, "r", errors="ignore") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
        except OSError:
            chunk = ""
        for line in chunk.splitlines():
            try:
                seen_done |= handle_trigger_line(run_id, line)
            except Exception:
                traceback.print_exc()
        if p.poll() is not None and not chunk:
            break
        time.sleep(0.2)
    r = get_run(run_id)
    if r and r["ended"] is None:
        state = r["state"]
        if state == "armed":
            state = "stopped" if not seen_done else "timeout"
        update_run(run_id, ended=time.time(), state=state)
        add_event(run_id, "trigger", "exited", f"trigger xApp ended (exit code {p.returncode})")


def handle_trigger_line(run_id, line):
    m = RE_PROGRESS.search(line)
    if m and "[after trigger]" not in line:
        ue, sst, metric, value, streak, needed = m.groups()
        with db() as c:
            c.execute(
                "INSERT OR REPLACE INTO progress(ue, sst, metric, value, streak, needed, tstamp) VALUES(?,?,?,?,?,?,?)",
                (int(ue), int(sst), metric, float(value), int(streak), int(needed), time.time()),
            )
        return False
    m = RE_FIRED.search(line)
    if m:
        update_run(run_id, state="fired", fired=time.time(), ue=int(m.group(1)))
        add_event(run_id, "trigger", "fired", f"UE {m.group(1)}: {m.group(2)} = {float(m.group(3)):.1f}")
        return False
    if "CONTROL sent to the gNB-CU-CP" in line:
        ok = "NOT acknowledged" not in line
        r = get_run(run_id)
        if ok:
            # the CU-CP's own events may have overtaken the trigger's log
            if r and r["state"] in ("armed", "fired"):
                update_run(run_id, state="acked", acked=time.time())
            else:
                update_run(run_id, acked=time.time())
        else:
            update_run(run_id, state="failed", note="CONTROL not acknowledged")
        add_event(run_id, "trigger", "acked" if ok else "failed", line.split("[RELOC]")[-1].strip())
        return False
    for needle, kind in (
        ("cannot trigger", "error"),
        ("no connected node offers", "error"),
        ("giving up", "timeout"),
        ("E2 node(s) connected", "info"),
    ):
        if needle in line:
            add_event(run_id, "trigger", kind, line.split("[RELOC]")[-1].strip())
            if kind == "timeout":
                update_run(run_id, state="timeout")
            return False
    if "[RELOC] done" in line:
        return True
    return False


# ------------------------------------------------ events from the agents ---


def handle_agent_event(ev):
    """One parsed CU-CP / CU-UP log line from reloc_log_agent.py."""
    kind = ev.get("kind", "?")
    src = ev.get("source", "agent")
    text = ev.get("text", "")
    run = active_run()
    run_id = run["id"] if run else None
    if kind == "start":
        if run is None or run["state"] in ("complete", "switched"):
            # a change of gNB-CU-UP nobody started from here (telnet, another xApp)
            with db() as c:
                cur = c.execute(
                    "INSERT INTO runs(started, mode, ue, state) VALUES(?, 'external', ?, 'acked')",
                    (time.time(), ev.get("ue")),
                )
                run_id = cur.lastrowid
        update_run(
            run_id,
            from_cuup=ev.get("from_cuup"),
            to_cuup=ev.get("to_cuup"),
            forwarding="yes" if ev.get("forwarding") else "no",
            fwd_sdus=0,
            held_sdus=0,
            held_ms=0,
        )
    elif kind == "complete":
        update_run(run_id, state="complete", complete=time.time(), procedure_ms=ev.get("ms"),
                   to_cuup=ev.get("to_cuup"))
    elif kind == "given_up":
        update_run(run_id, state="given up", note=text)
    elif kind == "fwd_done" and run_id is not None:
        r = get_run(run_id)
        update_run(
            run_id,
            fwd_sdus=(r["fwd_sdus"] or 0) + int(ev.get("forwarded", 0)),
            held_sdus=(r["held_sdus"] or 0) + int(ev.get("held", 0)),
            held_ms=max(r["held_ms"] or 0, float(ev.get("held_ms", 0))),
        )
    add_event(run_id, src, kind, text)


# ------------------------------------------------------------ KPM monitor ---


@contextmanager
def kpm_conn():
    c = sqlite3.connect(f"file:{KPM_DB}?mode=ro", uri=True, timeout=2)
    try:
        yield c
    finally:
        c.close()


def kpm_now(c):
    """Newest KPM timestamp and the factor to seconds (tstamp unit as stored)."""
    row = c.execute("SELECT MAX(tstamp) FROM KPM_MeasRecord").fetchone()
    if not row or row[0] is None:
        return None, 1
    t = row[0]
    scale = 1e6 if t > 1e14 else 1e3 if t > 1e11 else 1
    return t, scale


def monitor():
    prev_serving = {}
    while True:
        try:
            monitor_once(prev_serving)
        except sqlite3.OperationalError as e:
            if "no such table" not in str(e) and "unable to open" not in str(e):
                log(f"monitor: {e}")
        except Exception:
            traceback.print_exc()
        time.sleep(1)


def monitor_once(prev_serving):
    now = time.time()
    with kpm_conn() as k:
        t_max, scale = kpm_now(k)
        if t_max is None:
            return
        since = t_max - SERVING_WINDOW_S * scale
        # downlink volume per UE per CU-UP over the window; the CU-UP still carrying
        # it serves the UE (with step 9 the source stops sending to the DU at once)
        rows = k.execute(
            "SELECT COALESCE(ran_ue_id, '?'), cu_du_id, SUM(measure_value) FROM KPM_MeasRecord "
            "WHERE meas_name='DRB.PdcpSduVolumeDL' AND ngran_type='ngran_gNB_CUUP' AND tstamp >= ? "
            "GROUP BY 1, 2",
            (since,),
        ).fetchall()
        cuups_seen = {
            r[0]
            for r in k.execute(
                "SELECT DISTINCT cu_du_id FROM KPM_MeasRecord WHERE ngran_type='ngran_gNB_CUUP' AND tstamp >= ?",
                (t_max - 60 * scale,),
            )
        }
        # newest DU throughput per UE and slice (kbit/s)
        thp = k.execute(
            "SELECT ran_ue_id, COALESCE(sst, 0), measure_value FROM KPM_MeasRecord k "
            "WHERE meas_name='DRB.UEThpDl' AND ran_ue_id IS NOT NULL AND tstamp = "
            "(SELECT MAX(tstamp) FROM KPM_MeasRecord WHERE meas_name='DRB.UEThpDl')",
        ).fetchall()
        try:
            slices = k.execute("SELECT ran_ue_id, sst FROM UE_SLICE_MAP ORDER BY sst").fetchall()
        except sqlite3.OperationalError:
            slices = []

    per_ue = {}
    for ue, cuup, vol in rows:
        if vol and vol > 0:
            per_ue.setdefault(str(ue), []).append((vol, cuup))
    serving = {ue: max(v)[1] for ue, v in per_ue.items()}
    # a CU-UP that reports per-UE records with no UE id: one entry for all UEs
    if "?" in serving and len(serving) > 1:
        serving.pop("?")
    ue_thp = {}
    for ue, sst, v in thp:
        ue_thp[str(ue)] = ue_thp.get(str(ue), 0) + (v or 0) / 1000.0
    ue_slices = {}
    for ue, sst in slices:
        ue_slices.setdefault(str(ue), []).append(SLICE_NAMES.get(sst, f"SST {sst}"))
    for ue in ue_thp:
        ue_slices.setdefault(ue, [])

    # serving CU-UP changes: the run's "switched" moment
    for ue, cuup in serving.items():
        old = prev_serving.get(ue)
        if old is not None and old != cuup:
            run = active_run()
            run_id = run["id"] if run else None
            text = f"UE {ue}: downlink now carried by {CUUP_NAMES.get(cuup, cuup)} (was {CUUP_NAMES.get(old, old)})"
            if run and run["state"] in ("fired", "acked", "complete") and run["switched"] is None:
                update_run(run_id, switched=now, to_cuup=run["to_cuup"] or cuup,
                           from_cuup=run["from_cuup"] or old,
                           state="complete" if run["state"] == "complete" else "switched")
            add_event(run_id, "kpm", "switched", text)
        prev_serving[ue] = cuup

    run = active_run()
    in_flight = run is not None and run["state"] in ("fired", "acked") and run["complete"] is None
    with db() as c:
        c.execute("BEGIN")
        for cid in cuups_seen:
            c.execute(
                "INSERT INTO cuups(id, name, last_seen) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen",
                (cid, CUUP_NAMES.get(cid, f"CU-UP {cid}"), now),
            )
        for ue, cuup in serving.items():
            old = c.execute("SELECT cuup, since FROM serving WHERE ue=?", (ue,)).fetchone()
            since_t = old["since"] if old and old["cuup"] == cuup else now
            c.execute(
                "INSERT OR REPLACE INTO serving(ue, cuup, since, dl_mbps, slices, tstamp) VALUES(?,?,?,?,?,?)",
                (ue, cuup, since_t, round(ue_thp.get(ue, 0), 2), " · ".join(ue_slices.get(ue, [])), now),
            )
        # topology for the node graph
        c.execute("DELETE FROM nodes")
        c.execute("DELETE FROM edges")
        known = {r["id"]: r["name"] for r in c.execute("SELECT id, name FROM cuups WHERE last_seen > ?", (now - 120,))}
        for cid in CUUP_NAMES:
            known.setdefault(cid, CUUP_NAMES[cid])
        total = sum(ue_thp.values())
        c.execute(
            "INSERT INTO nodes VALUES('du','DU','du_e1',?,?, '#5794F2','gNB-DU')",
            (f"{total:.1f} Mbit/s", f"{len(ue_thp) or len(serving)} UE"),
        )
        target = run["target_cuup"] if run else None
        target = run["to_cuup"] if run and run["to_cuup"] else target
        for cid, name in sorted(known.items()):
            n_ues = sum(1 for v in serving.values() if v == cid)
            color = "#73BF69" if n_ues else "#8E8E8E"
            if in_flight and target == cid:
                color = "#FF9830"
            c.execute(
                "INSERT INTO nodes VALUES(?,?,?,?,?,?,'gNB-CU-UP')",
                (f"cuup{cid}", name, f"CU-UP {cid}", f"{n_ues} UE", "relocation target" if in_flight and target == cid else "",
                 color),
            )
        for ue in sorted(set(ue_thp) | set(serving)):
            if ue == "?":
                continue
            mbps = ue_thp.get(ue, 0)
            c.execute(
                "INSERT INTO nodes VALUES(?,?,?,?,?, '#B877D9','UE')",
                (f"ue{ue}", f"UE {ue}", " · ".join(ue_slices.get(ue, [])), f"{mbps:.1f} Mbit/s", ""),
            )
            c.execute(
                "INSERT INTO edges VALUES(?,?,?,?, '#B877D9', ?, NULL)",
                (f"ue{ue}-du", f"ue{ue}", "du", f"{mbps:.1f} Mbit/s", max(1.0, min(8.0, mbps / 15.0))),
            )
        for ue, cid in serving.items():
            label = f"UE {ue}" if ue != "?" else "all UEs"
            c.execute(
                "INSERT INTO edges VALUES(?,?,?,?, '#73BF69', 3, NULL)",
                (f"du-cuup{cid}-{ue}", "du", f"cuup{cid}", f"F1-U · {label}"),
            )
        if in_flight and target is not None and f"cuup{target}" in {f"cuup{x}" for x in known}:
            c.execute(
                "INSERT INTO edges VALUES('reloc','du',?, 'relocating', '#FF9830', 2, '6 4')",
                (f"cuup{target}",),
            )
        c.execute("COMMIT")


# --------------------------------------------------------------------- HTTP ---


def first(q, *names, default=None):
    for n in names:
        for key in (n, f"var-{n}"):
            if key in q and q[key] and q[key][0] != "":
                return q[key][0]
    return default


def to_int(v, default=None):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def to_float(v, default=None):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


class Handler(BaseHTTPRequestHandler):
    server_version = "reloc-ctl/1"

    def log_message(self, fmt, *args):
        pass

    def cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def reply_json(self, obj, code=200):
        body = json.dumps(obj, default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.cors()
        self.end_headers()
        self.wfile.write(body)

    def back_to_dashboard(self, q, message):
        """After a dashboard link: go back to the dashboard with the same choices."""
        if self.command == "POST" and "application/json" in (self.headers.get("Accept") or ""):
            return self.reply_json({"ok": True, "message": message})
        ref = first(q, "return") or self.headers.get("Referer") or ""
        u = urlparse(ref)
        if u.scheme and u.netloc:
            keep = {k: v[0] for k, v in q.items() if k.startswith("var-")}
            keep["refresh"] = "2s"
            loc = f"{u.scheme}://{u.netloc}{DASH_PATH}?{urlencode(keep)}"
            self.send_response(303)
            self.send_header("Location", loc)
            self.cors()
            self.end_headers()
            return
        body = f"<html><body style='font-family:sans-serif'><p>{message}</p></body></html>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.end_headers()

    def params(self):
        q = parse_qs(urlparse(self.path).query)
        if self.command == "POST":
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
            ctype = self.headers.get("Content-Type") or ""
            if raw and "json" in ctype:
                try:
                    for k, v in json.loads(raw).items():
                        q[k] = [str(v)] if not isinstance(v, (dict, list)) else [json.dumps(v)]
                except ValueError:
                    pass
            elif raw:
                for k, v in parse_qs(raw.decode()).items():
                    q[k] = v
        return q

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.route()

    def route(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        try:
            if path == "/health":
                return self.reply_json({"ok": True})
            if path == "/status":
                return self.reply_json(status())
            if path == "/event" and self.command == "POST":
                n = int(self.headers.get("Content-Length") or 0)
                ev = json.loads(self.rfile.read(n) or b"{}")
                handle_agent_event(ev)
                return self.reply_json({"ok": True})
            q = self.params()
            if path == "/stop":
                with lock:
                    n = kill_triggers("stopped from the dashboard")
                return self.back_to_dashboard(q, f"Stopped {n} trigger(s).")
            if path in ("/arm", "/now"):
                ue = to_int(first(q, "ue"), 0)
                sst = to_int(first(q, "sst"), 0)
                target = to_int(first(q, "target"), -1)
                if path == "/now":
                    # fires on the first DU report for the UE: every value is above -1
                    run_id = start_trigger("relocate now", ue, 0, target, "DRB.UEThpDl", "gt", -1, 1, None, None, None)
                    return self.back_to_dashboard(q, f"Run {run_id}: relocating now.")
                metric = first(q, "metric", default="DRB.UEThpDl")
                cmp = first(q, "cmp", default="gt")
                cmp = "lt" if cmp.lower() in ("lt", "<", "below") else "gt"
                threshold = to_float(first(q, "threshold"), 50000.0)
                consecutive = max(1, to_int(first(q, "consecutive"), 3))
                guard = first(q, "guard")
                guard = None if not guard or guard.lower() == "none" else guard
                guard_cmp = "gt" if (first(q, "guard_cmp", default="lt")).lower() in ("gt", ">") else "lt"
                guard_threshold = to_float(first(q, "guard_threshold"), 0.0)
                run_id = start_trigger("trigger", ue, sst, target, metric, cmp, threshold, consecutive,
                                       guard, guard_cmp, guard_threshold)
                return self.back_to_dashboard(q, f"Run {run_id}: trigger armed.")
            self.reply_json({"error": f"unknown path {path}"}, 404)
        except Exception as e:
            traceback.print_exc()
            self.reply_json({"error": str(e)}, 500)


def status():
    with db() as c:
        runs = [dict(r) for r in c.execute("SELECT * FROM runs ORDER BY id DESC LIMIT 5")]
        serving = [dict(r) for r in c.execute("SELECT * FROM serving")]
        progress = [dict(r) for r in c.execute("SELECT * FROM progress")]
    return {"triggers_running": trigger_pids(), "runs": runs, "serving": serving, "progress": progress}


def main():
    init_db()
    threading.Thread(target=monitor, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log(f"reloc-ctl listening on :{PORT}, KPM {KPM_DB}, state {CTL_DB}, xApp {XAPP_BIN}")
    try:
        srv.serve_forever()
    finally:
        kill_triggers("reloc-ctl stopped")


if __name__ == "__main__":
    sys.exit(main())
