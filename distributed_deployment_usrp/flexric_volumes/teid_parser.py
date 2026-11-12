"""
teid_parser.py - Parse F1-U TEID information from CU container logs.

For unified CU architecture, F1-U TEIDs are extracted from:
1. cu_stdout.log → GTPU instance [93] tunnel Create/Update events (F1-U only)
2. nrRRC_stats.log → UE ID ↔ RNTI mapping

Key insight:
- Instance [91] or [92] (port 2152) = N3 interface → UPF (IGNORE)
- Instance [93] (port 2153) = F1-U interface → DU (CAPTURE)
- "Update tunnel" with remote=192.168.74.151 contains the DU TEID
"""

import re
import os
import time
import threading
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple
from enum import Enum

# ============================================================
# Configuration
# ============================================================
DU_F1U_IP = "192.168.74.151"   # DU's F1-U interface IP
UPF_N3_IP = "192.168.71.134"   # UPF's N3 interface IP (IGNORE)

# Instance IDs from CU logs
F1U_INSTANCE_IDS = {"93"}      # F1-U instance (port 2153)
N3_INSTANCE_IDS = {"91", "92"} # N3 instances (port 2152) - IGNORE

# Log file paths (inside FlexRIC container)
CU_LOGS_DIR = "/usr/local/flexric/cu_logs"
CU_STDOUT_LOG = f"{CU_LOGS_DIR}/cu_stdout.log"
CU_RRC_STATS_LOG = f"{CU_LOGS_DIR}/nrRRC_stats.log"

# ============================================================
# Regex Patterns (matching actual CU log format)
# ============================================================

# Format: 1211068.259354 [GTPU]   I [93] UE ID 1: Create tunnel TEID incoming 0xb506b20 outgoing 0xffff to remote IPv4 0.0.0.0
TUNNEL_CREATE_RE = re.compile(
    r'\[GTPU\]\s+[A-Z]?\s*\[(\d+)\]\s+UE ID (\d+):\s*Create tunnel\s+'
    r'TEID incoming (0x[0-9a-fA-F]+)\s+outgoing (0x[0-9a-fA-F]+)\s+'
    r'to remote IPv4 ([\d.]+)',
    re.IGNORECASE
)

# Format: 1211068.266309 [GTPU]   I [93] UE ID 1: Update tunnel TEID incoming 0xb506b20 outgoing 0xf06cc720 to remote IPv4 192.168.74.151
TUNNEL_UPDATE_RE = re.compile(
    r'\[GTPU\]\s+[A-Z]?\s*\[(\d+)\]\s+UE ID (\d+):\s*Update tunnel\s+'
    r'TEID incoming (0x[0-9a-fA-F]+)\s+outgoing (0x[0-9a-fA-F]+)\s+'
    r'to remote IPv4 ([\d.]+)',
    re.IGNORECASE
)

# Fallback patterns without instance ID (older log formats)
TUNNEL_CREATE_FALLBACK_RE = re.compile(
    r'\[GTPU\].*UE ID (\d+):\s*Create tunnel\s+'
    r'TEID incoming (0x[0-9a-fA-F]+)\s+outgoing (0x[0-9a-fA-F]+)\s+'
    r'to remote IPv4 ([\d.]+)',
    re.IGNORECASE
)

TUNNEL_UPDATE_FALLBACK_RE = re.compile(
    r'\[GTPU\].*UE ID (\d+):\s*Update tunnel\s+'
    r'TEID incoming (0x[0-9a-fA-F]+)\s+outgoing (0x[0-9a-fA-F]+)\s+'
    r'to remote IPv4 ([\d.]+)',
    re.IGNORECASE
)

# RRC stats: UE 0 CU UE ID 1 DU UE ID 64629 RNTI fc75
RRC_STATS_RE = re.compile(
    r'UE\s+(\d+)\s+CU UE ID\s+(\d+)\s+DU UE ID\s+(\d+)\s+RNTI\s+([0-9a-fA-F]+)',
    re.IGNORECASE
)

# ============================================================
# Data Classes
# ============================================================

@dataclass
class F1UTunnel:
    """Represents a single F1-U GTP-U tunnel (CU ↔ DU)."""
    ue_id: int                      # CU UE ID
    teid_cu: int                    # CU-side F1-U TEID (incoming)
    teid_du: int                    # DU-side TEID (outgoing, after Update)
    du_addr: str                    # DU IP address
    instance_id: str                # GTPU instance ID (e.g., "93")
    established: bool = False       # True after Update with valid DU TEID
    timestamp: float = 0.0          # When this tunnel was last updated


@dataclass
class UEContext:
    """Complete UE context with RNTI and F1-U tunnels."""
    cu_ue_id: int
    ue_idx: int = 0
    du_ue_id: int = 0
    rnti: int = 0
    rnti_hex: str = ""
    f1u_tunnels: List[F1UTunnel] = field(default_factory=list)
    last_seen: float = 0.0


# ============================================================
# Main Parser Class - F1-U ONLY
# ============================================================

class F1UTeidParser:
    """
    Parse F1-U TEID information from CU logs.
    
    ONLY captures F1-U tunnels (CU ↔ DU), NOT N3 tunnels (CU ↔ UPF).
    
    Usage:
        parser = F1UTeidParser()
        parser.parse_log_file("/path/to/cu_stdout.log")
        parser.parse_rrc_stats("/path/to/nrRRC_stats.log")
        
        # Get DU TEIDs by RNTI (only newly discovered ones)
        new_tunnels = parser.get_new_established_tunnels()
        for rnti, tunnels in new_tunnels.items():
            print(f"RNTI {rnti:#06x}: DU_TEIDs = {[hex(t.teid_du) for t in tunnels]}")
    """
    
    def __init__(self, du_ip: str = DU_F1U_IP, upf_ip: str = UPF_N3_IP,
                 log_func=None):
        self.du_ip = du_ip
        self.upf_ip = upf_ip
        self._log = log_func or self._default_log
        
        # State
        self._ue_contexts: Dict[int, UEContext] = {}  # cu_ue_id -> UEContext
        self._lock = threading.Lock()
        
        # File tracking for incremental reads
        self._log_file_position = 0
        self._log_file_inode = None
        self._last_file_size = 0
        
        # Deduplication - track what we've already logged
        self._logged_creates: Set[Tuple[int, int]] = set()  # (ue_id, teid_cu)
        self._logged_updates: Set[Tuple[int, int, int]] = set()  # (ue_id, teid_cu, teid_du)
        self._reported_rnti_mappings: Set[int] = set()  # cu_ue_ids we've reported
        
        # Stats
        self._lines_processed = 0
        self._n3_skipped = 0
        self._f1u_creates = 0
        self._f1u_updates = 0
    
    def _default_log(self, level, msg):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{ts}] [{level}] {msg}", flush=True)

    # --------------------------------------------------------
    # Filtering: Is this an F1-U tunnel?
    # --------------------------------------------------------
    
    def _is_f1u_tunnel(self, instance_id: Optional[str], remote_addr: str, 
                        teid_outgoing: int) -> bool:
        """
        Determine if a tunnel is F1-U (to DU).
        
        Returns True for F1-U tunnels, False for N3 tunnels.
        """
        # Method 1: Check instance ID
        if instance_id:
            if instance_id in F1U_INSTANCE_IDS:
                return True
            if instance_id in N3_INSTANCE_IDS:
                return False
        
        # Method 2: Check remote address
        if remote_addr == self.du_ip:
            return True
        if remote_addr == self.upf_ip:
            return False
        
        # Method 3: F1-U pre-setup has remote 0.0.0.0 and outgoing 0xffff
        if remote_addr == "0.0.0.0" and teid_outgoing == 0xffff:
            return True
        
        return False

    # --------------------------------------------------------
    # Parsing Methods
    # --------------------------------------------------------
    
    def reset_state(self):
        """Reset all parsing state (called on file truncation/restart)."""
        with self._lock:
            self._ue_contexts.clear()
            self._logged_creates.clear()
            self._logged_updates.clear()
            self._reported_rnti_mappings.clear()
            self._log_file_position = 0
            self._last_file_size = 0
            self._lines_processed = 0
            self._n3_skipped = 0
            self._f1u_creates = 0
            self._f1u_updates = 0
        self._log("WARN", "[F1U_PARSER] State reset (file truncation or restart)")

    def parse_log_file(self, filepath: str = CU_STDOUT_LOG) -> int:
        """
        Parse CU stdout log for F1-U TEID information.
        Reads incrementally from last position.
        Returns number of NEW tunnels found.
        """
        try:
            if not os.path.exists(filepath):
                return 0
            
            stat_info = os.stat(filepath)
            current_size = stat_info.st_size
            current_inode = stat_info.st_ino
            
            # --- Truncation detection ---
            if current_size < self._log_file_position:
                self._log("WARN", f"[F1U_PARSER] File truncated: size={current_size} < pos={self._log_file_position}")
                self.reset_state()
            
            if self._log_file_inode is not None and current_inode != self._log_file_inode:
                self._log("WARN", f"[F1U_PARSER] File replaced: inode changed")
                self.reset_state()
            
            if current_size < self._last_file_size:
                self._log("WARN", f"[F1U_PARSER] File shrank")
                self.reset_state()
            
            self._log_file_inode = current_inode
            self._last_file_size = current_size
            
            # Nothing new to read
            if current_size == self._log_file_position:
                return 0
            
            with open(filepath, 'r') as f:
                f.seek(self._log_file_position)
                new_lines = f.readlines()
                self._log_file_position = f.tell()
            
        except FileNotFoundError:
            return 0
        except Exception as e:
            self._log("WARN", f"[F1U_PARSER] Read error: {e}")
            return 0
        
        if not new_lines:
            return 0
        
        return self._parse_lines(new_lines)

    def _parse_lines(self, lines: List[str]) -> int:
        """Parse log lines for F1-U TEID information. Returns new tunnel count."""
        new_tunnels = 0
        now = time.time()
        
        for line in lines:
            self._lines_processed += 1
            
            # --- Try Create tunnel with instance ID ---
            m = TUNNEL_CREATE_RE.search(line)
            if m:
                instance_id = m.group(1)
                ue_id = int(m.group(2))
                teid_incoming = int(m.group(3), 16)
                teid_outgoing = int(m.group(4), 16)
                remote_addr = m.group(5)
                
                # *** FILTER: F1-U ONLY ***
                if not self._is_f1u_tunnel(instance_id, remote_addr, teid_outgoing):
                    self._n3_skipped += 1
                    continue
                
                # Deduplication check
                create_key = (ue_id, teid_incoming)
                if create_key in self._logged_creates:
                    continue
                
                with self._lock:
                    if ue_id not in self._ue_contexts:
                        self._ue_contexts[ue_id] = UEContext(cu_ue_id=ue_id)
                    
                    ctx = self._ue_contexts[ue_id]
                    ctx.last_seen = now
                    
                    # Check for existing tunnel
                    exists = any(t.teid_cu == teid_incoming for t in ctx.f1u_tunnels)
                    if not exists:
                        tunnel = F1UTunnel(
                            ue_id=ue_id,
                            teid_cu=teid_incoming,
                            teid_du=0,
                            du_addr="",
                            instance_id=instance_id,
                            established=False,
                            timestamp=now,
                        )
                        ctx.f1u_tunnels.append(tunnel)
                        self._f1u_creates += 1
                        new_tunnels += 1
                        
                        # Log ONLY new creates
                        self._logged_creates.add(create_key)
                        rnti_info = self._ue_contexts.get(ue_id)
                        rnti = rnti_info.rnti if rnti_info else 0
                        self._log("INFO", f"[F1U] CREATE: UE_ID={ue_id} "
                                          f"RNTI={rnti:#06x} TEID_CU={teid_incoming:#010x} "
                                          f"(instance={instance_id})")
                continue
            
            # --- Try Create tunnel fallback ---
            m = TUNNEL_CREATE_FALLBACK_RE.search(line)
            if m:
                ue_id = int(m.group(1))
                teid_incoming = int(m.group(2), 16)
                teid_outgoing = int(m.group(3), 16)
                remote_addr = m.group(4)
                
                # *** FILTER: F1-U ONLY ***
                if not self._is_f1u_tunnel(None, remote_addr, teid_outgoing):
                    self._n3_skipped += 1
                    continue
                
                create_key = (ue_id, teid_incoming)
                if create_key in self._logged_creates:
                    continue
                
                with self._lock:
                    if ue_id not in self._ue_contexts:
                        self._ue_contexts[ue_id] = UEContext(cu_ue_id=ue_id)
                    
                    ctx = self._ue_contexts[ue_id]
                    ctx.last_seen = now
                    
                    exists = any(t.teid_cu == teid_incoming for t in ctx.f1u_tunnels)
                    if not exists:
                        tunnel = F1UTunnel(
                            ue_id=ue_id,
                            teid_cu=teid_incoming,
                            teid_du=0,
                            du_addr="",
                            instance_id="",
                            established=False,
                            timestamp=now,
                        )
                        ctx.f1u_tunnels.append(tunnel)
                        self._f1u_creates += 1
                        new_tunnels += 1
                        
                        self._logged_creates.add(create_key)
                        rnti = ctx.rnti
                        self._log("INFO", f"[F1U] CREATE: UE_ID={ue_id} "
                                          f"RNTI={rnti:#06x} TEID_CU={teid_incoming:#010x}")
                continue
            
            # --- Try Update tunnel with instance ID ---
            m = TUNNEL_UPDATE_RE.search(line)
            if m:
                instance_id = m.group(1)
                ue_id = int(m.group(2))
                teid_incoming = int(m.group(3), 16)
                teid_outgoing = int(m.group(4), 16)  # This is the DU TEID!
                remote_addr = m.group(5)
                
                # *** FILTER: F1-U ONLY ***
                if not self._is_f1u_tunnel(instance_id, remote_addr, teid_outgoing):
                    continue
                
                # Deduplication check
                update_key = (ue_id, teid_incoming, teid_outgoing)
                if update_key in self._logged_updates:
                    continue
                
                with self._lock:
                    if ue_id in self._ue_contexts:
                        ctx = self._ue_contexts[ue_id]
                        ctx.last_seen = now
                        
                        for t in ctx.f1u_tunnels:
                            if t.teid_cu == teid_incoming and not t.established:
                                t.teid_du = teid_outgoing  # *** THE DU TEID ***
                                t.du_addr = remote_addr
                                t.established = True
                                t.timestamp = now
                                self._f1u_updates += 1
                                new_tunnels += 1
                                
                                # Log ONLY new updates
                                self._logged_updates.add(update_key)
                                rnti = ctx.rnti
                                self._log("INFO", f"[F1U] ESTABLISHED: UE_ID={ue_id} "
                                                  f"RNTI={rnti:#06x} "
                                                  f"TEID_CU={teid_incoming:#010x} "
                                                  f"TEID_DU={teid_outgoing:#010x} "
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
                
                # *** FILTER: F1-U ONLY - must be DU IP ***
                if remote_addr != self.du_ip:
                    continue
                
                update_key = (ue_id, teid_incoming, teid_outgoing)
                if update_key in self._logged_updates:
                    continue
                
                with self._lock:
                    if ue_id in self._ue_contexts:
                        ctx = self._ue_contexts[ue_id]
                        ctx.last_seen = now
                        
                        for t in ctx.f1u_tunnels:
                            if t.teid_cu == teid_incoming and not t.established:
                                t.teid_du = teid_outgoing
                                t.du_addr = remote_addr
                                t.established = True
                                t.timestamp = now
                                self._f1u_updates += 1
                                new_tunnels += 1
                                
                                self._logged_updates.add(update_key)
                                rnti = ctx.rnti
                                self._log("INFO", f"[F1U] ESTABLISHED: UE_ID={ue_id} "
                                                  f"RNTI={rnti:#06x} "
                                                  f"TEID_CU={teid_incoming:#010x} "
                                                  f"TEID_DU={teid_outgoing:#010x} "
                                                  f"DU={remote_addr}")
                                break
                continue
        
        return new_tunnels

    def parse_rrc_stats(self, filepath: str = CU_RRC_STATS_LOG) -> int:
        """Parse nrRRC_stats.log for UE RNTI mapping. Returns new mapping count."""
        try:
            if not os.path.exists(filepath):
                return 0
            with open(filepath, 'r') as f:
                content = f.read()
        except FileNotFoundError:
            return 0
        except Exception as e:
            self._log("WARN", f"[RRC_STATS] Read error: {e}")
            return 0

        new_count = 0
        for m in RRC_STATS_RE.finditer(content):
            ue_idx = int(m.group(1))
            cu_ue_id = int(m.group(2))
            du_ue_id = int(m.group(3))
            rnti = int(m.group(4), 16)

            with self._lock:
                # Only log NEW mappings
                if cu_ue_id not in self._reported_rnti_mappings:
                    self._reported_rnti_mappings.add(cu_ue_id)
                    new_count += 1
                    self._log("INFO", f"[RRC_STATS] UE mapping: CU_UE_ID={cu_ue_id} "
                                      f"DU_UE_ID={du_ue_id} RNTI={rnti:#06x}")

                if cu_ue_id not in self._ue_contexts:
                    self._ue_contexts[cu_ue_id] = UEContext(cu_ue_id=cu_ue_id)

                ctx = self._ue_contexts[cu_ue_id]
                ctx.ue_idx = ue_idx
                ctx.du_ue_id = du_ue_id
                ctx.rnti = rnti
                ctx.rnti_hex = f'0x{m.group(4)}'
                ctx.last_seen = time.time()

        return new_count

    # --------------------------------------------------------
    # Query Methods
    # --------------------------------------------------------
    
    def get_du_teid_by_rnti(self) -> Dict[int, List[int]]:
        """
        Get DU TEIDs indexed by RNTI.
        Returns: Dict mapping RNTI (int) -> list of DU TEIDs (int)
        """
        result: Dict[int, List[int]] = {}
        
        with self._lock:
            for cu_ue_id, ctx in self._ue_contexts.items():
                if ctx.rnti == 0:
                    continue
                
                du_teids = []
                for tunnel in ctx.f1u_tunnels:
                    if tunnel.established and tunnel.teid_du != 0 and tunnel.teid_du != 0xffff:
                        du_teids.append(tunnel.teid_du)
                
                if du_teids:
                    result[ctx.rnti] = du_teids
        
        return result

    def get_full_teid_map(self) -> Dict[int, Dict]:
        """Get complete F1-U TEID information indexed by RNTI."""
        result = {}
        
        with self._lock:
            for cu_ue_id, ctx in self._ue_contexts.items():
                if ctx.rnti == 0:
                    continue
                
                result[ctx.rnti] = {
                    'cu_ue_id': ctx.cu_ue_id,
                    'du_ue_id': ctx.du_ue_id,
                    'rnti_hex': ctx.rnti_hex,
                    'f1u_tunnels': [
                        {
                            'teid_cu': t.teid_cu,
                            'teid_du': t.teid_du,
                            'du_addr': t.du_addr,
                            'established': t.established,
                            'instance_id': t.instance_id,
                        }
                        for t in ctx.f1u_tunnels
                    ],
                }
        
        return result

    def get_stats(self) -> Dict:
        """Get parser statistics."""
        with self._lock:
            total_ues = len(self._ue_contexts)
            ues_with_rnti = sum(1 for ctx in self._ue_contexts.values() if ctx.rnti != 0)
            established_tunnels = sum(
                sum(1 for t in ctx.f1u_tunnels if t.established)
                for ctx in self._ue_contexts.values()
            )
        
        return {
            'total_ues': total_ues,
            'ues_with_rnti': ues_with_rnti,
            'f1u_creates': self._f1u_creates,
            'f1u_updates': self._f1u_updates,
            'established_tunnels': established_tunnels,
            'n3_skipped': self._n3_skipped,
            'lines_processed': self._lines_processed,
            'file_position': self._log_file_position,
        }

    def print_summary(self):
        """Print a summary of parsed F1-U TEID information."""
        stats = self.get_stats()
        print(f"\n{'='*70}")
        print("F1-U TEID Parser Summary")
        print(f"{'='*70}")
        print(f"  Total UEs:           {stats['total_ues']}")
        print(f"  UEs with RNTI:       {stats['ues_with_rnti']}")
        print(f"  F1-U Creates:        {stats['f1u_creates']}")
        print(f"  F1-U Updates:        {stats['f1u_updates']}")
        print(f"  Established:         {stats['established_tunnels']}")
        print(f"  N3 Skipped:          {stats['n3_skipped']}")
        print(f"  Lines processed:     {stats['lines_processed']}")
        print()
        
        teid_map = self.get_full_teid_map()
        if teid_map:
            print("RNTI → F1-U TEID Mapping:")
            print(f"{'RNTI':<10} {'CU_UE_ID':<10} {'TEID_CU':<14} {'TEID_DU':<14} {'Status':<10}")
            print("-" * 60)
            
            for rnti, info in sorted(teid_map.items()):
                for t in info['f1u_tunnels']:
                    status = "✓" if t['established'] else "…"
                    print(f"{rnti:#06x}    "
                          f"{info['cu_ue_id']:<10} "
                          f"{t['teid_cu']:#010x}    "
                          f"{t['teid_du']:#010x}    "
                          f"{status}")
        else:
            print("No F1-U TEID mappings available yet")
        print()


# ============================================================
# Singleton instance for use in xapp_daemon.py
# ============================================================
_parser_instance: Optional[F1UTeidParser] = None

def get_parser(log_func=None) -> F1UTeidParser:
    """Get singleton parser instance."""
    global _parser_instance
    if _parser_instance is None:
        _parser_instance = F1UTeidParser(log_func=log_func)
    return _parser_instance


# ============================================================
# Main (for testing)
# ============================================================
if __name__ == "__main__":
    import sys
    
    log_file = sys.argv[1] if len(sys.argv) > 1 else CU_STDOUT_LOG
    rrc_file = sys.argv[2] if len(sys.argv) > 2 else CU_RRC_STATS_LOG
    
    print(f"Parsing F1-U TEIDs from '{log_file}'...")
    parser = F1UTeidParser()
    parser.parse_log_file(log_file)
    parser.parse_rrc_stats(rrc_file)
    parser.print_summary()
    
    print("\nDU TEIDs for OpenFlow rules:")
    du_teid_map = parser.get_du_teid_by_rnti()
    for rnti, teids in sorted(du_teid_map.items()):
        print(f"  RNTI {rnti:#06x}: DU_TEIDs = {[f'{t:#010x}' for t in teids]}")
