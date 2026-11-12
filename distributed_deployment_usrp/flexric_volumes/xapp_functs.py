import inspect
import time
import types
import ctypes
import xapp_sdk
from dataclasses import dataclass, field
from typing import Dict, List, Any

@dataclass
class Xapp_Metric_Storage:
    nodes: Dict[int, Any] = field(default_factory=dict)
    metrics: Dict[int, Dict[str, List[Any]]] = field(default_factory=dict)

    def add_node(self, node_idx: int, node_type: Any, metric_list: List[str]):
        self.nodes[node_idx] = node_type
        self.metrics[node_idx] = {metric: [] for metric in metric_list}

    def __str__(self):
        output = []
        for node_idx, node_type in self.nodes.items():
            output.append(f"Node {node_idx} (Type: {node_type}):")
            for metric, values in self.metrics[node_idx].items():
                output.append(f"  Metric {metric}: {values}")
        return "\n".join(output)


####################
#### CALLBACKS #####
####################

class RLCCallback(xapp_sdk.rlc_cb):
    internal_storage = None
    internal_node_id = None

    def __init__(self, storage, node_id):
        xapp_sdk.rlc_cb.__init__(self)
        self.internal_storage = storage
        self.internal_node_id = node_id

    def handle(self, ind):
        if len(ind.rb_stats) > 0:
            t_now = time.time_ns() / 1000.0
            self.internal_storage.metrics[self.internal_node_id]['rlc'].append(ind.rb_stats)


class MACCallback(xapp_sdk.mac_cb):
    # Class-level UE tracking
    ue_mac_map = {}
    _indication_count = 0
    _empty_count = 0
    _logged_ues = set()  # Track which UEs we've already logged

    def __init__(self, storage, node_id):
        xapp_sdk.mac_cb.__init__(self)
        self.internal_storage = storage
        self.internal_node_id = node_id
        self._instance_ind_count = 0

    def handle(self, ind):
        MACCallback._indication_count += 1
        self._instance_ind_count += 1

        if len(ind.ue_stats) > 0:
            t_now = time.time_ns() / 1000.0
            self.internal_storage.metrics[self.internal_node_id]['mac'].append(ind.ue_stats)

            for i in range(len(ind.ue_stats)):
                try:
                    ue = ind.ue_stats[i]
                    rnti = ue.rnti

                    stats = {
                        'rnti': rnti,
                        'dl_aggr_tbs': ue.dl_aggr_tbs,
                        'ul_aggr_tbs': ue.ul_aggr_tbs,
                        'dl_curr_tbs': ue.dl_curr_tbs,
                        'ul_curr_tbs': ue.ul_curr_tbs,
                        'dl_sched_rb': ue.dl_sched_rb,
                        'ul_sched_rb': ue.ul_sched_rb,
                        'pusch_snr': ue.pusch_snr,
                        'pucch_snr': ue.pucch_snr,
                        'dl_mcs1': ue.dl_mcs1,
                        'ul_mcs1': ue.ul_mcs1,
                        'dl_bler': ue.dl_bler,
                        'ul_bler': ue.ul_bler,
                        'bsr': ue.bsr,
                        'phr': ue.phr,
                        'wb_cqi': ue.wb_cqi,
                        'frame': ue.frame,
                        'slot': ue.slot,
                        'node_idx': self.internal_node_id,
                        'last_seen': t_now,
                    }

                    is_new = rnti not in MACCallback.ue_mac_map
                    MACCallback.ue_mac_map[rnti] = stats

                    # Only log NEW UEs
                    if is_new:
                        print(f"[MAC] NEW UE: RNTI={rnti:#06x} "
                              f"DL_TBS={ue.dl_curr_tbs} UL_TBS={ue.ul_curr_tbs} "
                              f"PUSCH_SNR={ue.pusch_snr:.1f} "
                              f"DL_MCS={ue.dl_mcs1} UL_MCS={ue.ul_mcs1} "
                              f"(total UEs: {len(MACCallback.ue_mac_map)})",
                              flush=True)

                except Exception as e:
                    print(f"[MAC ERROR] node={self.internal_node_id} ue[{i}]: {e}",
                          flush=True)
        else:
            MACCallback._empty_count += 1


class PDCPCallback(xapp_sdk.pdcp_cb):
    ue_pdcp_map = {}
    _indication_count = 0
    _empty_count = 0
    _logged_bearers = set()  # Track (rnti, rbid) we've logged

    def __init__(self, storage, node_id):
        xapp_sdk.pdcp_cb.__init__(self)
        self.internal_storage = storage
        self.internal_node_id = node_id
        self._instance_ind_count = 0

    def handle(self, ind):
        PDCPCallback._indication_count += 1
        self._instance_ind_count += 1

        if len(ind.rb_stats) > 0:
            t_now = time.time_ns() / 1000.0
            self.internal_storage.metrics[self.internal_node_id]['pdcp'].append(ind.rb_stats)

            for i in range(len(ind.rb_stats)):
                try:
                    rb = ind.rb_stats[i]
                    rnti = rb.rnti
                    rbid = rb.rbid

                    bearer = {
                        'rnti': rnti,
                        'rbid': rbid,
                        'mode': rb.mode,
                        'txpdu_pkts': rb.txpdu_pkts,
                        'txpdu_bytes': rb.txpdu_bytes,
                        'rxpdu_pkts': rb.rxpdu_pkts,
                        'rxpdu_bytes': rb.rxpdu_bytes,
                        'txsdu_pkts': rb.txsdu_pkts,
                        'txsdu_bytes': rb.txsdu_bytes,
                        'rxsdu_pkts': rb.rxsdu_pkts,
                        'rxsdu_bytes': rb.rxsdu_bytes,
                        'node_idx': self.internal_node_id,
                        'last_seen': t_now,
                    }

                    bearer_key = (rnti, rbid)
                    is_new_ue = rnti not in PDCPCallback.ue_pdcp_map
                    is_new_bearer = bearer_key not in PDCPCallback._logged_bearers

                    if rnti not in PDCPCallback.ue_pdcp_map:
                        PDCPCallback.ue_pdcp_map[rnti] = []

                    # Only log NEW bearers
                    if is_new_bearer:
                        PDCPCallback._logged_bearers.add(bearer_key)
                        print(f"[PDCP] NEW bearer: RNTI={rnti:#06x} "
                              f"RBID={rbid} mode={rb.mode} "
                              f"TX={rb.txpdu_bytes}B RX={rb.rxpdu_bytes}B "
                              f"(total UEs: {len(PDCPCallback.ue_pdcp_map)})",
                              flush=True)

                    # Update or add bearer
                    found = False
                    for existing in PDCPCallback.ue_pdcp_map[rnti]:
                        if existing['rbid'] == rbid:
                            existing.update(bearer)
                            found = True
                            break
                    if not found:
                        PDCPCallback.ue_pdcp_map[rnti].append(bearer)

                except Exception as e:
                    print(f"[PDCP ERROR] node={self.internal_node_id} rb[{i}]: {e}",
                          flush=True)
        else:
            PDCPCallback._empty_count += 1


class GTPCallback(xapp_sdk.gtp_cb):
    """
    GTP SM Callback - Receives N3 tunnel information from E2 interface.
    
    NOTE: This provides N3 TEIDs (CU ↔ UPF), NOT F1-U TEIDs (CU ↔ DU).
    For F1-U TEIDs, use teid_parser.py with CU log files.
    """
    internal_storage = None
    internal_node_id = None
    
    ue_gtp_map = {}
    _indication_count = 0
    _empty_count = 0
    _logged_tunnels: set = set()  # Track (rnti, qfi, teidgnb, teidupf)

    def __init__(self, storage, node_id):
        xapp_sdk.gtp_cb.__init__(self)
        self.internal_storage = storage
        self.internal_node_id = node_id
        self._instance_ind_count = 0

    def handle(self, ind):
        GTPCallback._indication_count += 1
        self._instance_ind_count += 1

        try:
            stats_len = len(ind.gtp_stats)
        except Exception:
            return

        if stats_len == 0:
            GTPCallback._empty_count += 1
            return

        t_now = time.time_ns() / 1000.0

        # Store raw stats (silently)
        self.internal_storage.metrics[self.internal_node_id]['gtp'].append(ind.gtp_stats)

        for i in range(stats_len):
            try:
                stat = ind.gtp_stats[i]
                rnti = stat.rnti
                teidgnb = stat.teidgnb
                teidupf = stat.teidupf
                qfi = stat.qfi
            except Exception:
                continue

            # Skip entries with no valid TEID
            if teidgnb == 0 and teidupf == 0:
                continue

            # Create unique key for deduplication
            tunnel_key = (rnti, qfi, teidgnb, teidupf, self.internal_node_id)
            
            is_new_ue = rnti not in GTPCallback.ue_gtp_map
            is_new_tunnel = tunnel_key not in GTPCallback._logged_tunnels

            if rnti not in GTPCallback.ue_gtp_map:
                GTPCallback.ue_gtp_map[rnti] = []

            tunnel_entry = {
                'teidgnb': teidgnb,
                'teidupf': teidupf,
                'qfi': qfi,
                'node_idx': self.internal_node_id,
                'last_seen': t_now
            }

            # Update or add tunnel
            found = False
            for existing in GTPCallback.ue_gtp_map[rnti]:
                if existing['qfi'] == qfi and existing['node_idx'] == self.internal_node_id:
                    # Check if TEID changed
                    if existing['teidgnb'] != teidgnb or existing['teidupf'] != teidupf:
                        is_new_tunnel = True
                    existing.update(tunnel_entry)
                    found = True
                    break
            if not found:
                GTPCallback.ue_gtp_map[rnti].append(tunnel_entry)

            # *** ONLY LOG NEW OR CHANGED TUNNELS ***
            if is_new_tunnel:
                GTPCallback._logged_tunnels.add(tunnel_key)
                # Don't log zero TEIDs
                if teidgnb != 0 or teidupf != 0:
                    print(f"[GTP-N3] {'NEW UE' if is_new_ue else 'Tunnel'}: "
                          f"RNTI={rnti:#06x} QFI={qfi} "
                          f"TEID_gNB={teidgnb:#010x} TEID_UPF={teidupf:#010x}",
                          flush=True)


##########################
#### Handler Cleanup #####
##########################

def handler_cleanup(node_handler, hndlr_key):
    if hndlr_key == 'nid':
        return

    Handler_TYPES = {
        'mac_hndlr': xapp_sdk.rm_report_mac_sm,
        'rlc_hndlr': xapp_sdk.rm_report_rlc_sm,
        'pdcp_hndlr': xapp_sdk.rm_report_pdcp_sm,
        'gtp_hndlr': xapp_sdk.rm_report_gtp_sm,
    }
    handler_func = Handler_TYPES.get(hndlr_key)
    if handler_func:
        return handler_func(node_handler)
    else:
        print("Unknown handler key:", hndlr_key)


#######################
#### Helper Functs ####
#######################

def classify_e2node(node, debug=True):
    """Classify E2 node as DU, CU-UP, CU-CP based on type."""
    NGRAN_NODE_TYPES = {
        0: "ngran_eNB",
        1: "ngran_ng_eNB",
        2: "ngran_gNB",
        3: "ngran_eNB_CU",
        4: "ngran_ng_eNB_CU",
        5: "ngran_gNB_CU",
        6: "ngran_eNB_DU",
        7: "ngran_gNB_DU",
        8: "ngran_eNB_MBMS_STA",
        9: "ngran_gNB_CUCP",
        10: "ngran_gNB_CUUP"
    }

    type_obj = getattr(node, "type", None)
    if type_obj is None:
        return "Unknown"
    
    type_obj.disown()
    raw_ptr = int(type_obj)
    ctype_int_ptr = ctypes.POINTER(ctypes.c_int)
    enum_val = ctypes.cast(raw_ptr, ctype_int_ptr).contents.value
    return NGRAN_NODE_TYPES.get(enum_val, "Unknown")


def safe_get(obj, name):
    try:
        obj.thisown = False
        return getattr(obj, name)
    except Exception as e:
        return "<err: %s>" % e
