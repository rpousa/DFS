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

#  MACCallback class is defined and derived from C++ class mac_cb
class MACCallback(xapp_sdk.mac_cb):
    internal_storage = None
    internal_node_id = None
    # Define Python class 'constructor'
    def __init__(self, storage, node_id):
        # Call C++ base class constructor
        xapp_sdk.mac_cb.__init__(self)
        self.internal_storage = storage
        self.internal_node_id = node_id

    # Override C++ method: virtual void handle(swig_mac_ind_msg_t a) = 0;
    def handle(self, ind):
        #print("MAC handle called")
        # dir(ind) = ['__class__', '__delattr__', '__dict__', '__dir__', '__doc__', '__eq__',
        #            '__format__', '__ge__', '__getattribute__', '__gt__', '__hash__', '__init__',
        #            '__init_subclass__', '__le__', '__lt__', '__module__', '__ne__', '__new__', '__reduce__',
        #            '__reduce_ex__', '__repr__', '__setattr__', '__sizeof__', '__str__', '__subclasshook__',
        #            '__swig_destroy__', '__weakref__', 'this', 'thisown', 'tstamp', 'ue_stats']
        #print(dir(ind.ue_stats))
        if len(ind.ue_stats) > 0:
            t_now = time.time_ns() / 1000.0
            t_mac = ind.tstamp / 1.0
            t_diff = t_now - t_mac
            self.internal_storage.metrics[self.internal_node_id]['mac'].append(ind.ue_stats)
            # print('MAC Indication tstamp = ' + str(t_mac) + ' latency = ' + str(t_diff) + ' μs')
            # print('MAC rnti = ' + str(ind.ue_stats[0].rnti))



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



# PDCPCallback class is defined and derived from C++ class pdcp_cb
class PDCPCallback(xapp_sdk.pdcp_cb):
    internal_storage = None
    internal_node_id = None
    
    def __init__(self, storage, node_id):
        xapp_sdk.pdcp_cb.__init__(self)
        self.internal_storage = storage
        self.internal_node_id = node_id

   
    def handle(self, ind):
        #print("PDCP handle called")
        #dir(ind) = ['__class__', '__delattr__', '__dict__', '__dir__', '__doc__', '__eq__', 
        #           '__format__', '__ge__', '__getattribute__', '__gt__', '__hash__', '__init__', 
        #           '__init_subclass__', '__le__', '__lt__', '__module__', '__ne__', '__new__', '__reduce__', 
        #           '__reduce_ex__', '__repr__', '__setattr__', '__sizeof__', '__str__', '__subclasshook__',
        #            '__swig_destroy__', '__weakref__', 'rb_stats', 'this', 'thisown', 'tstamp']
        #print(dir(ind.rb_stats))

        if len(ind.rb_stats) > 0:
            t_now = time.time_ns() / 1000.0
            t_pdcp = ind.tstamp / 1.0
            t_diff = t_now - t_pdcp
            #print(ind)
            self.internal_storage.metrics[self.internal_node_id]['pdcp'].append(ind.rb_stats)
            #print('PDCP Indication tstamp = ' + str(ind.tstamp) + ' latency = ' + str(t_diff) + ' μs')
            #print('PDCP rnti = '+ str(ind.rb_stats[0].rnti))


# GTPCallback class is defined and derived from C++ class gtp_cb
class GTPCallback(xapp_sdk.gtp_cb):
    internal_storage = None
    internal_node_id = None
    def __init__(self, storage, node_id):
        # Inherit C++ gtp_cb class
        xapp_sdk.gtp_cb.__init__(self)
        self.internal_storage = storage
        self.internal_node_id = node_id

    # Create an override C++ method 
    def handle(self, ind):
        print("GTPCallback handle called")
        print(dir(ind))
        if len(ind.gtp_stats) > 0:
            t_now = time.time_ns() / 1000.0
            t_gtp = ind.tstamp / 1.0
            t_diff = t_now - t_gtp
            self.internal_storage.metrics[self.internal_node_id]['gtp'].append(ind.gtp_stats)
            #print('GTP Indication tstamp = ' + str(ind.tstamp) + ' diff = ' + str(t_diff) + ' μs')

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
