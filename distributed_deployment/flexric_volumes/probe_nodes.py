#!/usr/bin/env python3
# Prints one line:  TOTAL CUCP CUUP DU
# Exit 0 always; parse stdout in bash.
import sys, time, ctypes
try:
    import xapp_sdk as ric
except Exception as e:
    print("0 0 0 0"); sys.exit(0)

def cu_du_id_of(nid):
    # cu_du_id is a pointer; deref if set (mirrors xapp_slice_check.py)
    try:
        return ctypes.cast(int(nid.cu_du_id), ctypes.POINTER(ctypes.c_uint64)).contents.value if nid.cu_du_id else None
    except Exception:
        return None

def main():
    ric.init()
    time.sleep(1)
    nodes = ric.conn_e2_nodes()
    total = len(nodes)
    cucp = cuup = du = 0
    for n in nodes:
        t = n.id.type
        # FlexRIC e2ap node types: CUCP / CUUP / DU (enum values from the SDK)
        name = str(t)
        if "CUCP" in name or t == ric.ngran_gNB_CUCP: cucp += 1
        elif "CUUP" in name or t == ric.ngran_gNB_CUUP: cuup += 1
        elif "DU"  in name or t == ric.ngran_gNB_DU:   du   += 1
    print(f"{total} {cucp} {cuup} {du}")
    try: ric.try_stop()
    except Exception: pass

if __name__ == "__main__":
    try: main()
    except Exception:
        print("0 0 0 0")