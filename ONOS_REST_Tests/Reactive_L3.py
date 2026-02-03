import json
import time
import requests
from requests.auth import HTTPBasicAuth


onos_url = "http://192.168.71.168:8181/onos/v1"
auth = HTTPBasicAuth('karaf', 'karaf')
headers = {'Content-Type': 'application/json'}
protocols = {"ICMP": 1, "TCP": 6, "UDP": 17, "SCTP": 132}

def install_flow(device_id, in_port, out_port, src_ip, dst_ip, proto):
    """Install flow matching IP src/dst and protocol"""
    flow = {
        "priority": 4000,
        "timeout": 30,
        "isPermanent": False,
        "deviceId": device_id,
        "treatment": {"instructions": [{"type": "OUTPUT", "port": str(out_port)}]},
        "selector": {
            "criteria": [
                {"type": "IN_PORT", "port": str(in_port)},
                {"type": "ETH_TYPE", "ethType": "0x0800"},
                {"type": "IPV4_SRC", "ip": f"{src_ip}/32"},
                {"type": "IPV4_DST", "ip": f"{dst_ip}/32"},
                {"type": "IP_PROTO", "protocol": proto}
            ]
        }
    }
    url = f"{onos_url}/flows/{device_id}"
    resp = requests.post(url, json=flow, auth=auth)
    print(f"[Flow Install] {device_id} {src_ip}->{dst_ip} proto={proto} "
          f"out:{out_port} status={resp.status_code}")

def clear_flows(device_id):
    """Remove all flows on device"""
    url = f"{onos_url}/flows/{device_id}"
    resp = requests.delete(url, auth=auth)
    print(f"[Clear Flows] {device_id} status={resp.status_code}")

def get_hosts():
    """Fetch hosts from ONOS to resolve dst -> location"""
    url = f"{onos_url}/hosts"
    resp = requests.get(url, auth=auth)
    if resp.status_code == 200:
        return resp.json().get("hosts", [])
    return []

def resolve_out_port(dst_ip, device_id):
    """Find the output port towards a given host"""
    hosts = get_hosts()
    for h in hosts:
        if "ipAddresses" in h and dst_ip in h["ipAddresses"]:
            loc = h["locations"][0]
            if loc["elementId"] == device_id:
                return loc["port"]  # directly connected
    return None  # unknown → fallback flood

def listen_packets():
    """Continuously poll packet-in events from ONOS"""
    url = f"{onos_url}/packets"
    print("[Reactive] Listening for packets...")
    while True:
        resp = requests.get(url, auth=auth, stream=False)
        print(resp)
        if resp.status_code != 200:
            print(f"[Error] Could not fetch packets, code={resp.status_code}")
            time.sleep(2)
            continue

        packets = resp.json().get("packets", [])
        for pkt in packets:
            device_id = pkt["deviceId"]
            in_port = pkt["port"]

            ipv4 = pkt.get("ipv4Packet")
            if not ipv4:
                continue  # ignore non-IPv4

            src_ip = ipv4["source"]
            dst_ip = ipv4["destination"]
            proto = ipv4.get("protocol")

            if proto not in protocols:
                continue

            out_port = resolve_out_port(dst_ip, device_id)
            if not out_port:
                out_port = "CONTROLLER"  # fallback (or FLOOD if supported)

            install_flow(device_id, in_port, out_port, src_ip, dst_ip, proto)

        time.sleep(1)

if __name__ == "__main__":
    # Example: clear flows on all devices before starting
    devices = requests.get(f"{onos_url}/devices", auth=auth).json()["devices"]
    for d in devices:
        clear_flows(d["id"])

    listen_packets()




