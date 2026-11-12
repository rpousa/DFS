#!/usr/bin/env python3
"""Create distributed_deployment_usrp from distributed_deployment.

New testbed (Nov 2026):
  * all three machines on one switch, LAN 192.168.1.0/24
      core 192.168.1.210, centraloffice 192.168.1.219, edge 192.168.1.221
  * centraloffice: UE (nr-uesoftmodem) on its own USRP over two SFP+ links
  * edge:          DU (nr-softmodem)    on its own USRP over two SFP+ links

Run from DFS/:  python3 make_usrp_dir.py
"""
import os
import re
import shutil
import sys

SRC = "distributed_deployment"
DST = "distributed_deployment_usrp"
EXCLUDE = {"old_scripts", "stable_scripts", "__pycache__", "logs", "results", "testing"}

IP_MAP = [
    ("192.168.0.200", "192.168.1.210"),  # core
    ("192.168.0.193", "192.168.1.219"),  # centraloffice
    ("192.168.0.243", "192.168.1.221"),  # edge
    ("172.31.54.33", "192.168.1.210"),   # Grafana / reloc-ctl bind (core had a second address)
]


def die(msg):
    sys.exit(f"error: {msg}")


if not os.path.isdir(SRC):
    die(f"run from DFS/ ({SRC} not found)")
if os.path.exists(DST):
    die(f"{DST} already exists")

shutil.copytree(SRC, DST, ignore=lambda d, names: [n for n in names if n in EXCLUDE])

# ---------------------------------------------------------------- 1. IPs ---
changed = []
for root, _, files in os.walk(DST):
    for fn in files:
        p = os.path.join(root, fn)
        try:
            with open(p, "rb") as f:
                b = f.read()
            s = b.decode("utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        t = s
        for a, b2 in IP_MAP:
            t = re.sub(re.escape(a) + r"(?![0-9])", b2, t)
        if t != s:
            with open(p, "w", encoding="utf-8", newline="") as f:
                f.write(t)
            changed.append(os.path.relpath(p, DST))

# two addresses on the core became one: drop repeated port mappings
for comp in ("docker-compose-core.yml", "docker-compose-observability.yml"):
    p = os.path.join(DST, comp)
    lines = open(p, newline="").read().split("\n")
    out = []
    for ln in lines:
        if re.match(r'^\s+- "?[0-9.]+:\d+:\d+(/\w+)?"?\s*$', ln) and ln in out[-6:]:
            continue
        out.append(ln)
    open(p, "w", newline="").write("\n".join(out))


def rd(rel):
    return open(os.path.join(DST, rel), newline="").read()


def wr(rel, s):
    with open(os.path.join(DST, rel), "w", newline="") as f:
        f.write(s)


def rep(s, old, new, rel, count=1):
    n = s.count(old)
    if n != count:
        die(f"{rel}: expected {count}x {old[:60]!r}, found {n}")
    return s.replace(old, new)


def macvlan_nets(prefix, if0, if1):
    return f"""
  # ---- USRP links (SFP+), one macvlan network per link, MTU 9000 on the parent.
  # The radio container gets its own address on each link, so UHD streams
  # straight to it (no NAT); the host keeps its own address there for probing.
  usrp_sfp0:
    driver: macvlan
    driver_opts:
      parent: ${{{prefix}_SFP0_IF:-{if0}}}
    ipam:
      config:
        - subnet: ${{{prefix}_SFP0_SUBNET:-192.168.10.0/24}}
          gateway: ${{{prefix}_SFP0_GW:-192.168.10.254}}

  usrp_sfp1:
    driver: macvlan
    driver_opts:
      parent: ${{{prefix}_SFP1_IF:-{if1}}}
    ipam:
      config:
        - subnet: ${{{prefix}_SFP1_SUBNET:-192.168.20.0/24}}
          gateway: ${{{prefix}_SFP1_GW:-192.168.20.254}}
"""


# ------------------------------------------------------- 2. edge compose ---
rel = "docker-compose-edge.yml"
s = rd(rel)
i, j = s.index("\n  du_e1:\n"), s.index("\n  ue_0:\n")
du = s[i:j]
du = rep(du, """      core_net:
        ipv4_address: 192.168.81.151
""", """      core_net:
        ipv4_address: 192.168.81.151
      usrp_sfp0:
        ipv4_address: ${EDGE_DU_SFP0_IP:-192.168.10.10}
      usrp_sfp1:
        ipv4_address: ${EDGE_DU_SFP1_IP:-192.168.20.10}
""", rel)
du = rep(du, "    ipc: host\n", "", rel)
du = rep(du, "      - ./configs/du_e1/gnb-du.sa.band78.106prb.vrtsim.yaml:/opt/oai-gnb/etc/gnb.yaml\n",
         "      - ./configs/du_e1/gnb-du.sa.band78.273prb.usrp.yaml:/opt/oai-gnb/etc/gnb.yaml\n", rel)
du = rep(du, "      - vrtsim_ipc:/vrtsim\n", "", rel)
du = rep(du, """        --device.name vrtsim
        --vrtsim.connection_descriptor /vrtsim/vrtsim_connection
        --vrtsim.timescale 0.4
""", """        --RUs.[0].sdr_addrs ${EDGE_SDR_ARGS:?set EDGE_SDR_ARGS in .env}
        --RUs.[0].att_tx ${EDGE_ATT_TX:-0}
        --RUs.[0].att_rx ${EDGE_ATT_RX:-0}
        --RUs.[0].max_rxgain ${EDGE_MAX_RXGAIN:-75}
""", rel)
du = rep(du, "        --thread-pool 5,6,7,8\n", "        --thread-pool ${EDGE_DU_THREAD_POOL:-5,6,7,8,9,10,11,12}\n", rel)
du = rep(du, "        --L1s.[0].L1_tx_thread_core 3\n",
         "        --L1s.[0].L1_tx_thread_core 3\n        ${EDGE_DU_EXTRA_OPTS:-}\n", rel)
du = rep(du, '    cpuset: "3-8"\n    cpus: 6.0\n',
         '    cpuset: "${EDGE_DU_CPUSET:-3-20}"   # the UE has left this machine: its cores go to the DU\n'
         '    cpus: ${EDGE_DU_CPUS:-18.0}\n', rel)
du = rep(du, "    cpu_shares: 8192            # absolute top priority — RFSim server\n",
         "    cpu_shares: 8192            # absolute top priority — radio\n", rel)
du = rep(du, '      sh -c "sleep 5 &&\n',
         '      sh -c "sleep 5 &&\n'
         '             ip route replace default via 192.168.81.129 &&\n', rel)
du = rep(du, "    cap_add:\n      - NET_ADMIN\n      - SYS_NICE\n",
         "    cap_add:\n      - NET_ADMIN\n      - SYS_NICE\n      - IPC_LOCK\n", rel)
k = s.index("\nnetworks:\n")
s = (s[:i] + du + "\n\n  # ue_0 moved to the centraloffice (docker-compose-centraloffice.yml), on its own USRP.\n\n"
     + s[k:])
s = rep(s, "\n# ==========================================\n# Volumes", macvlan_nets("EDGE", "eno10np0", "eno13np3")
        + "\n# ==========================================\n# Volumes", rel)
wr(rel, s)

# ------------------------------------------------ 3. centraloffice compose ---
rel = "docker-compose-centraloffice.yml"
s = rd(rel)
ue = """
  # ==========================================
  # UE on the centraloffice USRP (two SFP+ links). One UE, three PDU
  # sessions (eMBB / URLLC / mIoT). Started by deploy-ue.sh once the edge DU
  # is on air; it needs no docker network besides its USRP links.
  # ==========================================
  ue_0:
    image: ue:comnetsemu
    container_name: ue_0
    hostname: ue_0
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_NICE
      - IPC_LOCK
    networks:
      usrp_sfp0:
        ipv4_address: ${CO_UE_SFP0_IP:-192.168.10.10}
      usrp_sfp1:
        ipv4_address: ${CO_UE_SFP1_IP:-192.168.20.10}
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./configs/ue_1/nrue0.usrp.yaml:/opt/oai-nr-ue/etc/nr-ue.yaml
      - ./configs/ue_1/uecap_ports2.xml:/opt/oai-nr-ue/etc/uecap.xml
      - ./logs/ue_0:/opt/oai-nr-ue/logs
    environment:
      USE_ADDITIONAL_OPTIONS: >-
        --usrp-args ${CO_SDR_ARGS:?set CO_SDR_ARGS in .env}
        -r 273 --numerology 1 --band 78 -C 3450720000
        --ssb 1518
        --ue-nb-ant-tx 2 --ue-nb-ant-rx 2
        --ue-fo-compensation
        --uecap_file /opt/oai-nr-ue/etc/uecap.xml
        --log_config.global_log_options level,nocolor,time
        ${CO_UE_EXTRA_OPTS:-}
    cpuset: "${CO_UE_CPUSET:-2-13}"
    cpus: ${CO_UE_CPUS:-12.0}
    cpu_shares: 8192
    oom_score_adj: -700
    ulimits:
      memlock: -1
      nofile: 1048576
      rtprio: 99
    command: >
      sh -c "sleep 1 &&
             /tini -sv -- /opt/oai-nr-ue/bin/entrypoint.sh /opt/oai-nr-ue/bin/nr-uesoftmodem 2>&1 "

"""
s = rep(s, "\n\n# ==========================================\n# Networks Configuration", ue
        + "\n# ==========================================\n# Networks Configuration", rel)
s = s.rstrip("\n") + "\n" + macvlan_nets("CO", "eno11np1", "eno12np2")
wr(rel, s)

# ------------------------------------------------------ 4. radio configs ---
rel = "configs/du_e1/gnb-du.sa.band78.106prb.vrtsim.yaml"
s = rd(rel)
nl = "\r\n" if "\r\n" in s else "\n"
cut = s.index("channelmod:")
s = s[:cut].rstrip() + nl
s = rep(s, "  - local_rf: yes" + nl, "  - local_rf: yes" + nl
        + '    sdr_addrs: "addr=192.168.10.2,second_addr=192.168.20.2,clock_source=internal,time_source=internal"' + nl
        + "    clock_src: internal" + nl + "    time_src: internal" + nl, rel)
s = ("# DU on the edge USRP (two SFP+ links, 2x2, 273 PRB / 100 MHz, band 78)." + nl
     + "# sdr_addrs, gains and attenuation are overridden from .env by docker-compose-edge.yml." + nl + s)
wr("configs/du_e1/gnb-du.sa.band78.273prb.usrp.yaml", s)

rel = "configs/ue_1/nrue0.vrtsim.yaml"
s = rd(rel)
nl = "\r\n" if "\r\n" in s else "\n"
s = s[:s.index("vrtsim:")].rstrip() + nl
s = rep(s, "thread-pool: \"-1,-1,-1,-1,-1,-1,-1,-1\"   # 8 workers: ue_0 has cores 9-20 (one UE, 3 slices, 273 PRB 2x2)",
        "thread-pool: \"-1,-1,-1,-1,-1,-1,-1,-1\"   # 8 workers inside CO_UE_CPUSET (one UE, 3 slices, 273 PRB 2x2)", rel)
wr("configs/ue_1/nrue0.usrp.yaml", "# UE on the centraloffice USRP. USRP args come from .env (docker-compose-centraloffice.yml)." + nl + s)

# ------------------------------------------------------- 5. edge deploy ---
rel = "deploy-edge.sh"
s = rd(rel)
s = rep(s, '# Stage 3/7: DU_e1 (F1-U cross-machine to CO) + DU_e2 (F1-U local)\nprint_stage "Stage 3/7: Starting DU_e1 ..."\n',
        '# Stage 3/7: DU_e1 on the edge USRP (F1-U cross-machine to CO)\nprint_stage "Stage 3/7: Starting DU_e1 (USRP) ..."\n'
        'bash ./setup-usrp-host.sh edge --check || print_warn "USRP links not ready -- see setup-usrp-host.sh edge"\n', rel)
a = s.index("# Stage 5/7: UEs (connect to DU_e1)")
b = s.index("# Stage 6/7: Observability agents")
s = s[:a] + ("# Stage 5/7: the UE now runs on the centraloffice, on its own USRP.\n"
             "print_stage \"Stage 5/7: UE -- run ./deploy-ue.sh on the centraloffice once the DU is on air\"\n"
             "echo \"\"\n\n") + s[b:]
a = s.index("# Stage 7/7: UE connection verification")
b = s.index("# ==========================================\n# Final Verification")
s = s[:a] + ("# Stages 7-8 (UE sessions, slice stress) moved to deploy-ue.sh on the centraloffice.\n\n") + s[b:]
s = rep(s, 'print_info "UE summary: ${UES_WITH_IP:-0}/${CONNECTED_UES:-0}/3 UEs attached to DU_e1"\n',
        'print_info "Next: on the centraloffice (${CO_IP}), ./deploy-ue.sh"\n', rel)
wr(rel, s)

rel = "deploy-centraloffice.sh"
s = rd(rel)
s = rep(s, 'print_info "Next: On Edge ($EDGE_IP), run ./deploy-edge.sh"\n',
        'print_info "Next: On Edge ($EDGE_IP), run ./deploy-edge.sh, then here ./deploy-ue.sh (UE on this USRP)"\n', rel)
wr(rel, s)

print(f"created {DST}: {len(changed)} files with new IPs")
for c in sorted(changed):
    print("  ", c)
