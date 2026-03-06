import os
import time
import json
import subprocess

#"curl -u karaf:karaf -X POST http://192.168.71.168:8181/onos/v1/flows"

class switch:
    def __init__(self, id, type, available, role, mfr, hw, sw, serial, driver, chassisId, lastUpdate, humanReadableLastUpdate, channelId, managementAddress, protocol ):
        self.id = id
        self.type = type
        self.available = available
        self.role = role
        self.mfr = mfr
        self.hw = hw
        self.sw = sw
        self.serial = serial
        self.driver = driver
        self.chassisId = chassisId
        self.lastUpdate = lastUpdate
        self.humanReadableLastUpdate = humanReadableLastUpdate
        self.channelId = channelId
        self.managementAddress = managementAddress
        self.protocol = protocol
        self.flows = []
        self.hosts_connected = []
    
    def __str__(self):
        return f"Switch ID:{self.id}, Type:{self.type}, Available:{self.available}, Role:{self.role}, Mfr:{self.mfr}, HW:{self.hw}, SW:{self.sw}, Serial:{self.serial}, Driver:{self.driver}, ChassisId:{self.chassisId}, LastUpdate:{self.lastUpdate}, HumanReadableLastUpdate:{self.humanReadableLastUpdate}, ChannelId:{self.channelId}, ManagementAddress:{self.managementAddress}, Protocol:{self.protocol}"

class flow:
    def __init__(self, groupId, state, liveType, packets, id, priority, timeout, isPermanent, deviceId, ip_dst = None , ip_src = None, type_of_protocol = None, tun_id = None, dynamic=False):
        self.groupId = groupId
        self.state = state
        self.liveType = liveType
        self.packets = packets
        self.id = id
        self.priority = priority
        self.timeout = timeout
        self.isPermanent = isPermanent
        self.deviceId = deviceId
        self.ip_dst = ip_dst
        self.ip_src = ip_src
        self.type = type_of_protocol
        self.tun_id = tun_id
        self.dynamic = dynamic
    
    def __str__(self):
        return f"Flow ID:{self.id}, Priority:{self.priority}, Timeout:{self.timeout}, IsPermanent:{self.isPermanent}, DeviceId:{self.deviceId}, IP_DST:{self.ip_dst}, IP_SRC:{self.ip_src}, Type:{self.type}"

class host:
    def __init__(self, id, mac, vlan, innerVlan, outerTpid, configured, suspended, ipAddresses, locations):
        self.id = id
        self.mac = mac
        self.vlan = vlan
        self.innerVlan = innerVlan
        self.outerTpid = outerTpid
        self.configured = configured
        self.suspended = suspended
        self.ipAddresses = ipAddresses
        self.locations = locations
    
    def __str__(self):
        return f"Host ID:{self.id}, MAC:{self.mac}, VLAN:{self.vlan}, InnerVLAN:{self.innerVlan}, OuterTPID:{self.outerTpid}, Configured:{self.configured}, Suspended:{self.suspended}, IPAddresses:{self.ipAddresses}, Locations:{self.locations}"

def get_devices(onos_url, interface):
    cmd = [
        "curl",
        "--interface", interface,
        "-X", "GET",
        "-u", "karaf:karaf",
        f"{onos_url}/devices/"
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)    
    devices_from_onos = json.loads(result.stdout)["devices"]
    return devices_from_onos

def get_flows(onos_url, interface, sw):
    cmd = [
            "curl",
            "--interface", interface,
            "-X", "GET",
            "-u", "karaf:karaf",
            f"{onos_url}/flows/{sw['id']}"
            ]
    r_flows = json.loads(subprocess.run(cmd, capture_output=True, text=True).stdout)
    return r_flows

def get_hosts(onos_url, interface):
    cmd = [
            "curl",
            "--interface", interface,
            "-X", "GET",
            "-u", "karaf:karaf",
            f"{onos_url}/hosts"
            ]
    r = json.loads(subprocess.run(cmd, capture_output=True, text=True).stdout)
    return r

def print_device_info(devices):
    for d in devices.keys():
        print(d)
        print(devices[d].__str__())
        [print(h.__str__()) for h in devices[d].hosts_connected]
        [print(f.__str__()) for f in devices[d].flows]


def get_topology(onos_url, interface):
    cmd = [
            "curl",
            "--interface", interface,
            "-X", "GET",
            "-u", "karaf:karaf",
            f"{onos_url}/topology"
            ]
    topology_setup = json.loads(subprocess.run(cmd, capture_output=True, text=True).stdout)
    return topology_setup


def set_udp_flow_queue(onos_url, interface, tunnelID = 0x1234):
    # fix to check port_in and set port_out, no queues just flows priorities
    # fix als deviceIds and tunnelIDs
    Flow_and_queue_setup = {
            "priority": 50000,
            "timeout": 0,
            "isPermanent": True,
            "deviceId": "of:0000000000000002",
            "treatment": {
                "instructions": [ {"type": "QUEUE","queueId": "1","port": "1"} ]
            },
            "selector": {
                "criteria": [
                {"type": "ETH_TYPE","ethType": "0x0800"},
                {"type": "IP_PROTO","protocol": 17}, 
                {"type": "UDP_DST","udpPort": 2152}, 
                {"type": "TUNNEL_ID","tunnelId": 0x1234},
                ]
            }
        }
    cmd = ["curl",
            "--interface", interface,
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-u", "karaf:karaf",
            "-d", json.dumps(Flow_and_queue_setup).encode("utf-8"),
            f"{onos_url}/flows/of:0000000000000002"
            ]

    result_flow_setup = subprocess.run(cmd, capture_output=True, text=True)
    return result_flow_setup

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