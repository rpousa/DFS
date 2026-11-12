# /*
#  * Licensed to the OpenAirInterface (OAI) Software Alliance under one or more
#  * contributor license agreements.  See the NOTICE file distributed with
#  * this work for additional information regarding copyright ownership.
#  * The OpenAirInterface Software Alliance licenses this file to You under
#  * the OAI Public License, Version 1.1  (the "License"); you may not use this file
#  * except in compliance with the License.
#  * You may obtain a copy of the License at
#  *
#  *      http://www.openairinterface.org/?page_id=698
#  *
#  * Unless required by applicable law or agreed to in writing, software
#  * distributed under the License is distributed on an "AS IS" BASIS,
#  * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  * See the License for the specific language governing permissions and
#  * limitations under the License.
#  *-------------------------------------------------------------------------------
#  * For more information about the OpenAirInterface (OAI) Software Alliance:
#  *      contact@openairinterface.org
#  */

import os
import io
import struct
import numpy as np
import yaml
from cir_defs import MODEL_NAME, MODEL_TO_ID, PKG_HDR_FMT, ENT_FMT, PAIR_ORDER_TX_MAJOR_RX_MINOR

_ent_struct = struct.Struct(ENT_FMT)

def _yaml_sidecar_path(bin_path: str) -> str:
    base, ext = os.path.splitext(bin_path)
    return base + ".yaml" if ext.lower() == ".bin" else bin_path + ".yaml"

def _scan_dir_from_yaml(db_bin_path: str):
    sidecar = _yaml_sidecar_path(db_bin_path)
    if not os.path.isfile(sidecar):
        return None
    with open(sidecar, "r") as f:
        y = yaml.safe_load(f)
    entries = y.get("entries", [])
    out = []
    for e in entries:
        out.append({
            "key": str(e.get("key", "")).lower(),
            "model_id": int(e["model_id"]),
            "n_rx": int(e["n_rx"]),
            "n_tx": int(e["n_tx"]),
            "L": int(e["L"]),
            "S": int(e["S"]),
            "fs_hz": float(e["fs_hz"]),
            "fc_hz": float(e.get("fc_hz", 0.0)),
            "ds_ns": float(e["ds_ns"]),
            "speed_mps": float(e["speed_mps"]),
            "rho_rx": float(e.get("rho_rx", 0.0)),
            "rho_tx": float(e.get("rho_tx", 0.0)),
            "snapshot_dt_s": float(e["snapshot_dt_s"]),
            "k1_db": (float(e["k1_db"]) if e.get("k1_db") is not None else None),
            "pair_order": int(e.get("pair_order", PAIR_ORDER_TX_MAJOR_RX_MINOR)),
            "offset_bytes": int(e["offset_bytes"]),
            "nbytes": int(e["nbytes"]),
            "dtype": e.get("dtype", "complex64"),
        })
    return out

def _scan_dir_from_binary(db_bin_path: str):
    with open(db_bin_path, "rb") as f:
        hdr = f.read(struct.calcsize(PKG_HDR_FMT))
        if len(hdr) != struct.calcsize(PKG_HDR_FMT):
            raise IOError("Failed to read CIR DB header")
        magic, version, entry_count = struct.unpack(PKG_HDR_FMT, hdr)
        if magic != b"CIRP" or version != 1:
            raise ValueError("Bad CIR DB header")
        entries = []
        for _ in range(entry_count):
            b = f.read(_ent_struct.size)
            if len(b) != _ent_struct.size:
                raise IOError("Failed to read directory entry")
            (key,
             model_id, n_rx, n_tx,
             L, S,
             fs_hz, fc_hz,
             ds_ns, speed_mps,
             rho_rx, rho_tx,
             snapshot_dt_s, k1_db_or_nan,
             pair_order, offset, nbytes) = _ent_struct.unpack(b)
            entries.append({
                "key": f"{key:016x}",
                "model_id": int(model_id),
                "n_rx": int(n_rx),
                "n_tx": int(n_tx),
                "L": int(L),
                "S": int(S),
                "fs_hz": float(fs_hz),
                "fc_hz": float(fc_hz),
                "ds_ns": float(ds_ns),
                "speed_mps": float(speed_mps),
                "rho_rx": float(rho_rx),
                "rho_tx": float(rho_tx),
                "snapshot_dt_s": float(snapshot_dt_s),
                "k1_db": (None if np.isnan(k1_db_or_nan) else float(k1_db_or_nan)),
                "pair_order": int(pair_order),
                "offset_bytes": int(offset),
                "nbytes": int(nbytes),
                "dtype": "complex64",
            })
        return entries

def _scan_dir(db_bin_path: str):
    ent = _scan_dir_from_yaml(db_bin_path)
    if ent is not None:
        return ent
    return _scan_dir_from_binary(db_bin_path)

def cir_scan(db_bin_path: str):
    """
    Return a list of directory entries as dictionaries.
    Each dict at least includes model_id, n_rx, n_tx, L, S, fs_hz, ds_ns, speed_mps, pair_order, offset_bytes, nbytes, key.
    """
    return _scan_dir(db_bin_path)

def _nearest_match(entries, model_id, n_rx, n_tx, ds_ns, speed_mps):
    W_DS = 1.0
    W_SP = 0.2
    best = None
    best_cost = None
    for e in entries:
        if e["pair_order"] != PAIR_ORDER_TX_MAJOR_RX_MINOR:
            continue
        if e["model_id"] != model_id:
            continue
        if e["n_rx"] != n_rx or e["n_tx"] != n_tx:
            continue
        cds = abs(e["ds_ns"] - ds_ns)
        csp = abs(e["speed_mps"] - (speed_mps if speed_mps is not None else e["speed_mps"]))
        cost = W_DS * cds + W_SP * csp
        if best is None or cost < best_cost:
            best = e
            best_cost = cost
    if best is None:
        raise KeyError("No matching entry found for requested model and shape in CIR DB")
    return best

def cir_find(db_bin_path: str,
             model: str,
             n_rx: int,
             n_tx: int,
             ds_ns: float,
             speed_mps: float | None,
             expect_fs_hz: float | None = None):
    """
    Select an entry by parameters. Nearest match on ds and speed.
    Returns a spec dict used by snapshot readers and the emitter.
    """
    entries = _scan_dir(db_bin_path)
    model_id = MODEL_TO_ID[model]
    e = _nearest_match(entries, model_id, n_rx, n_tx, ds_ns, speed_mps)
    if expect_fs_hz is not None and abs(e["fs_hz"] - expect_fs_hz) > 1.0:
        raise KeyError(f"Sample rate mismatch. Entry has {e['fs_hz']} Hz, expected {expect_fs_hz} Hz")
    spec = {
        "db_path": db_bin_path,
        "key": e.get("key", ""),
        "offset_bytes": e["offset_bytes"],
        "nbytes": e["nbytes"],
        "model_id": e["model_id"],
        "n_rx": e["n_rx"],
        "n_tx": e["n_tx"],
        "L": e["L"],
        "S": e["S"],
        "fs_hz": e["fs_hz"],
        "snapshot_dt_s": e["snapshot_dt_s"],
        "ds_ns": e["ds_ns"],
        "speed_mps": e["speed_mps"],
        "pair_order": e["pair_order"],
        "dtype": e.get("dtype", "complex64"),
    }
    return spec

def cir_snapshot_rx_tx_L(spec: dict, s_idx: int) -> np.ndarray:
    """
    Return one snapshot as a complex64 array with shape [RX, TX, L].
    The file stores links in TX-major, RX-minor order with L complex taps per link.
    """
    db_path = spec["db_path"]
    n_tx = int(spec["n_tx"])
    n_rx = int(spec["n_rx"])
    L = int(spec["L"])
    S = int(spec["S"])
    if S <= 0:
        raise ValueError("Spec has zero snapshots")
    s_idx = int(s_idx) % S

    stride_bytes = n_tx * n_rx * L * 8
    offset = int(spec["offset_bytes"]) + s_idx * stride_bytes

    with open(db_path, "rb") as f:
        f.seek(offset, io.SEEK_SET)
        raw = f.read(stride_bytes)
        if len(raw) != stride_bytes:
            raise IOError("Short read while reading snapshot")
        arr = np.frombuffer(raw, dtype=np.complex64)

    arr = arr.reshape((n_tx, n_rx, L))
    rx_tx_L = np.transpose(arr, (1, 0, 2)).copy()
    return rx_tx_L

def flatten_txmajor_rxminor(rx_tx_L: np.ndarray) -> bytes:
    """
    Flatten taps in TX-major, RX-minor, L inner, interleaved float32 (re, im).
    Input shape must be [RX, TX, L].
    """
    if rx_tx_L.ndim != 3:
        raise ValueError("Expected rx_tx_L with shape [RX, TX, L]")
    tx_rx_L = np.transpose(rx_tx_L, (1, 0, 2))
    flat_c = tx_rx_L.reshape(-1)
    out = np.empty(flat_c.size * 2, dtype=np.float32)
    out[0::2] = flat_c.real.astype(np.float32, copy=False)
    out[1::2] = flat_c.imag.astype(np.float32, copy=False)
    return out.tobytes()
