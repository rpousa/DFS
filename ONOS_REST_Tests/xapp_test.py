import os
import xapp_sdk
import time
from topology import switch, flow, host, get_devices, get_flows, get_hosts, print_device_info, get_topology, set_udp_flow_queue
import xapp_functs


if __name__ == "__main__":
    devices = {}
    onos_url = "http://192.168.71.168:8181/onos/v1"
    interface = "eth0"
    devices_from_onos = get_devices(onos_url, interface)
    # global maps
    ue_to_slices = {}   # rnti -> {'dl_id': , 'ul_id': }
    ue_to_gtp = {}      # rnti -> [{'teidgnb':, 'teidupf':, 'qfi':, ...}, ...]

    for sw in devices_from_onos:
        switch_obj = switch(sw['id'], sw['type'], sw['available'], sw['role'], sw['mfr'], sw['hw'], sw['sw'], sw['serial'], sw['driver'], sw['chassisId'], sw['lastUpdate'], sw['humanReadableLastUpdate'], sw['annotations']['channelId'], sw['annotations']['managementAddress'], sw['annotations']['protocol'])
        devices[switch_obj.id] = switch_obj
        r_flows = get_flows(onos_url, interface, sw)

        flows = r_flows['flows']
        for fl in flows:
            if len(fl["selector"]["criteria"]) >1: # L3 flows 
                if fl["selector"]["criteria"][2].get(type) == "IP_PROTO":
                    flow_obj = flow(fl["groupId"],fl["state"], fl["liveType"], fl["packets"], fl["id"], fl["priority"], fl["timeout"], fl["isPermanent"], fl["deviceId"],
                                ip_dst=fl["selector"]["criteria"][4].get("ip"), ip_src=fl["selector"]["criteria"][3].get("ip"), type_of_protocol=fl["selector"]["criteria"][2].get("protocol"))
                else: # UDP tunnel
                    flow_obj = flow(fl["groupId"],fl["state"], fl["liveType"], fl["packets"], fl["id"], fl["priority"], fl["timeout"], fl["isPermanent"], fl["deviceId"],
                                ip_dst=None, ip_src=None, type_of_protocol=fl["selector"]["criteria"][1].get("type"), tun_id=fl["selector"]["criteria"][3].get("tunnelId"),
                                dynamic = True)
            else: # Non IP flows
                flow_obj = flow(fl["groupId"],fl["state"], fl["liveType"], fl["packets"], fl["id"], fl["priority"], fl["timeout"], fl["isPermanent"], fl["deviceId"],
                                None, None, "Ethernet")
            switch_obj.flows.append(flow_obj)
    
    host_list = []
    hosts_from_onos = get_hosts(onos_url, interface)

    for h in hosts_from_onos['hosts']:
        host_obj = host(h['id'], h['mac'], h['vlan'], h['innerVlan'], h['outerTpid'], h['configured'], h['suspended'], h['ipAddresses'], h['locations'])
        host_list.append(host_obj)
        devices[host_obj.locations[0]['elementId']].hosts_connected.append(host_obj)

    print("===================================FINALIZED DEVICE SURVEY===================================")
    print_device_info(devices)

    #print("===================================TOPOLOGY SETUP===================================")
    #topology_setup = get_topology(onos_url, interface)
    #print(topology_setup)
    
    print("===================================SET UDP FLOW===================================")
    print(set_udp_flow_queue(onos_url, interface))

    
    # initialize xapp framework (if required by your env)
    xapp_sdk.init()
    conn = xapp_sdk.conn_e2_nodes()
    assert(len(conn) > 0)
    node_idx = 0
    node_handlers = {}
    types_accepted = ["ngran_gNB_CUUP","ngran_gNB_DU","ngran_gNB_CUCP"]

    storage = xapp_functs.Xapp_Metric_Storage()

    for node_idx, con in enumerate(conn):
        nid = con.id
        node_handlers[node_idx] = {}
        node_handlers[node_idx]['nid'] = nid   
        node_type = xapp_functs.classify_e2node(nid)        
        print("Global E2 Node [" + str(node_idx) + "]: Node Type = " + str(node_type))

        
        if node_type in types_accepted:
            print(f"Registering stats callbacks for node type: {node_type}")
            if node_type == "ngran_gNB_DU":
                print("Registering MAC and RLC stats callback for DU node.")
                storage.add_node(node_idx, node_type, ['mac','rlc','gtp'])        
                mac_cb, rlc_cb, gtp_cb= xapp_functs.MACCallback(storage,node_idx), xapp_functs.RLCCallback(storage,node_idx),xapp_functs.GTPCallback(storage,node_idx) 
                node_handlers[node_idx]['mac_hndlr'] = xapp_sdk.report_mac_sm(nid, xapp_sdk.Interval_ms_10, mac_cb)                
                node_handlers[node_idx]['rlc_hndlr'] = xapp_sdk.report_rlc_sm(nid, xapp_sdk.Interval_ms_10, rlc_cb)
                node_handlers[node_idx]['gtp_hndlr'] = xapp_sdk.report_gtp_sm(nid, xapp_sdk.Interval_ms_10, gtp_cb)

            elif node_type == "ngran_gNB_CUUP":
                print("Registering GTP and PDCP stats callback for CU-UP node.")
                storage.add_node(node_idx, node_type, ['pdcp','gtp'])        
                pdcp_cb, gtp_cb = xapp_functs.PDCPCallback(storage,node_idx), xapp_functs.GTPCallback(storage,node_idx)
                node_handlers[node_idx]['pdcp_hndlr'] = xapp_sdk.report_pdcp_sm(nid, xapp_sdk.Interval_ms_10, pdcp_cb)
            elif node_type == "ngran_gNB_CUCP":
                storage.add_node(node_idx, node_type, ['gtp'])
                gtp_cb = xapp_functs.GTPCallback(storage,node_idx)
                node_handlers[node_idx]['gtp_hndlr'] = xapp_sdk.report_gtp_sm(nid, xapp_sdk.Interval_ms_10, gtp_cb)
                print("No stats callbacks implemented for CU-CP nodes yet.")

    print("All callbacks registered, waiting for indications...")
    time.sleep(10)  # wait/run for 10 seconds
    #print(storage)

    for i in range(0, len(conn)):  
        for hdlr in node_handlers[i]:
            if hdlr != 'nid':
                if hdlr == 'mac_hndlr':  xapp_sdk.rm_report_mac_sm(node_handlers[i][hdlr])
                if hdlr == 'rlc_hndlr':  xapp_sdk.rm_report_rlc_sm(node_handlers[i][hdlr])
                if hdlr == 'pdcp_hndlr': xapp_sdk.rm_report_pdcp_sm(node_handlers[i][hdlr])
                if hdlr == 'gtp_hndlr':  xapp_sdk.rm_report_gtp_sm(node_handlers[i][hdlr]) 

    xapp_sdk.try_stop()

    # register callbacks (id and inter parameters depend on your platform; use 0/None for default)
    #slice_cb = SliceCb()
    #gtp_cb = GtpCb()
    #xapp_sdk.report_slice_sm(conn[node_idx].id, xapp_sdk.Interval_ms_1, slice_cb)
    #xapp_sdk.report_gtp_sm(conn[node_idx].id, xapp_sdk.Interval_ms_1, gtp_cb)

    #print("Registered slice and gtp callbacks, waiting for indications...")
    # try:
    #     # run for a while, printing maps periodically
    #     for _ in range(60):
    #         time.sleep(1)
    #         if _ % 5 == 0:
    #             dump_maps()
    # finally:
    #     # cleanup registrations
    #     xapp_sdk.rm_report_slice_sm(0)
    #     xapp_sdk.rm_report_gtp_sm(0)
    #     xapp_sdk.try_stop()


    #{'id': 'AE:96:D1:27:79:73/None', 'mac': 'AE:96:D1:27:79:73', 'vlan': 'None', 'innerVlan': 'None', 'outerTpid': '0x0000', 'configured': False, 'suspended': False, 'ipAddresses': ['192.168.71.138'], 'locations': [{'elementId': 'of:0000000000000001', 'port': '4'}]}
    #if __name__ == "__main__":
        #while True:
        #    try:
        #        response = REST_request(session, base_url, "KMAC", base_json)
        #        json_response = response.json()
        #       
        #        print(json_response)
        #        if response.ok: print(response)
        #        else:print("Error in the request")
        #    except Exception as e:
        #        print(e)
        #        pass
        #    time.sleep(5)ls