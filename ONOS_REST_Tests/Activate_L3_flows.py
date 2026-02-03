import json
import requests
from requests.auth import HTTPBasicAuth

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
        return f"Host ID: {self.id}, MAC: {self.mac}, VLAN: {self.vlan}, InnerVLAN: {self.innerVlan}, OuterTPID: {self.outerTpid}, Configured: {self.configured}, Suspended: {self.suspended}, IPAddresses: {self.ipAddresses}, Locations: {self.locations}"


onos_url = "http://192.168.71.168:8181/onos/v1"
auth = HTTPBasicAuth('karaf', 'karaf')
headers = {'Content-Type': 'application/json'}
protocols = {"ICMP": 1, "TCP": 6, "UDP": 17, "SCTP": 132}

def install_flow(flow, device_id):
    #url = f"http://{ONOS_IP}:8181/onos/v1/flows/{DEVICE_ID}"
    response = requests.post(onos_url+"/flows/"+device_id, auth=auth,
                             headers=headers, data=json.dumps(flow))
    print(response)
    if response.status_code in [200, 201]:
        print(f"Flow installed successfully: {flow['selector']}")
    else:
        print(f"Failed to install flow: {response.status_code} - {response.text}")




r = requests.get(f"{onos_url}/devices", auth=auth)
devices = {}
devices_from_onos = r.json()['devices']



host_list = []    
r = requests.get(f"{onos_url}/hosts", auth=auth)
for h in r.json()['hosts']:
    host_obj = host(h['id'], h['mac'], h['vlan'], h['innerVlan'], h['outerTpid'], h['configured'], h['suspended'], h['ipAddresses'], h['locations'])
    host_list.append(host_obj)
    devices[host_obj.locations[0]['elementId']].hosts_connected.append(host_obj)

print()
for sw in devices_from_onos:
    dev = sw['id']
    base_flow = {
    "priority": 1000,
    "timeout": 0,
    "isPermanent": True,
    "deviceId": dev,
    "treatment": {"instructions": [{"type": "OUTPUT", "port": "1"}]},
    "selector": {"criteria": [{"type": "ETH_DST", "mac": "aa:bb:cc:dd:ee:ff"}]}
    }
    install_flow(base_flow, dev)
    for proto_name, proto_num in protocols.items():
        L3_flow = {
            "priority": 4000,
            "timeout": 0,
            "isPermanent": False,
            "deviceId": dev,
            "treatment": {"instructions": [{"type": "OUTPUT", "port": "2"}]},
            "selector": [
                {"type": "ETH_TYPE", "ethType": "0x0800"},
                {"type": "IP_PROTO", "protocol": proto_num}
            ]
        }
        install_flow(L3_flow,dev)
        #reactive_flows.append(L3_flow)

