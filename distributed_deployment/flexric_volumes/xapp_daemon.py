#!/usr/bin/env python3
"""
xapp_daemon.py - FlexRIC xApp with F1-U TEID parsing from CU log files.

This version ONLY captures F1-U TEIDs (CU ↔ DU), NOT N3 TEIDs (CU ↔ UPF).
"""

import os
import sys
import re
import json
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

# ============================================================
# F1-U IDENTIFICATION
# ============================================================
# DU's F1-U IP address - tunnels to this address are F1-U
DU_F1U_IP = "192.168.74.151"

# UPF's N3 IP address - tunnels to this address are N3 (IGNORE)
UPF_N3_IP = "192.168.71.134"

# F1-U instance ID (port 2153) - alternative filter method
F1U_INSTANCE_ID = "93"

# N3 instance ID (port 2152) - we ignore these
N3_INSTANCE_ID = "92"

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

# TEID state - F1-U ONLY
f1u_tunnels = {}        # cu_ue_id -> list of F1-U tunnel dicts
parsed_ue_rnti = {}     # cu_ue_id -> {rnti, du_ue_id, ...}
_log_file_position = 0
_log_file_inode = None
_last_file_size = 0


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
# F1-U TEID Parser (ONLY F1-U, NOT N3)
# ============================================================

# Regex patterns - now capture instance ID [XX]
# [GTPU] [93] UE ID 1: Create tunnel TEID incoming 0xf949d61a outgoing 0xffff to remote IPv4 0.0.0.0
TUNNEL_CREATE_RE = re.compile(
    r'\[GTPU\]\s+(?:I\s+)?\[(\d+)\]\s+UE ID (\d+): Create tunnel '
    r'TEID incoming (0x[0-9a-fA-F]+) outgoing (0x[0-9a-fA-F]+) '
    r'to remote IPv4 ([\d.]+)',
    re.IGNORECASE
)

# [GTPU] [93] UE ID 1: Update tunnel TEID incoming 0xf949d61a outgoing 0xae95307b to remote IPv4 192.168.74.151
TUNNEL_UPDATE_RE = re.compile(
    r'\[GTPU\]\s+(?:I\s+)?\[(\d+)\]\s+UE ID (\d+): Update tunnel '
    r'TEID incoming (0x[0-9a-fA-F]+) outgoing (0x[0-9a-fA-F]+) '
    r'to remote IPv4 ([\d.]+)',
    re.IGNORECASE
)

# Fallback patterns without instance ID (for different log formats)
TUNNEL_CREATE_FALLBACK_RE = re.compile(
    r'\[GTPU\].*UE ID (\d+): Create tunnel '
    r'TEID incoming (0x[0-9a-fA-F]+) outgoing (0x[0-9a-fA-F]+) '
    r'to remote IPv4 ([\d.]+)',
    re.IGNORECASE
)

TUNNEL_UPDATE_FALLBACK_RE = re.compile(
    r'\[GTPU\].*UE ID (\d+): Update tunnel '
    r'TEID incoming (0x[0-9a-fA-F]+) outgoing (0x[0-9a-fA-F]+) '
    r'to remote IPv4 ([\d.]+)',
    re.IGNORECASE
)

# RRC stats for RNTI mapping
RRC_STATS_RE = re.compile(
    r'UE (\d+) CU UE ID (\d+) DU UE ID (\d+) RNTI ([0-9a-fA-F]+)',
    re.IGNORECASE
)


def is_f1u_tunnel(instance_id, remote_addr):
    """
    Determine if a tunnel is F1-U (to DU) based on instance ID or remote address.
    
    Returns True for F1-U tunnels, False for N3 tunnels.
    """
    # Method 1: Check instance ID (93 = F1-U, 92 = N3)
    if instance_id:
        if instance_id == F1U_INSTANCE_ID:
            return True
        if instance_id == N3_INSTANCE_ID:
            return False
    
    # Method 2: Check remote address
    if remote_addr == DU_F1U_IP:
        return True
    if remote_addr == UPF_N3_IP:
        return False
    
    # Method 3: Pending F1-U tunnels have remote 0.0.0.0 and outgoing 0xffff
    if remote_addr == "0.0.0.0":
        return True  # Likely F1-U pending
    
    return False


def reset_teid_state():
    """Reset F1-U TEID parsing state (called on file truncation/restart)."""
    global f1u_tunnels, parsed_ue_rnti, _log_file_position, _last_file_size
    log("WARN", "[TEID] Resetting F1-U TEID state (file truncated or CU restarted)")
    f1u_tunnels = {}
    parsed_ue_rnti = {}
    _log_file_position = 0
    _last_file_size = 0


def parse_rrc_stats():
    """Parse nrRRC_stats.log for UE RNTI mapping."""
    global parsed_ue_rnti
    
    try:
        if not os.path.exists(CU_RRC_STATS_LOG):
            return 0
        with open(CU_RRC_STATS_LOG, 'r') as f:
            content = f.read()
    except FileNotFoundError:
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
    Parse CU stdout log for F1-U TEID information ONLY.
    Ignores N3 tunnels (to UPF).
    """
    global f1u_tunnels, _log_file_position, _log_file_inode, _last_file_size

    try:
        if not os.path.exists(CU_STDOUT_LOG):
            return 0
        
        stat_info = os.stat(CU_STDOUT_LOG)
        current_size = stat_info.st_size
        current_inode = stat_info.st_ino
        
        # Truncation detection
        if current_size < _log_file_position:
            log("WARN", f"[F1U_LOG] File truncated: size={current_size} < position={_log_file_position}")
            reset_teid_state()
        
        if _log_file_inode is not None and current_inode != _log_file_inode:
            log("WARN", f"[F1U_LOG] File replaced: inode {_log_file_inode} -> {current_inode}")
            reset_teid_state()
        
        if current_size < _last_file_size:
            log("WARN", f"[F1U_LOG] File shrank: {_last_file_size} -> {current_size}")
            reset_teid_state()
        
        _log_file_inode = current_inode
        _last_file_size = current_size
        
        if current_size == _log_file_position:
            return 0

        with open(CU_STDOUT_LOG, 'r') as f:
            f.seek(_log_file_position)
            new_lines = f.readlines()
            _log_file_position = f.tell()
            
    except FileNotFoundError:
        return 0
    except Exception as e:
        log("WARN", f"[F1U_LOG] Read error: {e}")
        return 0

    if not new_lines:
        return 0

    new_tunnels = 0

    for line in new_lines:
        # --- Try Create tunnel with instance ID ---
        m = TUNNEL_CREATE_RE.search(line)
        if m:
            instance_id = m.group(1)
            ue_id = int(m.group(2))
            teid_incoming = int(m.group(3), 16)
            teid_outgoing = int(m.group(4), 16)
            remote_addr = m.group(5)
            
            # *** ONLY PROCESS F1-U TUNNELS ***
            if not is_f1u_tunnel(instance_id, remote_addr):
                # Skip N3 tunnels
                continue
            
            if ue_id not in f1u_tunnels:
                f1u_tunnels[ue_id] = []
            
            # Check for duplicates
            exists = any(t['teid_cu'] == teid_incoming for t in f1u_tunnels[ue_id])
            if not exists:
                tunnel = {
                    'teid_cu': teid_incoming,       # CU-side F1-U TEID
                    'teid_du': 0,                   # Will be filled on Update
                    'du_addr': '',
                    'established': False,
                    'instance_id': instance_id,
                }
                f1u_tunnels[ue_id].append(tunnel)
                new_tunnels += 1

                rnti_info = parsed_ue_rnti.get(ue_id, {})
                rnti = rnti_info.get('rnti', 0)
                log("INFO", f"[F1U] CREATE: UE_ID={ue_id} RNTI={rnti:#06x} "
                            f"TEID_CU={teid_incoming:#010x} (instance={instance_id})")
            continue
        
        # --- Try Create tunnel fallback (no instance ID) ---
        m = TUNNEL_CREATE_FALLBACK_RE.search(line)
        if m:
            ue_id = int(m.group(1))
            teid_incoming = int(m.group(2), 16)
            teid_outgoing = int(m.group(3), 16)
            remote_addr = m.group(4)
            
            # *** ONLY PROCESS F1-U TUNNELS ***
            # Without instance ID, rely on remote address and teid pattern
            if remote_addr == UPF_N3_IP:
                continue  # Skip N3
            if remote_addr not in (DU_F1U_IP, "0.0.0.0"):
                continue  # Unknown, skip
            
            if ue_id not in f1u_tunnels:
                f1u_tunnels[ue_id] = []
            
            exists = any(t['teid_cu'] == teid_incoming for t in f1u_tunnels[ue_id])
            if not exists:
                tunnel = {
                    'teid_cu': teid_incoming,
                    'teid_du': 0,
                    'du_addr': '',
                    'established': False,
                    'instance_id': None,
                }
                f1u_tunnels[ue_id].append(tunnel)
                new_tunnels += 1

                rnti_info = parsed_ue_rnti.get(ue_id, {})
                rnti = rnti_info.get('rnti', 0)
                log("INFO", f"[F1U] CREATE: UE_ID={ue_id} RNTI={rnti:#06x} "
                            f"TEID_CU={teid_incoming:#010x}")
            continue

        # --- Try Update tunnel with instance ID ---
        m = TUNNEL_UPDATE_RE.search(line)
        if m:
            instance_id = m.group(1)
            ue_id = int(m.group(2))
            teid_incoming = int(m.group(3), 16)
            teid_outgoing = int(m.group(4), 16)  # This is the DU TEID!
            remote_addr = m.group(5)
            
            # *** ONLY PROCESS F1-U TUNNELS ***
            if not is_f1u_tunnel(instance_id, remote_addr):
                continue
            
            if ue_id in f1u_tunnels:
                for t in f1u_tunnels[ue_id]:
                    if t['teid_cu'] == teid_incoming and not t['established']:
                        t['teid_du'] = teid_outgoing  # *** THE DU TEID ***
                        t['du_addr'] = remote_addr
                        t['established'] = True
                        new_tunnels += 1

                        rnti_info = parsed_ue_rnti.get(ue_id, {})
                        rnti = rnti_info.get('rnti', 0)
                        log("INFO", f"[F1U] ESTABLISHED: UE_ID={ue_id} RNTI={rnti:#06x} "
                                    f"TEID_CU={teid_incoming:#010x} TEID_DU={teid_outgoing:#010x} "
                                    f"DU={remote_addr}")
                        break
            continue

        # --- Try Update tunnel fallback ---
        m = TUNNEL_UPDATE_FALLBACK_RE.search(line)
        if m:
            ue_id = int(m.group(1))
            teid_incoming = int(m.group(2), 16)
            teid_outgoing = int(m.group(3), 16)
            remote_addr = m.group(4)
            
            # *** ONLY PROCESS F1-U TUNNELS ***
            if remote_addr != DU_F1U_IP:
                continue
            
            if ue_id in f1u_tunnels:
                for t in f1u_tunnels[ue_id]:
                    if t['teid_cu'] == teid_incoming and not t['established']:
                        t['teid_du'] = teid_outgoing
                        t['du_addr'] = remote_addr
                        t['established'] = True
                        new_tunnels += 1

                        rnti_info = parsed_ue_rnti.get(ue_id, {})
                        rnti = rnti_info.get('rnti', 0)
                        log("INFO", f"[F1U] ESTABLISHED: UE_ID={ue_id} RNTI={rnti:#06x} "
                                    f"TEID_CU={teid_incoming:#010x} TEID_DU={teid_outgoing:#010x} "
                                    f"DU={remote_addr}")
                        break
            continue

    return new_tunnels


def get_f1u_teid_map_by_rnti():
    """
    Return RNTI -> list of F1-U tunnel info.
    ONLY returns established F1-U tunnels (to DU).
    """
    result = {}

    for ue_id, tunnels in f1u_tunnels.items():
        rnti_info = parsed_ue_rnti.get(ue_id, {})
        rnti = rnti_info.get('rnti', 0)

        if rnti == 0:
            continue

        established_tunnels = []
        for t in tunnels:
            if t['established'] and t['teid_du'] != 0 and t['teid_du'] != 0xffff:
                established_tunnels.append({
                    'ue_id': ue_id,
                    'cu_ue_id': rnti_info.get('cu_ue_id', ue_id),
                    'du_ue_id': rnti_info.get('du_ue_id', 0),
                    'rnti': rnti,
                    'rnti_hex': rnti_info.get('rnti_hex', f'{rnti:#06x}'),
                    'teid_cu': t['teid_cu'],    # CU F1-U TEID
                    'teid_du': t['teid_du'],    # DU TEID (for flow matching)
                    'du_addr': t['du_addr'],
                })

        if established_tunnels:
            result[rnti] = established_tunnels

    return result


def get_du_teids_for_flows():
    """
    Get DU TEIDs for OpenFlow rule installation.
    Returns dict: RNTI -> list of DU TEIDs
    """
    teid_map = get_f1u_teid_map_by_rnti()
    result = {}

    for rnti, tunnels in teid_map.items():
        du_teids = [t['teid_du'] for t in tunnels]
        if du_teids:
            result[rnti] = du_teids

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
# Phase 3: F1-U Flow Installation (IP-BASED for Aruba)
# ============================================================

# CU and DU IPs for flow matching
CU_IP = "192.168.71.140"
DU_IP = "192.168.74.151"


def set_f1u_flow_by_ip(device_id, src_ip, dst_ip, udp_port=2152, queue_id="7"):
    """Install F1-U flow based on IP addresses (works on Aruba 2930F)."""
    flow_data = {
        "priority": 50000,
        "timeout": 0,
        "isPermanent": True,
        "deviceId": device_id,
        "treatment": {
            "instructions": [{"type": "QUEUE", "queueId": queue_id, "port": "1"}]
        },
        "selector": {
            "criteria": [
                {"type": "ETH_TYPE", "ethType": "0x0800"},
                {"type": "IP_PROTO", "protocol": 17},
                {"type": "UDP_DST", "udpPort": udp_port},
                {"type": "IPV4_SRC", "ip": f"{src_ip}/32"},
                {"type": "IPV4_DST", "ip": f"{dst_ip}/32"},
            ]
        }
    }
    
    cmd = [
        "curl",
        "--interface", INTERFACE,
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-u", "karaf:karaf",
        "-d", json.dumps(flow_data),
        f"{ONOS_URL}/flows/{device_id}"
    ]
    return subprocess.run(cmd, capture_output=True, text=True)


def check_and_install_teid_flows():
    """
    Install F1-U flows using IP-based matching.
    
    Since Aruba 2930F doesn't support GTP TEID matching, we match on:
    - IP src/dst (CU ↔ DU)
    - UDP port 2152/2153 (GTP-U)
    """
    global installed_flows

    with state_lock:
        current_devices = dict(devices)
    if not current_devices:
        return 0

    # Get F1-U TEID map (for logging, even if we can't match on TEID)
    f1u_map = get_f1u_teid_map_by_rnti()
    
    if f1u_map:
        log("INFO", f"[F1U] {len(f1u_map)} UEs with established F1-U tunnels:")
        for rnti, tunnels in sorted(f1u_map.items()):
            for t in tunnels:
                log("INFO", f"    RNTI={rnti:#06x} TEID_CU={t['teid_cu']:#010x} "
                            f"TEID_DU={t['teid_du']:#010x} DU={t['du_addr']}")

    new_flows = 0

    for dev_id in current_devices:
        # F1-U Downlink: CU (192.168.71.140) → DU (192.168.74.151)
        for udp_port in [2152, 2153]:
            flow_key = (dev_id, "f1u_dl", udp_port)
            if flow_key not in installed_flows:
                log("INFO", f"  Installing F1-U DL flow: {CU_IP} → {DU_IP}:{udp_port} on {dev_id}")
                result = set_f1u_flow_by_ip(dev_id, CU_IP, DU_IP, udp_port)
                if result.returncode == 0:
                    installed_flows.add(flow_key)
                    new_flows += 1
                    log("INFO", f"    -> OK")
                else:
                    log("WARN", f"    -> FAILED: {result.stderr}")

        # F1-U Uplink: DU (192.168.74.151) → CU (192.168.71.140)
        for udp_port in [2152, 2153]:
            flow_key = (dev_id, "f1u_ul", udp_port)
            if flow_key not in installed_flows:
                log("INFO", f"  Installing F1-U UL flow: {DU_IP} → {CU_IP}:{udp_port} on {dev_id}")
                result = set_f1u_flow_by_ip(dev_id, DU_IP, CU_IP, udp_port)
                if result.returncode == 0:
                    installed_flows.add(flow_key)
                    new_flows += 1
                    log("INFO", f"    -> OK")
                else:
                    log("WARN", f"    -> FAILED: {result.stderr}")

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
    log("INFO", "xApp Daemon Starting (F1-U TEID parsing ONLY)")
    log("INFO", "=" * 70)
    log("INFO", f"CU logs directory: {CU_LOGS_DIR}")
    log("INFO", f"CU stdout log: {CU_STDOUT_LOG}")
    log("INFO", f"CU RRC stats: {CU_RRC_STATS_LOG}")
    log("INFO", f"")
    log("INFO", f"F1-U Filter Configuration:")
    log("INFO", f"  DU F1-U IP: {DU_F1U_IP} (CAPTURE)")
    log("INFO", f"  UPF N3 IP:  {UPF_N3_IP} (IGNORE)")
    log("INFO", f"  F1-U Instance: [{F1U_INSTANCE_ID}] (CAPTURE)")
    log("INFO", f"  N3 Instance:   [{N3_INSTANCE_ID}] (IGNORE)")

    # Check if logs directory is mounted
    if os.path.isdir(CU_LOGS_DIR):
        log("INFO", f"✓ CU logs directory is mounted")
        files = os.listdir(CU_LOGS_DIR)
        log("INFO", f"  Contents: {files if files else '(empty)'}")
    else:
        log("WARN", f"✗ CU logs directory not found at {CU_LOGS_DIR}")

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
    log("INFO", "Phase 5: Initial F1-U TEID parsing...")
    rrc_count = parse_rrc_stats()
    f1u_count = parse_cu_stdout_log()
    f1u_map = get_f1u_teid_map_by_rnti()
    log("INFO", f"  RRC stats: {len(parsed_ue_rnti)} UEs")
    log("INFO", f"  F1-U tunnels: {sum(len(t) for t in f1u_tunnels.values())} total")
    log("INFO", f"  Established F1-U (RNTI->TEID): {len(f1u_map)} UEs")

    # Print current F1-U TEID map
    if f1u_map:
        log("INFO", "  Current F1-U TEID map:")
        for rnti, tunnels in sorted(f1u_map.items()):
            for t in tunnels:
                log("INFO", f"    RNTI={rnti:#06x} TEID_CU={t['teid_cu']:#010x} "
                            f"TEID_DU={t['teid_du']:#010x}")

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
                    log("INFO", f"Subscribed to {new_nodes} new E2 node(s)")
                last_e2_poll = now

            # Parse CU logs + install flows
            if now - last_teid_check >= TEID_POLL_INTERVAL:
                parse_rrc_stats()
                parse_cu_stdout_log()
                new_flows = check_and_install_teid_flows()
                if new_flows > 0:
                    log("INFO", f"Installed {new_flows} new F1-U flow(s)")
                last_teid_check = now

            # Refresh ONOS
            if now - last_onos_refresh >= ONOS_REFRESH_INTERVAL:
                discover_onos_topology()
                last_onos_refresh = now

            # Status log every ~30s
            if loop_count % 30 == 0:
                f1u_map = get_f1u_teid_map_by_rnti()
                mac_ue_count = len(xapp_functs.MACCallback.ue_mac_map)
                
                log("INFO", f"[STATUS] E2:{len(subscribed_nodes)} | "
                            f"MAC:{mac_ue_count} UEs | "
                            f"F1U:{len(f1u_map)} UEs | "
                            f"Flows:{len(installed_flows)} | "
                            f"Switches:{len(devices)}")

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
