#!/usr/bin/env python3
"""db_prune.py [hours] [--loop SECONDS] [--vacuum]

Keeps the xApp SQLite databases small. xapp_kpm_moni (xapp_db) and the slice
daemon (xapp_daemon_db) append every E2 indication forever: by 25 Nov they had
reached 4.5 GB + 2.3 GB, the core disk was at 95 %, reloc-ctl logged
"database or disk is full", and each Grafana query took ~1.5 s, so the
relocation dashboard hung when it reloaded after a button press.

For every table with a `tstamp` column, rows older than `hours` (default 2)
before that table's newest row are deleted in batches (the writers keep
running; SQLite is in WAL mode). The unit of tstamp (s, ms or us) is guessed
from its magnitude. Indexes used by the dashboards are created if missing.
--vacuum rewrites the files to give the space back to the disk (needs free
space about the size of what is kept; briefly locks the writers).
"""
import os
import sqlite3
import sys
import time

DIR = os.environ.get("XAPP_DB_DIR", "/usr/local/xappdb")
DBS = ("xapp_db", "xapp_daemon_db")
INDEXES = {"KPM_MeasRecord": ["meas_name, tstamp", "ngran_type, tstamp", "tstamp"]}


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), "db_prune:", msg, flush=True)


def per_second(newest):
    if newest > 1e15:
        return 1e6
    if newest > 1e12:
        return 1e3
    return 1.0


def prune(path, hours, vacuum):
    if not os.path.exists(path):
        return
    c = sqlite3.connect(path, timeout=30)
    c.execute("PRAGMA busy_timeout=30000")
    tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    for t in tables:
        cols = [r[1] for r in c.execute(f'PRAGMA table_info("{t}")')]
        if t in INDEXES:
            for i, spec in enumerate(INDEXES[t]):
                if all(s.strip() in cols for s in spec.split(",")):
                    c.execute(f'CREATE INDEX IF NOT EXISTS "idx_{t}_{i}" ON "{t}"({spec})')
            c.commit()
        if "tstamp" not in cols:
            continue
        newest = c.execute(f'SELECT MAX(tstamp) FROM "{t}"').fetchone()[0]
        if not newest:
            continue
        cut = newest - hours * 3600 * per_second(float(newest))
        total = 0
        while True:
            n = c.execute(f'DELETE FROM "{t}" WHERE rowid IN '
                          f'(SELECT rowid FROM "{t}" WHERE tstamp < ? LIMIT 50000)', (cut,)).rowcount
            c.commit()
            total += n
            if n < 50000:
                break
            time.sleep(0.05)       # let the writers in between batches
        if total:
            log(f"{os.path.basename(path)}.{t}: deleted {total} rows older than {hours} h")
    c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    if vacuum:
        before = os.path.getsize(path)
        c.execute("VACUUM")
        log(f"{os.path.basename(path)}: vacuum {before / 1e9:.2f} GB -> {os.path.getsize(path) / 1e9:.2f} GB")
    c.close()


def main():
    args = sys.argv[1:]
    hours = float(args[0]) if args and not args[0].startswith("-") else 2.0
    vacuum = "--vacuum" in args
    loop = int(args[args.index("--loop") + 1]) if "--loop" in args else 0
    while True:
        for db in DBS:
            try:
                prune(os.path.join(DIR, db), hours, vacuum)
            except sqlite3.Error as e:
                log(f"{db}: {e}")
        if not loop:
            break
        vacuum = False             # only the first pass rewrites the files
        time.sleep(loop)


if __name__ == "__main__":
    main()
