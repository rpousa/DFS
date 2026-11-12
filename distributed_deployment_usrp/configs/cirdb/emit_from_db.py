#
# * Licensed to the OpenAirInterface (OAI) Software Alliance under one or more
# * contributor license agreements.  See the NOTICE file distributed with
# * this work for additional information regarding copyright ownership.
# * The OpenAirInterface Software Alliance licenses this file to You under
# * the OAI Public License, Version 1.1  (the "License"); you may not use this file
# * except in compliance with the License.
# * You may obtain a copy of the License at
# *
# *      http://www.openairinterface.org/?page_id=698
# *
# * Unless required by applicable law or agreed to in writing, software
# * distributed under the License is distributed on an "AS IS" BASIS,
# * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# * See the License for the specific language governing permissions and
# * limitations under the License.
#  *-------------------------------------------------------------------------------
# * For more information about the OpenAirInterface (OAI) Software Alliance:
# *      contact@openairinterface.org
# *

#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import time
import sys
import numpy as np
import flatbuffers
from collections import defaultdict
from nanomsg import Socket, PUB
from cir_loader import (
    cir_find,
    cir_scan,
    cir_snapshot_rx_tx_L,
    flatten_txmajor_rxminor
)
from cir_defs import MODEL_NAME, MODEL_TO_ID, MAX_L
from Phy import Taps

def build_msg(rx_tx_L: np.ndarray) -> bytes:
    RX, TX, L = rx_tx_L.shape
    flat_bytes = flatten_txmajor_rxminor(rx_tx_L)
    b = flatbuffers.Builder(1024 + len(flat_bytes))
    vec = b.CreateNumpyVector(np.frombuffer(flat_bytes, dtype=np.float32))
    Taps.TapsStart(b)
    Taps.TapsAddId(b, 0)
    Taps.TapsAddNumTxAntennas(b, TX)
    Taps.TapsAddNumRxAntennas(b, RX)
    Taps.TapsAddTapsLen(b, L)
    Taps.TapsAddTaps(b, vec)
    b.Finish(Taps.TapsEnd(b))
    return bytes(b.Output())

def describe_db(db_path, model=None, ds_ns=None, n_rx=None, n_tx=None, show_keys=True, verbose=False):
    """
    Describe database contents with comprehensive filtering and display options.

    Args:
        db_path: Path to the CIR database
        model: Filter by model name (e.g., "TDL-A")
        ds_ns: Filter by delay spread in nanoseconds
        n_rx: Filter by number of RX antennas
        n_tx: Filter by number of TX antennas
        show_keys: Whether to show sample keys
        verbose: Show detailed per-entry information
    """
    entries = cir_scan(db_path)

    if not entries:
        print(f"[describe] DB: {db_path}  - NO ENTRIES FOUND")
        return

    original_count = len(entries)
    if model is not None:
        entries = [e for e in entries if e["model_id"] == MODEL_TO_ID[model]]
    if ds_ns is not None:
        entries = [e for e in entries if abs(e["ds_ns"] - ds_ns) < 1e-6]
    if n_rx is not None:
        entries = [e for e in entries if e["n_rx"] == n_rx]
    if n_tx is not None:
        entries = [e for e in entries if e["n_tx"] == n_tx]

    print("=" * 80)
    print(f"DATABASE DESCRIPTION: {db_path}")
    print("=" * 80)
    print(f"Total entries in database: {original_count}")
    print(f"Entries after filtering: {len(entries)}")

    if not entries:
        print("\nNo entries match the specified filters.")
        return

    all_models = sorted(set(e["model_id"] for e in entries))
    all_ds = sorted(set(e["ds_ns"] for e in entries))
    all_tx = sorted(set(e["n_tx"] for e in entries))
    all_rx = sorted(set(e["n_rx"] for e in entries))
    all_speeds = sorted(set(e["speed_mps"] for e in entries))
    all_fs = sorted(set(e.get("fs_hz", 0) for e in entries))

    print("\n" + "-" * 80)
    print("AVAILABLE PARAMETERS:")
    print("-" * 80)
    print(f"Models:        {[MODEL_NAME[m] for m in all_models]}")
    print(f"Delay Spreads: {all_ds} ns")
    print(f"TX Antennas:   {all_tx}")
    print(f"RX Antennas:   {all_rx}")
    print(f"Speeds:        {all_speeds} m/s")
    if all_fs and all_fs != [0]:
        print(f"Sample Rates:  {all_fs} Hz")

    buckets = defaultdict(list)
    for e in entries:
        key = (e["model_id"], e["ds_ns"], e["n_tx"], e["n_rx"])
        buckets[key].append({
            "speed_mps": float(e["speed_mps"]),
            "key": e.get("key", None),
            "S": e.get("S", 0),
            "L": e.get("L", 0),
            "fs_hz": e.get("fs_hz", 0),
            "snapshot_dt_s": e.get("snapshot_dt_s", 0)
        })

    print("\n" + "-" * 80)
    print("ALL POSSIBLE COMBINATIONS:")
    print("-" * 80)
    print(f"Found {len(buckets)} unique (Model, DS, TX×RX) combinations\n")

    for idx, ((mid, ds, tx, rx), entries_list) in enumerate(sorted(buckets.items()), 1):
        model_name = MODEL_NAME[mid]
        print(f"\n[{idx}] {model_name} | DS={ds}ns | TX={tx} | RX={rx} ({len(entries_list)} speed variants)")
        print("    " + "-" * 72)

        entries_list = sorted(entries_list, key=lambda x: x["speed_mps"])

        for entry in entries_list:
            speed = entry["speed_mps"]
            S = entry["S"]
            L = entry["L"]
            fs = entry["fs_hz"]
            dt = entry["snapshot_dt_s"]
            key = entry["key"]

            if verbose:
                print(f"    Speed: {speed:8.3f} m/s | Snapshots: {S:5d} | Taps: {L:3d} | "
                      f"Fs: {fs:12.0f} Hz | dt: {dt:.6f}s")
                if show_keys and key:
                    print(f"           Key: {key}")
            else:
                info_parts = [f"{speed:.3f} m/s"]
                if S > 0:
                    info_parts.append(f"S={S}")
                if L > 0:
                    info_parts.append(f"L={L}")
                if fs > 0:
                    info_parts.append(f"fs={fs:.0f}Hz")

                info_str = " | ".join(info_parts)
                print(f"    • Speed: {info_str}")

                if show_keys and key:
                    print(f"      Key: {key}")

    print("\n" + "=" * 80)
    print("SUMMARY:")
    print("=" * 80)
    print(f"Unique (Model, DS, TX×RX) combinations: {len(buckets)}")
    print(f"Total database entries: {len(entries)}")

    if len(buckets) > 0:
        avg_speeds = len(entries) / len(buckets)
        print(f"Average speed variants per combination: {avg_speeds:.1f}")

    model_counts = defaultdict(int)
    for e in entries:
        model_counts[MODEL_NAME[e["model_id"]]] += 1

    print(f"\nEntries per model:")
    for model_name in sorted(model_counts.keys()):
        print(f"  {model_name}: {model_counts[model_name]}")

    antenna_counts = defaultdict(int)
    for e in entries:
        antenna_counts[f"{e['n_tx']}×{e['n_rx']}"] += 1

    print(f"\nEntries per TX×RX configuration:")
    for config in sorted(antenna_counts.keys()):
        print(f"  {config}: {antenna_counts[config]}")

    print("=" * 80)

def main():
    epilog = """
Examples
--------
Describe the entire database with all details:
   python3 emit_from_db.py --db ./cir_db.bin --describe-db

Describe with verbose output:
   python3 emit_from_db.py --db ./cir_db.bin --describe-db --verbose

Filter description by specific parameters:
   python3 emit_from_db.py --db ./cir_db.bin --describe-db --model TDL-A
   python3 emit_from_db.py --db ./cir_db.bin --describe-db --model TDL-B --ds-ns 30

Sequential replay, one snapshot every 0.5 s (always advances):
   python3 emit_from_db.py \\
     --bind tcp://127.0.0.1:5555 \\
     --db ./cir_db.bin \\
     --model TDL-A --ds-ns 10 --nrx 1 --ntx 1 --interval 0.5

List entries and then stream:
   python3 emit_from_db.py --db ./cir_db.bin --describe-db
   python3 emit_from_db.py \\
     --bind tcp://127.0.0.1:5555 \\
     --db ./cir_db.bin \\
     --model TDL-B --ds-ns 30 --nrx 1 --ntx 1 \\
     --interval 0.5

Tips
----
• Use --describe-db to see which (model, DS, TX×RX) combos and speeds exist in the DB.
• Add --verbose to --describe-db for detailed per-entry information.
• If --speed-mps doesn't exactly match a stored speed, the nearest speed in the DB is used.
• MAX_L is fixed to 8 inside the emitter for stability.
"""
    ap = argparse.ArgumentParser(
        description="Publish CIR taps from cir_db.bin to VRTSIM (parameter selection; sequential snapshots).",
        formatter_class=argparse.RawTextHelpFormatter,
        epilog=epilog
    )
    ap.add_argument("--bind", default="tcp://127.0.0.1:5555",
                    help="PUB socket bind (must match gNB --vrtsim.taps-socket)")
    ap.add_argument("--db", default="cir_db.bin",
                    help="Path to the CIR database file")

    ap.add_argument("--model", default="TDL-A",
                    choices=["TDL-A","TDL-B","TDL-C","TDL-D","TDL-E"],
                    help="Channel profile")
    ap.add_argument("--ds-ns", type=float, default=10.0,
                    help="RMS delay spread in ns")
    ap.add_argument("--nrx", type=int, default=1,
                    help="Receiver antenna count")
    ap.add_argument("--ntx", type=int, default=1,
                    help="Transmitter antenna count")

    ap.add_argument("--speed-mps", type=float, default=None,
                    help="Mobility speed in m/s (nearest available in DB is used)")
    ap.add_argument("--user-speed-mps", dest="speed_mps", type=float,
                    help=argparse.SUPPRESS)

    ap.add_argument("--fs", type=float, default=None,
                    help="Optional sample-rate check (Hz); leave empty to skip")
    ap.add_argument("--interval", type=float, default=0.5,
                    help="Publish period in seconds")
    ap.add_argument("--describe-db", action="store_true",
                    help="List all entries in database and exit")
    ap.add_argument("--verbose", action="store_true",
                    help="Show verbose output with --describe-db")
    ap.add_argument("--print-selected", action="store_true",
                    help="Print the resolved DB entry then continue streaming")

    args = ap.parse_args()

    if args.describe_db:
        describe_db(
            args.db,
            model=args.model,
            ds_ns=args.ds_ns,
            n_rx=args.nrx,
            n_tx=args.ntx,
            verbose=args.verbose
        )
        return

    try:
        spec = cir_find(
            args.db,
            model=args.model,
            n_rx=args.nrx,
            n_tx=args.ntx,
            ds_ns=args.ds_ns,
            speed_mps=args.speed_mps,
            expect_fs_hz=args.fs
        )
    except KeyError as e:
        print(f"[error] {e}. Hint: run with --describe-db to see available combinations.", file=sys.stderr)
        sys.exit(2)

    S = int(spec["S"])
    RX = int(spec["n_rx"])
    TX = int(spec["n_tx"])
    Lfull = int(spec["L"])
    L = min(Lfull, MAX_L)

    if args.print_selected:
        print("[selected]"
              f" model_id={spec['model_id']}"
              f" ds_ns={spec['ds_ns']}"
              f" speed_mps={spec['speed_mps']}"
              f" tx={TX} rx={RX}"
              f" L={L}/{Lfull}"
              f" S={S}"
              f" fs={spec['fs_hz']}"
              f" dt={spec['snapshot_dt_s']}"
              f" key={spec.get('key','')}")

    sock = Socket(PUB)
    try:
        # Handle different nanomsg wrapper implementations:
        # - C extension (_nanomsg_cpy.so) expects str
        # - ctypes wrapper (_nanomsg_ctypes) expects bytes
        try:
            sock.bind(args.bind)
        except Exception:
            # Fallback to bytes for ctypes wrapper
            bind_addr = args.bind.encode("ascii") if isinstance(args.bind, str) else args.bind
            sock.bind(bind_addr)

        if S <= 0:
            print("[error] Selected entry has zero snapshots (S=0).", file=sys.stderr)
            sys.exit(2)

        s_idx = 0
        print(f"[emitter] bind={args.bind} tx={TX} rx={RX} L={L} S={S} fs={spec['fs_hz']} "
              f"model_id={spec['model_id']} DS={spec['ds_ns']}ns speed={spec['speed_mps']}m/s")

        sleep_dt = args.interval if args.interval and args.interval > 0 else 0.001
        while True:
            rx_tx_L = cir_snapshot_rx_tx_L(spec, s_idx)[:, :, :L]
            sock.send(build_msg(rx_tx_L))
            time.sleep(sleep_dt)
            s_idx = (s_idx + 1) % S
    except KeyboardInterrupt:
        print("\n[emitter] stopped by user")
    finally:
        try:
            sock.close()
        except Exception:
            pass

if __name__ == "__main__":
    main()
