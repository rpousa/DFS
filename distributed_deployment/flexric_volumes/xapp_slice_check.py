#!/usr/bin/env python3
"""
xApp: per-DU / per-CU-UP UE residency-time reporting to Prometheus/Grafana
      + slice change after UE detection (Slice SM ASSOC).

- Residency: detect UEs via MAC (DU) and PDCP/GTP (CU-UP) indications,
  track first_seen/last_seen per (E2 node, RNTI), expose as Prometheus gauges.
- Slicing:   subscribe Slice SM on DUs to detect UEs+RNTIs, add target slices,
  then ASSOC each detected UE to the target DL slice using its REAL rnti.
"""

import time
import threading
import ctypes
import traceback
import signal

import xapp_sdk as ric
import xapp_functs                      # classify_e2node lives here  [[23]]
from prometheus_client import start_http_server, Gauge, Summary

# ----------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------
EXPORTER_PORT       = 9464               # flexric container already exposes this  [[21]]
REPORT_INTERVAL     = ric.Interval_ms_10 # E2 indication period
RESIDENCY_TIMEOUT   = 5.0                # s without indication => UE left the node
METRIC_REFRESH      = 1.0                # s between gauge refreshes
SLICE_POLL          = 2.0                # s between slice-control passes
TARGET_DL_SLICE_ID  = 2                  # move detected UEs onto this DL slice

TYPES_DU   = {"ngran_gNB_DU", "ngran_eNB_DU"}
TYPES_CUUP = {"ngran_gNB_CUUP", "ngran_gNB_CU"}   # unified CU carries UP too

# Slice definition pushed to every DU once (ids 0,2,5 -> STATIC)  (from your example) [[14]]
ADD_STATIC_SLICES = {
    "num_slices": 3, "slice_sched_algo": "STATIC",
    "slices": [
        {"id": 0, "label": "s1", "ue_sched_algo": "PF", "slice_algo_params": {"pos_low": 0,  "pos_high": 3}},
        {"id": 2, "label": "s2", "ue_sched_algo": "PF", "slice_algo_params": {"pos_low": 4,  "pos_high": 7}},
        {"id": 5, "label": "s3", "ue_sched_algo": "PF", "slice_algo_params": {"pos_low": 8,  "pos_high": 12}},
    ],
}

# ----------------------------------------------------------------------
# Prometheus metrics
# ----------------------------------------------------------------------
G_RESIDENCY = Gauge("ue_residency_seconds",
                    "Current UE residency time on an E2 node",
                    ["e2_node", "node_type", "cu_du_id", "rnti"])
G_ACTIVE    = Gauge("node_active_ue_count",
                    "Active UEs currently present on an E2 node",
                    ["e2_node", "node_type"])
S_SESSION   = Summary("ue_session_duration_seconds",
                      "Finalized UE residency (session) duration",
                      ["e2_node", "node_type"])
G_SLICE     = Gauge("ue_dl_slice_id",
                    "Current DL slice id associated to a UE",
                    ["e2_node", "rnti"])

_shutdown = False
def _sig(_s, _f):
    global _shutdown
    _shutdown = True
signal.signal(signal.SIGINT,  _sig)
signal.signal(signal.SIGTERM, _sig)


# ----------------------------------------------------------------------
# Residency tracker
# ----------------------------------------------------------------------
class ResidencyTracker:
    def __init__(self, timeout):
        self._lock = threading.Lock()
        self._first = {}   # (node_label, rnti) -> t_first
        self._last  = {}   # (node_label, rnti) -> t_last
        self._meta  = {}   # node_label -> (node_type, cu_du_id)
        self._exported = set()   # label tuples currently in G_RESIDENCY
        self.timeout = timeout

    def observe(self, node_label, node_type, cu_du_id, rnti, t=None):
        t = t or time.time()
        with self._lock:
            self._meta[node_label] = (node_type, cu_du_id)
            key = (node_label, rnti)
            self._first.setdefault(key, t)
            self._last[key] = t

    def refresh_metrics(self):
        now = time.time()
        with self._lock:
            per_node_active = {}
            for key in list(self._first.keys()):
                node_label, rnti = key
                node_type, cu_du_id = self._meta.get(node_label, ("unknown", "na"))
                labels = (node_label, node_type, cu_du_id, f"{rnti:#06x}")

                if now - self._last[key] > self.timeout:
                    # UE left -> finalize session, drop the gauge series
                    dur = self._last[key] - self._first[key]
                    S_SESSION.labels(node_label, node_type).observe(max(dur, 0.0))
                    try:
                        G_RESIDENCY.remove(*labels)
                    except KeyError:
                        pass
                    self._exported.discard(labels)
                    del self._first[key]; del self._last[key]
                    continue

                G_RESIDENCY.labels(*labels).set(now - self._first[key])
                self._exported.add(labels)
                per_node_active[(node_label, node_type)] = \
                    per_node_active.get((node_label, node_type), 0) + 1

            # active-UE counts (also zero-out nodes that emptied)
            for node_label, (node_type, _cu) in self._meta.items():
                G_ACTIVE.labels(node_label, node_type).set(
                    per_node_active.get((node_label, node_type), 0))

TRACKER = ResidencyTracker(RESIDENCY_TIMEOUT)

# ----------------------------------------------------------------------
# E2 indication callbacks  (pattern mirrors xapp_functs.py) [[23]]
# ----------------------------------------------------------------------
class MACCb(ric.mac_cb):
    def __init__(self, node_label, node_type, cu_du_id):
        ric.mac_cb.__init__(self)
        self.nl, self.nt, self.cu = node_label, node_type, cu_du_id
    def handle(self, ind):
        n = len(ind.ue_stats)
        if n and (int(time.time()) % 5 == 0):
            print(f"[dbg-mac] {self.nl} ue_stats={n} "
                  f"rntis={[hex(ind.ue_stats[i].rnti) for i in range(n)]}", flush=True)
        if n:
            now = time.time()
            for i in range(n):
                TRACKER.observe(self.nl, self.nt, self.cu, ind.ue_stats[i].rnti, now)

class PDCPCb(ric.pdcp_cb):
    def __init__(self, node_label, node_type, cu_du_id):
        ric.pdcp_cb.__init__(self)
        self.nl, self.nt, self.cu = node_label, node_type, cu_du_id
    def handle(self, ind):
        if len(ind.rb_stats) > 0:
            now = time.time()
            for i in range(len(ind.rb_stats)):
                TRACKER.observe(self.nl, self.nt, self.cu, ind.rb_stats[i].rnti, now)

class GTPCb(ric.gtp_cb):
    def __init__(self, node_label, node_type, cu_du_id):
        ric.gtp_cb.__init__(self)
        self.nl, self.nt, self.cu = node_label, node_type, cu_du_id
    def handle(self, ind):
        if len(ind.gtp_stats) > 0:
            now = time.time()
            for i in range(len(ind.gtp_stats)):
                TRACKER.observe(self.nl, self.nt, self.cu, ind.gtp_stats[i].rnti, now)

class SliceCb(ric.slice_cb):
    """Detect UEs + their current DL slice id per DU (structure from xapp_slice_moni_ctrl.py [[14]])."""
    def __init__(self, node_label):
        ric.slice_cb.__init__(self)
        self.node_label = node_label
    def handle(self, ind):
        st = ind.ue_slice_stats
        if int(time.time()) % 5 == 0:
            print(f"[dbg-slice] {self.node_label} len_ue_slice={st.len_ue_slice}", flush=True)
        if st.len_ue_slice > 0:
            with SLICE_LOCK:
                for u in st.ues:
                    dl_id = u.dl_id if u.dl_id >= 0 else -1
                    DETECTED_UES[(self.node_label, u.rnti)] = dl_id
                    G_SLICE.labels(self.node_label, f"{u.rnti:#06x}").set(dl_id)

SLICE_LOCK   = threading.Lock()
DETECTED_UES = {}          # (node_label, rnti) -> current dl_id
ASSOC_DONE   = set()       # (node_label, rnti) already moved to TARGET_DL_SLICE_ID

# ----------------------------------------------------------------------
# E2 node identity helpers  (cu_du_id extraction as in xapp_daemon.py) [[19]]
# ----------------------------------------------------------------------
def cu_du_id_of(nid):
    obj = getattr(nid, "cu_du_id", None)
    if obj is None:
        return None
    try:
        obj.disown()
        raw = int(obj)
        if raw == 0:
            return None
        return ctypes.cast(raw, ctypes.POINTER(ctypes.c_uint32)).contents.value
    except Exception:
        return None

def node_label_of(node_type, cu_du_id):
    short = {"ngran_gNB_DU": "du", "ngran_gNB_CUUP": "cuup",
             "ngran_gNB_CU": "cu", "ngran_gNB_CUCP": "cucp"}.get(node_type, "node")
    cu_hex = f"0x{cu_du_id:x}" if cu_du_id is not None else "na"
    return f"{short}_{cu_hex}"

# ----------------------------------------------------------------------
# Slice control message builders
# ----------------------------------------------------------------------
def build_addmod_static():
    msg = ric.slice_ctrl_msg_t()
    msg.type = ric.SLICE_CTRL_SM_V0_ADD
    dl = ric.ul_dl_slice_conf_t()
    dl.sched_name = "PF"; dl.len_sched_name = 2
    n = ADD_STATIC_SLICES["num_slices"]
    dl.len_slices = n
    arr = ric.slice_array(n)
    for i in range(n):
        sp = ADD_STATIC_SLICES["slices"][i]
        s = ric.fr_slice_t()
        s.id = sp["id"]
        s.label = sp["label"]; s.len_label = len(sp["label"])
        s.sched = sp["ue_sched_algo"]; s.len_sched = len(sp["ue_sched_algo"])
        s.params.type = ric.SLICE_ALG_SM_V0_STATIC
        s.params.u.sta.pos_low  = sp["slice_algo_params"]["pos_low"]
        s.params.u.sta.pos_high = sp["slice_algo_params"]["pos_high"]
        arr[i] = s
    dl.slices = arr
    msg.u.add_mod_slice.dl = dl
    return msg

def build_assoc(rnti, dl_id):
    msg = ric.slice_ctrl_msg_t()
    msg.type = ric.SLICE_CTRL_SM_V0_UE_SLICE_ASSOC
    msg.u.ue_slice.len_ue_slice = 1
    arr = ric.ue_slice_assoc_array(1)
    a = ric.ue_slice_assoc_t()
    a.rnti  = rnti          # <-- the REAL rnti, the fix vs. your TODO [[14]]
    a.dl_id = dl_id
    arr[0] = a
    msg.u.ue_slice.ues = arr
    return msg

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main():
    start_http_server(EXPORTER_PORT)          # /metrics for Prometheus
    print(f"[xapp] Prometheus exporter on :{EXPORTER_PORT}", flush=True)

    ric.init()
    conn = ric.conn_e2_nodes()
    EXPECTED = 4                       # cucp + cuup_co + cuup_e + du_co (5 with du_e1)
    if len(conn) < EXPECTED:
        print(f"[xapp] only {len(conn)} nodes at attach; exiting to retry", flush=True)
        ric.try_stop(); return         # clean exit; watchdog relaunches on a stable RIC
    
    
    cb_refs   = []        # keep callbacks alive (SDK GC caveat)
    handlers  = []
    du_nodes  = []        # (nid, node_label) for slice control
    subscribed = set()    # (node_type, cu_du_id) already subscribed

    def poll_and_subscribe(cb_refs, handlers, du_nodes, subscribed):
        """Subscribe to any E2 node not seen before. Safe to call repeatedly."""
        for con in ric.conn_e2_nodes():
            
            nid   = con.id
            ntype = xapp_functs.classify_e2node(nid)
            cu    = cu_du_id_of(nid)
            key   = (ntype, cu)
            if key in subscribed:
                continue
            label  = node_label_of(ntype, cu)
            cu_lbl = f"0x{cu:x}" if cu is not None else "na"
            print(f"[xapp] E2 node {label} type={ntype}", flush=True)

            if ntype in TYPES_DU:
                mac = MACCb(label, ntype, cu_lbl)
                cb_refs.append(mac)
                handlers.append(("mac", ric.report_mac_sm(nid, REPORT_INTERVAL, mac)))
                sl = SliceCb(label)
                cb_refs.append(sl)
                handlers.append(("slice", ric.report_slice_sm(nid, ric.Interval_ms_5, sl)))
                du_nodes.append((nid, label))
                time.sleep(2)   # let the slice subscription settle before ADD
                try:
                    ric.control_slice_sm(nid, build_addmod_static())
                    print(f"[xapp] Added STATIC subscription to slices on {label}", flush=True)
                except Exception as e:
                    print(f"[xapp] ADD slices failed on {label}: {e}", flush=True)

            elif ntype in TYPES_CUUP:
                p = PDCPCb(label, ntype, cu_lbl); 
                cb_refs += [p]
                handlers.append(("pdcp", ric.report_pdcp_sm(nid, REPORT_INTERVAL, p)))

            subscribed.add(key)
        return cb_refs, handlers, du_nodes, subscribed
    
    cb_refs, handlers, du_nodes, subscribed = poll_and_subscribe(cb_refs, handlers, du_nodes, subscribed)      # initial pass

    last_metric = last_slice = last_poll = last_status =  0.0
    try:
        while not _shutdown:
            now = time.time()

            if now - last_poll >= 5.0:      # pick up DUs that connect late
                cb_refs, handlers, du_nodes, subscribed = poll_and_subscribe(cb_refs, handlers, du_nodes, subscribed)
                last_poll = now

            if now - last_metric >= METRIC_REFRESH:
                TRACKER.refresh_metrics()
                last_metric = now

            # Slice change AFTER detection
            if now - last_slice >= SLICE_POLL:
                with SLICE_LOCK:
                    detected = dict(DETECTED_UES)
                for (label, rnti), dl_id in detected.items():
                    if (label, rnti) in ASSOC_DONE:
                        continue
                    if dl_id == TARGET_DL_SLICE_ID:
                        ASSOC_DONE.add((label, rnti))
                        continue
                    nid = next((n for n, l in du_nodes if l == label), None)
                    if nid is None:
                        continue
                    # try:
                    #     ric.control_slice_sm(nid, build_assoc(rnti, TARGET_DL_SLICE_ID))
                    #     ASSOC_DONE.add((label, rnti))
                    #     print(f"[xapp] Moved rnti={rnti:#06x} on {label} "
                    #           f"-> DL slice {TARGET_DL_SLICE_ID}", flush=True)
                    # except Exception as e:
                    #     print(f"[xapp] ASSOC failed rnti={rnti:#06x}: {e}", flush=True)
                last_slice = now
            
            if now - last_status >= 5.0:
                conn = ric.conn_e2_nodes()
                nodes = [(xapp_functs.classify_e2node(c.id), cu_du_id_of(c.id)) for c in conn]
                print(f"[dbg] connected E2 nodes={len(conn)} -> {nodes}", flush=True)
                print(f"[dbg] tracked residency keys={len(TRACKER._first)} "
                    f"detected_slice_ues={len(DETECTED_UES)} "
                    f"assoc_done={len(ASSOC_DONE)}", flush=True)
                print(f"[dbg] nodes={len(conn)} -> {nodes} | "
                    f"slice_ues={len(DETECTED_UES)} assoc_done={len(ASSOC_DONE)}", flush=True)

                last_status = now

            time.sleep(0.2)
    finally:
        rm = {"mac": ric.rm_report_mac_sm, "rlc": ric.rm_report_rlc_sm,
              "pdcp": ric.rm_report_pdcp_sm, "gtp": ric.rm_report_gtp_sm,
              "slice": ric.rm_report_slice_sm}
        for kind, h in handlers:
            try: rm[kind](h)
            except Exception: pass
        ric.try_stop()            # ← call it (clean disconnect)
        print("[xapp] stopped", flush=True)

if __name__ == "__main__":
    main()
