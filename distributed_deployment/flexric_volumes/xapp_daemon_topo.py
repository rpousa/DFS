#!/usr/bin/env python3
"""
Lightweight xApp:
  - Performs a one-shot topology survey via ONOS REST
  - Registers KPM-style reporting callbacks per E2 node type:
      * ngran_gNB_DU    -> MAC + RLC
      * ngran_gNB_CUUP  -> PDCP + GTP
      * ngran_gNB_CUCP  -> (none implemented)
"""

import os
import signal
import time
import xapp_sdk
import xapp_functs

from topology import (
    switch, flow, host,
    get_devices, get_flows, get_hosts,
    print_device_info,
)

# ------------------------------------------------------------------
# Config
# ------------------------------------------------------------------
ONOS_URL       = "http://192.168.0.193:8181/onos/v1"
INTERFACE      = "eth0"
REPORT_PERIOD  = xapp_sdk.Interval_ms_10
RUN_SECONDS    = 300            # lifetime of the xApp; set to None for forever
TYPES_ACCEPTED = ("ngran_gNB_CUUP", "ngran_gNB_DU", "ngran_gNB_CUCP")

# Graceful shutdown flag
_shutdown = False
def _handle_sig(signum, _frame):
    global _shutdown
    print(f"[xapp] Received signal {signum}, shutting down...")
    _shutdown = True

signal.signal(signal.SIGINT,  _handle_sig)
signal.signal(signal.SIGTERM, _handle_sig)


# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
def extract_criteria(criteria):
    """Build a dict of criteria by type for safe lookup."""
    return {c.get("type"): c for c in criteria}


def survey_topology():
    """One-shot ONOS topology survey. Returns dict[device_id] -> switch."""
    devices = {}
    devices_from_onos = get_devices(ONOS_URL, INTERFACE)

    for sw in devices_from_onos:
        switch_obj = switch(
            sw['id'], sw['type'], sw['available'], sw['role'],
            sw['mfr'], sw['hw'], sw['sw'], sw['serial'], sw['driver'],
            sw['chassisId'], sw['lastUpdate'], sw['humanReadableLastUpdate'],
            sw['annotations']['channelId'],
            sw['annotations']['managementAddress'],
            sw['annotations']['protocol'],
        )
        devices[switch_obj.id] = switch_obj

        r_flows = get_flows(ONOS_URL, INTERFACE, sw)
        for fl in r_flows['flows']:
            crits = fl["selector"]["criteria"]
            if len(crits) > 1:
                crit = extract_criteria(crits)
                if "IP_PROTO" in crit:
                    flow_obj = flow(
                        fl["groupId"], fl["state"], fl["liveType"], fl["packets"],
                        fl["id"], fl["priority"], fl["timeout"], fl["isPermanent"],
                        fl["deviceId"],
                        ip_dst=crit.get("IPV4_DST", {}).get("ip"),
                        ip_src=crit.get("IPV4_SRC", {}).get("ip"),
                        type_of_protocol=crit.get("IP_PROTO", {}).get("protocol"),
                    )
                else:  # UDP tunnel
                    flow_obj = flow(
                        fl["groupId"], fl["state"], fl["liveType"], fl["packets"],
                        fl["id"], fl["priority"], fl["timeout"], fl["isPermanent"],
                        fl["deviceId"],
                        ip_dst=None, ip_src=None,
                        type_of_protocol=crits[1].get("type"),
                        tun_id=crits[3].get("tunnelId"),
                        dynamic=True,
                    )
            else:  # Non-IP (pure Ethernet)
                flow_obj = flow(
                    fl["groupId"], fl["state"], fl["liveType"], fl["packets"],
                    fl["id"], fl["priority"], fl["timeout"], fl["isPermanent"],
                    fl["deviceId"],
                    None, None, "Ethernet",
                )
            switch_obj.flows.append(flow_obj)

    # Hosts
    hosts_from_onos = get_hosts(ONOS_URL, INTERFACE)
    for h in hosts_from_onos['hosts']:
        host_obj = host(
            h['id'], h['mac'], h['vlan'], h['innerVlan'], h['outerTpid'],
            h['configured'], h['suspended'], h['ipAddresses'], h['locations'],
        )
        devices[host_obj.locations[0]['elementId']].hosts_connected.append(host_obj)

    return devices


def register_kpm_callbacks(conn, storage):
    """Register KPM callbacks per E2 node type. Returns node_handlers dict."""
    node_handlers = {}

    for node_idx, con in enumerate(conn):
        nid       = con.id
        node_type = xapp_functs.classify_e2node(nid)
        print(f"[xapp] E2 Node [{node_idx}]: type = {node_type}")

        node_handlers[node_idx] = {'nid': nid, 'type': node_type}

        if node_type not in TYPES_ACCEPTED:
            print(f"[xapp]   -> Skipping (unsupported type)")
            continue

        if node_type == "ngran_gNB_DU":
            print("[xapp]   -> Registering MAC + RLC callbacks")
            storage.add_node(node_idx, node_type, ['mac', 'rlc'])
            mac_cb = xapp_functs.MACCallback(storage, node_idx)
            rlc_cb = xapp_functs.RLCCallback(storage, node_idx)
            node_handlers[node_idx]['mac_hndlr'] = xapp_sdk.report_mac_sm(nid, REPORT_PERIOD, mac_cb)
            node_handlers[node_idx]['rlc_hndlr'] = xapp_sdk.report_rlc_sm(nid, REPORT_PERIOD, rlc_cb)

        elif node_type == "ngran_gNB_CUUP":
            print("[xapp]   -> Registering PDCP + GTP callbacks")
            storage.add_node(node_idx, node_type, ['pdcp', 'gtp'])
            pdcp_cb = xapp_functs.PDCPCallback(storage, node_idx)
            gtp_cb  = xapp_functs.GTPCallback(storage, node_idx)
            node_handlers[node_idx]['pdcp_hndlr'] = xapp_sdk.report_pdcp_sm(nid, REPORT_PERIOD, pdcp_cb)
            node_handlers[node_idx]['gtp_hndlr']  = xapp_sdk.report_gtp_sm(nid, REPORT_PERIOD, gtp_cb)

        elif node_type == "ngran_gNB_CUCP":
            print("[xapp]   -> No KPM callbacks implemented for CU-CP")
            storage.add_node(node_idx, node_type, [''])

    return node_handlers


def deregister_callbacks(node_handlers):
    """Cleanly remove all registered SM handlers."""
    rm_map = {
        'mac_hndlr':  xapp_sdk.rm_report_mac_sm,
        'rlc_hndlr':  xapp_sdk.rm_report_rlc_sm,
        'pdcp_hndlr': xapp_sdk.rm_report_pdcp_sm,
        'gtp_hndlr':  xapp_sdk.rm_report_gtp_sm,
    }
    for idx, handlers in node_handlers.items():
        for key, hndlr in handlers.items():
            if key in rm_map:
                try:
                    rm_map[key](hndlr)
                except Exception as e:
                    print(f"[xapp] Failed to remove {key} for node {idx}: {e}")


# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
def main():
    # 1) Topology survey ---------------------------------------------------
    print("=" * 30 + " TOPOLOGY SURVEY " + "=" * 30)
    devices = survey_topology()
    print_device_info(devices)
    TOPO_REFRESH = 30  # seconds, or None to disable
    last_topo = time.time()
    # 2) E2 / KPM setup ----------------------------------------------------
    print("=" * 30 + " E2 / KPM SETUP " + "=" * 30)
    xapp_sdk.init()
    conn = xapp_sdk.conn_e2_nodes()
    assert len(conn) > 0, "No E2 nodes connected!"

    storage       = xapp_functs.Xapp_Metric_Storage()
    node_handlers = register_kpm_callbacks(conn, storage)

    print("[xapp] All callbacks registered. Collecting indications...")

    # 3) Run --------------------------------------------------------------
    start = time.time()
    try:
        while not _shutdown:
            time.sleep(1)
            if TOPO_REFRESH and (time.time() - last_topo) >= TOPO_REFRESH:
                devices = survey_topology()
                print_device_info(devices)
                last_topo = time.time()
            if RUN_SECONDS is not None and (time.time() - start) >= RUN_SECONDS:
                print(f"[xapp] Reached RUN_SECONDS={RUN_SECONDS}, exiting.")
                break
    finally:
        # 4) Cleanup ------------------------------------------------------
        print("[xapp] Deregistering callbacks...")
        deregister_callbacks(node_handlers)
        xapp_sdk.try_stop()
        print("[xapp] Stopped cleanly.")


if __name__ == "__main__":
    main()
