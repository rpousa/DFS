#!/bin/bash

# Configuration Generator for Multi-PC Deployment
# Generates configuration templates with correct IP addresses

set -e

echo "=========================================="
echo "5G Multi-PC Configuration Generator"
echo "=========================================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# Get deployment type
echo "Select deployment mode:"
echo "  1) Core PC (192.168.0.193)"
echo "  2) RAN PC (192.168.0.243)"
echo "  3) All-in-one (single PC)"
read -p "Enter choice [1-3]: " DEPLOY_MODE

case $DEPLOY_MODE in
    1)
        CORE_IP="192.168.0.193"
        RAN_IP="192.168.0.243"
        MODE="core"
        ;;
    2)
        CORE_IP="192.168.0.193"
        RAN_IP="192.168.0.243"
        MODE="ran"
        ;;
    3)
        read -p "Enter PC IP address: " PC_IP
        CORE_IP="$PC_IP"
        RAN_IP="$PC_IP"
        MODE="allinone"
        ;;
esac

print_info "Configuration mode: $MODE"
print_info "Core PC: $CORE_IP"
print_info "RAN PC: $RAN_IP"
echo ""

# Create AMF configuration template
create_amf_config() {
    cat > configs/amf/config.yaml << EOF
################################################################################
# AMF Configuration File
################################################################################
amf:
  instance_id: 0
  pid_directory: /var/run
  
  # Bind to all interfaces to accept connections from RAN PC
  n2:
    interface_name: eth0
    interface: eth0
    addr: 0.0.0.0          # Listen on all interfaces
    port: 38412
  
  # SBI Configuration - point to NRF on Core PC
  sbi:
    interface_name: eth0
    interface: eth0
    addr: 192.168.71.132   # Internal Docker IP
    port: 80
    api_version: v1
    http2_port: 8080
  
  # NRF Configuration - use physical IP for cross-PC
  nrf:
    ipv4: $CORE_IP         # Physical IP of Core PC
    port: 8080
    api_version: v1
    fqdn: nrf
  
  # Database
  mysql:
    server: $CORE_IP       # Physical IP
    user: test
    pass: test
    database: oai_db
  
  # GUAMI Configuration
  guami:
    mcc: 001
    mnc: 01
    region_id: 128
    amf_set_id: 1
    amf_pointer: 0
  
  # Served GUAMI List
  served_guami_list:
    - mcc: 001
      mnc: 01
      region_id: 128
      amf_set_id: 1
      amf_pointer: 0
  
  # PLMNs Support List
  plmn_support_list:
    - mcc: 001
      mnc: 01
      tac: 0x0001
      nssai:
        - sst: 1
          sd: 0x000001
  
  # Logging
  log_level:
    amf: debug
    nas: debug
    ngap: debug
    general: debug
EOF
}

# Create CU-CP configuration template  
create_cucp_config() {
    cat > configs/cucp/gnb.conf << EOF
Active_gNBs = ( "gNB-OAI");

gNBs = ({
    gNB_ID = 0xe00;
    gNB_name  = "gNB-OAI";
    gNB_CU = 1;
    
    # ========== AMF Configuration ==========
    # CRITICAL: Point to Core PC physical IP
    amf_ip_address = ({
        ipv4       = "$CORE_IP";     # Physical IP of Core PC
        ipv6       = "::";
        port       = 38412;
        active     = "yes";
        preference = "ipv4";
    });
    
    # ========== NGAP Configuration ==========
    NETWORK_INTERFACES : {
        GNB_INTERFACE_NAME_FOR_S1_MME = "eth0";
        GNB_IPV4_ADDRESS_FOR_S1_MME   = "0.0.0.0/24";
        GNB_INTERFACE_NAME_FOR_S1U    = "eth0";
        GNB_IPV4_ADDRESS_FOR_S1U      = "0.0.0.0/24";
        GNB_PORT_FOR_S1U              = 2152;
    };
    
    # ========== PLMN Configuration ==========
    tracking_area_code  =  1;
    plmn_list = ({
        mcc = 001;
        mnc = 01;
        mnc_length = 2;
        snssaiList = ({
            sst = 1;
            sd  = 0x000001;
        });
    });
    
    # ========== E1 Configuration (CU-CP to CU-UP) ==========
    enable_x2 = "no";
    enable_e1  = "yes";
    
    # ========== Logging ==========
    log_config : {
        global_log_level                      = "info";
        global_log_verbosity                  = "medium";
        hw_log_level                          = "info";
        hw_log_verbosity                      = "medium";
        phy_log_level                         = "info";
        phy_log_verbosity                     = "medium";
        mac_log_level                         = "info";
        mac_log_verbosity                     = "high";
        rlc_log_level                         = "info";
        rlc_log_verbosity                     = "medium";
        pdcp_log_level                        = "info";
        pdcp_log_verbosity                    = "medium";
        rrc_log_level                         = "info";
        rrc_log_verbosity                     = "medium";
        ngap_log_level                        = "debug";
        ngap_log_verbosity                    = "medium";
    };
});

MACRLCs = ({
    num_cc = 1;
    tr_s_preference = "local_L1";
    local_s_if_name  = "lo:";
    remote_s_address = "127.0.0.2";
    local_s_address  = "127.0.0.1"; 
    local_s_portc    = 50001;
    remote_s_portc   = 50000;
    local_s_portd    = 50011;
    remote_s_portd   = 50010;
});

L1s = ({
    num_cc = 1;
    tr_n_preference = "local_mac";
    prach_dtx_threshold = 120;
});

RUs = ({
    local_rf = "yes"
    nb_tx     = 1;
    nb_rx     = 1;
    att_tx    = 0;
    att_rx    = 0;
    bands      = [78];
    max_pdschReferenceSignalPower = -27;
    max_rxgain                    = 114;
    eNB_instances  = [0];
});
EOF
}

# Create NRF configuration
create_nrf_config() {
    cat > configs/nrf/config.yaml << EOF
nrf:
  instance_id: 0
  pid_directory: /var/run
  
  sbi:
    interface_name: eth0
    addr: 0.0.0.0        # Listen on all interfaces
    port: 80
    api_version: v1
    http2_port: 8080
  
  log_level:
    nrf: debug
    sbi: debug
    general: debug
EOF
}

# Create SMF configuration
create_smf_config() {
    cat > configs/smf/config.yaml << EOF
smf:
  instance_id: 0
  pid_directory: /var/run
  
  sbi:
    interface_name: eth0
    addr: 192.168.71.133
    port: 80
    api_version: v1
    http2_port: 8080
  
  nrf:
    ipv4: $CORE_IP       # Physical IP of Core PC
    port: 8080
    api_version: v1
  
  # UPF Configuration
  upf_list:
    - host: $CORE_IP     # Physical IP
      port: 8805
      nwi_list:
        - nwi: access
          dnn: oai
  
  local_subscription_infos:
    - single_nssai:
        sst: 1
        sd: 1
      dnn: oai
      qos_profile:
        5qi: 9
        session_ambr_ul: 1000Mbps
        session_ambr_dl: 1000Mbps
  
  log_level:
    smf: debug
    pfcp: debug
    general: debug
EOF
}

# Create UPF configuration
create_upf_config() {
    cat > configs/upf/config.yaml << EOF
upf:
  instance_id: 0
  pid_directory: /var/run
  
  sbi:
    interface_name: eth0
    addr: 192.168.71.134
    port: 80
    api_version: v1
  
  nrf:
    ipv4: $CORE_IP       # Physical IP of Core PC
    port: 8080
    api_version: v1
  
  # N3 interface (to RAN)
  n3:
    interface_name: eth0
    addr: 192.168.71.134
    port: 2152
  
  # N4 interface (PFCP to SMF)
  n4:
    interface_name: eth0
    addr: 192.168.71.134
    port: 8805
  
  # N6 interface (to DN)
  n6:
    interface_name: eth1
    addr: 192.168.72.134
  
  # DNN Configuration
  dnns:
    - dnn: oai
      pdu_session_type: IPv4
      ipv4_subnet: 12.1.1.0/24
  
  log_level:
    upf: debug
    pfcp: debug
    gtpu: debug
    general: debug
EOF
}

# Main execution
print_info "Creating configuration directories..."
mkdir -p configs/{mysql,nrf,amf,smf,pcf,nssf,udm,udr,ausf,upf,upf_1,ext_dn,ext_dn_1,cucp,cuup,du_1,ue_1,flexric,l2_proxy}
mkdir -p logs

if [ "$MODE" == "core" ] || [ "$MODE" == "allinone" ]; then
    print_info "Generating Core Network configurations..."
    create_nrf_config
    create_amf_config
    create_smf_config
    create_upf_config
fi

if [ "$MODE" == "ran" ] || [ "$MODE" == "allinone" ]; then
    print_info "Generating RAN configurations..."
    create_cucp_config
fi

print_info "Configuration templates created!"
echo ""
echo "IMPORTANT: These are templates. You must:"
echo "  1. Review each configuration file"
echo "  2. Add missing parameters specific to your setup"
echo "  3. Verify IP addresses match your deployment"
echo "  4. Configure subscriber information in MySQL"
echo ""
echo "Configuration files location:"
echo "  Core NFs: ./configs/{nrf,amf,smf,upf}/"
echo "  RAN: ./configs/{cucp,cuup,du_1}/"
echo ""
