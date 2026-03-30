#!/usr/bin/env python3
"""
xapp_daemon.py - FlexRIC xApp with TEID parsing from CU log files.

This xApp:
1. Connects to nearRT-RIC and subscribes to E2 nodes (DU, CU)
2. Discovers ONOS SDN topology
3. Parses CU log files for GTP-U TEID information (NO Docker socket needed)
4. Installs OpenFlow rules in ONOS based on discovered TEIDs

TEID Parsing Method:
- CU writes stdout to /opt/oai-gnb/logs/cu_stdout.log (via tee)
- FlexRIC mounts ./logs/cu:/usr/local/flexric/cu_logs:ro
- We parse cu_stdout.log for [GTPU] tunnel Create/Update messages
- We parse nrRRC_stats.log for UE RNTI mapping
- NO Docker socket required!
"""

import os
import sys
import re
import subprocess
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
E2_POLL_INTERVAL = 10
TEID_POLL_INTERVAL = 5
ONOS_REFRESH_INTERVAL = 60
RIC_CONNECT_RETRY = 5
MAX_RIC_RETRIES = 60

# Path to CU logs (mounted read-only from host ./logs/cu)
CU_LOGS_DIR = "/usr/local/flexric/cu_logs"
CU_STDOUT_LOG = f"{CU_LOGS_DIR}/cu_stdout.log"
CU_RRC_STATS_LOG = f"{CU_LOGS_DIR}/nrRRC_stats.log"

# DU and UPF IPs for tunnel type identification
DU_F1U_IP = "192.168.74.151"
UPF_N3_IP = "192.168.71.134"

TYPES_ACCEPTED = [
    "ngran_gNB_CUUP",
    "ngran_gNB_DU",
    "ngran_gNB_CUCP",
    "ngran_gNB_CU",
]

# ============================================================
# Global State
# ============================================================
shutdown_event = threading.Event()
devices = {}
node_handlers = {}
subscribed_nodes = set()
installed_flows = set()
storage = xapp_functs.Xapp_Metric_Storage()
state_lock = threading.Lock()

# TEID state parsed from CU logs
parsed_tunnels = {}     # cu_ue_id -> list of tunnel dicts
parsed_ue_rnti = {}     # cu_ue_id -> {rnti, du_ue_id, ...}
_log_file_position = 0  # Track position in log file for incremental reading


def log(level, msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] [{level}] {msg}", flush=True)


# ============================================================
# Signal Handling
# ============================================================
def signal_handler(sig, frame):
    log("INFO", f"Received signal {sig}, initiating shutdown...")
    shutdown_event.set()


signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)


# ============================================================
# CU Log TEID Parser (FILE-BASED - NO DOCKER SOCKET)
# ============================================================

# Regex patterns for CU log lines
TUNNEL_CREATE_RE = re.compile(
    r'\[GTPU\].*UE ID (\d+): Create tunnel '
    r'TEID incoming (0x[0-9a-fA-F]+) outgoing (0x[0-9a-fA-F]+) '
    r'to remote IPv4 ([\d.]+)',
    re.IGNORECASE
)
TUNNEL_UPDATE_RE = re.compile(
    r'\[GTPU\].*UE ID (\d+): Update tunnel '
    r'TEID incoming (0x[0-9a-fA-F]+) outgoing (0x[0-9a-fA-F]+) '
    r'to remote IPv4 ([\d.]+)',
    re.IGNORECASE
)
RRC_STATS_RE = re.compile(
    r'UE (\d+) CU UE ID (\d+) DU UE ID (\d+) RNTI ([0-9a-fA-F]+)',
    re.IGNORECASE
)
BEARER_SETUP_RE = re.compile(
    r'\[NR_RRC\].*Bearer Context Setup: PDU Session ID=(\d+), '
    r'incoming TEID=(0x[0-9a-fA-F]+), Addr=([\d.]+)',
    re.IGNORECASE
)


def parse_rrc_stats():
    """
    Parse nrRRC_stats.log for UE RNTI mapping.
    This file is written by the CU and contains UE ID -> RNTI mappings.
    """
    global parsed_ue_rnti
    
    try:
        with open(CU_RRC_STATS_LOG, 'r') as f:
            content = f.read()
    except FileNotFoundError:
        # File doesn't exist yet - CU hasn't written it
        return 0
    except Exception as e:
        log("WARN", f"[RRC_STATS] Read error: {e}")
        return 0

    new_count = 0
    for m in RRC_STATS_RE.finditer(content):
        ue_idx = int(m.group(1))
        cu_ue_id = int(m.group(2))
        du_ue_id = int(m.group(3))
        rnti = int(m.group(4), 16)

        if cu_ue_id not in parsed_ue_rnti:
            new_count += 1
            log("INFO", f"[RRC_STATS] UE mapping: CU_UE_ID={cu_ue_id} "
                        f"DU_UE_ID={du_ue_id} RNTI={rnti:#06x}")

        parsed_ue_rnti[cu_ue_id] = {
            'ue_idx': ue_idx,
            'cu_ue_id': cu_ue_id,
            'du_ue_id': du_ue_id,
            'rnti': rnti,
            'rnti_hex': f'0x{m.group(4)}',
        }

    return new_count


def parse_cu_stdout_log():
    """
    Parse CU stdout log for TEID information.
    Reads incrementally from last position to avoid re-processing.
    """
    global parsed_tunnels, _log_file_position

    try:
        with open(CU_STDOUT_LOG, 'r') as f:
            # Seek to last read position
            f.seek(_log_file_position)
            new_lines = f.readlines()
            _log_file_position = f.tell()
    except FileNotFoundError:
        # File doesn't exist yet - CU hasn't started writing
        return 0
    except Exception as e:
        log("WARN", f"[GTPU_LOG] Read error: {e}")
        return 0

    if not new_lines:
        return 0

    new_tunnels = 0

    for line in new_lines:
        # --- Create tunnel ---
        m = TUNNEL_CREATE_RE.search(line)
        if m:
            ue_id = int(m.group(1))
            teid_incoming = int(m.group(2), 16)  # gNB/CU TEID
            teid_outgoing = int(m.group(3), 16)  # Remote TEID (UPF or placeholder)
            remote_addr = m.group(4)

            if ue_id not in parsed_tunnels:
                parsed_tunnels[ue_id] = []

            # Determine tunnel type based on remote address
            if remote_addr == UPF_N3_IP:
                tunnel_type = "n3_upf"
            elif remote_addr == DU_F1U_IP:
                tunnel_type = "f1u_du"
            elif remote_addr == "0.0.0.0" and teid_outgoing == 0xffff:
                tunnel_type = "f1u_pending"
            else:
                tunnel_type = "unknown"

            # Check for duplicates
            exists = any(
                t['teid_local'] == teid_incoming and t['tunnel_type'] == tunnel_type
                for t in parsed_tunnels[ue_id]
            )
            if not exists:
                tunnel = {
                    'teid_local': teid_incoming,      # CU-side TEID
                    'teid_remote': teid_outgoing,     # Remote TEID
                    'remote_addr': remote_addr,
                    'tunnel_type': tunnel_type,
                    'teid_du': 0,
                    'du_addr': '',
                    'established': (tunnel_type == "n3_upf"),
                }
                parsed_tunnels[ue_id].append(tunnel)
                new_tunnels += 1

                rnti_info = parsed_ue_rnti.get(ue_id, {})
                rnti = rnti_info.get('rnti', 0)
                log("INFO", f"[GTPU] CREATE {tunnel_type}: UE_ID={ue_id} "
                            f"RNTI={rnti:#06x} TEID_local={teid_incoming:#010x} "
                            f"TEID_remote={teid_outgoing:#010x} remote={remote_addr}")
            continue

        # --- Update tunnel (F1-U establishment from DU) ---
        m = TUNNEL_UPDATE_RE.search(line)
        if m:
            ue_id = int(m.group(1))
            teid_incoming = int(m.group(2), 16)
            teid_outgoing = int(m.group(3), 16)  # This is the DU TEID!
            remote_addr = m.group(4)

            if ue_id in parsed_tunnels:
                for t in parsed_tunnels[ue_id]:
                    # Match by local TEID and update with DU info
                    if t['teid_local'] == teid_incoming and not t['established']:
                        t['teid_du'] = teid_outgoing
                        t['teid_remote'] = teid_outgoing
                        t['du_addr'] = remote_addr
                        t['remote_addr'] = remote_addr
                        t['established'] = True
                        t['tunnel_type'] = "f1u_du"
                        new_tunnels += 1

                        rnti_info = parsed_ue_rnti.get(ue_id, {})
                        rnti = rnti_info.get('rnti', 0)
                        log("INFO", f"[GTPU] UPDATE F1-U: UE_ID={ue_id} "
                                    f"RNTI={rnti:#06x} TEID_CU={teid_incoming:#010x} "
                                    f"TEID_DU={teid_outgoing:#010x} DU={remote_addr}")
                        break
            continue

    return new_tunnels


def get_teid_map_by_rnti():
    """
    Return RNTI -> list of tunnel info from parsed CU logs.
    Merges RRC stats (RNTI) with GTPU tunnel info (TEIDs).
    """
    result = {}

    for ue_id, tunnels in parsed_tunnels.items():
        rnti_info = parsed_ue_rnti.get(ue_id, {})
        rnti = rnti_info.get('rnti', 0)

        if rnti == 0:
            # No RNTI mapping yet - skip
            continue

        for t in tunnels:
            if rnti not in result:
                result[rnti] = []

            result[rnti].append({
                'ue_id': ue_id,
                'cu_ue_id': rnti_info.get('cu_ue_id', ue_id),
                'du_ue_id': rnti_info.get('du_ue_id', 0),
                'rnti': rnti,
                'rnti_hex': rnti_info.get('rnti_hex', f'{rnti:#06x}'),
                'teid_local': t.get('teid_local', 0),
                'teid_remote': t.get('teid_remote', 0),
                'teid_du': t.get('teid_du', 0),
                'remote_addr': t.get('remote_addr', ''),
                'du_addr': t.get('du_addr', ''),
                'tunnel_type': t.get('tunnel_type', 'unknown'),
                'established': t.get('established', False),
            })

    return result


def get_du_teids_for_flows():
    """
    Get DU TEIDs suitable for OpenFlow rule installation.
    Returns dict: RNTI -> list of DU TEIDs (for F1-U traffic matching)
    """
    teid_map = get_teid_map_by_rnti()
    result = {}

    for rnti, tunnels in teid_map.items():
        du_teids = []
        for t in tunnels:
            if t['tunnel_type'] == 'f1u_du' and t['established']:
                du_teids.append(t['teid_du'])
        if du_teids:
            result[rnti] = du_teids

    return result


def get_n3_teids_for_flows():
    """
    Get N3 (UPF) TEIDs suitable for OpenFlow rule installation.
    Returns dict: RNTI -> list of (teid_gnb, teid_upf) tuples
    """
    teid_map = get_teid_map_by_rnti()
    result = {}

    for rnti, tunnels in teid_map.items():
        n3_teids = []
        for t in tunnels:
            if t['tunnel_type'] == 'n3_upf':
                n3_teids.append({
                    'teid_gnb': t['teid_local'],
                    'teid_upf': t['teid_remote'],
                })
        if n3_teids:
            result[rnti] = n3_teids

    return result


# ============================================================
# Phase 1: ONOS Topology Discovery
# ============================================================
def discover_onos_topology():
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
                if len(criteria) > 2 and criteria[2].get("type") == "IP_PROTO":
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
    try:
        enum_val = -1
        type_obj = getattr(nid, "type", None)
        if type_obj is not None:
            type_obj.disown()
            raw_ptr = int(type_obj)
            ctype_int_ptr = ctypes.POINTER(ctypes.c_int)
            enum_val = ctypes.cast(raw_ptr, ctype_int_ptr).contents.value

        mcc = int(nid.plmn.mcc)
        mnc = int(nid.plmn.mnc)

        nb_id_val = 0
        nb_id_obj = getattr(nid, "nb_id", None)
        if nb_id_obj is not None:
            try:
                nb_id_obj.disown()
                raw_ptr = int(nb_id_obj)
                if raw_ptr != 0:
                    ctype_uint32_ptr = ctypes.POINTER(ctypes.c_uint32)
                    nb_id_val = ctypes.cast(raw_ptr, ctype_uint32_ptr).contents.value
            except Exception:
                nb_id_val = 0

        cu_du_val = 0
        cu_du_id_obj = getattr(nid, "cu_du_id", None)
        if cu_du_id_obj is not None:
            try:
                cu_du_id_obj.disown()
                raw_ptr = int(cu_du_id_obj)
                if raw_ptr != 0:
                    ctype_uint32_ptr = ctypes.POINTER(ctypes.c_uint32)
                    cu_du_val = ctypes.cast(raw_ptr, ctype_uint32_ptr).contents.value
            except Exception:
                cu_du_val = 0

        return (mcc, mnc, nb_id_val, enum_val, cu_du_val)
    except Exception as e:
        log("WARN", f"get_node_key failed: {e}")
        return (0, 0, 0, -999, 0)


def subscribe_node(node_idx, nid, node_type):
    """Subscribe to SMs. CRITICAL: store callback refs to prevent GC."""
    global node_handlers

    with state_lock:
        node_handlers[node_idx] = {'nid': nid}

    try:
        if node_type == "ngran_gNB_DU":
            log("INFO", f"  Node [{node_idx}] DU: subscribing MAC + RLC")
            storage.add_node(node_idx, node_type, ['mac', 'rlc'])
            mac_cb = xapp_functs.MACCallback(storage, node_idx)
            rlc_cb = xapp_functs.RLCCallback(storage, node_idx)
            with state_lock:
                node_handlers[node_idx]['mac_cb_ref'] = mac_cb
                node_handlers[node_idx]['rlc_cb_ref'] = rlc_cb
                node_handlers[node_idx]['mac_hndlr'] = xapp_sdk.report_mac_sm(
                    nid, xapp_sdk.Interval_ms_10, mac_cb)
                node_handlers[node_idx]['rlc_hndlr'] = xapp_sdk.report_rlc_sm(
                    nid, xapp_sdk.Interval_ms_10, rlc_cb)

        elif node_type in ("ngran_gNB_CUUP", "ngran_gNB_CU"):
            label = "Unified CU" if node_type == "ngran_gNB_CU" else "CU-UP"
            log("INFO", f"  Node [{node_idx}] {label}: subscribing PDCP + GTP")
            storage.add_node(node_idx, node_type, ['pdcp', 'gtp'])
            pdcp_cb = xapp_functs.PDCPCallback(storage, node_idx)
            gtp_cb = xapp_functs.GTPCallback(storage, node_idx)
            with state_lock:
                node_handlers[node_idx]['pdcp_cb_ref'] = pdcp_cb
                node_handlers[node_idx]['gtp_cb_ref'] = gtp_cb
                node_handlers[node_idx]['pdcp_hndlr'] = xapp_sdk.report_pdcp_sm(
                    nid, xapp_sdk.Interval_ms_10, pdcp_cb)
                node_handlers[node_idx]['gtp_hndlr'] = xapp_sdk.report_gtp_sm(
                    nid, xapp_sdk.Interval_ms_10, gtp_cb)

        elif node_type == "ngran_gNB_CUCP":
            log("INFO", f"  Node [{node_idx}] CU-CP: no user-plane subscriptions")
            storage.add_node(node_idx, node_type, [])

        else:
            log("WARN", f"  Node [{node_idx}] Unknown type '{node_type}': skipping")
            storage.add_node(node_idx, node_type, [])

        return True

    except Exception as e:
        log("ERROR", f"  Failed to subscribe node [{node_idx}]: {e}")
        traceback.print_exc()
        return False


def poll_e2_nodes():
    global subscribed_nodes
    try:
        conn = xapp_sdk.conn_e2_nodes()
        if len(conn) == 0:
            return 0
        new_count = 0
        for node_idx, con in enumerate(conn):
            nid = con.id
            node_key = get_node_key(nid)
            if node_key in subscribed_nodes:
                continue
            node_type = xapp_functs.classify_e2node(nid)
            log("INFO", f"New E2 Node [raw={node_idx}]: {node_type} key={node_key}")
            if node_type in TYPES_ACCEPTED:
                if subscribe_node(node_idx, nid, node_type):
                    subscribed_nodes.add(node_key)
                    new_count += 1
                    log("INFO", f"  -> Subscribed as sub_idx={node_idx}")
            else:
                log("WARN", f"  Skipping unsupported node type: {node_type}")
                subscribed_nodes.add(node_key)
        return new_count
    except Exception as e:
        log("ERROR", f"E2 node polling failed: {e}")
        return 0


# ============================================================
# Phase 3: TEID Flow Installation
# ============================================================
def check_and_install_teid_flows():
    """Install OpenFlow rules based on TEIDs parsed from CU logs."""
    global installed_flows

    # First try GTP SM (works with separate CU-UP architecture)
    gtp_map = xapp_functs.GTPCallback.ue_gtp_map
    if gtp_map:
        return _install_from_gtp_sm(gtp_map)

    # Fallback: use parsed CU logs (unified CU architecture)
    # Get N3 TEIDs (UPF direction) for flow installation
    n3_map = get_n3_teids_for_flows()
    if not n3_map:
        return 0

    with state_lock:
        current_devices = dict(devices)
    if not current_devices:
        return 0

    new_flows = 0
    for rnti, n3_tunnels in n3_map.items():
        for t in n3_tunnels:
            teid_upf = t['teid_upf']
            teid_gnb = t['teid_gnb']

            if teid_upf == 0 or teid_upf == 0xffff:
                continue

            for dev_id in current_devices:
                flow_key = (dev_id, teid_upf, "n3")
                if flow_key in installed_flows:
                    continue

                log("INFO", f"  Installing N3 flow: RNTI={rnti:#06x} "
                            f"TEID_gNB={teid_gnb:#010x} TEID_UPF={teid_upf:#010x} "
                            f"on {dev_id} (from CU log)")
                try:
                    result = set_udp_flow_queue(
                        ONOS_URL, INTERFACE,
                        device_id=dev_id,
                        tunnelID=teid_upf,
                        queue_id="9",
                        port="1",
                    )
                    if result.returncode == 0:
                        installed_flows.add(flow_key)
                        new_flows += 1
                        log("INFO", f"    -> {dev_id}: OK")
                    else:
                        log("WARN", f"    -> {dev_id}: FAILED (rc={result.returncode})")
                except Exception as e:
                    log("ERROR", f"    -> {dev_id}: {e}")

    return new_flows


def _install_from_gtp_sm(gtp_map):
    """Install flows from GTP SM indications (separate CU-UP architecture)."""
    global installed_flows
    with state_lock:
        current_devices = dict(devices)
    if not current_devices:
        return 0
    new_flows = 0
    for rnti, tunnels in gtp_map.items():
        for tunnel in tunnels:
            teid_upf = tunnel['teidupf']
            teid_gnb = tunnel['teidgnb']
            qfi = tunnel['qfi']
            for dev_id in current_devices:
                flow_key = (dev_id, teid_upf, qfi)
                if flow_key in installed_flows:
                    continue
                log("INFO", f"  Installing flow: RNTI={rnti:#06x} "
                            f"TEID_UPF={teid_upf:#010x} TEID_gNB={teid_gnb:#010x} "
                            f"QFI={qfi} on {dev_id} (from GTP SM)")
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
                except Exception as e:
                    log("ERROR", f"    -> {dev_id}: {e}")
    return new_flows


# ============================================================
# Phase 4: Cleanup
# ============================================================
def cleanup():
    log("INFO", "Cleaning up subscriptions...")
    with state_lock:
        handlers_copy = dict(node_handlers)
    for node_idx, handlers in handlers_copy.items():
        for hdlr_key, hdlr_val in handlers.items():
            if hdlr_key.endswith('_hndlr'):
                try:
                    xapp_functs.handler_cleanup(hdlr_val, hdlr_key)
                    log("INFO", f"  Removed {hdlr_key} for node {node_idx}")
                except Exception as e:
                    log("WARN", f"  Failed to remove {hdlr_key}: {e}")
    try:
        xapp_sdk.try_stop()
        log("INFO", "xApp SDK stopped")
    except Exception as e:
        log("WARN", f"SDK stop failed: {e}")


# ============================================================
# Main
# ============================================================
def main():
    log("INFO", "=" * 70)
    log("INFO", "xApp Daemon Starting (File-based TEID parsing)")
    log("INFO", "=" * 70)
    log("INFO", f"CU logs directory: {CU_LOGS_DIR}")
    log("INFO", f"CU stdout log: {CU_STDOUT_LOG}")
    log("INFO", f"CU RRC stats: {CU_RRC_STATS_LOG}")

    # Check if logs directory is mounted
    if os.path.isdir(CU_LOGS_DIR):
        log("INFO", f"✓ CU logs directory is mounted")
        files = os.listdir(CU_LOGS_DIR)
        log("INFO", f"  Contents: {files if files else '(empty)'}")
    else:
        log("WARN", f"✗ CU logs directory not found at {CU_LOGS_DIR}")
        log("WARN", "  TEID parsing from files will not work!")

    # ---- Phase 1: Wait for RIC ----
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
        log("ERROR", "Failed to connect to nearRT-RIC. Exiting.")
        return

    # ---- Phase 2: ONOS topology ----
    log("INFO", "Phase 2: Discovering ONOS topology...")
    for attempt in range(10):
        if shutdown_event.is_set():
            cleanup()
            return
        if discover_onos_topology():
            break
        log("WARN", f"  ONOS not ready (attempt {attempt + 1}/10), retrying...")
        time.sleep(5)

    # ---- Phase 3: Wait for E2 nodes ----
    log("INFO", "Phase 3: Waiting for E2 nodes to connect...")
    MIN_E2_NODES = 1
    while not shutdown_event.is_set():
        try:
            conn = xapp_sdk.conn_e2_nodes()
            if len(conn) >= MIN_E2_NODES:
                log("INFO", f"  {len(conn)} E2 node(s) connected")
                break
        except Exception:
            pass
        log("INFO", "  No E2 nodes yet, waiting...")
        time.sleep(E2_POLL_INTERVAL)
    if shutdown_event.is_set():
        cleanup()
        return

    # ---- Phase 4: Initial subscription ----
    log("INFO", "Phase 4: Subscribing to initial E2 nodes...")
    initial = poll_e2_nodes()
    log("INFO", f"  Initial subscription: {initial} node(s)")

    # ---- Phase 5: Initial CU log parse ----
    log("INFO", "Phase 5: Initial CU log parsing...")
    rrc_count = parse_rrc_stats()
    gtpu_count = parse_cu_stdout_log()
    teid_map = get_teid_map_by_rnti()
    log("INFO", f"  RRC stats: {len(parsed_ue_rnti)} UEs")
    log("INFO", f"  GTPU tunnels: {sum(len(t) for t in parsed_tunnels.values())} total")
    log("INFO", f"  Mapped (RNTI->TEID): {len(teid_map)} UEs")

    # Print current TEID map
    if teid_map:
        log("INFO", "  Current TEID map:")
        for rnti, tunnels in sorted(teid_map.items()):
            for t in tunnels:
                status = "✓" if t['established'] else "…"
                log("INFO", f"    RNTI={rnti:#06x} {t['tunnel_type']:12s} "
                            f"TEID_local={t['teid_local']:#010x} "
                            f"TEID_remote={t['teid_remote']:#010x} {status}")

    # ---- Main loop ----
    log("INFO", "Phase 6: Entering main event loop")
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

            # Poll E2 nodes
            if now - last_e2_poll >= E2_POLL_INTERVAL:
                new_nodes = poll_e2_nodes()
                if new_nodes > 0:
                    log("INFO", f"Subscribed to {new_nodes} new E2 node(s) "
                                f"(total unique: {len(subscribed_nodes)})")
                last_e2_poll = now

            # Parse CU logs + check TEIDs + install flows
            if now - last_teid_check >= TEID_POLL_INTERVAL:
                parse_rrc_stats()
                parse_cu_stdout_log()
                new_flows = check_and_install_teid_flows()
                if new_flows > 0:
                    log("INFO", f"Installed {new_flows} new flow(s) "
                                f"(total: {len(installed_flows)})")
                last_teid_check = now

            # Refresh ONOS
            if now - last_onos_refresh >= ONOS_REFRESH_INTERVAL:
                discover_onos_topology()
                last_onos_refresh = now

            # Status log every ~30s
            if loop_count % 30 == 0:
                mac_ue_count = len(xapp_functs.MACCallback.ue_mac_map)
                mac_ind = xapp_functs.MACCallback._indication_count
                pdcp_ue_count = len(xapp_functs.PDCPCallback.ue_pdcp_map)
                pdcp_ind = xapp_functs.PDCPCallback._indication_count
                gtp_ue_count = len(xapp_functs.GTPCallback.ue_gtp_map)
                gtp_ind = xapp_functs.GTPCallback._indication_count
                gtp_empty = xapp_functs.GTPCallback._empty_count
                teid_map = get_teid_map_by_rnti()
                n3_map = get_n3_teids_for_flows()
                f1u_map = get_du_teids_for_flows()

                log("INFO", f"[STATUS] E2: {len(subscribed_nodes)} | "
                            f"MAC: {mac_ue_count} UEs ({mac_ind} ind) | "
                            f"PDCP: {pdcp_ue_count} UEs ({pdcp_ind} ind) | "
                            f"GTP_SM: {gtp_ue_count} UEs ({gtp_ind} ind, {gtp_empty} empty) | "
                            f"CU_LOG: {len(teid_map)} UEs (N3:{len(n3_map)} F1U:{len(f1u_map)}) | "
                            f"Flows: {len(installed_flows)} | "
                            f"Switches: {len(devices)}")

            time.sleep(1)

        except KeyboardInterrupt:
            log("INFO", "Keyboard interrupt received")
            break
        except Exception as e:
            log("ERROR", f"Main loop error: {e}")
            traceback.print_exc()
            time.sleep(5)

    cleanup()
    log("INFO", "xApp daemon stopped")


if __name__ == "__main__":
    main()
