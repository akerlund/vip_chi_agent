################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_driver_hni.sv -- HN-I pass-through ordering proxy.
#
#   RN[0..N_RN-1] <==(RN-facing, HNI role)==> HN-I <==(SN-facing, RNI role)==> SN[0..N_SN-1]
#
# On each RN-facing bus the proxy plays the completer (reads REQ, sources
# RSP/DAT); on each SN-facing bus it plays the requester (sends REQ, reads
# RSP/DAT). Pure per-flit verbatim relay (whole packed flit forwarded, no TxnID
# remap). Routing is stateless-per-transaction:
#   * REQ (RN->SN): pick a pending RN (highest QoS), address-decode to an SN.
#   * CompAck-RSP / write-DAT (RN->SN): follow active_sn_of_rn[p].
#   * completion-RSP / read-DAT (SN->RN): route by flit.tgtid via port_of_node.
# Flow control is strict lock-step (grant one credit, return after forwarding),
# so each RN is single-outstanding. N_SN=1 collapses the address decode.
#
# Buses + cfg are assigned by the proxy env before run_phase. The env owns no
# rst_n watcher for the proxy, so this component runs its own (mirrors the SV
# parent's fork/disable-fork on reset).
#
################################################################################

from __future__ import annotations

import cocotb
from cocotb.triggers import FallingEdge, First

from pyuvm import uvm_component

from vip_chi_types_pkg import (
  ReqOpcode, RspOpcode,
  req_opcode_is_atomic, req_opcode_is_atomic_returning_data,
)
from vip_chi_lcrd_mgr import VipChiLcrdMgr
from vip_chi_cfg_agent import VipChiCfgAgent

_I = int

# Transaction kinds -> which observable event settles (frees) the SN.
_TXN_READ = "READ"        # last CompData beat relayed to the RN
_TXN_WRITE = "WRITE"      # last write-data beat (+ deferred Comp for split) to SN/RN
_TXN_RSP_ONLY = "RSP_ONLY"  # terminal completion RSP relayed to the RN (persist/zero)
_TXN_NO_COMP = "NO_COMP"  # nothing comes back (PrefetchTgt); settled at forward time

_TERMINAL_RSP = {int(RspOpcode.COMP), int(RspOpcode.COMP_DBID_RESP),
                 int(RspOpcode.COMP_PERSIST)}
_SPLIT_WRITE_GRANT = {int(RspOpcode.DBID_RESP), int(RspOpcode.DBID_RESP_ORD)}
_WRITE_COMP = {int(RspOpcode.COMP), int(RspOpcode.COMP_DBID_RESP)}


class vip_chi_driver_hni(uvm_component):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.rn_buses = []        # RN-facing ChiBus list (HNI role), assigned by env
    self.sn_buses = []        # SN-facing ChiBus list (RNI role), assigned by env
    self.cfg = None
    self.sam = None           # SAM addr->SN table (None -> stride decode)
    self.sn_addr_lsb = 12
    self.arb_window_cycles = 0
    self._tasks = []

  def build_phase(self):
    if self.cfg is None:
      self.cfg = VipChiCfgAgent("hni_default_cfg")

  # ==========================================================================
  # State (re)initialization -- sized to the assigned bus lists.
  # ==========================================================================
  def _init_state(self):
    n_rn = len(self.rn_buses)
    n_sn = len(self.sn_buses)

    self.rn_rsp_send = [VipChiLcrdMgr(f"rn_rsp_send_{i}") for i in range(n_rn)]
    self.rn_dat_send = [VipChiLcrdMgr(f"rn_dat_send_{i}") for i in range(n_rn)]
    self.sn_req_send = [VipChiLcrdMgr(f"sn_req_send_{j}") for j in range(n_sn)]
    self.sn_rsp_send = [VipChiLcrdMgr(f"sn_rsp_send_{j}") for j in range(n_sn)]
    self.sn_dat_send = [VipChiLcrdMgr(f"sn_dat_send_{j}") for j in range(n_sn)]
    self.reset_credit_state()

  def reset_credit_state(self):
    n_rn = len(self.rn_buses)
    n_sn = len(self.sn_buses)
    cfg = self.cfg

    for m in self.rn_rsp_send:
      m.reset(cfg.rsp_send_credit_cap, 0)
    for m in self.rn_dat_send:
      m.reset(cfg.dat_send_credit_cap, 0)
    for m in self.sn_req_send:
      m.reset(cfg.req_send_credit_cap, 0)
    for m in self.sn_rsp_send:
      m.reset(cfg.rsp_send_credit_cap, 0)
    for m in self.sn_dat_send:
      m.reset(cfg.dat_send_credit_cap, 0)

    self.rn_req_lcrdv_pending = [0] * n_rn
    self.rn_rsp_lcrdv_pending = [0] * n_rn
    self.rn_dat_lcrdv_pending = [0] * n_rn
    self.rn_link_up = [False] * n_rn
    self.active_sn_of_rn = [0] * n_rn

    self.sn_rsp_lcrdv_pending = [0] * n_sn
    self.sn_dat_lcrdv_pending = [0] * n_sn
    self.sn_link_up = [False] * n_sn

    self.req_slot = [0] * n_rn          # raw REQ flit int per RN
    self.req_fields = [None] * n_rn     # unpacked REQ dict per RN
    self.req_pending = [False] * n_rn
    self.req_qos = [0] * n_rn

    self.port_of_node = {}
    self.active_busy = False
    self.active_port = 0
    self.active_kind = _TXN_READ
    self.active_write_split = False
    self.active_write_data_done = False
    self.active_write_comp_done = False

    self.qos_rr_cursor = 0
    self.rsp_rr_cursor = 0
    self.dat_rr_cursor = 0
    self.sn_rsp_rr_cursor = 0
    self.sn_dat_rr_cursor = 0

  # ==========================================================================
  # Interface reset.
  # ==========================================================================
  def reset_outputs(self):
    for rn in self.rn_buses:
      rn.drive(txlinkactivereq=0, txlinkactiveack=0, txsactive=0, txreqlcrdv=0,
               txrspflitpend=0, txrspflitv=0, txrsplcrdv=0,
               txdatflitpend=0, txdatflitv=0, txdatlcrdv=0)
      rn.drive_flit("rsp", {})
      rn.drive_flit("dat", {})
    for sn in self.sn_buses:
      sn.drive(txlinkactivereq=0, txlinkactiveack=0, txsactive=0,
               txreqflitpend=0, txreqflitv=0,
               txrspflitpend=0, txrspflitv=0, txrsplcrdv=0,
               txdatflitpend=0, txdatflitv=0, txdatlcrdv=0)
      sn.drive_flit("req", {})
      sn.drive_flit("rsp", {})
      sn.drive_flit("dat", {})

  def reset_vif(self):
    self.reset_outputs()

  def handle_reset(self):
    self.reset_credit_state()
    self.reset_outputs()

  def drive_rn_idle_sideband(self, p):
    rn = self.rn_buses[p]
    rn.drive(txlinkactiveack=rn.get("rxlinkactivereq"))

  def drive_sn_idle_sideband(self, s):
    sn = self.sn_buses[s]
    sn.drive(txlinkactiveack=sn.get("rxlinkactivereq"))

  # ==========================================================================
  # run_phase: own rst_n watcher (the proxy env forks nothing for us).
  # ==========================================================================
  def _reset_link_buses(self):
    # SV waits for all RN and SN links and resets on any of them going down.
    return list(self.rn_buses) + list(self.sn_buses)

  async def run_phase(self):
    self._init_state()
    bus = self.rn_buses[0]              # shared clock reference (all links share clk)
    self.reset_outputs()
    while True:
      while any(b.in_reset() for b in self._reset_link_buses()):
        await bus.rising()
      self._tasks = []
      self._tasks.append(cocotb.start_soon(self.qos_forwarder()))
      self._tasks.append(cocotb.start_soon(self.arbiter_rsp_rn_to_sn()))
      self._tasks.append(cocotb.start_soon(self.arbiter_dat_rn_to_sn()))
      self._tasks.append(cocotb.start_soon(self.router_rsp_sn_to_rn()))
      self._tasks.append(cocotb.start_soon(self.router_dat_sn_to_rn()))
      for p in range(len(self.rn_buses)):
        self._tasks.append(cocotb.start_soon(self.rn_credit_loop(p)))
        self._tasks.append(cocotb.start_soon(self.rn_activate(p)))
        self._tasks.append(cocotb.start_soon(self.capture_req(p)))
      for s in range(len(self.sn_buses)):
        self._tasks.append(cocotb.start_soon(self.sn_credit_loop(s)))
        self._tasks.append(cocotb.start_soon(self.sn_activate(s)))

      await First(*[FallingEdge(b.rst_n) for b in self._reset_link_buses()])
      for t in self._tasks:
        try:
          if not t.done():
            t.kill()
        except Exception:
          pass
      self._tasks = []
      self.handle_reset()

  # ==========================================================================
  # Per-RN / per-SN credit + link loops.
  # ==========================================================================
  async def rn_credit_loop(self, p):
    rn = self.rn_buses[p]
    while True:
      await rn.rising()
      self.drive_rn_idle_sideband(p)
      rn.drive(txsactive=1 if self.rn_link_up[p] else 0,
               txreqlcrdv=1 if self.rn_req_lcrdv_pending[p] else 0,
               txrsplcrdv=1 if self.rn_rsp_lcrdv_pending[p] else 0,
               txdatlcrdv=1 if self.rn_dat_lcrdv_pending[p] else 0)
      if self.rn_req_lcrdv_pending[p]:
        self.rn_req_lcrdv_pending[p] -= 1
      if self.rn_rsp_lcrdv_pending[p]:
        self.rn_rsp_lcrdv_pending[p] -= 1
      if self.rn_dat_lcrdv_pending[p]:
        self.rn_dat_lcrdv_pending[p] -= 1
      if rn.get("rxrsplcrdv"):
        self.rn_rsp_send[p].return_credit()
      if rn.get("rxdatlcrdv"):
        self.rn_dat_send[p].return_credit()

  async def sn_credit_loop(self, s):
    sn = self.sn_buses[s]
    while True:
      await sn.rising()
      self.drive_sn_idle_sideband(s)
      sn.drive(txsactive=1 if self.sn_link_up[s] else 0,
               txrsplcrdv=1 if self.sn_rsp_lcrdv_pending[s] else 0,
               txdatlcrdv=1 if self.sn_dat_lcrdv_pending[s] else 0)
      if self.sn_rsp_lcrdv_pending[s]:
        self.sn_rsp_lcrdv_pending[s] -= 1
      if self.sn_dat_lcrdv_pending[s]:
        self.sn_dat_lcrdv_pending[s] -= 1
      if sn.get("rxreqlcrdv"):
        self.sn_req_send[s].return_credit()
      if sn.get("rxrsplcrdv"):
        self.sn_rsp_send[s].return_credit()
      if sn.get("rxdatlcrdv"):
        self.sn_dat_send[s].return_credit()

  async def rn_activate(self, p):
    rn = self.rn_buses[p]
    await rn.rising()
    while rn.rst_n.value and not rn.get("rxlinkactivereq"):
      await rn.rising()
    self.rn_req_lcrdv_pending[p] += 1
    self.rn_rsp_lcrdv_pending[p] += 1
    self.rn_dat_lcrdv_pending[p] += 1
    self.rn_link_up[p] = True

  async def sn_activate(self, s):
    sn = self.sn_buses[s]
    await sn.rising()
    sn.drive(txlinkactivereq=1)
    await sn.rising()
    while sn.rst_n.value and not sn.get("rxlinkactiveack"):
      await sn.rising()
    self.sn_rsp_lcrdv_pending[s] += 1
    self.sn_dat_lcrdv_pending[s] += 1
    self.sn_link_up[s] = True

  async def wait_rn_send_credit(self, p, mgr):
    rn = self.rn_buses[p]
    while not mgr.try_acquire_credit():
      await rn.rising()

  async def wait_sn_send_credit(self, s, mgr):
    sn = self.sn_buses[s]
    while not mgr.try_acquire_credit():
      await sn.rising()

  # ==========================================================================
  # Classification + settle helpers.
  # ==========================================================================
  def classify_req(self, fields):
    op = _I(fields["opcode"])
    if op == int(ReqOpcode.PREFETCH_TGT):
      return _TXN_NO_COMP
    if op in (int(ReqOpcode.WRITE_NO_SNP_ZERO), int(ReqOpcode.CLEAN_SHARED_PERSIST),
              int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP)):
      return _TXN_RSP_ONLY
    if req_opcode_is_atomic_returning_data(op):
      return _TXN_READ
    if req_opcode_is_atomic(op) or op in (int(ReqOpcode.WRITE_NO_SNP_FULL),
                                          int(ReqOpcode.WRITE_NO_SNP_PTL)):
      return _TXN_WRITE
    return _TXN_READ

  def try_settle_active_write(self, p):
    if not self.active_busy or self.active_kind != _TXN_WRITE or self.active_port != p:
      return
    if self.active_write_data_done and (
        not self.active_write_split or self.active_write_comp_done):
      self.active_busy = False

  def sn_port_of_addr(self, addr):
    n_sn = len(self.sn_buses)
    if n_sn <= 1:
      return 0
    if self.sam is not None:
      s = self.sam.lookup(_I(addr))
      if not (0 <= s < n_sn):
        raise AssertionError(
          f"[{self.get_name()}] SAM routed addr 0x{_I(addr):x} to SN {s}, out of range")
      return s
    return (_I(addr) >> self.sn_addr_lsb) % n_sn

  def has_pending_req(self):
    return any(self.req_pending)

  def pick_qos_req_port(self):
    n_rn = len(self.rn_buses)
    best = -1
    for k in range(n_rn):
      p = (self.qos_rr_cursor + k) % n_rn
      if self.req_pending[p]:
        if best < 0 or self.req_qos[p] > self.req_qos[best]:
          best = p
    if best >= 0:
      self.qos_rr_cursor = (best + 1) % n_rn
    return best

  def _pick_rn(self, cursor_attr, signal):
    n_rn = len(self.rn_buses)
    cur = getattr(self, cursor_attr)
    for k in range(n_rn):
      p = (cur + k) % n_rn
      if self.rn_buses[p].get(signal):
        setattr(self, cursor_attr, (p + 1) % n_rn)
        return p
    return -1

  def _pick_sn(self, cursor_attr, signal):
    n_sn = len(self.sn_buses)
    cur = getattr(self, cursor_attr)
    for k in range(n_sn):
      s = (cur + k) % n_sn
      if self.sn_buses[s].get(signal):
        setattr(self, cursor_attr, (s + 1) % n_sn)
        return s
    return -1

  def resolve_rn_port(self, node):
    return self.port_of_node.get(_I(node), 0)

  # ==========================================================================
  # Per-RN REQ ingress capture (1-deep slot; credit returned by the forwarder).
  # ==========================================================================
  async def capture_req(self, p):
    rn = self.rn_buses[p]
    while True:
      while not rn.get("rxreqflitv"):
        await rn.rising()
      self.req_slot[p] = _I(rn.sig["rxreqflit"].value)
      self.req_fields[p] = rn.sample_flit("req", "rx")
      self.req_qos[p] = _I(self.req_fields[p]["qos"])
      self.req_pending[p] = True
      while self.req_pending[p]:
        await rn.rising()

  # ==========================================================================
  # QoS-ordered REQ forwarder (single-outstanding).
  # ==========================================================================
  async def qos_forwarder(self):
    sn0 = self.sn_buses[0]
    while True:
      while not self.has_pending_req():
        await sn0.rising()
      for _ in range(self.arb_window_cycles):
        await sn0.rising()

      p = self.pick_qos_req_port()
      if p < 0:
        await sn0.rising()
        continue

      raw = self.req_slot[p]
      fields = self.req_fields[p]
      s = self.sn_port_of_addr(fields["addr"])

      self.port_of_node[_I(fields["srcid"])] = p
      self.active_sn_of_rn[p] = s
      self.active_port = p
      self.active_kind = self.classify_req(fields)
      self.active_write_split = False
      self.active_write_data_done = False
      self.active_write_comp_done = False
      self.active_busy = True

      sn = self.sn_buses[s]
      await self.wait_sn_send_credit(s, self.sn_req_send[s])

      await sn.rising()
      sn.drive(txreqflitpend=0, txreqflitv=1)
      sn.sig["txreqflit"].value = raw

      await sn.rising()
      sn.drive(txreqflitv=0)
      sn.drive_flit("req", {})

      if self.active_kind == _TXN_NO_COMP:
        self.active_busy = False

      while self.active_busy:
        await sn0.rising()

      self.rn_req_lcrdv_pending[p] += 1
      self.req_pending[p] = False

  # ==========================================================================
  # CompAck-RSP arbiter: any RN -> its active SN.
  # ==========================================================================
  async def arbiter_rsp_rn_to_sn(self):
    sn0 = self.sn_buses[0]
    while True:
      p = self._pick_rn("rsp_rr_cursor", "rxrspflitv")
      if p < 0:
        await sn0.rising()
        continue
      rn = self.rn_buses[p]
      raw = _I(rn.sig["rxrspflit"].value)
      pend = rn.get("rxrspflitpend")
      s = self.active_sn_of_rn[p]
      sn = self.sn_buses[s]

      await self.wait_sn_send_credit(s, self.sn_rsp_send[s])

      await sn.rising()
      sn.drive(txrspflitpend=pend, txrspflitv=1)
      sn.sig["txrspflit"].value = raw

      await sn.rising()
      sn.drive(txrspflitpend=0, txrspflitv=0)
      sn.drive_flit("rsp", {})

      self.rn_rsp_lcrdv_pending[p] += 1
      await rn.rising()

  # ==========================================================================
  # Write-DAT arbiter: any RN -> its active SN (locked to final beat).
  # ==========================================================================
  async def arbiter_dat_rn_to_sn(self):
    sn0 = self.sn_buses[0]
    while True:
      p = self._pick_rn("dat_rr_cursor", "rxdatflitv")
      if p < 0:
        await sn0.rising()
        continue
      rn = self.rn_buses[p]
      s = self.active_sn_of_rn[p]
      sn = self.sn_buses[s]

      while True:
        while not rn.get("rxdatflitv"):
          await rn.rising()
        raw = _I(rn.sig["rxdatflit"].value)
        pend = rn.get("rxdatflitpend")

        await self.wait_sn_send_credit(s, self.sn_dat_send[s])

        await sn.rising()
        sn.drive(txdatflitpend=pend, txdatflitv=1)
        sn.sig["txdatflit"].value = raw

        await sn.rising()
        sn.drive(txdatflitpend=0, txdatflitv=0)
        sn.drive_flit("dat", {})

        self.rn_dat_lcrdv_pending[p] += 1
        await rn.rising()

        if not pend:
          self.active_write_data_done = True
          self.try_settle_active_write(p)
          break

  # ==========================================================================
  # Completion-RSP router: any SN -> RN, routed by tgtid.
  # ==========================================================================
  async def router_rsp_sn_to_rn(self):
    rn0 = self.rn_buses[0]
    while True:
      s = self._pick_sn("sn_rsp_rr_cursor", "rxrspflitv")
      if s < 0:
        await rn0.rising()
        continue
      sn = self.sn_buses[s]
      raw = _I(sn.sig["rxrspflit"].value)
      pend = sn.get("rxrspflitpend")
      fields = sn.sample_flit("rsp", "rx")
      op = _I(fields["opcode"])
      p = self.resolve_rn_port(fields["tgtid"])
      rn = self.rn_buses[p]

      await self.wait_rn_send_credit(p, self.rn_rsp_send[p])

      await rn.rising()
      rn.drive(txrspflitpend=pend, txrspflitv=1)
      rn.sig["txrspflit"].value = raw

      await rn.rising()
      rn.drive(txrspflitpend=0, txrspflitv=0)
      rn.drive_flit("rsp", {})

      # Retry-through-proxy is unmodeled and would deadlock the forwarder.
      if self.active_busy and self.active_port == p and op == int(RspOpcode.RETRY_ACK):
        self.active_busy = False
        raise AssertionError(
          f"[{self.get_name()}] RetryAck relayed through the HN-I proxy "
          f"(RN port {p}): retry behind a proxy is not modeled -- do not set "
          f"force_retry_count on an SN behind the proxy")

      if self.active_busy and self.active_kind == _TXN_WRITE and self.active_port == p:
        if op in _SPLIT_WRITE_GRANT:
          self.active_write_split = True
        if op in _WRITE_COMP:
          self.active_write_comp_done = True
        self.try_settle_active_write(p)

      if (self.active_busy and self.active_kind == _TXN_RSP_ONLY and
          self.active_port == p and op in _TERMINAL_RSP):
        self.active_busy = False

      self.sn_rsp_lcrdv_pending[s] += 1
      await sn.rising()

  # ==========================================================================
  # Read-DAT / CompData router: any SN -> RN, routed by tgtid (locked to beat).
  # ==========================================================================
  async def router_dat_sn_to_rn(self):
    rn0 = self.rn_buses[0]
    while True:
      s = self._pick_sn("sn_dat_rr_cursor", "rxdatflitv")
      if s < 0:
        await rn0.rising()
        continue
      sn = self.sn_buses[s]

      while True:
        while not sn.get("rxdatflitv"):
          await sn.rising()
        raw = _I(sn.sig["rxdatflit"].value)
        pend = sn.get("rxdatflitpend")
        fields = sn.sample_flit("dat", "rx")
        p = self.resolve_rn_port(fields["tgtid"])
        rn = self.rn_buses[p]

        await self.wait_rn_send_credit(p, self.rn_dat_send[p])

        await rn.rising()
        rn.drive(txdatflitpend=pend, txdatflitv=1)
        rn.sig["txdatflit"].value = raw

        await rn.rising()
        rn.drive(txdatflitpend=0, txdatflitv=0)
        rn.drive_flit("dat", {})

        self.sn_dat_lcrdv_pending[s] += 1
        await sn.rising()

        if not pend:
          if self.active_busy and self.active_kind == _TXN_READ and self.active_port == p:
            self.active_busy = False
          break
