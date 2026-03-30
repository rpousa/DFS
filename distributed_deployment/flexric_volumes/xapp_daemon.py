import os
import sys
import time
import signal
import threading
import traceback
import ctypes
import xapp_sdk
import xapp_functs
from topology import (
    switch, flow, host,
    get_devices, get_flows, get_hosts,
    print_device_info, set_udp_flow_queue,
)

# ============================================================
# Configuration
# ============================================================
ONOS_URL = "http://192.168.0.193:8181/onos/v1"
INTERFACE = "eth0"
E2_POLL_INTERVAL = 10        # seconds between checking for new E2 nodes
TEID_POLL_INTERVAL = 5       # seconds between checking for new TEIDs to install
ONOS_REFRESH_INTERVAL = 60   # seconds between ONOS topology refreshes
RIC_CONNECT_RETRY = 5        # seconds between RIC connection retries
MAX_RIC_RETRIES = 60         # max retries before giving up

# Node types we care about for subscription
# ngran_gNB_CU (5) = unified CU that handles PDCP + GTP internally
TYPES_ACCEPTED = [
    "ngran_gNB_CUUP",   # type 10 - separate CU-UP (old architecture)
    "ngran_gNB_DU",      # type 7  - DU
    "ngran_gNB_CUCP",    # type 9  - separate CU-CP (old architecture)
    "ngran_gNB_CU",      # type 5  - unified CU (NEW architecture)
]

# ============================================================
# Global State
# ============================================================
shutdown_event = threading.Event()
devices = {}                    # ONOS switch topology
node_handlers = {}              # node_idx -> {handler_key: handler}
subscribed_nodes = set()        # set of node keys already subscribed
installed_flows = set()         # set of (dev_id, teid, qfi) already installed
storage = xapp_functs.Xapp_Metric_Storage()
state_lock = threading.Lock()   # protects shared state

# Monotonic subscription index to avoid node_idx collisions across polls
_next_sub_idx = 0
_sub_idx_lock = threading.Lock()

def _alloc_sub_idx():
    global _next_sub_idx
    with _sub_idx_lock:
        idx = _next_sub_idx
        _next_sub_idx += 1
        return idx

def log(level, msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)

# ============================================================
# Signal Handling for Graceful Shutdown
# ============================================================
def signal_handler(sig, frame):
    log("INFO", f"Received signal {sig}, initiating shutdown...")
    shutdown_event.set()

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

# ============================================================
# Phase 1: ONOS Topology Discovery
# ============================================================
def discover_onos_topology():
    """Query ONOS REST API for switches, flows, and hosts."""
    global devices
    log("INFO", "Discovering ONOS topology...")

    try:
        new_devices = {}
        devices_from_onos = get_devices(ONOS_URL, INTERFACE)

        for sw in devices_from_onos:
            switch_obj = switch(
                sw['id'], sw['type'], sw['available'], sw['role'],
                sw['mfr'], sw['hw'], sw['sw'], sw['serial'],
                sw['driver'], sw['chassisId'], sw['lastUpdate'],
                sw['humanReadableLastUpdate'],
                sw['annotations']['channelId'],
                sw['annotations']['managementAddress'],
                sw['annotations']['protocol'],
            )
            new_devices[switch_obj.id] = switch_obj

            r_flows = get_flows(ONOS_URL, INTERFACE, sw)
            for fl in r_flows['flows']:
                criteria = fl["selector"]["criteria"]
                if len(criteria) > 1 and len(criteria) > 2 and criteria[2].get("type") == "IP_PROTO":
                    flow_obj = flow(
                        fl["groupId"], fl["state"], fl["liveType"], fl["packets"],
                        fl["id"], fl["priority"], fl["timeout"], fl["isPermanent"],
                        fl["deviceId"],
                        ip_dst=criteria[4].get("ip") if len(criteria) > 4 else None,
                        ip_src=criteria[3].get("ip") if len(criteria) > 3 else None,
                        type_of_protocol=criteria[2].get("protocol"),
                    )
                else:
                    flow_obj = flow(
                        fl["groupId"], fl["state"], fl["liveType"], fl["packets"],
                        fl["id"], fl["priority"], fl["timeout"], fl["isPermanent"],
                        fl["deviceId"], None, None, "Ethernet",
                    )
                switch_obj.flows.append(flow_obj)

        hosts_from_onos = get_hosts(ONOS_URL, INTERFACE)
        for h in hosts_from_onos['hosts']:
            host_obj = host(
                h['id'], h['mac'], h['vlan'], h['innerVlan'],
                h['outerTpid'], h['configured'], h['suspended'],
                h['ipAddresses'], h['locations'],
            )
            elem_id = host_obj.locations[0]['elementId']
            if elem_id in new_devices:
                new_devices[elem_id].hosts_connected.append(host_obj)

        with state_lock:
            devices = new_devices

        log("INFO", f"ONOS topology: {len(devices)} switch(es) discovered")
        for dev_id, dev in devices.items():
            log("INFO", f"  {dev_id}: {dev.mfr} {dev.hw} FW:{dev.sw} "
                        f"IP:{dev.managementAddress} Flows:{len(dev.flows)}")
        return True

    except Exception as e:
        log("ERROR", f"ONOS topology discovery failed: {e}")
        return False

# ============================================================
# Phase 2: E2 Node Discovery + Subscription
# ============================================================

def get_node_key(nid):
    """
    Create a stable, hashable key from a node ID for deduplication.
    Uses the ctypes trick to read the enum value from the SWIG pointer,
    plus PLMN MCC/MNC and the raw nb_id pointer value.
    """
    try:
        # --- Extract node type enum via ctypes ---
        type_obj = getattr(nid, "type", None)
        if type_obj is not None:
            # disown so Python doesn't free the C memory
            type_obj.disown()
            raw_ptr = int(type_obj)
            ctype_int_ptr = ctypes.POINTER(ctypes.c_int)
            enum_val = ctypes.cast(raw_ptr, ctype_int_ptr).contents.value
        else:
            enum_val = -1

        # --- Extract PLMN ---
        mcc = int(nid.plmn.mcc)
        mnc = int(nid.plmn.mnc)

        # --- Extract nb_id as raw pointer value (stable across polls) ---
        nb_id_obj = getattr(nid, "nb_id", None)
        if nb_id_obj is not None:
            try:
                nb_id_obj.disown()
                nb_id_val = int(nb_id_obj)
            except Exception:
                nb_id_val = 0
        else:
            nb_id_val = 0

        # --- Extract cu_du_id if present ---
        cu_du_id_obj = getattr(nid, "cu_du_id", None)
        cu_du_val = 0
        if cu_du_id_obj is not None:
            try:
                cu_du_id_obj.disown()
                cu_du_val = int(cu_du_id_obj)
            except Exception:
                cu_du_val = 0

        key = (mcc, mnc, nb_id_val, enum_val, cu_du_val)
        return key

    except Exception as e:
        log("WARN", f"get_node_key failed: {e}")
        # Fallback: use enum_val only (still better than id(nid))
        try:
            return (0, 0, 0, enum_val, 0)
        except Exception:
            return (0, 0, 0, -999, 0)


def subscribe_node(sub_idx, nid, node_type):
    """Subscribe to the appropriate SMs for a single E2 node."""
    global node_handlers

    with state_lock:
        node_handlers[sub_idx] = {'nid': nid}

    try:
        if node_type == "ngran_gNB_DU":
            log("INFO", f"  Node [sub={sub_idx}] DU: subscribing MAC + RLC")
            storage.add_node(sub_idx, node_type, ['mac', 'rlc'])
            mac_cb = xapp_functs.MACCallback(storage, sub_idx)
            rlc_cb = xapp_functs.RLCCallback(storage, sub_idx)
            with state_lock:
                node_handlers[sub_idx]['mac_hndlr'] = xapp_sdk.report_mac_sm(
                    nid, xapp_sdk.Interval_ms_10, mac_cb)
                node_handlers[sub_idx]['rlc_hndlr'] = xapp_sdk.report_rlc_sm(
                    nid, xapp_sdk.Interval_ms_10, rlc_cb)

        elif node_type == "ngran_gNB_CUUP":
            log("INFO", f"  Node [sub={sub_idx}] CU-UP: subscribing PDCP + GTP (TEID source)")
            storage.add_node(sub_idx, node_type, ['pdcp', 'gtp'])
            pdcp_cb = xapp_functs.PDCPCallback(storage, sub_idx)
            gtp_cb = xapp_functs.GTPCallback(storage, sub_idx)
            with state_lock:
                node_handlers[sub_idx]['pdcp_hndlr'] = xapp_sdk.report_pdcp_sm(
                    nid, xapp_sdk.Interval_ms_10, pdcp_cb)
                node_handlers[sub_idx]['gtp_hndlr'] = xapp_sdk.report_gtp_sm(
                    nid, xapp_sdk.Interval_ms_10, gtp_cb)

        elif node_type == "ngran_gNB_CU":
            # ============================================================
            # UNIFIED CU: handles both control and user plane
            # Subscribe to PDCP + GTP (same as CU-UP) to get TEIDs
            # ============================================================
            log("INFO", f"  Node [sub={sub_idx}] Unified CU: subscribing PDCP + GTP (TEID source)")
            storage.add_node(sub_idx, node_type, ['pdcp', 'gtp'])
            pdcp_cb = xapp_functs.PDCPCallback(storage, sub_idx)
            gtp_cb = xapp_functs.GTPCallback(storage, sub_idx)
            with state_lock:
                node_handlers[sub_idx]['pdcp_hndlr'] = xapp_sdk.report_pdcp_sm(
                    nid, xapp_sdk.Interval_ms_10, pdcp_cb)
                node_handlers[sub_idx]['gtp_hndlr'] = xapp_sdk.report_gtp_sm(
                    nid, xapp_sdk.Interval_ms_10, gtp_cb)

        elif node_type == "ngran_gNB_CUCP":
            log("INFO", f"  Node [sub={sub_idx}] CU-CP: no user-plane subscriptions")
            storage.add_node(sub_idx, node_type, [])

        else:
            log("WARN", f"  Node [sub={sub_idx}] Unknown type '{node_type}': no subscriptions")
            storage.add_node(sub_idx, node_type, [])

        return True

    except Exception as e:
        log("ERROR", f"  Failed to subscribe node [sub={sub_idx}]: {e}")
        traceback.print_exc()
        return False


def poll_e2_nodes():
    """Check for new E2 nodes and subscribe to them."""
    global subscribed_nodes

    try:
        conn = xapp_sdk.conn_e2_nodes()
        if len(conn) == 0:
            return 0

        new_count = 0
        for raw_idx, con in enumerate(conn):
            nid = con.id
            node_key = get_node_key(nid)

            if node_key in subscribed_nodes:
                continue

            node_type = xapp_functs.classify_e2node(nid)
            log("INFO", f"New E2 Node [raw={raw_idx}]: {node_type} key={node_key}")

            if node_type in TYPES_ACCEPTED:
                sub_idx = _alloc_sub_idx()
                if subscribe_node(sub_idx, nid, node_type):
                    subscribed_nodes.add(node_key)
                    new_count += 1
                    log("INFO", f"  -> Subscribed as sub_idx={sub_idx}")
            else:
                log("WARN", f"  Skipping unsupported node type: {node_type}")
                subscribed_nodes.add(node_key)  # mark as seen so we don't retry

        return new_count

    except Exception as e:
        log("ERROR", f"E2 node polling failed: {e}")
        traceback.print_exc()
        return 0

# ============================================================
# Phase 3: Reactive TEID Flow Installation
# ============================================================
def check_and_install_teid_flows():
    """Check GTPCallback.ue_gtp_map for new TEIDs and install flows."""
    global installed_flows

    ue_map = xapp_functs.GTPCallback.ue_gtp_map
    if not ue_map:
        return 0

    with state_lock:
        current_devices = dict(devices)

    if not current_devices:
        return 0

    new_flows = 0
    for rnti, tunnels in ue_map.items():
        for tunnel in tunnels:
            teid_upf = tunnel['teidupf']
            teid_gnb = tunnel['teidgnb']
            qfi = tunnel['qfi']
            node_idx = tunnel['node_idx']

            for dev_id in current_devices:
                flow_key = (dev_id, teid_upf, qfi)

                if flow_key in installed_flows:
                    continue

                log("INFO", f"  Installing flow: RNTI={rnti:#06x} "
                            f"TEID_UPF={teid_upf:#010x} TEID_gNB={teid_gnb:#010x} "
                            f"QFI={qfi} on {dev_id} (from E2 node {node_idx})")

                try:
                    result = set_udp_flow_queue(
                        ONOS_URL, INTERFACE,
                        device_id=dev_id,
                        tunnelID=teid_upf,
                        queue_id=str(qfi),
                        port="1",
                    )
                    if result.returncode == 0:
                        installed_flows.add(flow_key)
                        new_flows += 1
                        log("INFO", f"    -> {dev_id}: OK")
                    else:
                        log("WARN", f"    -> {dev_id}: FAILED (rc={result.returncode})")
                        log("WARN", f"       stderr: {result.stderr[:200]}")
                except Exception as e:
                    log("ERROR", f"    -> {dev_id}: EXCEPTION: {e}")

    return new_flows

# ============================================================
# Phase 4: Cleanup
# ============================================================
def cleanup():
    """Unsubscribe all SM handlers and stop the SDK."""
    log("INFO", "Cleaning up subscriptions...")

    with state_lock:
        handlers_copy = dict(node_handlers)

    for sub_idx, handlers in handlers_copy.items():
        for hdlr_key, hdlr_val in handlers.items():
            if hdlr_key != 'nid':
                try:
                    xapp_functs.handler_cleanup(hdlr_val, hdlr_key)
                    log("INFO", f"  Removed {hdlr_key} for node sub={sub_idx}")
                except Exception as e:
                    log("WARN", f"  Failed to remove {hdlr_key} for node sub={sub_idx}: {e}")

    try:
        xapp_sdk.try_stop()
        log("INFO", "xApp SDK stopped")
    except Exception as e:
        log("WARN", f"SDK stop failed: {e}")

# ============================================================
# Main Event Loop
# ============================================================
def main():
    log("INFO", "=" * 70)
    log("INFO", "xApp Daemon Starting")
    log("INFO", "=" * 70)

    # ---- Wait for RIC to be ready ----
    log("INFO", "Phase 1: Waiting for nearRT-RIC to be ready...")
    ric_ready = False
    for attempt in range(MAX_RIC_RETRIES):
        if shutdown_event.is_set():
            return
        try:
            xapp_sdk.init()
            ric_ready = True
            log("INFO", f"  Connected to nearRT-RIC (attempt {attempt + 1})")
            break
        except Exception as e:
            log("WARN", f"  RIC not ready (attempt {attempt + 1}/{MAX_RIC_RETRIES}): {e}")
            time.sleep(RIC_CONNECT_RETRY)

    if not ric_ready:
        log("ERROR", "Failed to connect to nearRT-RIC after max retries. Exiting.")
        return

    # ---- Discover ONOS topology ----
    log("INFO", "Phase 2: Discovering ONOS topology...")
    for attempt in range(10):
        if shutdown_event.is_set():
            cleanup()
            return
        if discover_onos_topology():
            break
        log("WARN", f"  ONOS not ready (attempt {attempt + 1}/10), retrying...")
        time.sleep(5)

    if not devices:
        log("WARN", "No ONOS switches found — continuing without OpenFlow")

    # ---- Wait for E2 nodes ----
    log("INFO", "Phase 3: Waiting for E2 nodes to connect...")
    while not shutdown_event.is_set():
        try:
            conn = xapp_sdk.conn_e2_nodes()
            if len(conn) > 0:
                log("INFO", f"  {len(conn)} E2 node(s) connected")
                break
        except Exception:
            pass
        log("INFO", "  No E2 nodes yet, waiting...")
        time.sleep(E2_POLL_INTERVAL)

    if shutdown_event.is_set():
        cleanup()
        return

    # ---- Initial subscription ----
    log("INFO", "Phase 4: Subscribing to initial E2 nodes...")
    initial = poll_e2_nodes()
    log("INFO", f"  Initial subscription: {initial} node(s)")

    # ---- Main event loop ----
    log("INFO", "Phase 5: Entering main event loop")
    log("INFO", f"  E2 poll interval:   {E2_POLL_INTERVAL}s")
    log("INFO", f"  TEID poll interval: {TEID_POLL_INTERVAL}s")
    log("INFO", f"  ONOS refresh:       {ONOS_REFRESH_INTERVAL}s")
    log("INFO", "=" * 70)

    last_e2_poll = time.time()
    last_teid_check = time.time()
    last_onos_refresh = time.time()
    loop_count = 0

    while not shutdown_event.is_set():
        try:
            now = time.time()
            loop_count += 1

            # ---- Poll for new E2 nodes ----
            if now - last_e2_poll >= E2_POLL_INTERVAL:
                new_nodes = poll_e2_nodes()
                if new_nodes > 0:
                    log("INFO", f"Subscribed to {new_nodes} new E2 node(s) "
                                f"(total unique: {len(subscribed_nodes)})")
                last_e2_poll = now

            # ---- Check for new TEIDs and install flows ----
            if now - last_teid_check >= TEID_POLL_INTERVAL:
                new_flows = check_and_install_teid_flows()
                if new_flows > 0:
                    log("INFO", f"Installed {new_flows} new OpenFlow flow(s) "
                                f"(total installed: {len(installed_flows)})")
                last_teid_check = now

            # ---- Refresh ONOS topology periodically ----
            if now - last_onos_refresh >= ONOS_REFRESH_INTERVAL:
                discover_onos_topology()
                last_onos_refresh = now

            # ---- Periodic status log (every ~60s) ----
            if loop_count % 60 == 0:
                ue_count = len(xapp_functs.GTPCallback.ue_gtp_map)
                gtp_ind_count = xapp_functs.GTPCallback._indication_count
                gtp_empty = xapp_functs.GTPCallback._empty_count
                log("INFO", f"[STATUS] E2 nodes: {len(subscribed_nodes)} | "
                            f"UEs with TEIDs: {ue_count} | "
                            f"Installed flows: {len(installed_flows)} | "
                            f"Switches: {len(devices)} | "
                            f"GTP indications: {gtp_ind_count} (empty: {gtp_empty})")

                # Print current TEID map
                if xapp_functs.GTPCallback.ue_gtp_map:
                    log("INFO", "[TEID MAP]")
                    for rnti, tunnels in sorted(xapp_functs.GTPCallback.ue_gtp_map.items()):
                        for t in tunnels:
                            log("INFO", f"  RNTI={rnti:#06x} QFI={t['qfi']} "
                                        f"TEID_gNB={t['teidgnb']:#010x} "
                                        f"TEID_UPF={t['teidupf']:#010x} "
                                        f"node={t['node_idx']}")

            # Sleep in small increments so we can respond to shutdown quickly
            shutdown_event.wait(timeout=1.0)

        except Exception as e:
            log("ERROR", f"Main loop exception: {e}")
            traceback.print_exc()
            time.sleep(2)

    # ---- Shutdown ----
    log("INFO", "Shutting down...")
    cleanup()

    # ---- Final summary ----
    log("INFO", "=" * 70)
    log("INFO", "Final Summary:")
    log("INFO", f"  E2 nodes subscribed: {len(subscribed_nodes)}")
    log("INFO", f"  UEs discovered:      {len(xapp_functs.GTPCallback.ue_gtp_map)}")
    log("INFO", f"  Flows installed:     {len(installed_flows)}")
    log("INFO", f"  Switches:            {len(devices)}")
    log("INFO", f"  GTP indications:     {xapp_functs.GTPCallback._indication_count}")
    log("INFO", f"  GTP empty:           {xapp_functs.GTPCallback._empty_count}")

    if xapp_functs.GTPCallback.ue_gtp_map:
        log("INFO", "  UE GTP Map:")
        for rnti, tunnels in sorted(xapp_functs.GTPCallback.ue_gtp_map.items()):
            for t in tunnels:
                log("INFO", f"    RNTI={rnti:#06x} QFI={t['qfi']} "
                            f"TEID_gNB={t['teidgnb']:#010x} "
                            f"TEID_UPF={t['teidupf']:#010x}")

    log("INFO", "xApp Daemon terminated.")


if __name__ == "__main__":
    main()