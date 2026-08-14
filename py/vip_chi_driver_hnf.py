################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_driver_hnf.sv -- the coherent home node (HN-F).
#
#   RN-F[0..N_RNF-1] <==(RN-facing, HNF role)==> HN-F -> vip_mem
#                                                     `-> (optional) SN-F downstream
#
# A serial response_engine drains a captured-REQ queue and terminates each
# request against its own memory + directory, originating snoops toward the other
# RN-F sharers as the coherence protocol demands. The per-port credit/capture
# threads (mirroring the ported HN-I driver) drain each channel and return credit
# immediately, so no channel back-pressures into a wedge. The directory records
# per-port coherent state per line; an exclusive (LL/SC) monitor gates
# CleanUnique. DCT forwarding + a downstream SN fetch are cfg-gated (default off).
#
# The buses + cfg are assigned by the coherent env before run_phase; this
# component owns its own rst_n watcher (mirrors the ported HN-I driver).
#
################################################################################

from __future__ import annotations

import cocotb
from cocotb.triggers import FallingEdge, First

from pyuvm import uvm_component

from vip_chi_types_pkg import (
  Dir, Resp, RespErr, Exclusive, ReqOpcode, RspOpcode, DatOpcode, SnpOpcode,
  CACHE_LINE_BYTES, chi_xfer_dat_beats, mask,
)
from vip_chi_lcrd_mgr import VipChiLcrdMgr
from vip_chi_cfg_agent import VipChiCfgAgent
from vip_mem import vip_mem

_I = int

_COHERENT_READ_OPS = {
  int(ReqOpcode.READ_SHARED), int(ReqOpcode.READ_CLEAN),
  int(ReqOpcode.READ_UNIQUE), int(ReqOpcode.MAKE_READ_UNIQUE),
}
_UNIQUE_READ_OPS = {int(ReqOpcode.READ_UNIQUE), int(ReqOpcode.MAKE_READ_UNIQUE)}


class vip_chi_driver_hnf(uvm_component):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.rn_buses = []       # RN-facing ChiBus list (HNF role), assigned by env
    self.sn_buses = []       # downstream SN-facing ChiBus list (RNI role)
    self.cfg = None
    self.mem = None
    self._tasks = []

  def build_phase(self):
    if self.cfg is None:
      self.cfg = VipChiCfgAgent("hnf_default_cfg")

  # ==========================================================================
  # State (re)initialization -- sized to the assigned bus lists.
  # ==========================================================================
  def _init_state(self):
    n_rn = len(self.rn_buses)
    n_sn = len(self.sn_buses)

    if self.mem is None:
      cfg0 = self.rn_buses[0].cfg
      self.mem = vip_mem("mem", row_bytes=cfg0.data_bytes, addr_width=cfg0.addr_width)
      self.mem.reset()

    self.rn_rsp_send = [VipChiLcrdMgr(f"rn_rsp_send_{i}") for i in range(n_rn)]
    self.rn_dat_send = [VipChiLcrdMgr(f"rn_dat_send_{i}") for i in range(n_rn)]
    self.rn_snp_send = [VipChiLcrdMgr(f"rn_snp_send_{i}") for i in range(n_rn)]
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
    for m in self.rn_snp_send:
      m.reset(cfg.snp_send_credit_cap, 0)
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
    # One-shot latch per RN port for cfg.flitpend_without_valid: the control
    # fires once per link so the count a test asserts on is unambiguous.
    self.rn_flitpend_negctl_done = [False] * n_rn

    self.sn_rsp_lcrdv_pending = [0] * n_sn
    self.sn_dat_lcrdv_pending = [0] * n_sn
    self.sn_link_up = [False] * n_sn

    self.directory = {}       # line -> [per-port state int]
    self.excl_monitor = {}    # line -> [per-port bool]
    self.snp_txn_ctr = 0
    self.dn_txn_ctr = 0
    self.work_q = []          # (port, req_fields dict)

    self.dn_dat_beats = []
    self.dn_dat_resperr = int(RespErr.OKAY)
    self.dn_dat_valid = False
    self.dn_rsp_q = []

    self.mem_rows_written = set()
    if self.mem is not None:
      self.mem.reset()

  # ==========================================================================
  # Interface reset.
  # ==========================================================================
  def reset_outputs(self):
    for rn in self.rn_buses:
      rn.drive(txlinkactivereq=0, txlinkactiveack=0, txsactive=0, txreqlcrdv=0,
               txrspflitpend=0, txrspflitv=0, txrsplcrdv=0,
               txdatflitpend=0, txdatflitv=0, txdatlcrdv=0,
               txsnpflitpend=0, txsnpflitv=0)
      rn.drive_flit("rsp", {})
      rn.drive_flit("dat", {})
      rn.drive_flit("snp", {})
    for sn in self.sn_buses:
      sn.drive(txlinkactivereq=0, txlinkactiveack=0, txsactive=0,
               txreqflitpend=0, txreqflitv=0,
               txrspflitpend=0, txrspflitv=0, txrsplcrdv=0,
               txdatflitpend=0, txdatflitv=0, txdatlcrdv=0)
      sn.drive_flit("req", {})
      sn.drive_flit("rsp", {})
      sn.drive_flit("dat", {})
    if self.mem is not None:
      self.mem.reset()
    self.mem_rows_written = set()

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
  # run_phase: own rst_n watcher (the coherent env forks nothing for the home).
  # ==========================================================================
  def _reset_link_buses(self):
    # SV waits for all RN and SN links and resets on any of them going down.
    return list(self.rn_buses) + list(self.sn_buses)

  async def run_phase(self):
    self._init_state()
    bus = self.rn_buses[0]              # shared clock reference (all links share clk)
    self.reset_outputs()
    downstream = (len(self.sn_buses) > 0) and self.cfg.hnf_downstream_en
    while True:
      while any(b.in_reset() for b in self._reset_link_buses()):
        await bus.rising()
      self._tasks = [cocotb.start_soon(self.response_engine())]
      for p in range(len(self.rn_buses)):
        self._tasks.append(cocotb.start_soon(self.rn_credit_loop(p)))
        self._tasks.append(cocotb.start_soon(self.rn_activate(p)))
        self._tasks.append(cocotb.start_soon(self.capture_req(p)))
      if downstream:
        for s in range(len(self.sn_buses)):
          self._tasks.append(cocotb.start_soon(self.sn_credit_loop(s)))
          self._tasks.append(cocotb.start_soon(self.sn_activate(s)))
          self._tasks.append(cocotb.start_soon(self.sn_capture_dat(s)))
          self._tasks.append(cocotb.start_soon(self.sn_capture_rsp(s)))

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
  # Backing-store helpers (verbatim SN-F semantics).
  # ==========================================================================
  def _row_index(self, addr):
    return _I(addr) // self.rn_buses[0].cfg.data_bytes

  def _has_row(self, addr):
    return self._row_index(addr) in self.mem_rows_written

  def _mark_row(self, addr):
    self.mem_rows_written.add(self._row_index(addr))

  def auto_read_data(self, addr, beat_index):
    dw = self.rn_buses[0].cfg.data_bytes * 8
    return (_I(addr) + beat_index) & ((1 << dw) - 1)

  def read_data_beat(self, addr, beat_index):
    db = self.rn_buses[0].cfg.data_bytes
    beat_addr = _I(addr) + beat_index * db
    if self._has_row(beat_addr):
      return _I(self.mem.rd_addr(beat_addr))
    return self.auto_read_data(addr, beat_index)

  def line_beats(self):
    return CACHE_LINE_BYTES // self.rn_buses[0].cfg.data_bytes

  # Back the whole line with its current read image before a sub-beat partial
  # write, so wr_be merges enabled bytes over the real pre-write value rather than
  # zero-filling untouched lanes of an unbacked beat.
  def backfill_line_image(self, line):
    db = self.rn_buses[0].cfg.data_bytes
    lb = self.line_beats()
    beats = [self.read_data_beat(line, b) for b in range(lb)]
    be = [mask(self.rn_buses[0].cfg.be_width)] * lb
    self.mem.wr_be(line, beats, be)
    for b in range(lb):
      self._mark_row(line + b * db)

  def clear_backing_line(self, line, n_beats):
    db = self.rn_buses[0].cfg.data_bytes
    for i in range(n_beats):
      row = self._row_index(line + i * db)
      self.mem_rows_written.discard(row)

  def line_addr(self, addr):
    return _I(addr) & ~(CACHE_LINE_BYTES - 1)

  # ==========================================================================
  # Coherent-read classification + granted state.
  # ==========================================================================
  def req_opcode_is_coherent_read(self, opcode):
    return _I(opcode) in _COHERENT_READ_OPS

  def req_opcode_is_unique_read(self, opcode):
    return _I(opcode) in _UNIQUE_READ_OPS

  def granted_state_for(self, opcode):
    if self.req_opcode_is_unique_read(opcode):
      return int(self.cfg.coh_read_unique_state)
    return int(self.cfg.coh_read_shared_state)

  # ==========================================================================
  # Directory / exclusive-monitor helpers.
  # ==========================================================================
  def _dir_entry(self, line):
    return list(self.directory.get(line, [int(Resp.I)] * len(self.rn_buses)))

  def _excl_entry(self, line):
    if line not in self.excl_monitor:
      self.excl_monitor[line] = [False] * len(self.rn_buses)
    return self.excl_monitor[line]

  def _is_excl_req(self, fields):
    return (self.cfg.exclusives_enabled and
            _I(fields["excl"]) == int(Exclusive.EXCLUSIVE))

  # ==========================================================================
  # Per-RN credit/link + activate + REQ ingress capture.
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
      if rn.get("rxsnplcrdv"):
        self.rn_snp_send[p].return_credit()

  async def rn_activate(self, p):
    rn = self.rn_buses[p]
    while rn.rst_n.value and not rn.get("rxlinkactivereq"):
      await rn.rising()
    self.rn_req_lcrdv_pending[p] += self.cfg.initial_req_credits
    self.rn_rsp_lcrdv_pending[p] += self.cfg.initial_rsp_credits
    self.rn_dat_lcrdv_pending[p] += self.cfg.initial_dat_credits
    self.rn_link_up[p] = True
    await self.drive_snp_flitpend_negctl(p)

  async def drive_snp_flitpend_negctl(self, p):
    """Raise SNP FLITPEND for one cycle with no snoop behind it.

    The SNP twin of the REQ/RSP pulse in the requester driver, and it exists for
    the same reason: CHI_SNP_PEND_REQUIRES_VALID had never once been evaluated
    anywhere, because nothing raises SNP FLITPEND -- the home pairs it with the
    snoop it belongs to. A rule that has never run is indistinguishable from one
    that does not work.

    Emitted here, once per link, with the link up and before any snoop, so the
    rule has exactly one lone FLITPEND to report and nothing else on the wire can
    be confused for it.
    """
    if not self.cfg.flitpend_without_valid or self.rn_flitpend_negctl_done[p]:
      return
    self.rn_flitpend_negctl_done[p] = True

    rn = self.rn_buses[p]
    await rn.rising()
    rn.drive(txsnpflitpend=1)
    await rn.rising()
    rn.drive(txsnpflitpend=0)

  async def capture_req(self, p):
    rn = self.rn_buses[p]
    while True:
      while not rn.get("rxreqflitv"):
        await rn.rising()
      self.work_q.append((p, rn.sample_flit("req", "rx")))
      self.rn_req_lcrdv_pending[p] += 1
      await rn.rising()

  # ==========================================================================
  # Downstream SN-facing requester engine (active only when cfg.hnf_downstream_en).
  # ==========================================================================
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

  async def sn_activate(self, s):
    sn = self.sn_buses[s]
    await sn.rising()
    sn.drive(txlinkactivereq=1)
    while sn.rst_n.value and not sn.get("rxlinkactiveack"):
      await sn.rising()
    self.sn_rsp_lcrdv_pending[s] += self.cfg.initial_rsp_credits
    self.sn_dat_lcrdv_pending[s] += self.cfg.initial_dat_credits
    self.sn_link_up[s] = True

  async def sn_capture_dat(self, s):
    sn = self.sn_buses[s]
    while True:
      while not sn.get("rxdatflitv"):
        await sn.rising()
      self.dn_dat_beats = []
      while True:
        flit = sn.sample_flit("dat", "rx")
        self.sn_dat_lcrdv_pending[s] += 1
        self.dn_dat_beats.append(_I(flit["data"]))
        self.dn_dat_resperr = _I(flit["resperr"])
        last = not sn.get("rxdatflitpend")
        await sn.rising()
        if last:
          break
        while not sn.get("rxdatflitv"):
          await sn.rising()
      self.dn_dat_valid = True

  async def sn_capture_rsp(self, s):
    sn = self.sn_buses[s]
    while True:
      while not sn.get("rxrspflitv"):
        await sn.rising()
      self.dn_rsp_q.append(sn.sample_flit("rsp", "rx"))
      self.sn_rsp_lcrdv_pending[s] += 1
      await sn.rising()

  def alloc_dn_txn(self):
    t = self.dn_txn_ctr
    self.dn_txn_ctr = (self.dn_txn_ctr + 1) & ((1 << self.rn_buses[0].cfg.txn_id_width) - 1)
    return t

  async def wait_sn_req_send_credit(self, s):
    sn = self.sn_buses[s]
    while not self.sn_req_send[s].try_acquire_credit():
      await sn.rising()

  async def wait_sn_dat_send_credit(self, s):
    sn = self.sn_buses[s]
    while not self.sn_dat_send[s].try_acquire_credit():
      await sn.rising()

  async def downstream_read(self, addr, size):
    sn = self.sn_buses[0]
    s = 0
    self.dn_dat_valid = False
    self.dn_dat_beats = []

    fields = {
      "opcode": int(ReqOpcode.READ_NO_SNP), "addr": _I(addr), "size": _I(size),
      "txnid": self.alloc_dn_txn(), "srcid": 0,
      "tgtid": _I(self.cfg.hnf_downstream_snf_id),
    }
    await self.wait_sn_req_send_credit(s)
    await sn.rising()
    sn.drive(txreqflitpend=0, txreqflitv=1)
    sn.drive_flit("req", fields)
    await sn.rising()
    sn.drive(txreqflitv=0)
    sn.drive_flit("req", {})

    while not self.dn_dat_valid:
      await sn.rising()
    return list(self.dn_dat_beats)

  async def downstream_write(self, addr, size, beats, bes):
    sn = self.sn_buses[0]
    s = 0
    n_beats = len(beats)
    self.dn_rsp_q = []

    req_fields = {
      "opcode": int(ReqOpcode.WRITE_NO_SNP_FULL), "addr": _I(addr), "size": _I(size),
      "txnid": self.alloc_dn_txn(), "srcid": 0,
      "tgtid": _I(self.cfg.hnf_downstream_snf_id),
    }
    await self.wait_sn_req_send_credit(s)
    await sn.rising()
    sn.drive(txreqflitpend=0, txreqflitv=1)
    sn.drive_flit("req", req_fields)
    await sn.rising()
    sn.drive(txreqflitv=0)
    sn.drive_flit("req", {})

    while not self.dn_rsp_q:
      await sn.rising()
    grant = self.dn_rsp_q.pop(0)
    dbid = _I(grant["dbid"])

    be_all = mask(self.rn_buses[0].cfg.be_width)
    for i in range(n_beats):
      dat_fields = {
        "data": _I(beats[i]), "be": _I(bes[i]) if i < len(bes) else be_all,
        "dataid": i, "dbid": dbid, "txnid": dbid,
        "opcode": int(DatOpcode.NON_COPY_BACK_WR_DATA), "srcid": 0,
        "tgtid": _I(self.cfg.hnf_downstream_snf_id),
      }
      await self.wait_sn_dat_send_credit(s)
      await sn.rising()
      sn.drive(txdatflitpend=1 if i != (n_beats - 1) else 0, txdatflitv=1)
      sn.drive_flit("dat", dat_fields)
      await sn.rising()
      sn.drive(txdatflitpend=0, txdatflitv=0)
      sn.drive_flit("dat", {})

  # ==========================================================================
  # RN-facing send-credit waits.
  # ==========================================================================
  async def wait_rn_rsp_send_credit(self, p):
    rn = self.rn_buses[p]
    while not self.rn_rsp_send[p].try_acquire_credit():
      await rn.rising()
      self.drive_rn_idle_sideband(p)

  async def wait_rn_dat_send_credit(self, p):
    rn = self.rn_buses[p]
    while not self.rn_dat_send[p].try_acquire_credit():
      await rn.rising()

  async def wait_rn_snp_send_credit(self, k):
    rn = self.rn_buses[k]
    while not self.rn_snp_send[k].try_acquire_credit():
      await rn.rising()
      self.drive_rn_idle_sideband(k)

  # ==========================================================================
  # Serial response engine: drain the captured-REQ queue and terminate each.
  # ==========================================================================
  async def response_engine(self):
    bus = self.rn_buses[0]
    while True:
      if self.work_q:
        p, req = self.work_q.pop(0)
        await self.service_req(p, req)
      else:
        await bus.rising()

  async def service_req(self, p, req):
    op = _I(req["opcode"])
    if self.req_opcode_is_coherent_read(op):
      await self.service_coherent_read(p, req)
    elif op in (int(ReqOpcode.WRITE_BACK_FULL), int(ReqOpcode.WRITE_CLEAN_FULL)):
      await self.service_writeback(p, req)
    elif op == int(ReqOpcode.EVICT):
      await self.service_evict(p, req)
    elif op == int(ReqOpcode.CLEAN_INVALID):
      await self.service_cmo_invalidate(p, req, int(SnpOpcode.CLEAN_INVALID))
    elif op == int(ReqOpcode.MAKE_INVALID):
      await self.service_cmo_invalidate(p, req, int(SnpOpcode.MAKE_INVALID))
    elif op == int(ReqOpcode.READ_ONCE):
      await self.service_read_once(p, req)
    elif op in (int(ReqOpcode.WRITE_UNIQUE_FULL), int(ReqOpcode.WRITE_UNIQUE_PTL)):
      await self.service_write_unique(p, req)
    elif op == int(ReqOpcode.CLEAN_UNIQUE):
      await self.service_clean_unique(p, req)
    elif op == int(ReqOpcode.MAKE_UNIQUE):
      await self.service_make_unique(p, req)
    else:
      raise AssertionError(
        f"[{self.get_name()}] HN-F: unsupported REQ opcode 0x{op:x}")

  # ==========================================================================
  # MakeUnique: acquire Unique-Dirty with no data transfer; SnpMakeInvalid every
  # other holder, grant UD, RSP-only Comp.
  # ==========================================================================
  async def service_make_unique(self, p, req):
    line = self.line_addr(req["addr"])
    entry = self._dir_entry(line)
    for k in range(len(self.rn_buses)):
      if k == p or self.cfg.hnf_suppress_snoops:
        continue
      if entry[k] == int(Resp.I):
        continue
      await self.drive_snoop(k, line, int(SnpOpcode.MAKE_INVALID))
      entry[k] = int(Resp.I)
    entry[p] = int(Resp.UD_PD)
    self.directory[line] = entry
    self.excl_monitor.pop(line, None)
    await self.drive_rn_rsp(p, int(RspOpcode.COMP), _I(req["txnid"]), 0,
                            int(Resp.UD_PD), _I(req["tgtid"]), _I(req["srcid"]))

  # ==========================================================================
  # WriteUnique(Full/Ptl): non-allocating coherent write. SnpCleanInvalid every
  # other holder, grant CompDBIDResp, collect the burst into memory, end Invalid.
  # ==========================================================================
  async def service_write_unique(self, p, req):
    line = self.line_addr(req["addr"])
    entry = self._dir_entry(line)
    for k in range(len(self.rn_buses)):
      if k == p or self.cfg.hnf_suppress_snoops:
        continue
      if entry[k] == int(Resp.I):
        continue
      await self.drive_snoop(k, line, int(SnpOpcode.CLEAN_INVALID))

    self.directory[line] = [int(Resp.I)] * len(self.rn_buses)
    self.excl_monitor.pop(line, None)

    await self.drive_rn_rsp(p, int(RspOpcode.COMP_DBID_RESP), _I(req["txnid"]),
                            _I(req["txnid"]), int(Resp.I),
                            _I(req["tgtid"]), _I(req["srcid"]))

    is_ptl = _I(req["opcode"]) == int(ReqOpcode.WRITE_UNIQUE_PTL)
    write_addr = _I(req["addr"]) if is_ptl else line
    expected_beats = chi_xfer_dat_beats(_I(req["size"]), self.rn_buses[0].cfg.data_bytes)
    expected_dat = (int(DatOpcode.NCB_WR_DATA_COMP_ACK) if _I(req["expcompack"])
                    else int(DatOpcode.NON_COPY_BACK_WR_DATA))
    if is_ptl:
      self.backfill_line_image(line)
    await self.collect_write_data(p, _I(req["txnid"]), write_addr, expected_beats,
                                  expected_dat, _I(req["srcid"]), _I(req["tgtid"]),
                                  "WriteUnique")

  # ==========================================================================
  # ReadOnce: non-allocating snapshot read. SnpOnce any holder (dirty forwards
  # current data, merged to memory); grant resp=Invalid, directory untouched.
  # ==========================================================================
  async def service_read_once(self, p, req):
    line = self.line_addr(req["addr"])
    entry = self._dir_entry(line)
    for k in range(len(self.rn_buses)):
      if k == p or self.cfg.hnf_suppress_snoops:
        continue
      if entry[k] != int(Resp.I):
        await self.drive_snoop(k, line, int(SnpOpcode.ONCE))
    await self.drive_coherent_read_compdata(p, req, int(Resp.I))

  # ==========================================================================
  # CleanInvalid / MakeInvalid CMO: invalidate at the point of coherence. Snoop
  # every other holder to I, clear the directory entry, RSP-only Comp.
  # ==========================================================================
  async def service_cmo_invalidate(self, p, req, snp_op):
    line = self.line_addr(req["addr"])
    entry = self._dir_entry(line)
    for k in range(len(self.rn_buses)):
      if k == p or self.cfg.hnf_suppress_snoops:
        continue
      if entry[k] == int(Resp.I):
        continue
      await self.drive_snoop(k, line, snp_op)
    self.directory[line] = [int(Resp.I)] * len(self.rn_buses)
    self.excl_monitor.pop(line, None)
    await self.drive_rn_rsp(p, int(RspOpcode.COMP), _I(req["txnid"]), 0,
                            int(Resp.I), _I(req["tgtid"]), _I(req["srcid"]))

  # ==========================================================================
  # CleanUnique: the exclusive-store (SC) opcode + generic upgrade-to-Unique. No
  # data transfer (RSP-only Comp). Exclusive result gates ExclOkay/NormalOkay.
  # ==========================================================================
  async def service_clean_unique(self, p, req):
    line = self.line_addr(req["addr"])
    is_excl = self._is_excl_req(req)

    won = False
    if is_excl:
      if self.cfg.hnf_force_excl_success:
        won = True
      else:
        won = (line in self.excl_monitor) and bool(self.excl_monitor[line][p])

    entry = self._dir_entry(line)
    for k in range(len(self.rn_buses)):
      if k == p or self.cfg.hnf_suppress_snoops:
        continue
      if entry[k] == int(Resp.I):
        continue
      await self.drive_snoop(k, line, int(SnpOpcode.UNIQUE))
      entry[k] = int(Resp.I)
    entry[p] = int(Resp.UC)
    self.directory[line] = entry
    self.excl_monitor.pop(line, None)

    rerr = int(RespErr.EXOKAY) if (is_excl and won) else int(RespErr.OKAY)
    await self.drive_rn_rsp(p, int(RspOpcode.COMP), _I(req["txnid"]), 0,
                            int(Resp.UC), _I(req["tgtid"]), _I(req["srcid"]), rerr)

  # ==========================================================================
  # Coherent read: snoop the other holders as the request demands, grant the
  # requester, record the directory, return CompData from memory.
  # ==========================================================================
  async def service_coherent_read(self, p, req):
    line = self.line_addr(req["addr"])
    is_unique = self.req_opcode_is_unique_read(_I(req["opcode"]))
    entry = self._dir_entry(line)

    # DCT origination (cfg-gated, default off): exactly one peer holds the line
    # and the read is not an exclusive load -> forward from that peer.
    if (self.cfg.hnf_enable_snoop_fwd and not self.cfg.hnf_suppress_snoops and
        not self._is_excl_req(req)):
      fwd_k = -1
      fwd_holders = 0
      for k in range(len(self.rn_buses)):
        if k == p:
          continue
        if entry[k] != int(Resp.I):
          fwd_k = k
          fwd_holders += 1
      if fwd_holders == 1:
        await self.service_coherent_read_fwd(p, req, line, fwd_k, is_unique, entry)
        return

    for k in range(len(self.rn_buses)):
      if k == p or self.cfg.hnf_suppress_snoops:
        continue
      cur_k = entry[k]
      if cur_k == int(Resp.I):
        continue
      if is_unique:
        await self.drive_snoop(k, line, int(SnpOpcode.UNIQUE))
        entry[k] = int(Resp.I)
        if line in self.excl_monitor:
          self.excl_monitor[line][k] = False
      elif cur_k in (int(Resp.UC), int(Resp.UD_PD)):
        await self.drive_snoop(k, line, int(SnpOpcode.SHARED))
        entry[k] = int(Resp.SC)

    granted = self.granted_state_for(_I(req["opcode"]))
    entry[p] = granted
    self.directory[line] = entry

    is_excl_ll = self._is_excl_req(req)
    if is_excl_ll:
      self._excl_entry(line)[p] = True

    # Two-level hierarchy (cfg-gated): on a mem MISS fetch from the SN-F and fill.
    if self.cfg.hnf_downstream_en and len(self.sn_buses) > 0 and not self._has_row(line):
      db = self.rn_buses[0].cfg.data_bytes
      dn_beats = await self.downstream_read(line, _I(req["size"]))
      if self.cfg.hnf_downstream_corrupt_data:
        dw = db * 8
        dn_beats = [(~b) & ((1 << dw) - 1) for b in dn_beats]
      dn_be = [mask(self.rn_buses[0].cfg.be_width)] * len(dn_beats)
      self.mem.wr_be(line, dn_beats, dn_be)
      for i in range(len(dn_beats)):
        self._mark_row(line + i * db)

    await self.drive_coherent_read_compdata(p, req, granted, is_excl_ll)

  # ==========================================================================
  # WriteBackFull / WriteCleanFull: grant CompDBIDResp, collect CopyBackWrData
  # into memory, clear the requester's directory ownership.
  # ==========================================================================
  async def service_writeback(self, p, req):
    line = self.line_addr(req["addr"])
    await self.drive_rn_rsp(p, int(RspOpcode.COMP_DBID_RESP), _I(req["txnid"]),
                            _I(req["txnid"]), int(Resp.I),
                            _I(req["tgtid"]), _I(req["srcid"]))
    await self.collect_write_data(
        p, _I(req["txnid"]), line,
        chi_xfer_dat_beats(_I(req["size"]), self.rn_buses[0].cfg.data_bytes),
        int(DatOpcode.COPY_BACK_WR_DATA), _I(req["srcid"]), _I(req["tgtid"]),
        "WriteBack/WriteClean")

    if line in self.directory:
      self.directory[line][p] = int(Resp.I)
    self.excl_monitor.pop(line, None)

    if self.cfg.hnf_downstream_en and len(self.sn_buses) > 0:
      db = self.rn_buses[0].cfg.data_bytes
      nb = chi_xfer_dat_beats(_I(req["size"]), db)
      wb_beats = [self.read_data_beat(line, i) for i in range(nb)]
      wb_be = [mask(self.rn_buses[0].cfg.be_width)] * nb
      await self.downstream_write(line, _I(req["size"]), wb_beats, wb_be)
      self.clear_backing_line(line, nb)

  # ==========================================================================
  # Evict: RSP-only ownership drop.
  # ==========================================================================
  async def service_evict(self, p, req):
    line = self.line_addr(req["addr"])
    if line in self.directory:
      self.directory[line][p] = int(Resp.I)
    await self.drive_rn_rsp(p, int(RspOpcode.COMP), _I(req["txnid"]), 0,
                            int(Resp.I), _I(req["tgtid"]), _I(req["srcid"]))

  # ==========================================================================
  # Drive one RSP flit toward RN-F port p (Comp / CompDBIDResp).
  # ==========================================================================
  async def drive_rn_rsp(self, p, opcode, txnid, dbid, resp, src_id, tgt_id,
                         resperr=int(RespErr.OKAY)):
    rn = self.rn_buses[p]
    fields = {
      "opcode": opcode, "txnid": txnid, "dbid": dbid, "resp": resp,
      "resperr": resperr, "srcid": src_id, "tgtid": tgt_id, "qos": 0,
    }
    await self.wait_rn_rsp_send_credit(p)
    await rn.rising()
    self.drive_rn_idle_sideband(p)
    rn.drive(txsactive=1, txrspflitpend=0, txrspflitv=1)
    rn.drive_flit("rsp", fields)
    await rn.rising()
    self.drive_rn_idle_sideband(p)
    rn.drive(txrspflitv=0, txsactive=0)
    rn.drive_flit("rsp", {})

  # ==========================================================================
  # Collect a coherent write-data burst into memory (DBID = REQ TxnID).
  # ==========================================================================
  async def collect_write_data(self, p, dbid, write_addr, expected_beats,
                               expected_opcode, expected_src, expected_tgt, flow):
    rn = self.rn_buses[p]
    db = self.rn_buses[0].cfg.data_bytes
    if expected_beats == 0:
      raise AssertionError(f"[{self.get_name()}] port {p}: {flow} expected zero DAT beats")

    data_q, be_q = [], []
    for beat_index in range(expected_beats):
      while not rn.get("rxdatflitv"):
        await rn.rising()
        self.drive_rn_idle_sideband(p)
      flit = rn.sample_flit("dat", "rx")
      self.rn_dat_lcrdv_pending[p] += 1

      if _I(flit["txnid"]) != dbid:
        raise AssertionError(
          f"[{self.get_name()}] port {p}: {flow} DAT TxnID 0x{_I(flit['txnid']):x} "
          f"!= granted DBID 0x{dbid:x}")
      if _I(flit["dbid"]) != dbid:
        raise AssertionError(
          f"[{self.get_name()}] port {p}: {flow} DAT DBID 0x{_I(flit['dbid']):x} "
          f"!= granted DBID 0x{dbid:x}")
      if _I(flit["opcode"]) != expected_opcode:
        raise AssertionError(
          f"[{self.get_name()}] port {p}: {flow} DAT opcode 0x{_I(flit['opcode']):x} "
          f"!= expected 0x{expected_opcode:x}")
      if _I(flit["srcid"]) != expected_src or _I(flit["tgtid"]) != expected_tgt:
        raise AssertionError(
          f"[{self.get_name()}] port {p}: {flow} DAT src/tgt "
          f"0x{_I(flit['srcid']):x}->0x{_I(flit['tgtid']):x} != expected "
          f"0x{expected_src:x}->0x{expected_tgt:x}")
      if _I(flit["dataid"]) != beat_index:
        raise AssertionError(
          f"[{self.get_name()}] port {p}: {flow} DAT DataID {_I(flit['dataid'])} "
          f"!= expected {beat_index}")

      data_q.append(_I(flit["data"]))
      be_q.append(_I(flit["be"]))
      last_beat = not rn.get("rxdatflitpend")
      if last_beat != (beat_index == (expected_beats - 1)):
        raise AssertionError(
          f"[{self.get_name()}] port {p}: {flow} DAT burst ended at beat "
          f"{beat_index} with expected_beats={expected_beats}")
      await rn.rising()
      self.drive_rn_idle_sideband(p)

    self.mem.wr_be(write_addr, data_q, be_q)
    for i in range(len(data_q)):
      self._mark_row(write_addr + i * db)

  # ==========================================================================
  # Snoop origination.
  # ==========================================================================
  def alloc_snp_txn(self):
    t = self.snp_txn_ctr
    self.snp_txn_ctr = (self.snp_txn_ctr + 1) & ((1 << self.rn_buses[0].cfg.txn_id_width) - 1)
    return t

  async def send_snoop_flit(self, k, line, op, fwd_nid=0, fwd_txn=0):
    rn = self.rn_buses[k]
    snp_txn = self.alloc_snp_txn()
    fields = {
      "opcode": op, "addr": _I(line), "txnid": snp_txn, "srcid": 0,
      "fwdnid": fwd_nid, "fwdtxnid": fwd_txn,
    }
    await self.wait_rn_snp_send_credit(k)
    await rn.rising()
    self.drive_rn_idle_sideband(k)
    rn.drive(txsactive=1, txsnpflitpend=0, txsnpflitv=1)
    rn.drive_flit("snp", fields)
    await rn.rising()
    self.drive_rn_idle_sideband(k)
    rn.drive(txsnpflitv=0)
    rn.drive_flit("snp", {})
    return snp_txn

  async def drive_snoop(self, k, line, op):
    snp_txn = await self.send_snoop_flit(k, line, op)
    await self.collect_snp_response(k, snp_txn, line)

  # Collect the response to the originated snoop on port k. Clean -> no-data
  # SnpResp on RSP; dirty -> SnpRespData on DAT (merged to memory as authority).
  async def collect_snp_response(self, k, snp_txn, line):
    rn = self.rn_buses[k]
    while True:
      if rn.get("rxdatflitv"):
        dflit = rn.sample_flit("dat", "rx")
        dop = _I(dflit["opcode"])
        if (dop in (int(DatOpcode.SNP_RESP_DATA), int(DatOpcode.SNP_RESP_DATA_PTL)) and
            _I(dflit["txnid"]) == snp_txn):
          await self.collect_snp_resp_data(k, snp_txn, line)
          break
        raise AssertionError(
          f"[{self.get_name()}] port {k}: unexpected DAT (opcode 0x{dop:x} "
          f"TxnID 0x{_I(dflit['txnid']):x}) while awaiting SnpResp for snoop "
          f"TxnID 0x{snp_txn:x}")

      if rn.get("rxrspflitv"):
        rflit = rn.sample_flit("rsp", "rx")
        self.rn_rsp_lcrdv_pending[k] += 1
        if (_I(rflit["opcode"]) == int(RspOpcode.SNP_RESP) and
            _I(rflit["txnid"]) == snp_txn):
          await rn.rising()
          self.drive_rn_idle_sideband(k)
          break
        raise AssertionError(
          f"[{self.get_name()}] port {k}: unexpected RSP (opcode "
          f"0x{_I(rflit['opcode']):x} TxnID 0x{_I(rflit['txnid']):x}) while "
          f"awaiting SnpResp for snoop TxnID 0x{snp_txn:x}")

      await rn.rising()
      self.drive_rn_idle_sideband(k)

  async def collect_snp_resp_data(self, k, snp_txn, line):
    rn = self.rn_buses[k]
    db = self.rn_buses[0].cfg.data_bytes
    expected_beats = chi_xfer_dat_beats(6, db)
    data_q, be_q = [], []
    for beat_index in range(expected_beats):
      while not rn.get("rxdatflitv"):
        await rn.rising()
        self.drive_rn_idle_sideband(k)
      flit = rn.sample_flit("dat", "rx")
      self.rn_dat_lcrdv_pending[k] += 1
      if _I(flit["txnid"]) != snp_txn or _I(flit["dbid"]) != snp_txn:
        raise AssertionError(
          f"[{self.get_name()}] port {k}: SnpRespData TxnID/DBID != snoop "
          f"TxnID 0x{snp_txn:x}")
      if _I(flit["opcode"]) != int(DatOpcode.SNP_RESP_DATA):
        raise AssertionError(
          f"[{self.get_name()}] port {k}: SnpRespData opcode 0x{_I(flit['opcode']):x} "
          f"!= expected 0x{int(DatOpcode.SNP_RESP_DATA):x}")
      if _I(flit["dataid"]) != beat_index:
        raise AssertionError(
          f"[{self.get_name()}] port {k}: SnpRespData DataID {_I(flit['dataid'])} "
          f"!= expected {beat_index}")
      data_q.append(_I(flit["data"]))
      be_q.append(_I(flit["be"]))
      last_beat = not rn.get("rxdatflitpend")
      if last_beat != (beat_index == (expected_beats - 1)):
        raise AssertionError(
          f"[{self.get_name()}] port {k}: SnpRespData burst ended at beat "
          f"{beat_index} with expected_beats={expected_beats}")
      await rn.rising()
      self.drive_rn_idle_sideband(k)

    if not self.cfg.hnf_corrupt_dirty_merge:
      self.mem.wr_be(line, data_q, be_q)
      for i in range(len(data_q)):
        self._mark_row(line + i * db)

  # ==========================================================================
  # Serve a coherent read: return CompData carrying the granted state.
  # ==========================================================================
  async def drive_coherent_read_compdata(self, p, req, gstate, excl_okay=False):
    rn = self.rn_buses[p]
    req_addr = _I(req["addr"])
    req_src = _I(req["srcid"])
    req_tgt = _I(req["tgtid"])
    req_txn = _I(req["txnid"])
    be_all = mask(self.rn_buses[0].cfg.be_width)
    beat_count = chi_xfer_dat_beats(_I(req["size"]), self.rn_buses[0].cfg.data_bytes)

    for beat_index in range(beat_count):
      fields = {
        "data": self.read_data_beat(req_addr, beat_index), "be": be_all,
        "dataid": beat_index, "ccid": 0, "dbid": req_txn, "resp": _I(gstate),
        "resperr": int(RespErr.EXOKAY) if excl_okay else int(RespErr.OKAY),
        "opcode": int(DatOpcode.COMP_DATA), "homenid": req_tgt, "txnid": req_txn,
        "srcid": req_tgt, "tgtid": req_src, "qos": _I(req["qos"]),
      }
      await self.wait_rn_dat_send_credit(p)
      await rn.rising()
      self.drive_rn_idle_sideband(p)
      rn.drive(txsactive=1, txdatflitpend=1 if beat_index != (beat_count - 1) else 0,
               txdatflitv=1)
      rn.drive_flit("dat", fields)
      await rn.rising()
      self.drive_rn_idle_sideband(p)
      rn.drive(txdatflitpend=0, txdatflitv=0)
      rn.drive_flit("dat", {})

    await rn.rising()
    self.drive_rn_idle_sideband(p)
    rn.drive(txsactive=0)

  # ==========================================================================
  # DCT coherent read: forwarding snoop to the single peer holder; relay its
  # forwarded data to the requester as CompData (not re-read from memory).
  # ==========================================================================
  async def service_coherent_read_fwd(self, p, req, line, fwd_k, is_unique, entry_in):
    entry = list(entry_in)
    granted = self.granted_state_for(_I(req["opcode"]))
    fwd_op = int(SnpOpcode.UNIQUE_FWD) if is_unique else int(SnpOpcode.SHARED_FWD)
    snoopee_next = int(Resp.I) if is_unique else int(Resp.SC)

    snp_txn = await self.send_snoop_flit(fwd_k, line, fwd_op,
                                         _I(req["srcid"]), _I(req["txnid"]))
    fwd_beats = await self.collect_fwd_resp_data(fwd_k, snp_txn, line)
    await self.drive_relayed_compdata(p, req, granted, fwd_beats)

    entry[fwd_k] = snoopee_next
    entry[p] = granted
    self.directory[line] = entry
    if snoopee_next == int(Resp.I) and line in self.excl_monitor:
      self.excl_monitor[line][fwd_k] = False

  async def collect_fwd_resp_data(self, k, snp_txn, line):
    rn = self.rn_buses[k]
    db = self.rn_buses[0].cfg.data_bytes
    expected_beats = chi_xfer_dat_beats(6, db)
    data_q, be_q = [], []
    for beat_index in range(expected_beats):
      while not rn.get("rxdatflitv"):
        await rn.rising()
        self.drive_rn_idle_sideband(k)
      flit = rn.sample_flit("dat", "rx")
      self.rn_dat_lcrdv_pending[k] += 1
      if _I(flit["txnid"]) != snp_txn or _I(flit["dbid"]) != snp_txn:
        raise AssertionError(
          f"[{self.get_name()}] port {k}: SnpRespDataFwded TxnID/DBID != snoop "
          f"TxnID 0x{snp_txn:x}")
      if _I(flit["opcode"]) != int(DatOpcode.SNP_RESP_DATA_FWDED):
        raise AssertionError(
          f"[{self.get_name()}] port {k}: SnpRespDataFwded opcode "
          f"0x{_I(flit['opcode']):x} != expected 0x{int(DatOpcode.SNP_RESP_DATA_FWDED):x}")
      if _I(flit["dataid"]) != beat_index:
        raise AssertionError(
          f"[{self.get_name()}] port {k}: SnpRespDataFwded DataID "
          f"{_I(flit['dataid'])} != expected {beat_index}")
      data_q.append(_I(flit["data"]))
      be_q.append(_I(flit["be"]))
      last_beat = not rn.get("rxdatflitpend")
      if last_beat != (beat_index == (expected_beats - 1)):
        raise AssertionError(
          f"[{self.get_name()}] port {k}: SnpRespDataFwded burst ended at beat "
          f"{beat_index} with expected_beats={expected_beats}")
      await rn.rising()
      self.drive_rn_idle_sideband(k)

    self.mem.wr_be(line, data_q, be_q)
    for i in range(len(data_q)):
      self._mark_row(line + i * db)
    return data_q

  async def drive_relayed_compdata(self, p, req, gstate, beats):
    rn = self.rn_buses[p]
    db = self.rn_buses[0].cfg.data_bytes
    dw = db * 8
    req_src = _I(req["srcid"])
    req_tgt = _I(req["tgtid"])
    req_txn = _I(req["txnid"])
    be_all = mask(self.rn_buses[0].cfg.be_width)
    beat_count = len(beats)

    for beat_index in range(beat_count):
      data = (~beats[beat_index]) & ((1 << dw) - 1) if self.cfg.hnf_corrupt_fwd_data \
             else beats[beat_index]
      fields = {
        "data": data, "be": be_all, "dataid": beat_index, "ccid": 0, "dbid": req_txn,
        "resp": _I(gstate), "resperr": int(RespErr.OKAY),
        "opcode": int(DatOpcode.COMP_DATA), "homenid": req_tgt, "txnid": req_txn,
        "srcid": req_tgt, "tgtid": req_src, "qos": _I(req["qos"]),
      }
      await self.wait_rn_dat_send_credit(p)
      await rn.rising()
      self.drive_rn_idle_sideband(p)
      rn.drive(txsactive=1, txdatflitpend=1 if beat_index != (beat_count - 1) else 0,
               txdatflitv=1)
      rn.drive_flit("dat", fields)
      await rn.rising()
      self.drive_rn_idle_sideband(p)
      rn.drive(txdatflitpend=0, txdatflitv=0)
      rn.drive_flit("dat", {})

    await rn.rising()
    self.drive_rn_idle_sideband(p)
    rn.drive(txsactive=0)

  # ==========================================================================
  # Test/scoreboard accessors.
  # ==========================================================================
  def get_directory_state(self, addr):
    line = self.line_addr(addr)
    if line not in self.directory:
      return int(Resp.I)
    entry = self.directory[line]
    agg = int(Resp.I)
    for k in range(len(self.rn_buses)):
      st = entry[k]
      if st in (int(Resp.UC), int(Resp.UD_PD)):
        return st
      if st == int(Resp.SC):
        agg = int(Resp.SC)
    return agg

  def get_directory_port_state(self, addr, port):
    line = self.line_addr(addr)
    if line not in self.directory:
      return int(Resp.I)
    return self.directory[line][port]
