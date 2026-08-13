################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_driver_rnf.sv -- the coherent requester (RN-F).
#
# RN-F is an RN-I that also participates in coherence: it issues coherent REQ
# opcodes, holds a per-line cache-state + data shadow, and answers snoops. It
# reuses the ENTIRE RN-I request/credit/link/retry machinery by extending
# vip_chi_driver_rni; the base exposes three empty hooks the RN-F fills in:
#   * post_activate_hook      -- advertise the initial SNP receive credits.
#   * extra_rx_channels       -- fork the SNP credit loop + the snoop responder.
#   * on_transaction_complete -- record the granted state/data into the cache.
# The base tx-flit mutex (acquire_tx_flit / release_tx_flit) serializes the
# autonomous snoop responder against the request thread on the shared TX signals.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import (
  Role, Dir, Resp, RespErr, ReqOpcode, RspOpcode, DatOpcode, SnpOpcode,
  CACHE_LINE_BYTES, mask,
)
from vip_chi_driver_rni import vip_chi_driver_rni

_I = int

# Coherent read REQ opcodes that populate the cache with granted state + data.
_COHERENT_READ_OPS = {
  int(ReqOpcode.READ_SHARED), int(ReqOpcode.READ_CLEAN),
  int(ReqOpcode.READ_UNIQUE), int(ReqOpcode.MAKE_READ_UNIQUE),
}
# Invalidating CMOs the RN-F issues (complete RSP-only, drop the local copy).
_COHERENT_CMO_OPS = {int(ReqOpcode.CLEAN_INVALID), int(ReqOpcode.MAKE_INVALID)}
# Non-allocating coherent writes (WriteUnique Full/Ptl -> end Invalid).
_COHERENT_WU_OPS = {int(ReqOpcode.WRITE_UNIQUE_FULL), int(ReqOpcode.WRITE_UNIQUE_PTL)}
# Coherent writes that evict the line to the home (end Invalid).
_COHERENT_EVICT_WRITE_OPS = {int(ReqOpcode.WRITE_BACK_FULL), int(ReqOpcode.EVICT)}

# Forwarding (DCT) snoop opcodes -- the snoopee forwards its data for relay.
_SNP_FWD_OPS = {
  int(SnpOpcode.SHARED_FWD), int(SnpOpcode.CLEAN_FWD), int(SnpOpcode.ONCE_FWD),
  int(SnpOpcode.NOT_SHARED_DIRTY_FWD), int(SnpOpcode.UNIQUE_FWD),
}
# Snoops that retain the shared (SC) state (else stay Invalid).
_SNP_TO_SHARED_OPS = {
  int(SnpOpcode.SHARED), int(SnpOpcode.CLEAN), int(SnpOpcode.CLEAN_SHARED),
  int(SnpOpcode.SHARED_FWD), int(SnpOpcode.CLEAN_FWD),
  int(SnpOpcode.NOT_SHARED_DIRTY_FWD),
}
# Snoops that invalidate the snoopee (-> Invalid).
_SNP_TO_INVALID_OPS = {
  int(SnpOpcode.UNIQUE), int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.MAKE_INVALID),
  int(SnpOpcode.UNIQUE_FWD),
}
# PassDirty cache states whose snoop response must carry data.
_DIRTY_STATES = {int(Resp.UD_PD), int(Resp.SD_PD)}


class vip_chi_driver_rnf(vip_chi_driver_rni):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.role = Role.RNF
    # Per-line cache-state model (line-aligned addr -> held coherent state) and a
    # parallel per-line data image (list of beats). The snoop responder answers
    # from this shadow; a PassDirty holder forwards these beats to the home.
    self.cache_state = {}
    self.cache_data = {}
    # Outbound SNP receive-credit pulses queued for the HN-F.
    self.snp_lcrdv_pulses_pending = 0

  # ==========================================================================
  # Line-align to the 64 B coherence granule (NOT the bus width): a mid-line
  # address on a narrow bus still resolves to the single cache-line key.
  # ==========================================================================
  def line_addr(self, addr):
    return _I(addr) & ~(CACHE_LINE_BYTES - 1)

  def req_opcode_is_coherent_read(self, opcode):
    return _I(opcode) in _COHERENT_READ_OPS

  def req_opcode_is_coherent_cmo(self, opcode):
    return _I(opcode) in _COHERENT_CMO_OPS

  def req_opcode_is_coherent_write_unique(self, opcode):
    return _I(opcode) in _COHERENT_WU_OPS

  def req_opcode_is_coherent_evicting_write(self, opcode):
    return _I(opcode) in _COHERENT_EVICT_WRITE_OPS

  def state_is_dirty(self, state):
    return _I(state) in _DIRTY_STATES

  def snp_opcode_is_fwd(self, op):
    return _I(op) in _SNP_FWD_OPS

  # ==========================================================================
  # Reset: clear coherent-local state (the base clears RN-I bookkeeping).
  # ==========================================================================
  def handle_reset(self):
    self.cache_state = {}
    self.cache_data = {}
    self.snp_lcrdv_pulses_pending = 0
    super().handle_reset()
    self.reset_snp_outputs()

  def reset_vif(self):
    super().reset_vif()
    self.reset_snp_outputs()

  def reset_snp_outputs(self):
    self.bus.drive(txsnplcrdv=0)

  # ==========================================================================
  # Test-facing: model a local store into a held line -- mutate the cached beats
  # and move the line to Unique-Dirty (PassDirty) so a later snoop forwards it.
  # ==========================================================================
  def make_line_dirty(self, addr, xor_pattern):
    line = self.line_addr(addr)
    if line not in self.cache_data:
      raise AssertionError(
        f"[{self.get_name()}] make_line_dirty on line 0x{line:x} "
        f"that is not held with data")
    self.cache_data[line] = [b ^ _I(xor_pattern) for b in self.cache_data[line]]
    self.cache_state[line] = int(Resp.UD_PD)

  # ==========================================================================
  # Bounded-cache silent eviction: drop the lowest-address CLEAN victim (no bus
  # transaction) when allocating new_line would exceed cfg.rnf_cache_max_lines.
  # No-op when unbounded or new_line is resident. A cache full of DIRTY lines is
  # a modeling error (dirty writeback-on-eviction is not modeled).
  # ==========================================================================
  def evict_for_capacity(self, new_line):
    if self.cfg.rnf_cache_max_lines <= 0:
      return
    if new_line in self.cache_state:
      return
    while len(self.cache_state) >= self.cfg.rnf_cache_max_lines:
      victim = None
      for a in sorted(self.cache_state):
        if not self.state_is_dirty(self.cache_state[a]):
          victim = a
          break
      if victim is None:
        raise AssertionError(
          f"[{self.get_name()}] bounded RN-F cache (max "
          f"{self.cfg.rnf_cache_max_lines} lines) is full of DIRTY lines while "
          f"allocating 0x{new_line:x}; dirty writeback-on-eviction is not modeled")
      self.cache_state.pop(victim, None)
      self.cache_data.pop(victim, None)

  # ==========================================================================
  # Extension hooks (called by the RN-I base).
  # ==========================================================================
  def post_activate_hook(self):
    self.snp_lcrdv_pulses_pending += self.cfg.initial_snp_credits

  def extra_rx_channels(self):
    self._spawn(self.snp_credit_loop())
    self._spawn(self.snoop_responder())

  def schedule_snp_credit_return(self):
    self.snp_lcrdv_pulses_pending += 1

  # ==========================================================================
  # Emit one-cycle txsnplcrdv pulses for the queued SNP receive credits. Drives
  # only txsnplcrdv (disjoint from the base credit_loop), so they coexist.
  # ==========================================================================
  async def snp_credit_loop(self):
    bus = self.bus
    while True:
      await bus.rising()
      # cfg.hold_snp_credit lets a test starve the HN-F's SNP send pool; the
      # pending grants accumulate and drain once cleared.
      snp_hold = self.cfg.hold_snp_credit
      emit = (self.snp_lcrdv_pulses_pending != 0) and not snp_hold
      bus.drive(txsnplcrdv=1 if emit else 0)
      if emit:
        self.snp_lcrdv_pulses_pending -= 1

  # ==========================================================================
  # Autonomous snoop responder: capture each inbound snoop, return its credit,
  # update the cache, and drive the SnpResp. Independent of the request thread.
  # ==========================================================================
  async def snoop_responder(self):
    bus = self.bus
    while True:
      while not bus.get("rxsnpflitv"):
        await bus.rising()
        self.drive_idle_sideband()

      snp = bus.sample_flit("snp", "rx")
      self.schedule_snp_credit_return()

      # Step off the accepted snoop beat before responding.
      await bus.rising()
      self.drive_idle_sideband()

      # A snoop response is outbound activity this node owes the home, so it
      # opens a TXSACTIVE window of its own: the request-side count knows
      # nothing about it, and a SnpRespData burst can span many cycles during
      # which the sideband must not drop.
      self.tx_activity_begin()
      try:
        await self.process_snoop(snp)
      finally:
        self.tx_activity_end()

  # ==========================================================================
  # Resulting state after a snoop for the clean/no-data cases:
  #   Snp{Shared,Clean,CleanShared,*Fwd shared-ish} -> retain SC (unless already I)
  #   Snp{Unique,CleanInvalid,MakeInvalid,UniqueFwd} -> Invalid
  #   SnpOnce / SnpOnceFwd -> unchanged (snapshot).
  # ==========================================================================
  def snoop_next_state(self, snp_opcode, current):
    op = _I(snp_opcode)
    if op in _SNP_TO_SHARED_OPS:
      return int(Resp.I) if _I(current) == int(Resp.I) else int(Resp.SC)
    if op in _SNP_TO_INVALID_OPS:
      return int(Resp.I)
    return _I(current)  # SnpOnce / SnpOnceFwd and anything else: no change

  # ==========================================================================
  # Apply one snoop to the cache model and drive its SnpResp.
  # ==========================================================================
  async def process_snoop(self, snp):
    if self.snp_opcode_is_fwd(snp["opcode"]):
      await self.process_snoop_fwd(snp)
      return

    line = self.line_addr(snp["addr"])
    cur = self.cache_state.get(line, int(Resp.I))
    nxt = self.snoop_next_state(snp["opcode"], cur)
    was_dirty = self.state_is_dirty(cur)

    # Snapshot the beats to forward BEFORE mutating the model.
    fwd_data = list(self.cache_data[line]) if (was_dirty and line in self.cache_data) else []

    if nxt == int(Resp.I):
      self.cache_state.pop(line, None)
      self.cache_data.pop(line, None)
    else:
      self.cache_state[line] = nxt
      # Drop the retained dirty copy only if this snoop moved us OUT of a dirty
      # state (we handed our dirty data to the home and are now clean).
      if was_dirty and not self.state_is_dirty(nxt) and line in self.cache_data:
        self.cache_data.pop(line, None)

    if was_dirty and fwd_data:
      await self.drive_snp_resp_data(snp, nxt, fwd_data)
    else:
      await self.drive_snp_resp(snp, nxt)

  # ==========================================================================
  # Forwarding (DCT) snoop: ALWAYS forwards data (the requester is reading). The
  # data travels home as SnpRespDataFwded; the home relays it to the requester.
  # ==========================================================================
  async def process_snoop_fwd(self, snp):
    line = self.line_addr(snp["addr"])
    cur = self.cache_state.get(line, int(Resp.I))
    nxt = self.snoop_next_state(snp["opcode"], cur)

    fwd_data = list(self.cache_data[line]) if line in self.cache_data else []

    if nxt == int(Resp.I):
      self.cache_state.pop(line, None)
      self.cache_data.pop(line, None)
    else:
      self.cache_state[line] = nxt

    if fwd_data:
      await self.drive_snp_resp_data(snp, nxt, fwd_data, is_fwd=True)
    else:
      await self.drive_snp_resp(snp, nxt)

  # ==========================================================================
  # Drive one SnpResp on the RSP channel (clean, no data). The snoop's TxnID is
  # echoed so the home can match; the home matches on TxnID + port.
  # ==========================================================================
  async def drive_snp_resp(self, snp, resp_state):
    bus = self.bus
    fields = {
      "opcode": int(RspOpcode.SNP_RESP), "resp": _I(resp_state),
      "resperr": int(RespErr.OKAY), "txnid": snp["txnid"],
      "srcid": 0, "tgtid": snp["srcid"], "qos": snp["qos"],
    }
    await self.wait_for_credit(self.rsp_lcrd)

    await self.acquire_tx_flit()
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(txrspflitpend=0, txrspflitv=1)
    bus.drive_flit("rsp", fields)

    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(txrspflitv=0)
    bus.drive_flit("rsp", {})
    self.release_tx_flit()

  # ==========================================================================
  # Drive a dirty snoop response as SnpRespData(Fwded) on DAT: one beat per held
  # line beat, carrying the modified data with PassDirty semantics.
  # ==========================================================================
  async def drive_snp_resp_data(self, snp, resp_state, beats, is_fwd=False):
    bus = self.bus
    be_all = mask(bus.cfg.be_width)
    opcode = int(DatOpcode.SNP_RESP_DATA_FWDED) if is_fwd else int(DatOpcode.SNP_RESP_DATA)
    n_beats = len(beats)

    # Hold the mutex across the whole burst (beat atomicity); each beat's DAT
    # credit is returned by the home independently, so the burst always drains.
    await self.acquire_tx_flit()
    for i, b in enumerate(beats):
      fields = {
        "data": _I(b), "be": be_all, "dataid": i, "dbid": snp["txnid"],
        "resp": _I(resp_state), "resperr": int(RespErr.OKAY), "opcode": opcode,
        "txnid": snp["txnid"], "srcid": 0, "tgtid": snp["srcid"], "qos": snp["qos"],
      }
      await self.wait_for_credit(self.dat_lcrd)

      await bus.rising()
      self.drive_idle_sideband()
      bus.drive(txdatflitpend=1 if i != (n_beats - 1) else 0, txdatflitv=1)
      bus.drive_flit("dat", fields)

      await bus.rising()
      self.drive_idle_sideband()
      bus.drive(txdatflitpend=0, txdatflitv=0)
      bus.drive_flit("dat", {})

    await bus.rising()
    self.drive_idle_sideband()
    self.release_tx_flit()

  # ==========================================================================
  # Record the granted coherent state/data as each request retires.
  # ==========================================================================
  def on_transaction_complete(self, req):
    line = self.line_addr(req.addr)
    op = _I(req.opcode)

    if _I(req.direction) == int(Dir.READ) and self.req_opcode_is_coherent_read(op):
      self.evict_for_capacity(line)
      self.cache_state[line] = _I(req.rsp_resp)
      self.cache_data[line] = [_I(x) for x in req.data]
    elif (self.req_opcode_is_coherent_evicting_write(op) or
          self.req_opcode_is_coherent_cmo(op) or
          self.req_opcode_is_coherent_write_unique(op)):
      # The line leaves this cache (Invalid, no data).
      self.cache_state.pop(line, None)
      self.cache_data.pop(line, None)
    elif op == int(ReqOpcode.CLEAN_UNIQUE):
      # Upgrade a held (clean) line to Unique-Clean; no data transfer. An
      # exclusive store upgrades only on ExclOkay (else it lost; line untouched).
      if line in self.cache_state:
        if (not _I(req.excl)) or (_I(req.rsp_resp_err) == int(RespErr.EXOKAY)):
          self.cache_state[line] = int(Resp.UC)
    elif op == int(ReqOpcode.MAKE_UNIQUE):
      # Acquire Unique-Dirty WITHOUT a data transfer; materialize a zero image
      # sized to the coherence line so a later snoop can forward real beats.
      self.evict_for_capacity(line)
      self.cache_state[line] = int(Resp.UD_PD)
      n_beats = CACHE_LINE_BYTES // self.bus.cfg.data_bytes
      self.cache_data[line] = [0] * n_beats

  # ==========================================================================
  # Test/scoreboard accessor: the held state for a line (I when never cached).
  # ==========================================================================
  def get_cache_state(self, addr):
    return self.cache_state.get(self.line_addr(addr), int(Resp.I))
