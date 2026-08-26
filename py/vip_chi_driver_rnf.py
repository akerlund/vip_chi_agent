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
  CACHE_LINE_BYTES, mask, snp_opcode_returns_no_data,
  FillAction, req_fill_action,
  req_final_state,
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
_COHERENT_WU_OPS = {int(ReqOpcode.WRITE_UNIQUE_FULL), int(ReqOpcode.WRITE_UNIQUE_PTL),
                    # The combined forms carry the same write and take the same
                    # requester-side path; only the completer does anything extra.
                    int(ReqOpcode.WRITE_UNIQUE_FULL_CLEAN_SH),
                    int(ReqOpcode.WRITE_UNIQUE_FULL_CLEAN_SH_PER_SEP),
                    int(ReqOpcode.WRITE_UNIQUE_PTL_CLEAN_SH),
                    int(ReqOpcode.WRITE_UNIQUE_PTL_CLEAN_SH_PER_SEP)}
# Coherent writes that evict the line to the home (end Invalid).
# WriteEvictOrEvict gives the line up either way: with the data when the home
# asks for it, and as a plain Evict when it does not.
_COHERENT_EVICT_WRITE_OPS = {int(ReqOpcode.WRITE_BACK_FULL), int(ReqOpcode.EVICT),
                             int(ReqOpcode.WRITE_EVICT_OR_EVICT),
                             # WriteBackFull + CMO evicts exactly as WriteBackFull
                             # does. WriteCleanFull + CMO is deliberately absent
                             # from this set for the same reason WriteCleanFull
                             # is: a WriteClean writes the data back and the
                             # requester KEEPS a clean copy.
                             int(ReqOpcode.WRITE_BACK_FULL_CLEAN_SH),
                             int(ReqOpcode.WRITE_BACK_FULL_CLEAN_INV),
                             int(ReqOpcode.WRITE_BACK_FULL_CLEAN_SH_PER_SEP)}

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
    # Per-BEAT dirty byte mask, parallel to cache_data and the same length. One
    # bit per byte, exactly the wire's own byte-enable width, set by the local
    # store model.
    #
    # This is the distinction the Resp field cannot carry. Table 4-6 gives UD and
    # UDP the same encoding, UD_PD, so a line's state says it is Unique and Dirty
    # and says nothing about WHICH bytes. A mask that is all ones is UD; a mask
    # with some bits set is UDP, and Table 4-14 footnote c treats the two
    # differently when a read returns data for a line already held.
    self.cache_dirty_be = {}
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
    self.cache_dirty_be = {}
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
    self.store_into_line(addr, xor_pattern, self._all_bytes())

  def make_line_dirty_partial(self, addr, xor_pattern, dirty_bytes):
    """A PARTIAL local store, leaving the line UniqueDirtyPartial.

    UDP is not a wire state -- Table 4-6 encodes it as UD_PD, the same as UD --
    so it exists only as the dirty byte mask this records. It is the state Table
    4-14 footnote c reserves the MERGE case for, and the only way to reach that
    case: without a mask every dirty line is fully dirty and the footnote's drop
    half is the whole of it.

    Test-facing, like its full-line twin.
    """
    self.store_into_line(addr, xor_pattern, dirty_bytes)

  def _all_bytes(self):
    return (1 << self.bus.cfg.data_bytes) - 1

  def store_into_line(self, addr, xor_pattern, dirty_bytes):
    """The one writer behind both, so the mask and the beats cannot disagree."""
    line = self.line_addr(addr)
    if line not in self.cache_data:
      raise AssertionError(
        f"[{self.get_name()}] a local store into line 0x{line:x} "
        f"that is not held with data")

    dirty_bytes = _I(dirty_bytes)
    if not dirty_bytes:
      raise AssertionError(
        f"[{self.get_name()}] a local store into line 0x{line:x} with no byte "
        f"selected: a store that writes nothing cannot dirty the line, and "
        f"recording it would make a CLEAN line report UD_PD")

    bits = self.be_to_bitmask(dirty_bytes)
    held = self.cache_dirty_be.get(line)
    if held is None or len(held) != len(self.cache_data[line]):
      held = [0] * len(self.cache_data[line])

    self.cache_data[line] = [b ^ (_I(xor_pattern) & bits)
                             for b in self.cache_data[line]]
    self.cache_dirty_be[line] = [m | dirty_bytes for m in held]
    self.cache_state[line] = int(Resp.UD_PD)

  def be_to_bitmask(self, be):
    """Expand one beat's byte enables into a data-width bit mask."""
    be = _I(be)
    m = 0
    for b in range(self.bus.cfg.data_bytes):
      if (be >> b) & 1:
        m |= 0xFF << (8 * b)
    return m

  def line_is_partial_dirty(self, line):
    """True when the line is dirty in SOME of its bytes but not all -- UDP.

    A line with no mask recorded is fully dirty if its state says so: the mask
    only ever exists where a partial store put it.
    """
    held = self.cache_dirty_be.get(line)
    if held is None:
      return False
    return any(m != self._all_bytes() for m in held)

  def drop_line_data(self, line):
    """Give up a line's beats.

    One writer for both dicts, so a dirty mask cannot outlive the data it
    describes and be read against the next line allocated at the same address.
    """
    self.cache_data.pop(line, None)
    self.cache_dirty_be.pop(line, None)

  def take_fetched_beats(self, line, req):
    """Table 4-14 footnote c, TAKE.

    Nothing locally modified is at stake, so the fetched line replaces whatever
    was held and the dirty mask goes with it.
    """
    self.cache_data[line] = [_I(x) for x in req.data]
    self.cache_dirty_be.pop(line, None)

  def merge_fetched_beats(self, line, req):
    """Table 4-14 footnote c, MERGE.

    The line is UDP, so each byte comes from whichever copy is authoritative for
    it -- the local store where the mask is set, the fetch everywhere else.

    Neither of the other two outcomes is right here, and both lose data. Taking
    the fetch discards the store. Dropping the fetch keeps bytes this cache never
    had: a UDP line's clean bytes are precisely the ones it was never given, so
    what it is holding for them is filler.

    The mask SURVIVES the merge. The line is still Unique and still dirty in
    those bytes; only the clean ones changed hands, and the requester still owes
    the dirty ones to the next holder.
    """
    if len(req.data) != len(self.cache_data[line]):
      raise AssertionError(
        f"[{self.get_name()}] a merge on line 0x{line:x} fetched "
        f"{len(req.data)} beat(s) against {len(self.cache_data[line])} held; "
        f"the two copies of one line must be the same length or there is no "
        f"byte-for-byte question to answer")

    merged = []
    for i, fetched in enumerate(req.data):
      bits = self.be_to_bitmask(self.cache_dirty_be[line][i])
      merged.append((self.cache_data[line][i] & bits) | (_I(fetched) & ~bits))
    self.cache_data[line] = merged

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
      self.drop_line_data(victim)

  # ==========================================================================
  # Extension hooks (called by the RN-I base).
  # ==========================================================================
  def post_activate_hook(self):
    # Less whatever the negative control already put on the wire ahead of the
    # link, so the run's total budget is unchanged and only the timing moved.
    early = int(self.cfg.rnf_snp_credit_before_link_negctl)
    if self.cfg.initial_snp_credits > early:
      self.snp_lcrdv_pulses_pending += self.cfg.initial_snp_credits - early

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

    # Negative control: put credits on the wire before the receive link exists.
    # Queued HERE rather than in post_activate_hook because the whole point is
    # that the activation has not happened yet -- this task is spawned before it.
    self.snp_lcrdv_pulses_pending += int(
      self.cfg.rnf_snp_credit_before_link_negctl)

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
      if self.cfg.rnf_txsactive_snoop_drop_negctl:
        await self.process_snoop(snp)
      else:
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
  # ==========================================================================
  # Resulting state after a snoop, and where DoNotGoToSD is honoured.
  #
  # Two decisions meet here and they have to be read together.
  #
  # The first is this VIP's never-SD reduction: a snoopee in this model adopts
  # only I, SC or its current state, so SD is not in the range of this function
  # at all. The second is the SNP flit's DoNotGoToSD bit -- "Snoopee receiving a
  # Snoop request with the DoNotGoToSD bit set, except when the Snoop is
  # SnpOnceFwd, must not transition to SD".
  #
  # Together those mean the bit is satisfied here by CONSTRUCTION rather than by
  # obedience, and that is a fragile way to satisfy a rule: it holds only while
  # the reduction does, and nothing would notice if SD were added to the state
  # set later. So the bit is read explicitly below. The guard is inert today --
  # nothing above it can produce SD -- and it is written anyway, because the day
  # the reduction is lifted is the day someone needs this to already be right.
  #
  # SnpOnceFwd is the specification's own exception and is excluded from the
  # guard, not overlooked.
  # ==========================================================================
  def snoop_next_state(self, snp_opcode, current, do_not_go_to_sd=0):
    op = _I(snp_opcode)
    if op in _SNP_TO_SHARED_OPS:
      nxt = int(Resp.I) if _I(current) == int(Resp.I) else int(Resp.SC)
    elif op in _SNP_TO_INVALID_OPS:
      nxt = int(Resp.I)
    else:
      nxt = _I(current)  # SnpOnce / SnpOnceFwd and anything else: no change

    if (nxt == int(Resp.SD_PD) and _I(do_not_go_to_sd)
        and op != int(SnpOpcode.ONCE_FWD)):
      # Staying in SD would not be a transition and is not caught here; this
      # bounds where the snoop MOVES the line to.
      return int(Resp.SC)
    return nxt

  # ==========================================================================
  # Apply one snoop to the cache model and drive its SnpResp.
  # ==========================================================================
  async def process_snoop(self, snp):
    if self.snp_opcode_is_fwd(snp["opcode"]):
      await self.process_snoop_fwd(snp)
      return

    line = self.line_addr(snp["addr"])
    cur = self.cache_state.get(line, int(Resp.I))
    nxt = self.snoop_next_state(snp["opcode"], cur, snp["donotgotosd"])
    was_dirty = self.state_is_dirty(cur)
    no_data = snp_opcode_returns_no_data(snp["opcode"])

    # The control puts a dirty holder on the data-bearing path for a snoop that
    # returns none, which is the pairing Tables 4-9 / 4-11 do not list. Applied
    # to the decision and not to the flit, so the snapshot below is taken too and
    # the response is one a real snoopee could emit. See the knob.
    if self.cfg.rnf_snp_resp_data_negctl:
      no_data = False

    # Snapshot the beats to forward BEFORE mutating the model. A snoop that
    # returns no data takes no snapshot: its dirty copy is discarded here rather
    # than forwarded.
    fwd_data = (list(self.cache_data[line])
                if (was_dirty and not no_data and line in self.cache_data) else [])

    if nxt == int(Resp.I):
      self.cache_state.pop(line, None)
      self.drop_line_data(line)
    else:
      self.cache_state[line] = nxt
      # Drop the retained dirty copy only if this snoop moved us OUT of a dirty
      # state (we handed our dirty data to the home and are now clean).
      if was_dirty and not self.state_is_dirty(nxt) and line in self.cache_data:
        self.drop_line_data(line)

    # The opcode is part of this decision and not only the held state -- see
    # vip_chi_types_pkg.snp_opcode_returns_no_data -- because a dirty holder
    # snooped by SnpMakeInvalid still answers on RSP.
    if not no_data and was_dirty and fwd_data:
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
    nxt = self.snoop_next_state(snp["opcode"], cur, snp["donotgotosd"])

    fwd_data = list(self.cache_data[line]) if line in self.cache_data else []

    if nxt == int(Resp.I):
      self.cache_state.pop(line, None)
      self.drop_line_data(line)
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
    # The control reports SD without the shadow ever holding it -- what the rule
    # judges is the response, so that is what the control corrupts. See the knob.
    if self.cfg.rnf_snp_resp_sd_negctl:
      resp_state = int(Resp.SD_PD)
    fields = {
      "opcode": int(RspOpcode.SNP_RESP), "resp": _I(resp_state),
      "resperr": int(RespErr.OKAY), "txnid": snp["txnid"],
      "srcid": 0, "tgtid": snp["srcid"], "qos": snp["qos"],
    }
    await self.wait_rsp_credit()

    await self.acquire_tx_flit()
    await self.announce_flit("rsp")
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
      await self.wait_dat_credit()

      # Every beat: the gap cycle after each one drops FLITPEND, so nothing
      # carries the lead across. See vip_chi_driver_rni.announce_flit.
      await self.announce_flit("dat")
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
  # Record the coherent state as each request retires.
  #
  # The final state is a function of the state this cache HELD and the state the
  # completion GRANTED -- req_final_state, IHI 0050 E Tables 4-14, 4-17, 4-18 and
  # 4-19 (D Tables 4-12 and 4-13). It is NOT the granted Resp on its own: a UD
  # holder that issues ReadClean stays UD however weak the grant, and taking Resp
  # verbatim would drop a writeback obligation this cache still owes.
  # ==========================================================================
  def on_transaction_complete(self, req):
    line = self.line_addr(req.addr)
    op = _I(req.opcode)
    held = self.cache_state.get(line, int(Resp.I))

    if _I(req.direction) == int(Dir.READ) and self.req_opcode_is_coherent_read(op):
      self.evict_for_capacity(line)
      # Negative control: reinstate the pre-3.2 shortcut in full -- the granted
      # Resp verbatim, and the fetched beats over the top of whatever was held.
      verbatim = bool(self.cfg.rnf_req_final_state_verbatim)
      self.cache_state[line] = (_I(req.rsp_resp) if verbatim
                                else req_final_state(op, held, _I(req.rsp_resp)))
      # Keep the granted beats for a later snoop to forward -- under Table 4-14
      # footnote c, which decides between three outcomes and not two. See
      # req_fill_action; the partial-dirty half of its question is the mask this
      # cache keeps, since the wire cannot tell UD from UDP.
      #
      # The negative control takes the verbatim path, which is the pre-footnote
      # behaviour in full: the fetched beats over the top of whatever was held.
      if verbatim:
        self.take_fetched_beats(line, req)
      else:
        action = req_fill_action(held, self.line_is_partial_dirty(line))
        if action == int(FillAction.TAKE):
          self.take_fetched_beats(line, req)
        elif action == int(FillAction.MERGE):
          self.merge_fetched_beats(line, req)
        # DROP: the held copy is the newer one.
    elif (self.req_opcode_is_coherent_evicting_write(op) or
          self.req_opcode_is_coherent_cmo(op) or
          self.req_opcode_is_coherent_write_unique(op)):
      # The line leaves this cache (Invalid, no data).
      self.cache_state.pop(line, None)
      self.drop_line_data(line)
    elif op == int(ReqOpcode.CLEAN_UNIQUE):
      # Upgrade a held (clean) line to Unique-Clean; no data transfer. An
      # exclusive store upgrades only on ExclOkay (else it lost; line untouched).
      if line in self.cache_state:
        if (not _I(req.excl)) or (_I(req.rsp_resp_err) == int(RespErr.EXOKAY)):
          # Table 4-19 gives CleanUnique three rows, all completing Comp_UC: SC
          # becomes UC and SD becomes UD. The grant confers the write right; it
          # does not wash the line clean, and this is the join again rather than
          # a fixed UC.
          self.cache_state[line] = req_final_state(op, held, _I(req.rsp_resp))
    elif op == int(ReqOpcode.MAKE_UNIQUE):
      # Acquire Unique-Dirty WITHOUT a data transfer; materialize a zero image
      # sized to the coherence line so a later snoop can forward real beats.
      self.evict_for_capacity(line)
      self.cache_state[line] = req_final_state(op, held, _I(req.rsp_resp))
      self.drop_line_data(line)
      n_beats = CACHE_LINE_BYTES // self.bus.cfg.data_bytes
      self.cache_data[line] = [0] * n_beats

  # ==========================================================================
  # Test/scoreboard accessor: the held state for a line (I when never cached).
  # ==========================================================================
  def get_cache_line(self, addr):
    """Test accessor: the held beats and the dirty byte mask for a line.

    A test that has to say WHICH bytes survived a merge cannot ask the wire,
    because the wire never carries the mask.
    """
    line = self.line_addr(addr)
    return (list(self.cache_data.get(line, [])),
            list(self.cache_dirty_be.get(line, [])))

  def get_cache_state(self, addr):
    return self.cache_state.get(self.line_addr(addr), int(Resp.I))
