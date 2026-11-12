#/*
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
# *-------------------------------------------------------------------------------
# * For more information about the OpenAirInterface (OAI) Software Alliance:
# *      contact@openairinterface.org
# */

import os
import sys
import argparse
import hashlib
import struct
import numpy as np
import yaml
from cir_defs import MODEL_NAME, MODEL_TO_ID, PKG_HDR_FMT, ENT_FMT, PKG_HDR_SIZE, ENT_SIZE, PAIR_ORDER_TX_MAJOR_RX_MINOR, MAX_L

# -------- 3GPP TDL profiles (3GPP TR 38.901 Release 18) --------

# Table 7.7.2-1. TDL-A
TDL_TABLES = {
    # Table 7.7.2-1. TDL-A (3GPP TR 38.901)
    "TDL-A": {
        "delays": [
            0.0000, 0.3819, 0.4025, 0.5868, 0.4610, 0.5375, 0.6708, 0.5750,
            0.7618, 1.5375, 1.8978, 2.2242, 2.1718, 2.4942, 2.5119, 3.0582,
            4.0810, 4.4579, 4.5695, 4.7966, 5.0066, 5.3043, 9.6586
        ],
        "pdb": [
            -13.4, 0.0, -2.2, -4.0, -6.0, -8.2, -9.9, -10.5, -7.5, -15.9,
            -6.6, -16.7, -12.4, -15.2, -10.8, -11.3, -12.7, -16.2, -18.3,
            -18.9, -16.6, -19.9, -29.7
        ],
        "k1_db": None
    },

    # Table 7.7.2-2. TDL-B (3GPP TR 38.901)
    "TDL-B": {
        "delays": [
            0.0000, 0.1072, 0.2155, 0.2095, 0.2870, 0.2986, 0.3752, 0.5055,
            0.3681, 0.3697, 0.5700, 0.5283, 1.1021, 1.2756, 1.5474, 1.7842,
            2.0169, 2.8294, 3.0219, 3.6187, 4.1067, 4.2790, 4.7834
        ],
        "pdb": [
            0.0, -2.2, -4.0, -3.2, -9.8, -1.2, -3.4, -5.2, -7.6, -3.0,
            -8.9, -9.0, -4.8, -5.7, -7.5, -1.9, -7.6, -12.2, -9.8, -11.4,
            -14.9, -9.2, -11.3
        ],
        "k1_db": None
    },

    # Table 7.7.2-3. TDL-C (3GPP TR 38.901)
    "TDL-C": {
        "delays": [
            0.0000, 0.2099, 0.2219, 0.2329, 0.2176, 0.6366, 0.6448, 0.6560,
            0.6584, 0.7935, 0.8213, 0.9336, 1.2285, 1.3083, 2.1704, 2.7105,
            4.2589, 4.6003, 5.4902, 5.6077, 6.3065, 6.6374, 7.0427, 8.6523
        ],
        "pdb": [
            -4.4, -1.2, -3.5, -5.2, -2.5, 0.0, -2.2, -3.9, -7.4, -7.1,
            -10.7, -11.1, -5.1, -6.8, -8.7, -13.2, -13.9, -13.9, -15.8,
            -17.1, -16.0, -15.7, -21.6, -22.8
        ],
        "k1_db": None
    },

    # Table 7.7.2-4. TDL-D (3GPP TR 38.901)
    "TDL-D": {
        "delays": [
            0.0000, 0.0350, 0.6120, 1.3630, 1.4050, 1.8040, 2.5960, 1.7750,
            4.0420, 7.9370, 9.4240, 9.7080, 12.5250
        ],
        "pdb": [
            0.0, -18.8, -21.0, -22.8, -17.9, -20.1, -21.9, -22.9,
            -27.8, -23.6, -24.8, -30.0, -27.7
        ],
        "k1_db": 13.3
    },

    # Table 7.7.2-5. TDL-E (3GPP TR 38.901)
    "TDL-E": {
        "delays": [
            0.0000, 0.5133, 0.5440, 0.5630, 0.5440, 0.7112, 1.9092, 1.9293,
            1.9589, 2.6426, 3.7136, 5.4524, 12.0034, 20.6519
        ],
        "pdb": [
            -0.03, -15.8, -18.1, -19.8, -22.9, -22.4, -18.6, -20.8,
            -22.6, -22.3, -25.6, -20.2, -29.8, -29.2
        ],
        "k1_db": 22.0
    },
}


def _u64_key(model_id: int, n_tx: int, n_rx: int, ds_ns: float, sp_mps: float) -> int:
    h = hashlib.sha1(f"{model_id}|{n_tx}|{n_rx}|{ds_ns:.6f}|{sp_mps:.6f}".encode("ascii")).digest()
    return int.from_bytes(h[:8], "little", signed=False)

def _estimate_total_bytes(models, ds_values, shapes, speeds, snapshots, fs_hz, max_taps):
    total = 0
    for model_name in models:
        tab = TDL_TABLES[model_name]
        delays_norm = tab["delays"]
        pdb_db = tab["pdb"]
        for ds_ns in ds_values:
            _, _, L = _pick_compact_taps(delays_norm, pdb_db, fs_hz, ds_ns, max_taps)
            for (tx, rx) in shapes:
                for _sp in speeds:
                    total += snapshots * tx * rx * L * 8
    return total

def _pick_compact_taps(delays_norm, pdb_db, fs_hz, ds_ns, max_taps=8):
    ds_s = ds_ns * 1e-9
    abs_delays_s = np.asarray(delays_norm, dtype=np.float64) * ds_s
    tap_idx = np.rint(abs_delays_s * fs_hz).astype(np.int64)

    # unique by time, sorted by increasing delay
    uniq, first_idx = np.unique(tap_idx, return_index=True)
    order = np.argsort(uniq)
    chosen_src_idx = first_idx[order]

    # take earliest max_taps distinct taps
    M = int(min(max_taps, chosen_src_idx.size))
    if M == 0:
        # degenerate guard
        pow_lin = np.ones((1,), dtype=np.float32)
        return np.arange(1, dtype=np.int64), pow_lin, 1

    chosen_src_idx = chosen_src_idx[:M]
    chosen_pdb = np.take(np.asarray(pdb_db, dtype=np.float32), chosen_src_idx)

    pow_lin = 10.0 ** (chosen_pdb / 10.0)
    s = pow_lin.sum()
    pow_lin = (pow_lin / s) if s > 0 else np.ones_like(pow_lin, dtype=np.float32) / float(M)

    # compact to contiguous 0..L-1 (L = M)
    compact_pos = np.arange(M, dtype=np.int64)
    return compact_pos, pow_lin.astype(np.float32), M

def _toeplitz_corr(n: int, rho: float) -> np.ndarray:
    if n <= 1 or rho == 0.0:
        return np.eye(n, dtype=np.float32)
    absrho = float(rho)
    v = np.power(absrho, np.arange(n, dtype=np.int64)).astype(np.float32)
    R = np.empty((n, n), dtype=np.float32)
    for i in range(n):
        R[i, :] = v[np.abs(np.arange(n) - i)]
    return R

def _corr_sqrt(R: np.ndarray) -> np.ndarray:
    R = 0.5 * (R + R.T)
    try:
        L = np.linalg.cholesky(R + 1e-6 * np.eye(R.shape[0], dtype=R.dtype))
    except np.linalg.LinAlgError:
        w, V = np.linalg.eigh(R)
        w = np.clip(w, 1e-8, None)
        L = V @ np.diag(np.sqrt(w).astype(R.dtype)) @ V.T
    return L.astype(np.float32, copy=False)

def _coupling_matrix(n: int, k: float, decay: float) -> np.ndarray:
    if n <= 1 or abs(k) < 1e-9:
        return np.eye(n, dtype=np.complex64)
    C = np.eye(n, dtype=np.complex64)
    k = np.complex64(k)
    d = float(decay)
    for i in range(n):
        for j in range(n):
            if i == j:
                continue
            dist = abs(i - j)
            C[i, j] = k * (d ** max(0, dist - 1))
    return C

def _ula_steering(n: int, spacing_wl: float, angle_deg: float) -> np.ndarray:
    if n <= 0:
        return np.ones((0,), dtype=np.complex64)
    theta = np.deg2rad(angle_deg)
    m = np.arange(n, dtype=np.float32)
    phase = 2.0 * np.pi * spacing_wl * m * np.sin(theta)
    a = np.exp(1j * phase).astype(np.complex64)
    a /= np.sqrt(np.maximum(1e-12, np.vdot(a, a).real)).astype(np.float32)
    return a

def _gen_snapshot(rng, n_tx, n_rx, L, pow_sqrt, k1_db, shadow_sigma_db=0.0):
    h = (rng.standard_normal((n_tx, n_rx, L), dtype=np.float32) +
         1j * rng.standard_normal((n_tx, n_rx, L), dtype=np.float32)) / np.sqrt(2.0)

    h *= pow_sqrt[None, None, :]

    if k1_db is not None and L > 0:
        K = np.float32(10.0 ** (k1_db / 10.0))
        s = np.sqrt(K / (K + 1.0)).astype(np.float32)
        n = np.sqrt(1.0 / (K + 1.0)).astype(np.float32)
        phi = rng.uniform(0.0, 2.0 * np.pi, size=(n_tx, n_rx)).astype(np.float32)
        h[..., 0] = s * np.exp(1j * phi) + n * h[..., 0]

    if shadow_sigma_db and shadow_sigma_db > 0.0:
        s_db = rng.normal(0.0, shadow_sigma_db, size=(n_tx, n_rx)).astype(np.float32)
        scale = np.power(10.0, s_db * 0.05, dtype=np.float32)[..., None]
        h *= scale

    return h.astype(np.complex64, copy=False)

def _apply_corr_and_coupling(h_ntx_nrx_L: np.ndarray,
                             Rtx_sqrt: np.ndarray,
                             Rrx_sqrt: np.ndarray,
                             Ctx: np.ndarray,
                             Crx: np.ndarray,
                             k1_db,
                             los_enable: bool,
                             los_aod_deg: float,
                             los_aoa_deg: float,
                             spacing_wl: float) -> np.ndarray:
    n_tx, n_rx, L = h_ntx_nrx_L.shape

    H = np.transpose(h_ntx_nrx_L, (2, 1, 0))

    H = np.einsum('ij,ljk->lik', Rrx_sqrt.astype(np.complex64), H, optimize=True)
    H = np.einsum('lik,km->lim', H, Rtx_sqrt.astype(np.complex64), optimize=True)

    if k1_db is not None and L > 0 and los_enable:
        K = np.float32(10.0 ** (k1_db / 10.0))
        s = np.sqrt(K / (K + 1.0)).astype(np.float32)
        n = np.sqrt(1.0 / (K + 1.0)).astype(np.float32)
        a_tx = _ula_steering(n_tx, spacing_wl, los_aod_deg)
        a_rx = _ula_steering(n_rx, spacing_wl, los_aoa_deg)
        H_los = (s.astype(np.complex64)) * np.outer(a_rx.conj(), a_tx).astype(np.complex64)
        H0_scatter = H[0, ...]
        H[0, ...] = H_los + (n.astype(np.complex64)) * H0_scatter

    H = np.einsum('ij,ljk->lik', Crx.astype(np.complex64), H, optimize=True)
    H = np.einsum('lik,km->lim', H, Ctx.T.astype(np.complex64), optimize=True)

    return np.transpose(H, (2, 1, 0))

def _write_entry_data(fh, rng, n_tx, n_rx, S, L, pow_lin, k1_db, shadow_sigma_db,
                      rho_tx, rho_rx, coup_tx, coup_rx, coup_decay,
                      los_enable, los_aod_deg, los_aoa_deg, spacing_wl,
                      snapshot_dt_s, shadow_corr_time_s):
    offset = fh.tell()
    pow_sqrt = np.sqrt(pow_lin).astype(np.float32)

    Rtx = _toeplitz_corr(n_tx, rho_tx)
    Rrx = _toeplitz_corr(n_rx, rho_rx)
    Rtx_sqrt = _corr_sqrt(Rtx)
    Rrx_sqrt = _corr_sqrt(Rrx)
    Ctx = _coupling_matrix(n_tx, coup_tx, coup_decay)
    Crx = _coupling_matrix(n_rx, coup_rx, coup_decay)

    use_shadow = shadow_sigma_db is not None and shadow_sigma_db > 0.0
    ar1 = use_shadow and shadow_corr_time_s is not None and shadow_corr_time_s > 0.0

    if use_shadow and not ar1:
        s_db = rng.normal(0.0, shadow_sigma_db, size=(n_tx, n_rx)).astype(np.float32)
        fixed_scale = np.power(10.0, 0.05 * s_db, dtype=np.float32)[..., None]
    else:
        fixed_scale = None

    if ar1:
        x_db = rng.normal(0.0, shadow_sigma_db, size=(n_tx, n_rx)).astype(np.float32)
        phi = float(np.exp(-snapshot_dt_s / shadow_corr_time_s))
        sigma_w = float(shadow_sigma_db * np.sqrt(max(1e-12, 1.0 - phi * phi)))

    for _ in range(S):
        h = _gen_snapshot(rng, n_tx, n_rx, L, pow_sqrt, k1_db, shadow_sigma_db=0.0)
        h = _apply_corr_and_coupling(h, Rtx_sqrt, Rrx_sqrt, Ctx, Crx, k1_db,
                                     los_enable, los_aod_deg, los_aoa_deg, spacing_wl)
        if use_shadow:
            if ar1:
                w = rng.normal(0.0, sigma_w, size=(n_tx, n_rx)).astype(np.float32)
                x_db = phi * x_db + w
                scale = np.power(10.0, 0.05 * x_db, dtype=np.float32)[..., None]
                h *= scale
            else:
                h *= fixed_scale
        fh.write(h.tobytes(order="C"))
    nbytes = n_tx * n_rx * L * 8 * S
    return offset, nbytes

def _yaml_sidecar_path(bin_path: str) -> str:
    base, ext = os.path.splitext(bin_path)
    if ext.lower() == ".bin":
        return base + ".yaml"
    return bin_path + ".yaml"

def _parse_antenna_string(ant_str):
    parts = ant_str.lower().split('x')
    if len(parts) != 2:
        raise ValueError(f"Invalid antenna format: {ant_str}. Use format like '1x1' or '4x4'")
    return (int(parts[0]), int(parts[1]))

def main():
    p = argparse.ArgumentParser(
        description="Generate a CIR DB (TDL A to E, DS set, speeds, shapes up to 64x64) with compact L<=8."
    )
    p.add_argument("--out", required=True, help="Output file (e.g., ./cir_db.bin)")
    p.add_argument("--fs-hz", type=float, default=61.44e6, help="Sample rate (Hz)")
    p.add_argument("--fc-hz", type=float, default=3.6192e9, help="Carrier (Hz)")
    p.add_argument("--snapshots", type=int, default=1000, help="Snapshots per entry")
    p.add_argument("--snapshot-dt-s", type=float, default=1e-3, help="Time step between snapshots (s)")
    p.add_argument("--shadow-sigma-db", type=float, default=6.0, help="Per-link shadowing sigma (dB)")
    p.add_argument("--max-taps", type=int, default=8, help="Maximum number of taps per link (default: 8)")
    p.add_argument("--models", nargs='+', choices=["TDL-A", "TDL-B", "TDL-C", "TDL-D", "TDL-E"],
                   help="Select specific models (e.g., --models TDL-A TDL-B)")
    p.add_argument("--antennas", nargs='+',
                   help="Antenna configurations (e.g., --antennas 1x1 2x2 4x4)")
    p.add_argument("--delay-spreads", nargs='+', type=float,
                   help="Delay spreads in ns (e.g., --delay-spreads 10 30)")
    p.add_argument("--speeds", nargs='+', type=float,
                   help="User speeds in m/s (e.g., --speeds 1.5 30)")
    p.add_argument("--demo", action="store_true",
                   help="Generate demo preset: All 5 TDL models | 1x1 up to 4x4 | DS=10,30,100ns | speeds=1.5,30,120 m/s")

    p.add_argument("--shadow-corr-time-s", type=float, default=2.0,
                   help="Shadowing correlation time in seconds. 0 means fixed across snapshots.")
    p.add_argument("--seed", type=int, default=1, help="Base RNG seed")

    # Spatial correlation and coupling controls (enabled by default)
    p.add_argument("--rho-tx", type=float, default=0.5,
                   help="Exponential correlation coefficient at TX side (0..0.99)")
    p.add_argument("--rho-rx", type=float, default=0.5,
                   help="Exponential correlation coefficient at RX side (0..0.99)")
    p.add_argument("--coupling-tx", type=float, default=0.2,
                   help="Nearest-neighbor coupling magnitude at TX side")
    p.add_argument("--coupling-rx", type=float, default=0.2,
                   help="Nearest-neighbor coupling magnitude at RX side")
    p.add_argument("--coupling-decay", type=float, default=0.6,
                   help="Exponential decay for farther neighbors in coupling matrix (0..1)")

    # LOS steering for TDL-D/E (enabled by default)
    p.add_argument("--los-enable", action="store_true",
                   help="Enable ULA steering for LOS tap (TDL-D/E only)")
    p.set_defaults(los_enable=True)
    p.add_argument("--los-aoa-deg", type=float, default=0.0,
                   help="LOS angle of arrival at RX array in degrees")
    p.add_argument("--los-aod-deg", type=float, default=0.0,
                   help="LOS angle of departure at TX array in degrees")
    p.add_argument("--array-spacing-wl", type=float, default=0.5,
                   help="Array element spacing in wavelengths for steering")

    args = p.parse_args()

    def _clip(name, val, lo, hi):
        if val < lo or val > hi:
            print(f"[warn] {name}={val} out of range [{lo},{hi}], clipping", flush=True)
        return max(lo, min(val, hi))

    args.rho_tx = _clip("rho_tx", float(args.rho_tx), 0.0, 0.99)
    args.rho_rx = _clip("rho_rx", float(args.rho_rx), 0.0, 0.99)
    args.coupling_tx = float(args.coupling_tx)
    args.coupling_rx = float(args.coupling_rx)
    args.coupling_decay = _clip("coupling_decay", float(args.coupling_decay), 0.0, 1.0)

    if args.max_taps <= 0:
        raise ValueError("--max-taps must be > 0")
    if args.max_taps > 64:
        print(f"[warn] --max-taps={args.max_taps} is very large, this may consume significant memory")

    if args.snapshots <= 0:
        raise ValueError("--snapshots must be > 0")
    if args.fs_hz <= 0.0:
        raise ValueError("--fs-hz must be > 0")
    if args.snapshot_dt_s <= 0.0:
        raise ValueError("--snapshot-dt-s must be > 0")

    if args.shadow_sigma_db > 0.0 and args.shadow_corr_time_s > 0.0:
        phi = float(np.exp(-args.snapshot_dt_s / args.shadow_corr_time_s))
        sigma_w = float(args.shadow_sigma_db * np.sqrt(max(1e-12, 1.0 - phi * phi)))
        print(f"[shadowing] time-varying AR(1) enabled: sigma={args.shadow_sigma_db:.2f} dB, "
              f"tau={args.shadow_corr_time_s:.3f} s, dt={args.snapshot_dt_s:.6f} s, "
              f"phi={phi:.6f}, sigma_w={sigma_w:.3f} dB")
    elif args.shadow_sigma_db > 0.0:
        print(f"[shadowing] fixed per-entry shadowing enabled: sigma={args.shadow_sigma_db:.2f} dB")
    else:
        print("[shadowing] disabled (sigma=0)")

    if args.demo:
        selected_models = ["TDL-A", "TDL-B", "TDL-C", "TDL-D", "TDL-E"]
        selected_antennas = [(1, 1), (1, 2), (2, 1), (2, 2), (4, 2), (2, 4), (4, 4)]
        selected_delays = [10.0, 30.0, 100.0]
        selected_speeds = [1.5, 30.0, 120.0]
        print("[demo] Generating demo configuration:")
        print(f"  Models: {selected_models}")
        print(f"  Antennas: {selected_antennas}")
        print(f"  Delay spreads: {selected_delays} ns")
        print(f"  Speeds: {selected_speeds} m/s")
    else:
        if not args.models and not args.antennas and not args.delay_spreads and not args.speeds:
            print("Error: At least one of --models, --antennas, --delay-spreads, or --speeds must be specified")
            print("       Or use --demo for quick preset")
            print("\nExamples:")
            print("  python3 cir_generator.py --models TDL-A --antennas 1x1 --delay-spreads 30")
            print("  python3 cir_generator.py --demo")
            sys.exit(1)

        selected_models = args.models if args.models else ["TDL-A", "TDL-B"]

        if args.antennas:
            selected_antennas = [_parse_antenna_string(a) for a in args.antennas]
        else:
            selected_antennas = [(1, 1), (1, 2), (2, 1), (2, 2), (4, 2), (2, 4), (4, 4)]

        selected_delays = args.delay_spreads if args.delay_spreads else [10.0, 30.0, 100.0]
        selected_speeds = args.speeds if args.speeds else [1.5, 30.0, 120.0]

    models = selected_models
    shapes = selected_antennas
    ds_values = selected_delays
    speeds = selected_speeds

    entry_count = len(models) * len(ds_values) * len(speeds) * len(shapes)

    print(f"\nConfiguration:")
    print(f"  Models: {models}")
    print(f"  Antennas: {shapes}")
    print(f"  Delay spreads: {ds_values} ns")
    print(f"  Speeds: {speeds} m/s")
    print(f"  Total entries: {entry_count}\n")

    est_bytes = _estimate_total_bytes(models, ds_values, shapes, speeds,
                                      args.snapshots, args.fs_hz, args.max_taps)
    approx_file_size = PKG_HDR_SIZE + entry_count * ENT_SIZE + est_bytes

    size_gb = approx_file_size / (1024**3)

    if size_gb >= 1.0:
        print(f"Approximate output file size: {size_gb:.2f} GB\n")
    else:
        size_mb = approx_file_size / (1024**2)
        print(f"Approximate output file size: {size_mb:.1f} MB\n")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or '.', exist_ok=True)
    with open(args.out, "wb") as fh:
        fh.write(struct.pack(PKG_HDR_FMT, b"CIRP", 1, entry_count))
        dir_pos = fh.tell()
        fh.write(b"\x00" * (ENT_SIZE * entry_count))

        dir_records = []
        yaml_entries = []
        idx = 0

        for model_name in models:
            model_id = MODEL_TO_ID[model_name]
            tab = TDL_TABLES[model_name]
            delays_norm = tab["delays"]
            pdb_db = tab["pdb"]
            k1_db = tab["k1_db"]

            for ds_ns in ds_values:
                _pos, pow_lin, L = _pick_compact_taps(delays_norm, pdb_db, args.fs_hz, ds_ns, args.max_taps)

                for sp_mps in speeds:
                    for (n_tx, n_rx) in shapes:
                        key = _u64_key(model_id, n_tx, n_rx, ds_ns, sp_mps)
                        sub_seed = (int(key) ^ args.seed) & 0xFFFFFFFF
                        rng = np.random.default_rng(sub_seed)

                        off, nbytes = _write_entry_data(
                            fh, rng, n_tx, n_rx, args.snapshots, L,
                            pow_lin=pow_lin, k1_db=k1_db, shadow_sigma_db=args.shadow_sigma_db,
                            rho_tx=args.rho_tx, rho_rx=args.rho_rx,
                            coup_tx=args.coupling_tx, coup_rx=args.coupling_rx, coup_decay=args.coupling_decay,
                            los_enable=args.los_enable, los_aod_deg=args.los_aod_deg,
                            los_aoa_deg=args.los_aoa_deg, spacing_wl=args.array_spacing_wl,
                            snapshot_dt_s=args.snapshot_dt_s, shadow_corr_time_s=args.shadow_corr_time_s
                        )

                        rec = struct.pack(
                            ENT_FMT,
                            key,
                            np.uint16(model_id),
                            np.uint16(n_rx),
                            np.uint16(n_tx),
                            np.uint32(L),
                            np.uint32(args.snapshots),
                            float(args.fs_hz),
                            float(args.fc_hz),
                            float(ds_ns),
                            float(sp_mps),
                            float(args.rho_rx),
                            float(args.rho_tx),
                            float(args.snapshot_dt_s),
                            float(k1_db if k1_db is not None else float("nan")),
                            np.uint32(PAIR_ORDER_TX_MAJOR_RX_MINOR),
                            np.uint64(off),
                            np.uint64(nbytes),
                        )
                        dir_records.append(rec)

                        yaml_entries.append({
                            "key": f"{key:016x}",
                            "model": model_name,
                            "model_id": int(model_id),
                            "n_tx": int(n_tx),
                            "n_rx": int(n_rx),
                            "L": int(L),
                            "S": int(args.snapshots),
                            "fs_hz": float(args.fs_hz),
                            "fc_hz": float(args.fc_hz),
                            "ds_ns": float(ds_ns),
                            "speed_mps": float(sp_mps),
                            "rho_rx": float(args.rho_rx),
                            "rho_tx": float(args.rho_tx),
                            "snapshot_dt_s": float(args.snapshot_dt_s),
                            "k1_db": (float(k1_db) if k1_db is not None else None),
                            "pair_order": int(PAIR_ORDER_TX_MAJOR_RX_MINOR),
                            "offset_bytes": int(off),
                            "nbytes": int(nbytes),
                            "pow_lin": [float(x) for x in pow_lin.tolist()],
                            "dtype": "complex64",
                            "shadow_sigma_db": float(args.shadow_sigma_db),
                            "shadow_corr_time_s": float(args.shadow_corr_time_s),
                            "coupling_tx": float(args.coupling_tx),
                            "coupling_rx": float(args.coupling_rx),
                            "coupling_decay": float(args.coupling_decay),
                            "los_enable": bool(args.los_enable),
                            "los_aoa_deg": float(args.los_aoa_deg),
                            "los_aod_deg": float(args.los_aod_deg),
                            "array_spacing_wl": float(args.array_spacing_wl),
                            "max_taps": int(args.max_taps),
                            "shadow_model": "AR1" if (args.shadow_sigma_db > 0.0 and args.shadow_corr_time_s > 0.0) else ("fixed" if args.shadow_sigma_db > 0.0 else "none"),
                        })

                        idx += 1
                        print(f"  wrote {idx}/{entry_count} entries...", flush=True)

        end_pos = fh.tell()
        fh.seek(dir_pos, os.SEEK_SET)
        for rec in dir_records:
            fh.write(rec)
        fh.seek(end_pos, os.SEEK_SET)

    sidecar = _yaml_sidecar_path(args.out)
    with open(sidecar, "w") as yf:
        yaml.safe_dump({"version": 1, "entries": yaml_entries}, yf, sort_keys=False)
    print(f"Wrote YAML index: {sidecar}")

    print("Done.")

if __name__ == "__main__":
    main()
