import inspect
import time
import types
import ctypes
import xapp_sdk
from dataclasses import dataclass, field
from typing import Dict, List, Any

@dataclass
class Xapp_Metric_Storage:
    # def __init__(self):
    #     self.nodes = {} # Node:idx : ngran_node_type
    #     self.metrics = {} # Node_idx : { metric_name : [values] }
    
    # node_idx : node_type
    nodes: Dict[int, Any] = field(default_factory=dict)
    # node_idx : { metric_name : [values] }
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


#  RLCCallback class is defined and derived from C++ class mac_cb
class RLCCallback(xapp_sdk.rlc_cb):
    internal_storage = None
    internal_node_id = None
    # Define Python class 'constructor'
    def __init__(self, storage, node_id):
        # Call C++ base class constructor
        xapp_sdk.rlc_cb.__init__(self)
        self.internal_storage = storage
        self.internal_node_id = node_id

    # Override C++ method: virtual void handle(swig_rlc_ind_msg_t a) = 0;
    def handle(self, ind):
    #    print("RLC handle called")
    # dir(ind) = ['__class__', '__delattr__', '__dict__', '__dir__', '__doc__', '__eq__',
    #            '__format__', '__ge__', '__getattribute__', '__gt__', '__hash__', '__init__', 
    #            '__init_subclass__', '__le__', '__lt__', '__module__', '__ne__', '__new__', '__reduce__',
    #            '__reduce_ex__', '__repr__', '__setattr__', '__sizeof__', '__str__', '__subclasshook__',
    #            '__swig_destroy__', '__weakref__', 'rb_stats', 'this', 'thisown', 'tstamp']
    #    print(dir(ind.rb_stats))
        # Print swig_rlc_ind_msg_t
        if len(ind.rb_stats) > 0:
            t_now = time.time_ns() / 1000.0
            t_rlc = ind.tstamp / 1.0
            t_diff = t_now - t_rlc
            self.internal_storage.metrics[self.internal_node_id]['rlc'].append(ind.rb_stats)
            #print('RLC Indication tstamp = ' + str(ind.tstamp) + ' latency = ' + str(t_diff) + ' μs')
            #print('RLC rnti = '+ str(ind.rb_stats[0].rnti))



class MACCallback(xapp_sdk.mac_cb):
    # Class-level UE tracking
    ue_mac_map = {}        # rnti -> latest mac stats dict
    _indication_count = 0
    _empty_count = 0

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
            t_mac = ind.tstamp / 1.0
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

            # Log first few + periodic
            if self._instance_ind_count <= 3 or self._instance_ind_count % 500 == 0:
                print(f"[MAC DEBUG] node={self.internal_node_id} "
                      f"ind#{self._instance_ind_count} "
                      f"ue_count={len(ind.ue_stats)} "
                      f"total_ues_seen={len(MACCallback.ue_mac_map)}",
                      flush=True)
        else:
            MACCallback._empty_count += 1


class PDCPCallback(xapp_sdk.pdcp_cb):
    # Class-level UE tracking
    ue_pdcp_map = {}       # rnti -> list of bearer stats
    _indication_count = 0
    _empty_count = 0

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

                    bearer = {
                        'rnti': rnti,
                        'rbid': rb.rbid,
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

                    if rnti not in PDCPCallback.ue_pdcp_map:
                        PDCPCallback.ue_pdcp_map[rnti] = []
                        print(f"[PDCP] NEW UE: RNTI={rnti:#06x} "
                              f"RBID={rb.rbid} mode={rb.mode} "
                              f"TX={rb.txpdu_bytes}B RX={rb.rxpdu_bytes}B "
                              f"(total UEs: {len(PDCPCallback.ue_pdcp_map)})",
                              flush=True)

                    # Update or add bearer
                    found = False
                    for existing in PDCPCallback.ue_pdcp_map[rnti]:
                        if existing['rbid'] == rb.rbid:
                            existing.update(bearer)
                            found = True
                            break
                    if not found:
                        PDCPCallback.ue_pdcp_map[rnti].append(bearer)

                except Exception as e:
                    print(f"[PDCP ERROR] node={self.internal_node_id} rb[{i}]: {e}",
                          flush=True)

            if self._instance_ind_count <= 3 or self._instance_ind_count % 500 == 0:
                print(f"[PDCP DEBUG] node={self.internal_node_id} "
                      f"ind#{self._instance_ind_count} "
                      f"rb_count={len(ind.rb_stats)} "
                      f"total_ues_seen={len(PDCPCallback.ue_pdcp_map)}",
                      flush=True)
        else:
            PDCPCallback._empty_count += 1


# GTPCallback class is defined and derived from C++ class gtp_cb
class GTPCallback(xapp_sdk.gtp_cb):
    internal_storage = None
    internal_node_id = None
    
    ue_gtp_map = {}
    _indication_count = 0
    _empty_count = 0

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
        except Exception as e:
            print(f"[GTP ERROR] node={self.internal_node_id} "
                  f"Cannot read gtp_stats: {e}")
            return

        # Log EVERY indication for first 5, then every 100th
        if self._instance_ind_count <= 5 or self._instance_ind_count % 100 == 0:
            print(f"[GTP DEBUG] node={self.internal_node_id} "
                  f"ind#{self._instance_ind_count} "
                  f"gtp_stats_len={stats_len} "
                  f"tstamp={ind.tstamp} "
                  f"global_ind={GTPCallback._indication_count} "
                  f"empty_count={GTPCallback._empty_count} "
                  f"ue_map_size={len(GTPCallback.ue_gtp_map)}")

        if stats_len == 0:
            GTPCallback._empty_count += 1
            # First time only: introspect the indication object
            if GTPCallback._empty_count == 1:
                print(f"[GTP DEBUG] FIRST EMPTY indication object:")
                print(f"  type(ind) = {type(ind).__name__}")
                print(f"  dir(ind) = {[x for x in dir(ind) if not x.startswith('__')]}")
                print(f"  type(gtp_stats) = {type(ind.gtp_stats).__name__}")
                try:
                    print(f"  dir(gtp_stats) = {[x for x in dir(ind.gtp_stats) if not x.startswith('__')]}")
                except:
                    pass
            return

        t_now = time.time_ns() / 1000.0
        t_gtp = ind.tstamp / 1.0
        t_diff = t_now - t_gtp

        # Store raw stats
        self.internal_storage.metrics[self.internal_node_id]['gtp'].append(ind.gtp_stats)

        # Extract per-UE TEID information
        for i in range(stats_len):
            try:
                stat = ind.gtp_stats[i]
                rnti = stat.rnti
                teidgnb = stat.teidgnb
                teidupf = stat.teidupf
                qfi = stat.qfi
            except Exception as e:
                print(f"[GTP ERROR] node={self.internal_node_id} "
                      f"Cannot read gtp_stats[{i}]: {e}")
                continue

            if rnti not in GTPCallback.ue_gtp_map:
                GTPCallback.ue_gtp_map[rnti] = []
                print(f"[GTP] NEW UE discovered: RNTI={rnti:#06x} "
                      f"(total UEs: {len(GTPCallback.ue_gtp_map)})")

            tunnel_entry = {
                'teidgnb': teidgnb,
                'teidupf': teidupf,
                'qfi': qfi,
                'node_idx': self.internal_node_id,
                'last_seen': t_now
            }

            found = False
            for existing in GTPCallback.ue_gtp_map[rnti]:
                if existing['qfi'] == qfi and existing['node_idx'] == self.internal_node_id:
                    existing.update(tunnel_entry)
                    found = True
                    break
            if not found:
                GTPCallback.ue_gtp_map[rnti].append(tunnel_entry)

            print(f"[GTP] RNTI={rnti:#06x} QFI={qfi} "
                  f"TEID_gNB={teidgnb:#010x} TEID_UPF={teidupf:#010x} "
                  f"node={self.internal_node_id}")

##########################
#### Handler Handler #####
##########################

def handler_cleanup(node_handler, hndlr_key):
    if hndlr_key == 'nid': return

    Handler_TYPES = {
        'mac_hndlr': xapp_sdk.rm_report_mac_sm,
        'rlc_hndlr': xapp_sdk.rm_report_rlc_sm,
        'pdcp_hndlr': xapp_sdk.rm_report_pdcp_sm,
        'gtp_hndlr': xapp_sdk.rm_report_gtp_sm, 
    }
    handler_func =  Handler_TYPES.get(hndlr_key)
    if handler_func:
        return handler_func(node_handler)
    else:
        print("Unknown handler key:", hndlr_key)        

#######################
#### Helper Functs ####
#######################
def print_swig_members(obj, max_items=1000, show_values=True, show_methods=True):
    try:
        print("obj repr:", safe_repr(obj))
    except Exception:
        print("obj repr: <failed>")
    try:
        print("type:", type(obj).__name__)
    except Exception:
        pass
    try:
        # common SWIG internals
        print("this:", safe_get(obj, "this"))
        print("thisown:", safe_get(obj, "thisown"))
    except Exception:
        pass

    # Collect names (dir may raise on some proxies)
    try:
        names = [n for n in dir(obj) if not n.startswith("__")]
    except Exception as e:
        print("dir(obj) failed:", e)
        names = []

    print(f"Total members (non-dunder): {len(names)}")
    if not names:
        return

    # Show attributes (non-callable) and methods (callable) separately
    attrs = []
    methods = []
    for n in names[:max_items]:
        val = safe_get(obj, n)
        if callable(val) or isinstance(val, (types.MethodType, types.FunctionType)):
            methods.append((n, val))
        else:
            attrs.append((n, val))

    print("\n--- ATTRIBUTES ---")
    for name, val in attrs:
        try:
            if show_values:
                # show small preview for sequences
                if hasattr(val, "__len__") and not isinstance(val, (str, bytes)):
                    try:
                        ln = len(val)
                    except Exception:
                        try:
                            ln = val.size()
                        except Exception:
                            ln = None
                    preview = None
                    if ln is not None and ln > 0:
                        try:
                            take = min(3, ln)
                            preview = [safe_repr(val[i]) for i in range(take)]
                        except Exception:
                            preview = safe_repr(val)
                    print(f"{name} -> type:{type(val).__name__} len={ln} preview={preview}")
                else:
                    print(f"{name} -> type:{type(val).__name__} value={safe_repr(val)}")
            else:
                print(name)
        except Exception as e:
            print(f"{name} -> <error printing: {e}>")

    if not show_methods: return
    print("\n--- METHODS / CALLABLES ---")
    for name, val in methods:
        try:
            sig = None
            try:
                sig = inspect.signature(val)
            except Exception:
                try:
                    # some SWIG methods present as descriptors; try __call__ signature
                    if hasattr(val, "__call__"):
                        sig = inspect.signature(val.__call__)
                except Exception:
                    sig = None
            doc = None
            try:
                doc = val.__doc__[:200] if val.__doc__ else None
            except Exception:
                doc = None
            print(f"{name}() -> type:{type(val).__name__} signature:{sig} doc:{doc}")
        except Exception as e:
            print(f"{name} -> <error inspecting callable: {e}>")
    return
    # print("\n--- help(obj) preview ---")
    # try:
    #     import io, sys
    #     buf = io.StringIO()
    #     try:
    #         help(obj)
    #     except Exception as e:
    #         print(f"help() raised: {e}")
    # except Exception:
    #     print("help() not available for this object")
    

def classify_e2node(node,debug=True):
    """
    Classify E2 node as DU, CU-UP, CU-CP based on type and attributes
    Returns: str ('DU', 'CU-UP', 'CU-CP', 'UNKNOWN')
    """

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

    type_obj= safe_get(node, "type")
    type_obj.disown() 

    #print(node.type.__repr__())
    #print(dir(node.type))
    #print(node.type.__doc__)
    
    raw_ptr = int(type_obj)  # SWIG pointer → raw address
    ctype_int_ptr = ctypes.POINTER(ctypes.c_int)
    enum_val = ctypes.cast(raw_ptr, ctype_int_ptr).contents.value
    return NGRAN_NODE_TYPES.get(enum_val, "Unknown")
    

def is_swig(obj):
    try:
        if obj is None:
            return False

        # Fast path: SWIG usually exposes "this" and "thisown"
        if hasattr(obj, "this") and hasattr(obj, "thisown"):
            return True

        # SWIG exposes a few internal hooks on some builds
        if hasattr(obj, "__swig_getmethods__") or hasattr(obj, "_swig_repr"):
            return True

        # Type-name heuristic (e.g. "SwigPyObject" or generated wrapper classes)
        tname = type(obj).__name__
        if "swig" in tname.lower():
            return True
        # Repr heuristic: "<Swig Object of type '...'>"
        try:
            r = repr(obj)
            if r.startswith("<Swig Object") or "Swig Object of type" in r:
                return True
        except Exception:
            pass
    except Exception:
        return False
    return False

def safe_get(obj, name):
    try:
        obj.thisown = False
        return getattr(obj, name)
    except Exception as e:
        return "<err: %s>" % e
    
def safe_repr(v, maxlen=200):
        try:
            r = repr(v)
            return r if len(r) <= maxlen else r[:maxlen] + "..."
        except Exception:
            return "<unreprable>"
        
def supports_gtp(ran_func):
    try:
        return "gtp" in ran_func.defn.lower() or "gtp" in str(ran_func.id).lower()
    except Exception:
        return False
    
def on_gtp_ind(node_id, interval, msg):
    # msg is a gtp_ind_msg_t; read fields via properties (e.g. msg.ngut, msg.len, msg.tstamp)
    print("GTP indication from", node_id)
    print("ngut:", getattr(msg, "ngut", None), "len:", getattr(msg, "len", None))
