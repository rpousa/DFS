"""
teid_parser.py - Parse GTP TEID information from CU container logs.

For unified CU architecture, TEIDs are extracted from:
1. nrRRC_stats.log  → UE ID ↔ RNTI mapping
2. docker logs cu   → GTPU tunnel Create/Update events

Key insight: 
- "Update tunnel" with remote=192.168.74.151 (DU F1-U IP) contains the DU TEID
- "Create tunnel" with remote=192.168.71.134 (UPF IP) contains the N3 TEID
"""

import re
import subprocess
import time
import threading
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple
from enum import Enum

# ============================================================
# Configuration
# ============================================================
DU_F1U_IP = "192.168.74.151"   # DU's F1-U interface IP
UPF_N3_IP = "192.168.71.134"   # UPF's N3 interface IP
CU_CONTAINER = "cu"

# ============================================================
# Regex Patterns (matching your actual log format)
# ============================================================

# [GTPU] UE ID 1: Create tunnel TEID incoming 0x2c933859 outgoing 0x1 to remote IPv4 192.168.71.134, IPv6 ::, port 2152
TUNNEL_CREATE_RE = re.compile(
    r'\[GTPU\].*UE ID (\d+): Create tunnel '
    r'TEID incoming (0x[0-9a-fA-F]+) outgoing (0x[0-9a-fA-F]+) '
    r'to remote IPv4 ([\d.]+)'
)

# [GTPU] UE ID 1: Update tunnel TEID incoming 0xaa530c58 outgoing 0x78199bc8 to remote IPv4 192.168.74.151, IPv6 ::, port 2152
TUNNEL_UPDATE_RE = re.compile(
    r'\[GTPU\].*UE ID (\d+): Update tunnel '
    r'TEID incoming (0x[0-9a-fA-F]+) outgoing (0x[0-9a-fA-F]+) '
    r'to remote IPv4 ([\d.]+)'
)

# UE 0 CU UE ID 1 DU UE ID 64629 RNTI fc75
RRC_STATS_RE = re.compile(
    r'UE (\d+) CU UE ID (\d+) DU UE ID (\d+) RNTI ([0-9a-fA-F]+)'
)

# [NR_RRC] Bearer Context Setup: PDU Session ID=1, incoming TEID=0x00000001, Addr=192.168.71.134
BEARER_SETUP_RE = re.compile(
    r'\[NR_RRC\].*Bearer Context Setup: PDU Session ID=(\d+), '
    r'incoming TEID=(0x[0-9a-fA-F]+), Addr=([\d.]+)'
)

# ============================================================
# Data Classes
# ============================================================

class TunnelType(Enum):
    N3_UPF = "n3_upf"       # CU ↔ UPF (N3 interface)
    F1U_DU = "f1u_du"       # CU ↔ DU (F1-U interface)
    UNKNOWN = "unknown"


@dataclass
class GTPTunnel:
    """Represents a single GTP-U tunnel."""
    ue_id: int                      # CU UE ID
    teid_local: int                 # TEID on CU side (incoming)
    teid_remote: int                # TEID on remote side (outgoing)
    remote_addr: str                # Remote IP address
    tunnel_type: TunnelType         # N3 or F1-U
    pdu_session_id: int = 0         # PDU Session ID (if known)
    qfi: int = 0                    # QoS Flow Identifier
    timestamp: float = 0.0          # When this tunnel was created/updated
    is_established: bool = False    # True after Update (for F1-U)


@dataclass
class UEContext:
    """Complete UE context with RNTI and all tunnels."""
    cu_ue_id: int
    ue_idx: int = 0
    du_ue_id: int = 0
    rnti: int = 0
    rnti_hex: str = ""
    n3_tunnels: List[GTPTunnel] = field(default_factory=list)
    f1u_tunnels: List[GTPTunnel] = field(default_factory=list)
    last_seen: float = 0.0


# ============================================================
# Main Parser Class
# ============================================================

class CUTeidParser:
    """
    Parse TEID information from CU logs.
    
    Usage:
        parser = CUTeidParser()
        parser.parse_docker_logs()          # or parse_from_files(...)
        parser.parse_rrc_stats("/path/to/nrRRC_stats.log")
        
        # Get DU TEIDs by RNTI
        teid_map = parser.get_du_teid_by_rnti()
        for rnti, teids in teid_map.items():
            print(f"RNTI {rnti:#06x}: DU_TEIDs = {[hex(t) for t in teids]}")
    """
    
    def __init__(self, du_ip: str = DU_F1U_IP, upf_ip: str = UPF_N3_IP):
        self.du_ip = du_ip
        self.upf_ip = upf_ip
        
        # State
        self._ue_contexts: Dict[int, UEContext] = {}  # cu_ue_id -> UEContext
        self._lock = threading.Lock()
        self._lines_processed = 0
        self._last_parse_time = 0.0
        
    # --------------------------------------------------------
    # Parsing Methods
    # --------------------------------------------------------
    
    def parse_docker_logs(self, container: str = CU_CONTAINER) -> int:
        """Parse `docker logs <container>` for TEID information."""
        try:
            result = subprocess.run(
                ["docker", "logs", container],
                capture_output=True, text=True, timeout=30
            )
            lines = result.stdout.split('\n') + result.stderr.split('\n')
            return self._parse_lines(lines)
        except subprocess.TimeoutExpired:
            print(f"[TEID_PARSER] docker logs {container} timed out")
            return 0
        except FileNotFoundError:
            print("[TEID_PARSER] docker command not found")
            return 0
        except Exception as e:
            print(f"[TEID_PARSER] Error reading docker logs: {e}")
            return 0

    def parse_from_file(self, filepath: str) -> int:
        """Parse GTPU log from a file."""
        try:
            with open(filepath, 'r') as f:
                lines = f.readlines()
            return self._parse_lines(lines)
        except FileNotFoundError:
            return 0
        except Exception as e:
            print(f"[TEID_PARSER] Error reading {filepath}: {e}")
            return 0
    
    def parse_rrc_stats(self, filepath: str) -> int:
        """Parse nrRRC_stats.log for UE RNTI mapping."""
        try:
            with open(filepath, 'r') as f:
                content = f.read()
        except FileNotFoundError:
            return 0
        except Exception as e:
            print(f"[TEID_PARSER] Error reading RRC stats: {e}")
            return 0
        
        count = 0
        for m in RRC_STATS_RE.finditer(content):
            ue_idx = int(m.group(1))
            cu_ue_id = int(m.group(2))
            du_ue_id = int(m.group(3))
            rnti = int(m.group(4), 16)
            
            with self._lock:
                if cu_ue_id not in self._ue_contexts:
                    self._ue_contexts[cu_ue_id] = UEContext(cu_ue_id=cu_ue_id)
                
                ctx = self._ue_contexts[cu_ue_id]
                ctx.ue_idx = ue_idx
                ctx.du_ue_id = du_ue_id
                ctx.rnti = rnti
                ctx.rnti_hex = f"0x{m.group(4)}"
                ctx.last_seen = time.time()
                count += 1
        
        return count

    def parse_rrc_stats_from_container(self, container: str = CU_CONTAINER, 
                                        path: str = "nrRRC_stats.log") -> int:
        """Parse nrRRC_stats.log directly from CU container."""
        try:
            result = subprocess.run(
                ["docker", "exec", "-t", container, "cat", path],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode != 0:
                return 0
            
            count = 0
            for m in RRC_STATS_RE.finditer(result.stdout):
                ue_idx = int(m.group(1))
                cu_ue_id = int(m.group(2))
                du_ue_id = int(m.group(3))
                rnti = int(m.group(4), 16)
                
                with self._lock:
                    if cu_ue_id not in self._ue_contexts:
                        self._ue_contexts[cu_ue_id] = UEContext(cu_ue_id=cu_ue_id)
                    
                    ctx = self._ue_contexts[cu_ue_id]
                    ctx.ue_idx = ue_idx
                    ctx.du_ue_id = du_ue_id
                    ctx.rnti = rnti
                    ctx.rnti_hex = f"0x{m.group(4)}"
                    ctx.last_seen = time.time()
                    count += 1
            return count
        except Exception as e:
            print(f"[TEID_PARSER] Error reading RRC stats from container: {e}")
            return 0

    def _parse_lines(self, lines: List[str]) -> int:
        """Parse log lines for TEID information."""
        new_tunnels = 0
        now = time.time()
        
        for line in lines:
            self._lines_processed += 1
            
            # --- Create tunnel ---
            m = TUNNEL_CREATE_RE.search(line)
            if m:
                ue_id = int(m.group(1))
                teid_incoming = int(m.group(2), 16)
                teid_outgoing = int(m.group(3), 16)
                remote_addr = m.group(4)
                
                # Determine tunnel type
                if remote_addr == self.upf_ip:
                    tunnel_type = TunnelType.N3_UPF
                elif remote_addr == self.du_ip:
                    tunnel_type = TunnelType.F1U_DU
                elif remote_addr == "0.0.0.0" and teid_outgoing == 0xffff:
                    # F1-U pre-setup placeholder
                    tunnel_type = TunnelType.F1U_DU
                else:
                    tunnel_type = TunnelType.UNKNOWN
                
                tunnel = GTPTunnel(
                    ue_id=ue_id,
                    teid_local=teid_incoming,
                    teid_remote=teid_outgoing,
                    remote_addr=remote_addr,
                    tunnel_type=tunnel_type,
                    timestamp=now,
                    is_established=(tunnel_type == TunnelType.N3_UPF),
                )
                
                with self._lock:
                    if ue_id not in self._ue_contexts:
                        self._ue_contexts[ue_id] = UEContext(cu_ue_id=ue_id)
                    
                    ctx = self._ue_contexts[ue_id]
                    ctx.last_seen = now
                    
                    # Add to appropriate list (avoid duplicates)
                    if tunnel_type == TunnelType.N3_UPF:
                        if not any(t.teid_local == teid_incoming for t in ctx.n3_tunnels):
                            ctx.n3_tunnels.append(tunnel)
                            new_tunnels += 1
                    elif tunnel_type == TunnelType.F1U_DU:
                        if not any(t.teid_local == teid_incoming for t in ctx.f1u_tunnels):
                            ctx.f1u_tunnels.append(tunnel)
                            new_tunnels += 1
                continue
            
            # --- Update tunnel (F1-U establishment) ---
            m = TUNNEL_UPDATE_RE.search(line)
            if m:
                ue_id = int(m.group(1))
                teid_incoming = int(m.group(2), 16)
                teid_outgoing = int(m.group(3), 16)
                remote_addr = m.group(4)
                
                with self._lock:
                    if ue_id in self._ue_contexts:
                        ctx = self._ue_contexts[ue_id]
                        ctx.last_seen = now
                        
                        # Find matching F1-U tunnel and update it
                        for tunnel in ctx.f1u_tunnels:
                            if tunnel.teid_local == teid_incoming and not tunnel.is_established:
                                tunnel.teid_remote = teid_outgoing  # This is the DU TEID!
                                tunnel.remote_addr = remote_addr
                                tunnel.is_established = True
                                tunnel.timestamp = now
                                new_tunnels += 1
                                break
                continue
        
        self._last_parse_time = now
        return new_tunnels

    # --------------------------------------------------------
    # Query Methods
    # --------------------------------------------------------
    
    def get_du_teid_by_rnti(self) -> Dict[int, List[int]]:
        """
        Get DU TEIDs indexed by RNTI.
        
        Returns:
            Dict mapping RNTI (int) -> list of DU TEIDs (int)
        """
        result: Dict[int, List[int]] = {}
        
        with self._lock:
            for cu_ue_id, ctx in self._ue_contexts.items():
                if ctx.rnti == 0:
                    continue
                
                du_teids = []
                for tunnel in ctx.f1u_tunnels:
                    if tunnel.is_established and tunnel.teid_remote != 0xffff:
                        du_teids.append(tunnel.teid_remote)
                
                if du_teids:
                    result[ctx.rnti] = du_teids
        
        return result

    def get_full_teid_map(self) -> Dict[int, Dict]:
        """
        Get complete TEID information indexed by RNTI.
        
        Returns:
            Dict mapping RNTI -> {
                'cu_ue_id': int,
                'du_ue_id': int,
                'rnti_hex': str,
                'n3_tunnels': [{'teid_gnb': int, 'teid_upf': int}, ...],
                'f1u_tunnels': [{'teid_cu': int, 'teid_du': int, 'established': bool}, ...]
            }
        """
        result = {}
        
        with self._lock:
            for cu_ue_id, ctx in self._ue_contexts.items():
                if ctx.rnti == 0:
                    continue
                
                result[ctx.rnti] = {
                    'cu_ue_id': ctx.cu_ue_id,
                    'du_ue_id': ctx.du_ue_id,
                    'rnti_hex': ctx.rnti_hex,
                    'n3_tunnels': [
                        {
                            'teid_gnb': t.teid_local,
                            'teid_upf': t.teid_remote,
                            'upf_addr': t.remote_addr,
                        }
                        for t in ctx.n3_tunnels
                    ],
                    'f1u_tunnels': [
                        {
                            'teid_cu': t.teid_local,
                            'teid_du': t.teid_remote,
                            'du_addr': t.remote_addr,
                            'established': t.is_established,
                        }
                        for t in ctx.f1u_tunnels
                    ],
                }
        
        return result

    def get_ue_by_rnti(self, rnti: int) -> Optional[UEContext]:
        """Get UE context by RNTI."""
        with self._lock:
            for ctx in self._ue_contexts.values():
                if ctx.rnti == rnti:
                    return ctx
        return None

    def get_all_ues(self) -> List[UEContext]:
        """Get all UE contexts."""
        with self._lock:
            return list(self._ue_contexts.values())

    def get_stats(self) -> Dict:
        """Get parser statistics."""
        with self._lock:
            total_ues = len(self._ue_contexts)
            ues_with_rnti = sum(1 for ctx in self._ue_contexts.values() if ctx.rnti != 0)
            ues_with_f1u = sum(1 for ctx in self._ue_contexts.values() 
                              if any(t.is_established for t in ctx.f1u_tunnels))
            total_n3 = sum(len(ctx.n3_tunnels) for ctx in self._ue_contexts.values())
            total_f1u = sum(len(ctx.f1u_tunnels) for ctx in self._ue_contexts.values())
            established_f1u = sum(
                sum(1 for t in ctx.f1u_tunnels if t.is_established)
                for ctx in self._ue_contexts.values()
            )
        
        return {
            'total_ues': total_ues,
            'ues_with_rnti': ues_with_rnti,
            'ues_with_f1u': ues_with_f1u,
            'total_n3_tunnels': total_n3,
            'total_f1u_tunnels': total_f1u,
            'established_f1u_tunnels': established_f1u,
            'lines_processed': self._lines_processed,
            'last_parse_time': self._last_parse_time,
        }

    def print_summary(self):
        """Print a summary of parsed TEID information."""
        stats = self.get_stats()
        print(f"\n{'='*70}")
        print("CU TEID Parser Summary")
        print(f"{'='*70}")
        print(f"  Total UEs:           {stats['total_ues']}")
        print(f"  UEs with RNTI:       {stats['ues_with_rnti']}")
        print(f"  UEs with F1-U:       {stats['ues_with_f1u']}")
        print(f"  N3 Tunnels (to UPF): {stats['total_n3_tunnels']}")
        print(f"  F1-U Tunnels:        {stats['total_f1u_tunnels']} "
              f"({stats['established_f1u_tunnels']} established)")
        print(f"  Lines processed:     {stats['lines_processed']}")
        print()
        
        teid_map = self.get_full_teid_map()
        if teid_map:
            print("RNTI → TEID Mapping:")
            print(f"{'RNTI':<10} {'CU_UE_ID':<10} {'DU_UE_ID':<10} "
                  f"{'TEID_gNB (N3)':<14} {'TEID_UPF':<12} "
                  f"{'TEID_CU (F1)':<14} {'TEID_DU':<12} {'Status':<10}")
            print("-" * 100)
            
            for rnti, info in sorted(teid_map.items()):
                n3 = info['n3_tunnels'][0] if info['n3_tunnels'] else {}
                f1u = info['f1u_tunnels'][0] if info['f1u_tunnels'] else {}
                
                status = "✓" if f1u.get('established', False) else "…"
                
                print(f"{rnti:#06x}    "
                      f"{info['cu_ue_id']:<10} "
                      f"{info['du_ue_id']:<10} "
                      f"{n3.get('teid_gnb', 0):#010x}    "
                      f"{n3.get('teid_upf', 0):#010x}  "
                      f"{f1u.get('teid_cu', 0):#010x}    "
                      f"{f1u.get('teid_du', 0):#010x}  "
                      f"{status}")
        else:
            print("No RNTI → TEID mappings available yet")
        print()


# ============================================================
# Convenience Functions
# ============================================================

def parse_cu_teids(container: str = "cu", 
                   rrc_stats_path: str = "nrRRC_stats.log") -> CUTeidParser:
    """
    One-shot parse of CU TEIDs.
    
    Usage:
        parser = parse_cu_teids()
        parser.print_summary()
        
        # Get DU TEIDs for a specific RNTI
        du_teids = parser.get_du_teid_by_rnti()
    """
    parser = CUTeidParser()
    parser.parse_docker_logs(container)
    parser.parse_rrc_stats_from_container(container, rrc_stats_path)
    return parser


# ============================================================
# Main (for testing)
# ============================================================

if __name__ == "__main__":
    import sys
    
    container = sys.argv[1] if len(sys.argv) > 1 else "cu"
    
    print(f"Parsing TEIDs from container '{container}'...")
    parser = parse_cu_teids(container)
    parser.print_summary()
    
    # Show DU TEIDs for flow installation
    print("\nDU TEIDs for OpenFlow rules:")
    du_teid_map = parser.get_du_teid_by_rnti()
    for rnti, teids in sorted(du_teid_map.items()):
        print(f"  RNTI {rnti:#06x}: DU_TEIDs = {[f'{t:#010x}' for t in teids]}")
