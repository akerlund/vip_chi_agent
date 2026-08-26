################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_driver_rni.sv (serial request path).
#
# RN-I initiator. driver_start() forks the credit loop, activates the link, and
# runs seq_loop(): pull a request item off the sequencer, drive the REQ flit,
# and run the direction-specific completion collection (write: DBID grant ->
# DAT burst -> Comp; read: CompData burst). Link-credit is counted per channel
# by VipChiLcrdMgr; the credit loop advertises RN-I receive credits (RSP/DAT)
# and returns send credits on inbound LCRDV pulses.
#
# Timing discipline (the ChiBus contract): every SV `@(rni_cb)` becomes
# `await bus.rising()`, every sampled `rni_cb.rx*` becomes `bus.get(...)` read
# in the post-edge region (returns the value the peer drove last cycle, because
# cocotb defers `.value=` writes to the ReadWrite region -- the clocking-block
# output-skew / NBA feel), and every driven `rni_cb.tx* <= v` becomes
# `bus.drive(...)` / `bus.drive_flit(...)`.
#
# Scope: this is the Tier-A serial cut. The multi-outstanding / mixed pipeline
# (cfg.multi_outstanding) and the coherent RN-F extension hooks are Tier B/C;
# cfg.multi_outstanding defaults False so seq_loop() is the only path here.
#
# Port deviation (PORTING_PLAN §11.3): SV exposes exact-CHI-E behavior through a
# vip_chi_driver_rni_e subclass wired by an agent factory hook
# (vip_chi_agent_e.sv:59). The port folds the E-only field handling into this
# generic driver via runtime `cfg.is_e` branches instead of a subclass.
#
################################################################################

from __future__ import annotations

import cocotb

from pyuvm import uvm_driver, ConfigDB

from vip_chi_reject import reject
from vip_chi_types_pkg import (
  req_opcode_combined_cmo_is_persist, req_dwt_grant_uses_return_path,
  Role, Dir, DatOpcode, ReqOpcode, RspOpcode, RawChannel,
  req_opcode_is_atomic, lasm, chi_xfer_dat_beats, req_bit17_is_dodwt,
  req_has_modeled_completion, req_completion_uses_dat,
  is_final_rsp_completion, unpack,
  req_opcode_is_combined_write_cmo, req_opcode_combined_cmo_is_persist,
)
from vip_chi_if import ChiBus

# Combined Write + CMO membership, and the persistent subset, are asked of the
# TYPE PACKAGE rather than kept here. They were spelled out locally so the
# driver's response expectations read in one place, and the cost of that showed
# the first time the family grew: a local list is a copy, and this file held two
# of them plus a third in _WRITE_DATA_OPCODES. All three missed the coherent
# forms, and the failure was a driver that thought a combined write carried no
# data at all.
# Cycles the raw-injection path will hold a request's TXSACTIVE window open
# waiting for a completion it does not itself collect.
#
# Matched to the CHECKER's completion timeout rather than picked: past that
# point the checker has already reported the transaction as never completed, by
# name and with the TxnID, and a sideband still up would only add a second and
# vaguer report of the same thing. It also has to be BOUNDED at all, because
# wait_for_drain refuses to take the link down while a window is open -- a
# watcher that waited forever for a completion nobody will send would hang the
# deactivation rather than fail it.
_RAW_COMPLETION_WATCH_CYCLES_C = 1024
from vip_chi_lcrd_mgr import VipChiLcrdMgr
from vip_chi_cfg_agent import VipChiCfgAgent

# Writes whose REQ is followed by a DAT burst (after the DBID grant).
_WRITE_DATA_OPCODES = {
  int(ReqOpcode.WRITE_NO_SNP_FULL), int(ReqOpcode.WRITE_NO_SNP_PTL),
  int(ReqOpcode.WRITE_BACK_FULL), int(ReqOpcode.WRITE_CLEAN_FULL),
  int(ReqOpcode.WRITE_UNIQUE_FULL), int(ReqOpcode.WRITE_UNIQUE_PTL),
}

# Atomics that return data (AtomicLoad/Swap/Compare); AtomicStore does not.
_ATOMIC_RETURN_DATA = (
  set(range(int(ReqOpcode.ATOMIC_LOAD_0), int(ReqOpcode.ATOMIC_LOAD_7) + 1))
  | {int(ReqOpcode.ATOMIC_SWAP), int(ReqOpcode.ATOMIC_COMPARE)}
)

_I = int

# Mixed-pipeline transaction kinds. A READ and a non-store ATOMIC complete on
# inbound DAT (CompData); a WRITE, a store ATOMIC and a PERSIST complete on
# inbound RSP -- so the two completion monitors never contend.
_KIND_READ = "READ"
_KIND_WRITE = "WRITE"
_KIND_ATOMIC = "ATOMIC"
_KIND_PERSIST = "PERSIST"


class _MxCtx:
  """One in-flight transaction in the multi-outstanding pipeline."""

  __slots__ = (
    "kind", "item", "dbid", "grant_seen", "comp_seen", "data_sent",
    "read_done", "receipt_seen", "persist_seen", "compack_sent",
    "retry_pending", "retried", "pcrd_type", "req_src_id", "req_tgt_id",
    "dat_beats",
  )

  def __init__(self, kind, item):
    self.kind = kind
    self.item = item
    self.dbid = 0
    self.grant_seen = False
    self.comp_seen = False
    self.data_sent = False
    self.read_done = False
    # Read-data beats banked for THIS transaction so far. A completer may
    # interleave the beats of several reads on the DAT channel, so a beat is
    # filed against the transaction its TxnID names rather than assumed to
    # belong to whichever read is currently being collected.
    self.dat_beats = []
    self.receipt_seen = False
    # Separated persist: Comp says Point of Coherency, Persist says Point of
    # Persistence, and the transaction is not done until BOTH have arrived -- or
    # a single CompPersist has, which is both at once. comp_seen alone would
    # retire on the Comp and leave the Persist to arrive against a closed
    # transaction.
    self.persist_seen = False
    self.compack_sent = False
    self.retry_pending = False
    self.retried = False
    self.pcrd_type = 0
    self.req_src_id = _I(item.src_id)
    self.req_tgt_id = _I(item.tgt_id)


class vip_chi_driver_rni(uvm_driver):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.bus = None
    self.cfg = None
    # Which responses retired the most recent combined write's obligations; see
    # collect_combined_write_obligations.
    self.combined_completion_log = []
    self.role = Role.RNI

    self.next_txn_id = 0
    self.outstanding_ids = []

    # Multi-outstanding (opt-in via cfg.multi_outstanding) pipeline state.
    self.mx_ctx = []          # in-flight _MxCtx entries
    self._accepted = []       # items accepted off the sequencer, awaiting issue
    self.pcrd_pool = {}       # PCrdType -> banked PCrdGrant credit count
    # PCrdType -> (granter SrcID, our own NodeID), both taken off the PCrdGrant.
    # PCrdReturn must carry the granter as its TgtID ("the TgtID must match the
    # SrcID of the credit that was obtained") and this requester as its SrcID, so
    # both identities have to survive banking; the count alone cannot say where
    # to send the credit back. They come off the grant rather than out of config
    # because the grant is addressed to us: its TgtID is this requester.
    self.pcrd_src = {}
    self.n_pcrd_returned = 0  # credits handed back with PCrdReturn
    self.n_pcrd_budget_violation = 0  # banked credits past cfg.max_pcrd_budget
    self.n_pcrd_leak = 0              # credits still banked at end of test

    self.req_lcrd = VipChiLcrdMgr("req_lcrd_mgr")
    self.rsp_lcrd = VipChiLcrdMgr("rsp_lcrd_mgr")
    self.dat_lcrd = VipChiLcrdMgr("dat_lcrd_mgr")
    self.rsp_lcrdv_pending = 0
    self.dat_lcrdv_pending = 0
    self.seen_rx_dat_flit = False

    # One-shot latch for cfg.lasm_abort_activation (see activate_link): the
    # negative control aborts a single bring-up, so the LASM check has exactly
    # one illegal transition to report. Cleared in handle_reset, so a test that
    # resets mid-run gets the control again on the next activation rather than
    # silently losing it.
    self.lasm_abort_done = False

    # One-shot latch for cfg.flit_without_flitpend: the control drops the
    # FLITPEND announcement in front of one flit and then stops, so the rest of
    # the run stays legal and the rule is proved to fire rather than jammed.
    self.flit_without_pend_done = False
    # One-shot latch for cfg.flitpend_without_valid, same reasoning as the abort
    # above: the control fires once so the count a test asserts on is
    # unambiguous.
    self.flitpend_negctl_done = False

    # One-shot latch for cfg.lasm_reactivate_during_deactivate.
    self.lasm_race_done = False
    # Shadow of the activation request last driven; see _drive_link_req.
    self._req_driven = False

    # Forked-coroutine registry so handle_reset() can tear down the credit loop
    # (cocotb does not cascade-kill start_soon children when the agent kills the
    # top-level driver_start()).
    self._driver_tasks = []
    self.agent_owned = False

    # TX flit-driving mutex (SV tx_flit_arb). Serializes concurrent flit drivers
    # -- the coherent RN-F snoop responder vs the request thread -- on the shared
    # tx*flit signals. Uncontended in the RN-I cut (one TX thread), so acquire
    # returns without advancing time -> byte-identical RN-I timing.
    self._tx_flit_locked = False

    # TXSACTIVE outstanding-window state. See tx_activity_begin().
    self.tx_active_count = 0
    self._tx_active_extend = 0

  # ==========================================================================
  def build_phase(self):
    self.bus = ConfigDB().get(self, "", "vif")
    try:
      self.cfg = ConfigDB().get(self, "", "cfg")
    except Exception:
      self.cfg = VipChiCfgAgent("default_cfg")
      self.cfg.role = Role.RNI
    try:
      self.role = Role(ConfigDB().get(self, "", "role"))
    except Exception:
      self.role = Role.RNI
    self.reset_credit_state()

  # -- fork registry ---------------------------------------------------------
  def _spawn(self, coro):
    self._driver_tasks = [t for t in self._driver_tasks if not t.done()]
    t = cocotb.start_soon(coro)
    self._driver_tasks.append(t)
    return t

  def _kill_driver_tasks(self):
    for t in self._driver_tasks:
      try:
        if not t.done():
          t.kill()
      except Exception:
        pass
    self._driver_tasks = []

  # ==========================================================================
  # Credit bookkeeping.
  # ==========================================================================
  def reset_credit_state(self):
    self.req_lcrd.reset(self.cfg.req_send_credit_cap, 0)
    self.rsp_lcrd.reset(self.cfg.rsp_send_credit_cap, 0)
    self.dat_lcrd.reset(self.cfg.dat_send_credit_cap, 0)
    self.rsp_lcrdv_pending = 0
    self.dat_lcrdv_pending = 0
    # Remaining REQ sends that step around the credit manager, drawn from
    # cfg.req_send_without_credit_negctl at reset.
    self.req_send_without_credit_remaining = int(
      self.cfg.req_send_without_credit_negctl)
    # Set while cfg.lasm_ack_delay_cycles is still holding this receiver's
    # acknowledge down. Read by drive_idle_sideband and written only by
    # ack_delay_loop, so that method stays a pure function of wires and flags.
    self._ack_held = bool(self.cfg.lasm_ack_delay_cycles)
    # Graceful-deactivation state (see deactivate_watch).
    #
    # link_deactivating suppresses NEW receive-credit grants: a receiver may not
    # issue L-credits once the link is coming down, or the drain would be chasing
    # a pool the credit loop keeps refilling and would never finish.
    #
    # rsp/dat_lcrd_granted are the credits this node has advertised and the peer
    # has not yet spent -- the mirror image of the send-side managers, and the
    # half of quiescence a sender cannot see from its own pools. The link is only
    # drained when BOTH halves are empty at both ends.
    self.link_deactivating = False
    self.rsp_lcrd_granted = 0
    self.dat_lcrd_granted = 0
    self.seen_rx_dat_flit = False

  def schedule_initial_credit_grants(self):
    # RN-I consumes inbound RSP/DAT, so it advertises those receive credits.
    self.rsp_lcrdv_pending += self.cfg.initial_rsp_credits
    self.dat_lcrdv_pending += self.cfg.initial_dat_credits

  def schedule_rsp_credit_return(self):
    self.rsp_lcrdv_pending += 1

  def schedule_dat_credit_return(self):
    self.dat_lcrdv_pending += 1

  # ==========================================================================
  # Interface reset.
  # ==========================================================================
  def reset_outputs(self):
    bus = self.bus
    self._req_driven = False
    bus.drive(txlinkactivereq=0, txlinkactiveack=0, txsactive=0)
    bus.drive(txreqflitpend=0, txreqflitv=0)
    bus.drive_flit("req", {})
    bus.drive(txrspflitpend=0, txrspflitv=0, txrsplcrdv=0)
    bus.drive_flit("rsp", {})
    bus.drive(txdatflitpend=0, txdatflitv=0, txdatlcrdv=0)
    bus.drive_flit("dat", {})
    # Reset-idle controls, applied last so they overwrite the parked values
    # rather than racing them. E section 14.1.3 / D section 13.1.3 requires
    # exactly TX***LCRDV, TX***FLITV, TXLINKACTIVEREQ and RXLINKACTIVEACK
    # deasserted during reset and then says "All other signals can be any
    # value", so the first knob drives what that sentence permits and the second
    # drives what the list names.
    if self.cfg is not None:
      if self.cfg.reset_permitted_high:
        bus.drive(txsactive=1, txreqflitpend=1, txrspflitpend=1,
                  txdatflitpend=1)
      if self.cfg.reset_idle_violation:
        bus.drive(txrsplcrdv=1)

  def reset_vif(self):
    self.reset_outputs()

  def release_reset_outputs(self):
    """Drop the reset-window TXSACTIVE, in the cycle rst_n rises.

    cfg.reset_permitted_high parks it high for the reset window, which
    E section 14.1.3 / D section 13.1.3 permits. It must not survive the release:
    the deactivate-when-idle rule requires the sideband low while the LASM sits
    in STOP, and the link sits in STOP from reset release until the activation
    handshake completes.

    The agent calls this on the rst_n TRANSITION and not at the first non-reset
    clock edge. A cocotb write lands at the end of the timestep it is made in, so
    a write made from a clock-edge callback is first SAMPLED at the following
    edge -- and the following edge is one the checker has already judged.

    FLITPEND is left alone: section 14.4 / D 13.4 permits holding it permanently
    asserted. So is the reset-window L-Credit, and that one is a limit rather
    than a choice -- the SystemVerilog twin drives its outputs through a clocking
    block, whose value at the first post-release edge was decided at the last
    reset edge, before the driver could know the release was coming. Neither port
    can be clean there, so both leak the parked credit for exactly one judged
    cycle and tc_chi_reset_idle_scope asserts that it is reported.
    """
    self.bus.drive(txsactive=0)

  def handle_reset(self):
    self._kill_driver_tasks()
    self.next_txn_id = 0
    self.outstanding_ids = []
    self.mx_ctx = []
    self._accepted = []
    self.pcrd_pool = {}
    self.pcrd_src = {}
    self._tx_flit_locked = False
    self.tx_active_count = 0
    self._tx_active_extend = 0
    self.lasm_abort_done = False
    self.flitpend_negctl_done = False
    self.flit_without_pend_done = False
    self.lasm_race_done = False
    # A reset takes the link down by force, which is not the graceful path: the
    # published "done" would otherwise survive as a claim about a drain that
    # never happened.
    self.cfg.link_deactivate_done = False
    self.reset_credit_state()
    self.reset_outputs()

  def drive_idle_sideband(self):
    # The plain mirror, deliberately: it is ALREADY the one-cycle delay that
    # E section 14.6.3 / D 13.6.3 wants. The drive is non-blocking, so the
    # acknowledge lands one cycle behind the request it mirrors, rising and
    # falling -- which is exactly "RXACK must not change before TXREQ".
    #
    # An earlier attempt gated this on self._req_driven to enforce the same rule
    # explicitly. That was over-engineering and it BROKE the invariant: an
    # attribute is not a wire, so two callers in one cycle could disagree, and
    # the acknowledge fell a cycle early. Reading only wires is what makes this
    # call-order independent.
    # 14.6.3's requirement on the OBSERVER: while the peer's two outputs have
    # arrived out of order and the second has not yet followed, neither of our
    # outputs may move. This writer recomputes its intent every cycle, so
    # SKIPPING is the whole hold -- an unwritten signal keeps its value and the
    # same intent is re-derived next cycle. It must NOT re-drive the wires
    # instead: txlinkactivereq is written by the activation path, and a writer
    # that seizes a signal it does not own loses that path's one-shot request,
    # which hung tc_chi_coh_d_reset_mid_snoop. ChiBus owns the flag; see there.
    if self.bus.input_race_hold():
      return

    self.bus.drive(txlinkactiveack=(
      0 if self._ack_held else self.bus.get("rxlinkactivereq")))

  # --------------------------------------------------------------------------
  async def ack_delay_loop(self):
    """Hold this receiver's acknowledge down for cfg.lasm_ack_delay_cycles.

    Counted while the peer's request is UP, so it measures the peer's dwell in
    ACTIVATE rather than wall-clock time, and spent once: the delay is about
    the bring-up, and re-arming it on a later re-activation would make a test
    that cycles the link stall a different number of times each pass.
    """
    remaining = int(self.cfg.lasm_ack_delay_cycles)
    self._ack_held = bool(remaining)
    while remaining:
      await self.bus.rising()
      if self.bus.get("rxlinkactivereq"):
        remaining -= 1
    self._ack_held = False

  # ==========================================================================
  # TXSACTIVE outstanding-window drive.
  #
  # TXSACTIVE tells the receiver this node MAY have snoopable transactions
  # outstanding, so it must stay asserted across that WHOLE window -- not
  # bracket each flit. A per-flit pulse drops the signal to zero while requests
  # are still in flight, which is precisely the interval a receiver reads it to
  # decide whether it can gate its snoop logic.
  #
  # So the signal is a level driven from a counter rather than a pulse driven
  # by whoever happens to be sending. Every transaction brackets itself with
  # begin/end, and the count -- not any one transaction -- decides the level.
  # That is what makes overlapping transactions correct: with the pipeline
  # running, one transaction retiring no longer drops the sideband out from
  # under the others still outstanding.
  #
  # The window counted here is EVERY outstanding transaction, not just the
  # snoopable ones. Over-assertion is always legal (the signal is permissive --
  # "may have"), under-assertion is the protocol violation, and counting
  # uniformly keeps one mechanism across roles that have no snoopable traffic
  # at all. cfg.txsactive_extend_max_cycles then holds it a bounded number of
  # cycles past the close, modelling a node that speculates on more traffic.
  #
  # Assertion is immediate (in the caller's cycle, as the old per-flit pulse
  # was) and only the DROP is deferred to the per-cycle tick, so the sideband
  # still rises in the same cycle as the first flit it covers.
  # ==========================================================================
  def tx_activity_begin(self):
    self.tx_active_count += 1
    self._tx_active_extend = 0
    self.bus.drive(txsactive=1)

  def tx_activity_end(self):
    if self.tx_active_count > 0:
      self.tx_active_count -= 1
    if self.tx_active_count == 0:
      self._tx_active_extend = max(0, int(self.cfg.txsactive_extend_max_cycles))

  # Called once per cycle from credit_loop -- once, so the extension counts
  # cycles rather than callers. With the default extension of 0 the drop lands
  # on the first edge after the window closes, which is the cycle the per-flit
  # pulse used to drop on.
  def tx_activity_tick(self):
    if self.tx_active_count > 0:
      return
    if self._tx_active_extend > 0:
      self._tx_active_extend -= 1
      return
    self.bus.drive(txsactive=0)

  # ==========================================================================
  # TX flit-driving mutex + coherent-role extension hooks (empty in RN-I).
  #
  # A coroutine that drives a tx*flit group brackets its beat section with
  # acquire/release so concurrent drivers (the RN-F snoop responder vs the
  # request thread) never write the shared TX signals in the same timestep. When
  # free, acquire returns immediately (no edge) -- so the single-threaded RN-I
  # path is timing-unchanged.
  #
  # txsactive is deliberately NOT among the signals this protects. It is a level
  # driven from tx_active_count, so two concurrent senders compute the same
  # value and cannot disagree; it also has to stay asserted ACROSS the gaps when
  # neither holds the key, which a mutex-guarded signal could not.
  # ==========================================================================
  async def acquire_tx_flit(self):
    while self._tx_flit_locked:
      await self.bus.rising()
      self.drive_idle_sideband()
    self._tx_flit_locked = True

  def release_tx_flit(self):
    self._tx_flit_locked = False

  async def announce_flit(self, channel):
    """Raise FLITPEND for the cycle before a flit goes out.

    E section 14.4 / D section 13.4 require the signal asserted exactly one
    cycle before a flit is sent -- it is a look-ahead a receiver uses to ungate
    its capture path, so a flit that arrives without it can be missed entirely
    by a conformant DUT.

    Called after every wait the send performs (credit, tx-flit lock) and never
    before one: anything that can block between the announcement and the flit
    would leave FLITPEND asserted over cycles that carry nothing. That is legal
    -- the same section permits asserting and then deasserting without sending
    -- but it would stop this being the one-cycle lead the rule is about.
    """
    bus = self.bus
    await bus.rising()
    self.drive_idle_sideband()
    # Negative control (cfg.flit_without_flitpend): skip the announcement once,
    # so exactly one flit goes out with FLITPEND low in the cycle before it and
    # CHI_*_VALID_REQUIRES_PEND has a real violation to catch. Returning without
    # driving leaves FLITPEND at the 0 the previous send cleared it to.
    if self.cfg.flit_without_flitpend and not self.flit_without_pend_done:
      self.flit_without_pend_done = True
      return
    bus.drive(**{f"tx{channel}flitpend": 1})

  # Forked alongside credit_loop; RN-F starts its SNP receive-credit loop +
  # snoop responder here. No-op in RN-I.
  def extra_rx_channels(self):
    pass

  # Runs once after activate_link; RN-F advertises its initial SNP receive
  # credits. No-op in RN-I.
  def post_activate_hook(self):
    pass

  # Runs as each request retires in seq_loop; RN-F records the granted coherent
  # state into its cache model. No-op in RN-I.
  def on_transaction_complete(self, req):
    pass

  # ==========================================================================
  # Outstanding-TxnID pool (bounded by cfg.max_outstanding_*, not the ID space).
  # ==========================================================================
  def _txn_in_flight(self, tid):
    return tid in self.outstanding_ids

  def alloc_txn_id(self):
    width = self.cfg_txn_mask()
    while True:
      cand = self.next_txn_id & width
      self.next_txn_id = (self.next_txn_id + 1) & width
      if not self._txn_in_flight(cand):
        self.outstanding_ids.append(cand)
        if len(self.outstanding_ids) > self.cfg.observed_peak_outstanding:
          self.cfg.observed_peak_outstanding = len(self.outstanding_ids)
        return cand

  def cfg_txn_mask(self):
    return (1 << self.bus.cfg.txn_id_width) - 1

  def free_txn_id(self, tid):
    if tid in self.outstanding_ids:
      self.outstanding_ids.remove(tid)

  # Signal a pipelined sequence that this item's transaction has fully retired.
  # Harmless (no-op) for the serial, non-pipelined path where no event was set.
  # The one retire point both paths share: the serial loop reaches it through
  # _complete_item(), the mixed pipeline calls it directly as a context is
  # deleted. Closing the TXSACTIVE window here rather than at either call site
  # is what keeps the sideband up across a pipelined run -- the count only
  # reaches zero once the LAST outstanding transaction has retired.
  def _signal_mo_done(self, item):
    self.tx_activity_end()
    evt = getattr(item, "_mo_evt", None)
    if evt is not None:
      evt.set()

  def _complete_item(self, req):
    self._signal_mo_done(req)
    self.seq_item_port.item_done()

  # ==========================================================================
  # run_phase: standalone drivers self-drive; agent-owned ones stand down (the
  # agent forks driver_start() and owns the reset watcher).
  # ==========================================================================
  async def run_phase(self):
    if self.agent_owned:
      return
    self.reset_vif()
    while self.bus.in_reset():
      await self.bus.rising()
    await self.driver_start()

  # ==========================================================================
  async def driver_start(self):
    self._spawn(self.credit_loop())
    # Watches cfg.link_deactivate_request. A separate task rather than a step in
    # the sequence loop, because the loop blocks on the sequencer: a test that
    # has stopped sending is exactly a test whose driver is parked waiting for
    # the next item and would never look at the flag.
    self._spawn(self.deactivate_watch())
    # Counts cfg.lasm_ack_delay_cycles down in a task of its own, because
    # drive_idle_sideband runs from several tasks in one cycle and a decrement
    # inside it would run as many times.
    self._spawn(self.ack_delay_loop())
    # Coherent-role extension point: RN-F forks its SNP receive-credit loop and
    # snoop responder here. No-op in RN-I.
    self.extra_rx_channels()
    await self.activate_link()
    # Coherent-role extension point: RN-F advertises its initial SNP receive
    # credits now the link is up. No-op in RN-I.
    self.post_activate_hook()
    if self.cfg.multi_outstanding:
      await self.seq_loop_mixed_pipelined()
    else:
      await self.seq_loop()

  # --------------------------------------------------------------------------
  async def credit_loop(self):
    bus = self.bus
    while True:
      await bus.rising()
      self.drive_idle_sideband()
      self.tx_activity_tick()

      if bus.get("rxdatflitv"):
        self.seen_rx_dat_flit = True

      # link_deactivating holds both channels for a different reason than
      # hold_dat_credit does: a receiver must not issue L-credits once the link
      # is coming down. Without it the drain could never finish -- every credit
      # the peer returned would be handed straight back.
      dat_hold = ((self.cfg.hold_dat_credit and self.seen_rx_dat_flit)
                  or self.link_deactivating)
      rsp_grant = bool(self.rsp_lcrdv_pending) and not self.link_deactivating

      bus.drive(txrsplcrdv=1 if rsp_grant else 0)
      bus.drive(txdatlcrdv=1 if (self.dat_lcrdv_pending and not dat_hold) else 0)

      if rsp_grant:
        self.rsp_lcrdv_pending -= 1
        self.rsp_lcrd_granted += 1
      if self.dat_lcrdv_pending and not dat_hold:
        self.dat_lcrdv_pending -= 1
        self.dat_lcrd_granted += 1

      # Every inbound flit spends one of the credits advertised above, INCLUDING
      # an L-credit return: the return is itself a flit and consumes the credit
      # it hands back. That is what lets the drain converge with no separate
      # accounting for the two kinds.
      if bus.get("rxrspflitv") and self.rsp_lcrd_granted:
        self.rsp_lcrd_granted -= 1
      if bus.get("rxdatflitv") and self.dat_lcrd_granted:
        self.dat_lcrd_granted -= 1

      if bus.get("rxreqlcrdv"):
        self.req_lcrd.return_credit()
      if bus.get("rxrsplcrdv"):
        self.rsp_lcrd.return_credit()
      if bus.get("rxdatlcrdv"):
        self.dat_lcrd.return_credit()

  # --------------------------------------------------------------------------
  async def wait_for_credit(self, lcrd):
    bus = self.bus
    while True:
      if lcrd.try_acquire_credit():
        return
      await bus.rising()
      self.drive_idle_sideband()

  # --------------------------------------------------------------------------
  # Hold an assembled flit for its channel's configured transmit delay, then
  # take the credit.
  #
  # BEFORE the credit and before acquire_tx_flit(), on purpose. The delay models
  # a source that is not ready yet, which is upstream of asking for permission
  # to send; taking the TX-flit mutex first would make one channel's delay stall
  # every other channel's driver, and holding a credit across it would reserve
  # link resources for a flit that has not been offered.
  #
  # Per FLIT, which inside a DAT burst means per beat. That is what the knob
  # says -- a transmit delay on a channel -- and gapped beats are legal: a beat
  # counter counts FLITV cycles, not consecutive ones.
  #
  # NOT applied to L-credit returns. Those are link-layer bookkeeping rather
  # than traffic, and delaying a credit return starves the peer's send side
  # instead of shaping this side's.
  # --------------------------------------------------------------------------
  async def wait_channel_delay(self, cycles):
    bus = self.bus
    for _ in range(cycles):
      await bus.rising()
      self.drive_idle_sideband()

  async def wait_req_credit(self):
    await self.wait_channel_delay(self.cfg.draw_req_valid_delay())

    # The credit manager refusing at zero is the only thing that keeps this
    # driver off the wire without permission, so a control that needs an
    # uncredited flit has to step around it rather than configure it. Bounded by
    # the knob's count: each send spends one bypass and the driver goes back to
    # asking.
    if self.req_send_without_credit_remaining:
      self.req_send_without_credit_remaining -= 1
      return

    await self.wait_for_credit(self.req_lcrd)

  async def wait_rsp_credit(self):
    await self.wait_channel_delay(self.cfg.draw_rsp_valid_delay())
    await self.wait_for_credit(self.rsp_lcrd)

  async def wait_dat_credit(self):
    await self.wait_channel_delay(self.cfg.draw_dat_valid_delay())
    await self.wait_for_credit(self.dat_lcrd)

  # --------------------------------------------------------------------------
  async def activate_link(self):
    bus = self.bus
    await bus.rising()
    self.drive_idle_sideband()

    # Negative control (cfg.lasm_abort_activation): raise the activation request
    # and withdraw it again before the completer has acknowledged it, which steps
    # the LASM out of ACTIVATE without ever reaching RUN. A requester is not
    # entitled to do that -- once it has asked for the link it must wait for the
    # acknowledge -- so it is a genuine illegal transition rather than an
    # unusual-but-legal sequence, which is what makes it a usable control.
    #
    # It fires ONCE, before the real activation below, so the check has exactly
    # one aborted bring-up to report and the count a negative control asserts on
    # is unambiguous. The link then activates normally, so the rest of the test
    # is ordinary traffic.
    if self.cfg.lasm_abort_activation and not self.lasm_abort_done:
      self.lasm_abort_done = True
      await self._drive_link_req_held(1)
      await bus.rising()
      self.drive_idle_sideband()
      await self._drive_link_req_held(0)
      await bus.rising()
      self.drive_idle_sideband()
      # Let the completer's mirrored acknowledge retire before asking again, so
      # the aborted attempt and the real one are two separate bring-ups rather
      # than one ambiguous glitch.
      for _ in range(4):
        await bus.rising()
        self.drive_idle_sideband()

    await self.wait_lasm_req_delay()

    await self._drive_link_req_held(1)
    while True:
      await bus.rising()
      self.drive_idle_sideband()
      if bus.in_reset() or bus.get("rxlinkactiveack"):
        break
    self.schedule_initial_credit_grants()
    await self.drive_flitpend_negctl()

  # --------------------------------------------------------------------------
  def _observed_lasm(self):
    """The link state this endpoint currently observes.

    One LASM per link, so this node's own request and the peer's mirrored
    acknowledge are the whole state -- the same pair the checkers read. The
    request comes from the shadow rather than the wire, mirroring the SV port
    where a clocking-block output cannot be sampled at all.
    """
    return lasm(self._req_driven, bool(self.bus.get_or("rxlinkactiveack")))

  def _drive_link_req(self, value):
    """The only place txlinkactivereq is driven, so the shadow cannot drift."""
    self._req_driven = bool(value)
    self.bus.drive(txlinkactivereq=1 if value else 0)

  async def _drive_link_req_held(self, value):
    """The same write, with 14.6.3's obligation on the OBSERVER honoured.

    While the peer's two outputs have arrived out of order and the second has
    not yet followed, none of our outputs may move. drive_idle_sideband meets
    that by SKIPPING, which works only because it recomputes its intent every
    cycle. This writer is a ONE-SHOT -- skipping would lose the request
    altogether -- so it waits instead, and being a coroutine is what lets it.
    reset_vif keeps calling the plain writer: 14.1.3 has both peers holding the
    sideband idle through reset, and ChiBus clears the hold there, so there is
    nothing to wait out.

    Bounded by construction, not by a timeout: the hold is armed for exactly one
    cycle and resolve takes precedence over arm, so it cannot chain and this
    cannot wait more than one.
    """
    while self.bus.input_race_hold():
      await self.bus.rising()
      self.drive_idle_sideband()

    self._drive_link_req(value)

  async def wait_lasm_req_delay(self):
    """Hold off the activation request by cfg.lasm_req_delay_by_state.

    Indexed by the state the link is in RIGHT NOW, and sampled once before the
    wait: the delay is a property of the state the requester decided to act
    from, and re-reading it each cycle would make the wait chase a moving index
    and never settle.
    """
    cycles = int(self.cfg.lasm_req_delay_by_state[int(self._observed_lasm())])
    for _ in range(cycles):
      await self.bus.rising()
      self.drive_idle_sideband()

  async def drive_flitpend_negctl(self):
    """Raise FLITPEND on REQ and RSP for one cycle with no flit behind it.

    Emitted here, once, with the link up and before any traffic, so the two
    rules have exactly one lone FLITPEND to report and nothing else on the wire
    can be confused for it. Both channels in the same cycle because the rules are
    per channel and one pulse should exercise each exactly once.
    """
    if not self.cfg.flitpend_without_valid or self.flitpend_negctl_done:
      return
    self.flitpend_negctl_done = True

    bus = self.bus
    await self.acquire_tx_flit()
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(txreqflitpend=1, txrspflitpend=1)

    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(txreqflitpend=0, txrspflitpend=0)
    self.release_tx_flit()

  # --------------------------------------------------------------------------
  async def deactivate_watch(self):
    """Graceful link deactivation: the second half of the LASM cycle.

    Without this the VIP could only ever take a link down by RESET, so the two
    tear-down edges (RUN -> DEACTIVATE, DEACTIVATE -> STOP) were checked but
    never once walked, and every rule that only holds while a link is coming
    down was untestable by construction.

    The order below is the protocol's, and each step exists because the one
    before it makes the next legal:

      1. wait for the traffic to retire. A deactivation with a transaction still
         in flight would strand it -- the completion has nowhere to arrive.
      2. stop advertising receive credits. A receiver may not issue L-credits
         once the link is coming down, and a drain racing a credit loop that
         keeps refilling the pool would never converge.
      3. drop LINKACTIVEREQ. The link is now in DEACTIVATE, which is the one
         state in which a sender may still transmit -- and only L-credit
         returns.
      4. return every credit still held, on all three channels.
      5. wait for the peer to do the same, which is what finally drops the
         acknowledge and puts the link in STOP with both pools empty.

    Lowering the request afterwards brings the link back up, so a single test
    can prove the whole cycle rather than only its first half.
    """
    bus = self.bus

    # Spawned alongside activate_link rather than after it, so wait for the link
    # to be up before watching for a request to take it down. A test that set the
    # flag before time 0 would otherwise withdraw a request never raised.
    while not bus.get("rxlinkactiveack"):
      await bus.rising()

    while True:
      # Idle here on every test that never asks, at no cost beyond the poll the
      # credit loop is already making anyway.
      while not self.cfg.link_deactivate_request:
        await bus.rising()
        self.drive_idle_sideband()

      # 1. Let the traffic retire. _tx_active_extend is waited on as well as the
      # count: TXSACTIVE says this node MAY have snoopable transactions
      # outstanding, and taking a link down while still claiming that tells the
      # receiver to keep watching a link that is about to stop existing.
      while self.outstanding_ids or self.tx_active_count or self._tx_active_extend:
        await bus.rising()
        self.drive_idle_sideband()

      # The count reaching zero only ARMS the drop; tx_activity_tick lowers the
      # signal on its next call, so give it that cycle before the request falls.
      await bus.rising()
      self.drive_idle_sideband()

      # 2 + 3. Stand the grants down, then withdraw the request.
      self.link_deactivating = True
      await self._drive_link_req_held(0)

      await bus.rising()
      self.drive_idle_sideband()

      # Negative control (cfg.lasm_reactivate_during_deactivate): change our mind
      # half way through the tear-down. The link is in DEACTIVATE (request low,
      # acknowledge still high), so raising the request again makes the pair
      # {1,1} = RUN -- a jump the cycle does not allow, since DEACTIVATE may only
      # advance to STOP.
      #
      # Placed HERE, before the drain, because that is what makes it a race
      # rather than a malformed sequence: the completer is still returning
      # credits and has not yet decided to drop its acknowledge.
      if self.cfg.lasm_reactivate_during_deactivate and not self.lasm_race_done:
        self.lasm_race_done = True
        await self._drive_link_req_held(1)
        await bus.rising()
        self.drive_idle_sideband()
        await self._drive_link_req_held(0)
        await bus.rising()
        self.drive_idle_sideband()

      # 4. Hand back what this node holds.
      await self.drain_tx_credits()

      # 5. And wait for the peer to hand back what it holds. The completer drops
      # its acknowledge on the same condition, so this loop ends at STOP.
      while self.rsp_lcrd_granted or self.dat_lcrd_granted:
        await bus.rising()
        self.drive_idle_sideband()

      # Queued-but-unsent grants are dropped rather than carried across the gap:
      # they were promises about a link that no longer exists, and re-activation
      # advertises a fresh budget from schedule_initial_credit_grants().
      self.rsp_lcrdv_pending = 0
      self.dat_lcrdv_pending = 0
      self.seen_rx_dat_flit = False

      self.cfg.link_deactivate_done = True
      self.logger.info(
        f"[{self.get_name()}] link deactivated: every L-credit returned, "
        f"link in STOP")

      # Held down until the test asks for the link back.
      while self.cfg.link_deactivate_request:
        await bus.rising()
        self.drive_idle_sideband()

      self.link_deactivating = False
      self.cfg.link_deactivate_done = False
      await self.activate_link()
      self.post_activate_hook()
      self.logger.info(
        f"[{self.get_name()}] link reactivated after a graceful deactivation")

  # --------------------------------------------------------------------------
  async def drain_tx_credits(self):
    """Return every send-side L-credit this node still holds, one flit each.

    An L-credit return is a flit like any other and is sent UNDER one of the
    credits it returns, so the loop needs no separate budget: acquiring is what
    makes the send legal, and the pool empties itself. That symmetry is also why
    the credit shadow in the checkers needs no special case for it.
    """
    for channel, lcrd in (("req", self.req_lcrd),
                          ("rsp", self.rsp_lcrd),
                          ("dat", self.dat_lcrd)):
      while lcrd.try_acquire_credit():
        await self.drive_lcrd_return(channel)

  async def drive_lcrd_return(self, channel):
    """One L-credit return flit.

    All fields zero: the opcode is the whole message, and a return names no
    address, no TxnID and no data.
    """
    bus = self.bus
    await self.acquire_tx_flit()
    await self.announce_flit(channel)
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(**{f"tx{channel}flitpend": 0, f"tx{channel}flitv": 1})
    bus.drive_flit(channel, {"opcode": 0})

    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(**{f"tx{channel}flitv": 0})
    bus.drive_flit(channel, {})
    self.release_tx_flit()

  # ==========================================================================
  # Request/completion helpers.
  # ==========================================================================
  def req_expects_write_data(self, req):
    """Does this request carry a write data burst?

    The combined Write + CMO forms are answered from the CLASSIFIER rather than
    from a list here, because a list here is a third copy of the family
    membership and the family has grown twice. The last time it grew, two
    hand-kept sets were missed: the perf counters called a combined write a read,
    and the protocol checker's write classification stood the burst-length rules
    down for the whole family. Asking req_opcode_is_combined_write_cmo means a
    form added to the type package is carried here for free.

    The CMO half adds responses, not data, so every combined form carries the
    payload of the write it contains.
    """
    op = _I(req.opcode)
    if op in _WRITE_DATA_OPCODES or req_opcode_is_combined_write_cmo(op):
      return True
    return req_opcode_is_atomic(op)

  def req_expects_atomic_data_completion(self, req):
    return _I(req.opcode) in _ATOMIC_RETURN_DATA

  def req_expects_persist_sep_completion(self, req):
    return _I(req.opcode) == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP)

  def req_is_combined_write_cmo(self, req):
    """A combined Write + CMO owes the requester a SECOND completion.

    The write half completes exactly like an ordinary write, so without this the
    driver would retire the transaction on the write's completion alone and
    leave the CMO's CompCMO -- and, for the persistent forms, its Persist --
    sitting in the response stream to be mistaken for the NEXT transaction's
    completion. That is not a hypothetical: it is what happened the first time
    this ran, and it surfaced as a wrong-opcode assertion on an unrelated write.
    """
    return req_opcode_is_combined_write_cmo(_I(req.opcode))

  def req_expects_combined_persist(self, req):
    return req_opcode_combined_cmo_is_persist(_I(req.opcode))

  def req_expects_read_completion(self, req):
    return _I(req.opcode) != int(ReqOpcode.PREFETCH_TGT)

  def req_expects_read_receipt(self, req):
    return self.req_expects_read_completion(req) and _I(req.order) != 0

  def expected_read_completion_txn_id(self, req):
    if _I(req.opcode) == int(ReqOpcode.READ_NO_SNP_SEP):
      return _I(req.return_txn_id)
    return _I(req.txn_id)

  # ==========================================================================
  # Main serial request loop.
  # ==========================================================================
  async def seq_loop(self):
    bus = self.bus
    while True:
      req = await self.seq_item_port.get_next_item()

      if req.raw_override:
        await self.drive_raw_item(req)
        self._complete_item(req)
        continue

      await self.drive_req(req)

      if _I(req.direction) == int(Dir.WRITE):
        await self.handle_retry(req)
        req_src_id = _I(req.src_id)
        req_tgt_id = _I(req.tgt_id)
        send_write_data = self.req_expects_write_data(req)

        if _I(req.opcode) == int(ReqOpcode.WRITE_EVICT_OR_EVICT):
          await self.drive_write_evict_or_evict(req, req_src_id, req_tgt_id)
        elif send_write_data:
          wait_deferred, grant = await self.collect_write_dbid_grant(req)
          await self.drive_dat(req)
          if self.req_expects_atomic_data_completion(req):
            # Returning-data atomics must be granted with a deferred DBIDResp/
            # DBIDRespOrd (never a combined CompDBIDResp) before their CompData.
            if not wait_deferred:
              raise AssertionError(
                f"[{self.get_name()}] Non-store atomic grant opcode "
                f"0x{grant['opcode']:x} was not DBIDResp/DBIDRespOrd")
            await self.collect_read_completion(req)
          elif self.req_is_combined_write_cmo(req):
            # A combined request's remaining completions are collected as ONE
            # obligation set rather than write-then-CMO, because Issue E does
            # not order them that way. Handled here and not after the branch:
            # the write's own Comp is one of the obligations, and a completer
            # is free to put CompCMO in front of it.
            await self.collect_combined_write_obligations(
              req, req_src_id, req_tgt_id, need_comp=wait_deferred)
            if not wait_deferred:
              self.stamp_rsp_flit_on_req(req, grant)
          elif wait_deferred:
            await self.collect_write_completion(req)
          else:
            self.stamp_rsp_flit_on_req(req, grant)
        else:
          if self.req_expects_persist_sep_completion(req):
            await self.collect_persist_sep_completion(req)
          elif _I(req.opcode) in (int(ReqOpcode.WRITE_NO_SNP_ZERO),
                                  # WriteUniqueZero is the snoopable twin and
                                  # completes the same two ways: DBIDResp* + Comp,
                                  # or a combined CompDBIDResp.
                                  int(ReqOpcode.WRITE_UNIQUE_ZERO)):
            await self.collect_write_zero_completion(req)
          elif self.req_is_combined_write_cmo(req):
            # A combined write with no data phase. None exist today -- every
            # combined form carries a write payload -- but the arm is here so a
            # future dataless one does not silently skip its CMO obligations,
            # which is what the old unconditional call after this chain gave
            # for free.
            await self.collect_combined_write_obligations(
              req, req_src_id, req_tgt_id, need_comp=True)
          else:
            await self.collect_write_completion(req)

        # WriteEvictOrEvict always sets ExpCompAck but acknowledges itself: the
        # data leg's CopyBackWrData IS the acknowledgement, and the no-data leg
        # already sent an explicit CompAck above. Either way a second one here
        # would be a CompAck the home never expects.
        if (_I(req.exp_comp_ack)
            and _I(req.opcode) != int(ReqOpcode.WRITE_EVICT_OR_EVICT)):
          await self.drive_comp_ack(_I(req.txn_id), req_src_id, req_tgt_id)

        await bus.rising()
        self.drive_idle_sideband()
        self.free_txn_id(_I(req.txn_id))
        self.on_transaction_complete(req)
        self._complete_item(req)
      else:
        if self.req_expects_read_completion(req):
          await self.handle_retry(req)
          # A separated read retires on ReadReceipt + DataSepResp, not on
          # RespSepData + DataSepResp. Table B-3 permits RespSepData from a Home
          # only, and section 2.3.1 makes ReadReceipt the response the Slave
          # owes -- so on this link, where this requester is the Home stand-in,
          # ReadReceipt is what arrives. It arrives for every separated read,
          # ordered or not.
          if (self.req_expects_read_receipt(req)
              or _I(req.opcode) == int(ReqOpcode.READ_NO_SNP_SEP)):
            await self.collect_read_receipt(req)
          if self.cfg.snf_resp_sep_data_negctl:
            await self.collect_resp_sep_data(req)
          await self.collect_read_completion(req)

          # IHI 0050 E section 2.8.3 rule 1: "An RN-F sends a CompAck after
          # receiving Comp, RespSepData or CompData". This is the read half of
          # the acknowledgement, and until Table 2-9 was implemented in the item
          # constraint it was unreachable -- ExpCompAck was forced to zero on
          # every read, so the branch had nothing to send and was never written.
          # The completer half of the same rule (wait for CompAck before
          # snooping the line again) lives in the HN-F.
          if _I(req.exp_comp_ack):
            await self.drive_comp_ack(_I(req.txn_id), _I(req.src_id),
                                      _I(req.tgt_id))
        else:
          await bus.rising()
          self.drive_idle_sideband()

        self.free_txn_id(_I(req.txn_id))
        self.on_transaction_complete(req)
        self._complete_item(req)

  # ==========================================================================
  # Flit drivers.
  # ==========================================================================
  def _req_fields(self, req):
    f = {
      "mpam": _I(req.mpam), "tracetag": _I(req.tracetag),
      "expcompack": _I(req.exp_comp_ack), "excl": _I(req.excl),
      # REQ bit 17 is SnpAttr, which under Issue E is also DoDWT (E section
      # 13.10.25, "The bit shares the same field as SnpAttr"). The opcode picks
      # which field the bit carries; the item's con_dodwt_overload guarantees the
      # discarded one is zero, so nothing a sequence asked for is lost here.
      "snpattr": (_I(req.dodwt)
                  if req_bit17_is_dodwt(self.bus.cfg.issue, _I(req.opcode))
                  else _I(req.snp_attr)),
      "memattr": _I(req.mem_attr),
      "pcrdtype": _I(req.pcrd_type), "order": _I(req.order),
      "allowretry": _I(req.allow_retry), "likelyshared": _I(req.likelyshared),
      "ns": _I(req.ns), "addr": _I(req.addr), "size": _I(req.size),
      "opcode": _I(req.opcode), "returntxnid": _I(req.return_txn_id),
      "endian": _I(req.endian), "returnnid": _I(req.return_nid),
      "lpid": _I(req.lp_id), "txnid": _I(req.txn_id),
      "srcid": _I(req.src_id), "tgtid": _I(req.tgt_id), "qos": _I(req.qos),
    }
    if self.bus.cfg.is_e:
      f["tagop"] = _I(req.tagop)
      f["groupidext"] = _I(req.group_id_ext)
    return f

  async def drive_req(self, req, alloc_id=True):
    bus = self.bus
    # Negative control for CHI_EXPCOMPACK_REQUIRED_BUT_ZERO. The item field is
    # cleared, not just the flit field, and that is the whole point: the
    # requester then stays self-consistent -- it puts a zero on the wire AND does
    # not send the CompAck -- so exactly one rule can fire. Zeroing only the
    # outgoing field would also trip COMPACK_WITHOUT_EXPCOMPACK a few cycles
    # later, and a control that breaks two rules at once cannot show which of
    # them is being exercised.
    if self.cfg.rn_drop_required_exp_comp_ack and _I(req.exp_comp_ack):
      req.exp_comp_ack = 0
    if alloc_id:
      req.txn_id = self.alloc_txn_id()
    fields = self._req_fields(req)

    await self.wait_req_credit()

    await self.acquire_tx_flit()
    await self.announce_flit("req")
    await bus.rising()
    self.drive_idle_sideband()
    # alloc_id is exactly "this is a fresh transaction", so it is also the right
    # predicate for opening the TXSACTIVE window: handle_retry() and the mixed
    # pipeline both re-issue with alloc_id=False, and a re-issue must not open a
    # second window over a transaction that already has one.
    if alloc_id:
      self.tx_activity_begin()
    bus.drive(txreqflitpend=0, txreqflitv=1)
    bus.drive_flit("req", fields)

    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(txreqflitv=0)
    bus.drive_flit("req", {})
    self.release_tx_flit()

  async def return_unused_pcrds(self):
    """Hand back every banked P-credit with PCrdReturn.

    PCrdReturn is a NOP transaction that consumes the credit it names, so it is
    the only way to give one back. There is no response to wait for -- which is
    also why a randomly generated PCrdReturn would wedge this driver, and why the
    opcode is kept out of the item randomization pools.

    Identifier fields are fixed by the specification rather than chosen: TxnID is
    not used and must be zero, TgtID must match the SrcID of the node that
    granted the credit, and PCrdType must match the grant's.
    """
    bus = self.bus
    for pcrd_type in sorted(self.pcrd_pool):
      granter, own_id = self.pcrd_src.get(pcrd_type, (0, 0))
      while self.pcrd_pool[pcrd_type] > 0:
        fields = {
          "opcode": int(ReqOpcode.PCRD_RETURN),
          "pcrdtype": pcrd_type,
          "txnid": 0,
          "srcid": own_id,
          "tgtid": granter,
          "qos": 0, "addr": 0, "size": 0, "allowretry": 0,
        }

        await self.wait_req_credit()
        await self.acquire_tx_flit()
        await self.announce_flit("req")
        await bus.rising()
        self.drive_idle_sideband()
        bus.drive(txreqflitpend=0, txreqflitv=1)
        bus.drive_flit("req", fields)
        await bus.rising()
        self.drive_idle_sideband()
        bus.drive(txreqflitv=0)
        bus.drive_flit("req", {})
        self.release_tx_flit()

        self.pcrd_pool[pcrd_type] -= 1
        self.n_pcrd_returned += 1

  async def drive_dat(self, req):
    bus = self.bus
    cfg = self.bus.cfg
    if _I(req.opcode) in (int(ReqOpcode.WRITE_NO_SNP_ZERO),
                          int(ReqOpcode.WRITE_UNIQUE_ZERO)):
      return

    # Hold the TX flit mutex for the whole burst so a concurrent flit driver (an
    # RN-F snoop responder's SnpRespData) cannot interleave another packet's beats
    # into this one. Safe: each beat's DAT send credit is returned by the receiver
    # independently, so the burst always drains and releases the key.
    await self.acquire_tx_flit()
    n = len(req.data)
    for i in range(n):
      fields = {
        "data": _I(req.data[i]), "be": _I(req.be[i]),
        "poison": _I(req.poison) if cfg.poison_en else 0,
        "datacheck": _I(req.datacheck) if cfg.datacheck_en else 0,
        "dataid": i, "ccid": 0, "dbid": _I(req.dbid),
        "resp": _I(req.dat_resp[i]) if i < len(req.dat_resp) else 0,
        "resperr": _I(req.dat_resp_err[i]) if i < len(req.dat_resp_err) else 0,
        "opcode": _I(req.dat_opcode), "txnid": _I(req.dbid),
        "srcid": _I(req.src_id), "tgtid": _I(req.tgt_id), "qos": _I(req.qos),
      }
      if cfg.is_e:
        fields["tagop"] = _I(req.dat_tagop)
        fields["tag"] = _I(req.tag[i]) if i < len(req.tag) else 0
        fields["tu"] = _I(req.tu[i]) if i < len(req.tu) else 0
      await self.wait_dat_credit()

      # Every beat, not only the first: the gap cycle after each beat drops
      # FLITPEND, so nothing carries the lead across to the next one. The value
      # driven WITH the beat keeps its established burst meaning (more beats
      # follow), which is what every receiver here reads to find the last beat.
      await self.announce_flit("dat")
      await bus.rising()
      self.drive_idle_sideband()
      bus.drive(txdatflitpend=1 if i != (n - 1) else 0, txdatflitv=1)
      bus.drive_flit("dat", fields)

      await bus.rising()
      self.drive_idle_sideband()
      bus.drive(txdatflitpend=0, txdatflitv=0)
      bus.drive_flit("dat", {})
    self.release_tx_flit()

  async def drive_comp_ack(self, txn_id, src_id, tgt_id):
    bus = self.bus
    fields = {"opcode": int(RspOpcode.COMP_ACK), "txnid": txn_id,
              "srcid": src_id, "tgtid": tgt_id}
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
  # Completion collectors.
  # ==========================================================================
  def stamp_rsp_flit_on_req(self, req, flit):
    req.role = int(Role.SNF)
    req.src_id = flit["srcid"]
    req.tgt_id = flit["tgtid"]
    req.qos = flit["qos"]
    req.rsp_opcode = flit["opcode"]
    req.rsp_resp = flit["resp"]
    req.rsp_resp_err = flit["resperr"]
    req.dbid = flit["dbid"]

  async def take_rsp_flit(self):
    """Take the next RSP flit off the wire and return the link credit for it.

    The credit is returned here rather than at each caller's check, because it
    is owed the moment the flit is accepted off the channel: whether the
    requester likes what the flit says is a protocol question and the credit is
    a link one. Three callers used to carry their own copy of this loop.
    """
    bus = self.bus
    while not bus.get("rxrspflitv"):
      await bus.rising()
      self.drive_idle_sideband()
    flit = bus.sample_flit("rsp", "rx")
    self.schedule_rsp_credit_return()
    return flit

  async def wait_for_matching_rsp(self, req_txn_id, reject_rule=None):
    """Take the next RSP flit and require it to carry the expected TxnID.

    reject_rule routes the mismatch through reject() instead of raising, so a
    negative control can record the refusal and let the run continue -- the
    same treatment wait_for_standalone_persist_rsp gets, and the behaviour of a
    demoted `uvm_fatal in the SV twin. It is passed only by the
    callers that have a control aimed at them; everywhere else a completion on
    the wrong TxnID is still a hard stop, because nothing downstream of here
    can make sense of a flit that belongs to another transaction.
    """
    flit = await self.take_rsp_flit()
    if flit["txnid"] != req_txn_id:
      message = (f"[{self.get_name()}] RSP completion txnid 0x{flit['txnid']:x} "
                 f"!= request txnid 0x{req_txn_id:x}")
      if reject_rule is None:
        raise AssertionError(message)
      reject(reject_rule, message)
    return flit

  async def wait_for_standalone_persist_rsp(self, expect_tgt_id, req_tgt_id):
    """Standalone Persist has no applicable TxnID; match by routing fields.

    The expected target is the node the REQUEST asked for -- IHI 0050 E 2.8
    routes a PCMO's Persist to ReturnNID, so that is where the requester looks
    for it, and not at its own SrcID. The two are the same node whenever a
    requester wants its own Persist back, which is why reading SrcID here worked
    for as long as nothing set ReturnNID to anything else.

    A route mismatch goes through reject() rather than raise, so a negative
    control can record the refusal instead of dying on it -- the same treatment
    the completion-form mismatch in collect_persist_sep_completion gets, and the
    behaviour of a demoted `uvm_fatal in the SV twin.
    """
    flit = await self.take_rsp_flit()
    self.check_persist_route(flit, expect_tgt_id, req_tgt_id)
    return flit

  def check_persist_route(self, flit, expect_tgt_id, req_tgt_id):
    """A Persist carries no applicable TxnID, so its routing is its identity."""
    if flit["srcid"] != req_tgt_id or flit["tgtid"] != expect_tgt_id:
      reject("PERSIST_ROUTE",
             f"[{self.get_name()}] Standalone Persist route "
             f"0x{flit['srcid']:x}->0x{flit['tgtid']:x} does not match expected "
             f"0x{req_tgt_id:x}->0x{expect_tgt_id:x}")

  async def drive_write_evict_or_evict(self, req, req_src_id, req_tgt_id):
    """WriteEvictOrEvict: the one write whose shape the COMPLETER chooses.

    The requester hands back a clean line and the home decides whether it wants
    the data. Both answers are legal and neither is predictable from the request,
    so the requester cannot commit to a data phase until the first response tells
    it which transaction this turned out to be:

      CompDBIDResp -> the home wants it. Send CopyBackWrData. No CompAck follows:
                      the specification states the CopyBackWriteData message is
                      itself the implicit acknowledgement.
      Comp         -> the home declined. Send an explicit CompAck and no data.
                      The transaction degenerates into an Evict.

    This is why the opcode cannot ride the ordinary write path: that path decides
    whether to send data from the OPCODE alone, before any response has arrived.
    """
    flit = await self.wait_for_matching_rsp(_I(req.txn_id))
    self.stamp_rsp_flit_on_req(req, flit)

    if flit["opcode"] == int(RspOpcode.COMP_DBID_RESP):
      req.dbid = flit["dbid"]
      await self.drive_dat(req)
      return

    if flit["opcode"] != int(RspOpcode.COMP):
      raise AssertionError(
        f"[{self.get_name()}] WriteEvictOrEvict first response opcode "
        f"0x{flit['opcode']:x} was neither CompDBIDResp nor Comp")

    await self.drive_comp_ack(_I(req.txn_id), req_src_id, req_tgt_id)

  def write_grant_txn_id(self, req) -> int:
    """The TxnID this requester should expect its write grant under.

    Ordinarily its own. Under Direct Write Transfer it is ReturnTxnID, because
    section 2.5 puts the grant on the return path whole: "when DoDWT = 1,
    ReturnTxnID value is expected to be the original Requester TxnID [...] Used
    as the TxnID in the DBIDResp response", and Table 2-8 sends the TgtID to
    ReturnNID alongside it.

    The item's dodwt field is passed as bit 17 rather than its snp_attr,
    because on the ITEM the two are separate fields and only one of them can be
    set (con_dodwt_overload); it is the FLIT that overloads the bit. Under
    Issue D the classifier answers false whatever is passed, so a D requester
    keeps matching on its own TxnID with no issue test here.
    """
    if req_dwt_grant_uses_return_path(
        self.bus.cfg.issue, _I(req.opcode), _I(req.dodwt)):
      return _I(req.return_txn_id)
    return _I(req.txn_id)

  async def collect_write_dbid_grant(self, req):
    # Under DWT the grant is the one response whose TxnID the REQUEST chose, so
    # a completer that ignores the rule sends it somewhere this requester is not
    # listening. That refusal is the negative control's second observer, so it
    # goes through reject() rather than raise.
    grant_txn = self.write_grant_txn_id(req)
    flit = await self.wait_for_matching_rsp(
      grant_txn, reject_rule=("DWT_GRANT_ROUTE"
                              if grant_txn != _I(req.txn_id) else None))
    req.dbid = flit["dbid"]
    op = flit["opcode"]
    if op == int(RspOpcode.COMP_DBID_RESP):
      return False, flit
    if op in (int(RspOpcode.DBID_RESP), int(RspOpcode.DBID_RESP_ORD)):
      return True, flit
    raise AssertionError(
      f"[{self.get_name()}] Write grant opcode 0x{op:x} was not "
      f"CompDBIDResp/DBIDResp/DBIDRespOrd")

  async def collect_write_completion(self, req):
    """Collect the write's Comp, stepping over a TagMatch that precedes it.

    A write whose data carried TagOp = Match is owed a TagMatch response as
    well, and IHI 0050 E orders it against nothing: section 2.3.1 says only that
    the Slave sends it "after completing the required Tag Match operation", and
    permits it before the write data has even arrived when the Slave does not
    perform the check. So it may land either side of the write's own completion,
    and this requester must not treat it as one.

    Stepped over rather than collected into a milestone, deliberately: the
    scoreboard is what judges TagMatch, and it sees every RSP the monitor does.
    Adding a second observer here would only give the same fact two owners.
    """
    while True:
      flit = await self.wait_for_matching_rsp(_I(req.txn_id))
      if flit["opcode"] == int(RspOpcode.TAG_MATCH):
        await self.bus.rising()
        self.drive_idle_sideband()
        continue
      break
    self.stamp_rsp_flit_on_req(req, flit)
    if flit["opcode"] != int(RspOpcode.COMP):
      raise AssertionError(
        f"[{self.get_name()}] Deferred write completion opcode "
        f"0x{flit['opcode']:x} was not Comp")

  async def collect_read_receipt(self, req):
    flit = await self.wait_for_matching_rsp(_I(req.txn_id))
    if flit["opcode"] != int(RspOpcode.READ_RECEIPT):
      raise AssertionError(
        f"[{self.get_name()}] Read receipt opcode 0x{flit['opcode']:x} "
        f"was not ReadReceipt")
    await self.bus.rising()
    self.drive_idle_sideband()

  async def collect_resp_sep_data(self, req):
    flit = await self.wait_for_matching_rsp(_I(req.txn_id))
    self.stamp_rsp_flit_on_req(req, flit)
    if flit["opcode"] != int(RspOpcode.RESP_SEP_DATA):
      raise AssertionError(
        f"[{self.get_name()}] Separated read response opcode "
        f"0x{flit['opcode']:x} was not RespSepData")
    await self.bus.rising()
    self.drive_idle_sideband()

  async def collect_combined_write_obligations(self, req, req_src_id, req_tgt_id,
                                               need_comp):
    """Collect a combined Write + CMO's completions as an obligation SET.

    Completion of a combined request is *both obligations met*, not *this
    sequence observed*, and Issue E is explicit about how much freedom the
    completer has in producing them. This used to be a fixed script -- write
    completion, then exactly CompCMO, then exactly Persist -- which turned two
    behaviours the specification permits into a stopped simulation:

      * **CompPersist in place of CompCMO + Persist.** Section 2.8: the SN "is
        permitted to combine CompCMO with Persist as a CompPersist response if
        the two are sent to Home". The VIP already models the combined encoding
        on the standalone CleanSharedPersistSep path (cfg.combined_persist_rsp),
        so the requester had to handle it in one path and fatalled on it in the
        other.
      * **CompCMO before the write's completion.** The only ordering rule Issue
        E places on CompCMO is that it "must only be sent after the associated
        request is received". Nothing puts it after the write's Comp. The old
        code consumed the write completion first, so a completer that led with
        CompCMO had it collected by the write path and died on "was not Comp".

    The scoreboard already models it this way -- need_comp_cmo / comp_cmo_seen
    are flags, not a sequence -- so the driver was stricter than the checker
    behind it.

    An opcode that satisfies no OUTSTANDING obligation is still refused, and
    that is the whole strictness this keeps: tolerance of order is not tolerance
    of anything at all. A second CompCMO is as wrong as a ReadReceipt here.
    """
    # What actually retired each obligation, for the tests to read back.
    #
    # A testcase that only asserts "the transaction completed" cannot tell a
    # completer that took the encoding it was asked for from one that quietly
    # sent the default and was accepted anyway -- both complete. This list is
    # what makes tc_chi_e_combined_write_comp_persist and
    # tc_chi_e_combined_write_cmo_first evidence rather than restatements.
    self.combined_completion_log = []

    need_cmo = True
    need_persist = self.req_expects_combined_persist(req)
    # Section 2.8 routes a PCMO's Persist by ReturnNID and everything else by
    # SrcID; see wait_for_standalone_persist_rsp.
    persist_tgt = (_I(req.return_nid)
                   if req_opcode_combined_cmo_is_persist(_I(req.opcode))
                   else req_src_id)

    while need_comp or need_cmo or need_persist:
      await self.bus.rising()
      self.drive_idle_sideband()
      flit = await self.take_rsp_flit()
      opcode = flit["opcode"]

      if opcode == int(RspOpcode.COMP) and need_comp:
        self.check_combined_rsp_txn(flit, req)
        self.stamp_rsp_flit_on_req(req, flit)
        self.combined_completion_log.append(opcode)
        need_comp = False
      elif opcode == int(RspOpcode.COMP_CMO) and need_cmo:
        self.check_combined_rsp_txn(flit, req)
        self.combined_completion_log.append(opcode)
        need_cmo = False
      elif opcode == int(RspOpcode.PERSIST) and need_persist:
        self.check_persist_route(flit, persist_tgt, req_tgt_id)
        self.combined_completion_log.append(opcode)
        need_persist = False
      elif (opcode == int(RspOpcode.COMP_PERSIST)
            and need_cmo and need_persist):
        # One response retiring two obligations, which is the whole point of
        # the encoding. It is permitted only when both would go to the same
        # node, so it is checked against the CMO's target and the persist's
        # agreement with it is what made the combination legal in the first
        # place.
        self.check_combined_rsp_txn(flit, req)
        self.combined_completion_log.append(opcode)
        need_cmo = False
        need_persist = False
      else:
        reject("COMBINED_WRITE_COMPLETION",
               f"[{self.get_name()}] combined Write + CMO received RSP opcode "
               f"0x{opcode:x} satisfying no outstanding obligation "
               f"(comp={int(need_comp)} cmo={int(need_cmo)} "
               f"persist={int(need_persist)})")
        return

  def check_combined_rsp_txn(self, flit, req):
    """The TxnID-carrying half of a combined write's completions.

    Persist is excluded by its caller and not by a test here: it carries no
    applicable TxnID at all, so there is nothing to compare and the routing is
    what identifies it.
    """
    if flit["txnid"] != _I(req.txn_id):
      raise AssertionError(
        f"[{self.get_name()}] combined Write + CMO completion txnid "
        f"0x{flit['txnid']:x} != request txnid 0x{_I(req.txn_id):x}")

  async def collect_write_zero_completion(self, req):
    """Collect a zero-write completion, in either of its two legal forms.

    WriteNoSnpZero is answered by DBIDResp and a Comp, or by a combined
    CompDBIDResp. It carries no write data, so the granted buffer is never used
    and the DBID looks pointless -- which is exactly why this used to accept a
    bare Comp, matching a completer that sent one. Both were wrong together.
    """
    flit = await self.wait_for_matching_rsp(_I(req.txn_id))

    if flit["opcode"] == int(RspOpcode.COMP_DBID_RESP):
      self.stamp_rsp_flit_on_req(req, flit)
      return

    if flit["opcode"] != int(RspOpcode.DBID_RESP):
      reject("WRITE_ZERO_FIRST_RESPONSE",
             f"[{self.get_name()}] zero-write first response opcode "
             f"0x{flit['opcode']:x} was neither DBIDResp nor CompDBIDResp")
      # Nothing follows a refused opening response. With no expectation armed
      # reject() raises and this is unreachable; inside a control it returns, and
      # falling through instead would wait for a grant the completer was never
      # going to send.
      return

    await self.bus.rising()
    self.drive_idle_sideband()
    flit = await self.wait_for_matching_rsp(_I(req.txn_id))
    self.stamp_rsp_flit_on_req(req, flit)
    if flit["opcode"] != int(RspOpcode.COMP):
      reject("WRITE_ZERO_COMPLETION",
             f"[{self.get_name()}] zero-write completion after DBIDResp had "
             f"opcode 0x{flit['opcode']:x}, not Comp")

  async def collect_persist_sep_completion(self, req):
    """Collect a separated-persist completion, in either of its two legal forms.

    A requester MUST accept both, so this accepts both rather than picking one:

      * Comp then Persist -- Point of Coherency reached, then Point of
        Persistence. Two milestones, two responses.
      * CompPersist alone -- the completer combined them.

    Everything else is rejected, and the rejection is the point. This used to
    demand Persist THEN CompPersist, which is neither form: no bare Comp ever
    arrived, and persistence was signalled twice. Because the requester demanded
    exactly what this VIP's own completer produced, the two agreed with each
    other and the pair was wrong together.
    """
    req_src_id = _I(req.src_id)
    req_tgt_id = _I(req.tgt_id)

    flit = await self.wait_for_matching_rsp(_I(req.txn_id))

    # The combined form is the whole completion: nothing follows it.
    if flit["opcode"] == int(RspOpcode.COMP_PERSIST):
      self.stamp_rsp_flit_on_req(req, flit)
      return

    if flit["opcode"] != int(RspOpcode.COMP):
      # reject() rather than raise: with no expectation armed it raises exactly
      # as before, and inside an expect_rejection scope it records and returns so
      # a negative control can prove the refusal happened -- the behaviour of a
      # demoted `uvm_fatal in the SV twin. See py/vip_chi_reject.py.
      reject("PERSIST_SEP_FIRST_COMPLETION",
             f"[{self.get_name()}] PersistSep first completion opcode "
             f"0x{flit['opcode']:x} was neither Comp nor CompPersist")
      # As above: a refused opening completion ends the collection rather than
      # falling through to wait for the Persist that would have followed a Comp.
      return

    await self.bus.rising()
    self.drive_idle_sideband()
    flit = await self.wait_for_standalone_persist_rsp(
      _I(req.return_nid) if req_opcode_combined_cmo_is_persist(_I(req.opcode))
      else req_src_id, req_tgt_id)
    self.stamp_rsp_flit_on_req(req, flit)
    if flit["opcode"] != int(RspOpcode.PERSIST):
      raise AssertionError(
        f"[{self.get_name()}] PersistSep completion after Comp had opcode "
        f"0x{flit['opcode']:x}, not Persist")

  # No clear_activity parameter any more: TXSACTIVE is closed at the shared
  # retire point, so a collector no longer needs to know whether it is the
  # serial path (which used to drop the sideband here) or the pipelined one
  # (which had to be told not to, or it would have dropped it while its peers
  # were still outstanding).
  # Fields a read-data beat carries about the transfer as a whole, copied onto
  # the request so a sequence can read them back. Every beat of a transfer
  # carries the same values, so the last one to land wins and it does not matter
  # which order they arrived in.
  def stamp_dat_beat_on_req(self, req, flit):
    req.role = int(Role.SNF)
    req.src_id = flit["srcid"]
    req.tgt_id = flit["tgtid"]
    req.qos = flit["qos"]
    req.dat_opcode = flit["opcode"]
    req.dbid = flit["dbid"]
    req.rsp_resp = flit["resp"]
    req.rsp_resp_err = flit["resperr"]

  # Place each beat at the position its DataID names, not at the position it
  # arrived in: CHI lets the beats of one transfer return in any order, and a
  # sequence reading back req.data[] must see the payload in address order
  # regardless. A DataID outside the burst cannot be placed, so that beat keeps
  # its arrival slot and the arrival order stands for the whole burst -- the
  # monitor is the component that reports the malformed DataID.
  def place_dat_beats(self, req, beats):
    n = len(beats)
    id_q = [int(f["dataid"]) for f in beats]
    order = list(range(n))
    if all(d < n for d in id_q):
      order = id_q

    req.data = [0] * n
    req.be = [0] * n
    req.data_id = [0] * n
    req.cc_id = [0] * n
    req.dat_resp = [0] * n
    req.dat_resp_err = [0] * n
    for i, pos in enumerate(order):
      req.data[pos] = beats[i]["data"]
      req.be[pos] = beats[i]["be"]
      req.data_id[pos] = beats[i]["dataid"]
      req.cc_id[pos] = beats[i]["ccid"]
      req.dat_resp[pos] = beats[i]["resp"]
      req.dat_resp_err[pos] = beats[i]["resperr"]

  # Collect ONE read's data as a contiguous run of beats, terminated by the
  # FLITPEND deassert. Used by the serial issue paths and by the atomic data
  # completion, all of which have exactly one transfer outstanding, so no beat on
  # the channel can belong to anything else. The mixed pipeline cannot assume
  # that and files beats by TxnID instead -- see mixed_dat_proc.
  async def collect_read_completion(self, req):
    bus = self.bus
    expected = self.expected_read_completion_txn_id(req)
    beats = []

    while True:
      while not bus.get("rxdatflitv"):
        await bus.rising()
        self.drive_idle_sideband()

      flit = bus.sample_flit("dat", "rx")
      if flit["txnid"] != expected:
        raise AssertionError(
          f"[{self.get_name()}] Read completion txnid 0x{flit['txnid']:x} "
          f"!= expected 0x{expected:x}")
      self.schedule_dat_credit_return()

      beats.append(flit)
      self.stamp_dat_beat_on_req(req, flit)

      if not bus.get("rxdatflitpend"):
        break
      await bus.rising()
      self.drive_idle_sideband()

    self.place_dat_beats(req, beats)

    await bus.rising()
    self.drive_idle_sideband()

  # ==========================================================================
  # A P-credit granted and never consumed is a leaked protocol credit: the
  # completer set aside a re-issue slot this requester never took, and nothing
  # else in the flow notices -- the traffic completes, the test passes, and the
  # retry handshake is left half-finished. Name whatever is still banked at end
  # of test, with its PCrdType, so the leak is attributable.
  #
  # A reset clears the bank (handle_reset), which is correct: credits do not
  # survive a link teardown, so only a leak in the final reset-free stretch is
  # reported. A self.logger.error() does not auto-fail pyUVM, so the leak also
  # bumps a public counter a test can assert on.
  # ==========================================================================
  def check_phase(self):
    for pcrd_type, count in sorted(self.pcrd_pool.items()):
      if count > 0:
        self.n_pcrd_leak += count
        self.logger.error(
          f"[{self.get_name()}] {count} P-credit(s) of PCrdType "
          f"0x{int(pcrd_type):x} were granted and never consumed at end of "
          f"test: the retry handshake is left half-finished")

  # ==========================================================================
  # cfg.max_pcrd_budget bounds how many P-credits this requester is willing to
  # hold at once. A completer may only grant a credit against a RetryAck it has
  # already sent, so the bank can never legitimately outgrow the number of
  # requests this node has in flight: exceeding the budget means the completer
  # granted credits it never owed, and the surplus would otherwise sit in the
  # pool authorizing re-issues that nothing bounced. 0 disables the bound.
  # ==========================================================================
  # A self.logger.error() does not auto-fail pyUVM, so the violation also bumps
  # a public counter a test can assert on (same idiom as the checkers).
  def check_pcrd_budget(self):
    budget = int(self.cfg.max_pcrd_budget)
    if budget <= 0:
      return
    total = sum(self.pcrd_pool.values())
    if total > budget:
      self.n_pcrd_budget_violation += 1
      self.logger.error(
        f"[{self.get_name()}] banked P-credits ({total}) exceeded "
        f"cfg.max_pcrd_budget ({budget}): the completer granted more protocol "
        f"credits than it bounced requests")

  # ==========================================================================
  # Protocol-credit retry (no-op unless the request allowed retry and the SN-F
  # bounced it with a RetryAck).
  # ==========================================================================
  def bank_pcrd_grant(self, flit) -> None:
    """Record one granted P-credit, by type.

    IHI 0050 E 2.11: "There is no fixed relationship between credits and
    particular transactions" -- a credit belongs to its PCrdType and to this
    link, not to whatever was bounced. Banking is therefore always the right
    thing to do with a grant, whether or not the RetryAck it answers has been
    seen yet.

    State only -- the LINK credit is returned by the caller, because the two
    callers differ on when: the pipelined loop returns it for every RSP before
    dispatching on the opcode, the serial path only for the ones it consumes.

    One function for both, deliberately. Two paths each carrying their own copy
    of "what to do with a PCrdGrant" is exactly how happened: the
    pipelined one banked by type and absorbed a reordered grant, the serial one
    did not, and nothing made them disagree visibly.
    """
    pcrd_type = flit["pcrdtype"]
    self.pcrd_pool[pcrd_type] = self.pcrd_pool.get(pcrd_type, 0) + 1
    self.pcrd_src[pcrd_type] = (flit["srcid"], flit["tgtid"])
    self.check_pcrd_budget()

  async def collect_pcrd_grant(self, pcrd_type):
    """Obtain the P-credit a RetryAck owed, from the bank or from the wire.

    The bank is consulted FIRST, and that is the whole of what section 2.11
    requires here: "It is possible that a reordering interconnect can reorder
    the responses such that the PCrdGrant is received by the Requester before
    the RetryAck response for the transaction is received. In this case, the
    Requester must record the credit it has received, including the credit
    type, so that it can assign the credit appropriately when it does receive
    the RetryAck response."

    This path used to demand the grant arrive next on the wire and fatal on
    anything else, so a conformant reordering interconnect produced a VIP crash
    reported as a DUT failure. The pipelined path in this same class already
    banked credits by type; the two paths are selected by cfg.max_outstanding_*,
    which is not something a reader of section 2.11 would think to check.
    """
    bus = self.bus
    if self.pcrd_pool.get(pcrd_type, 0) > 0:
      # Already banked -- the grant beat its own RetryAck here.
      self.pcrd_pool[pcrd_type] -= 1
      return

    while True:
      while not bus.get("rxrspflitv"):
        await bus.rising()
        self.drive_idle_sideband()
      flit = bus.sample_flit("rsp", "rx")
      if flit["opcode"] != int(RspOpcode.PCRD_GRANT):
        # Nothing in 2.11 makes the grant the next response on the channel, and
        # a completer may interleave other transactions' completions. The serial
        # path has only one transaction outstanding, so there is nothing this
        # can usefully be -- but it goes through reject() rather than raise, so
        # a control can record the refusal instead of dying on it, and so the
        # message names the assumption rather than the symptom.
        self.schedule_rsp_credit_return()
        reject("PCRD_GRANT_UNEXPECTED",
               f"[{self.get_name()}] waiting for a PCrdGrant of type "
               f"0x{pcrd_type:x}, got RSP opcode 0x{flit['opcode']:x}")
        await bus.rising()
        self.drive_idle_sideband()
        continue

      # Banked by type, never matched against the owed type on arrival: a
      # completer with several outstanding RetryAcks may grant them in any
      # order, and a grant of another type is this node's credit too.
      self.bank_pcrd_grant(flit)
      self.schedule_rsp_credit_return()
      await bus.rising()
      self.drive_idle_sideband()
      if self.pcrd_pool.get(pcrd_type, 0) > 0:
        self.pcrd_pool[pcrd_type] -= 1
        return

  async def handle_retry(self, req):
    bus = self.bus
    if not _I(req.allow_retry):
      return
    while True:
      while not bus.get("rxrspflitv") and not bus.get("rxdatflitv"):
        await bus.rising()
        self.drive_idle_sideband()
      if not bus.get("rxrspflitv"):
        return  # DAT beat -> read completion, no retry
      flit = bus.sample_flit("rsp", "rx")
      if flit["opcode"] == int(RspOpcode.PCRD_GRANT):
        # The grant overtook its own RetryAck (2.11's reordering case). Bank it
        # and keep peeking: the RetryAck this request is waiting for is still
        # coming, and collect_pcrd_grant will find the credit already in hand.
        self.bank_pcrd_grant(flit)
        self.schedule_rsp_credit_return()
        await bus.rising()
        self.drive_idle_sideband()
        continue
      if flit["opcode"] != int(RspOpcode.RETRY_ACK):
        return  # a normal completion; leave it for the collector
      if flit["txnid"] != _I(req.txn_id):
        raise AssertionError(
          f"[{self.get_name()}] RetryAck txnid 0x{flit['txnid']:x} "
          f"!= request txnid 0x{_I(req.txn_id):x}")
      pcrd = flit["pcrdtype"]
      self.schedule_rsp_credit_return()
      await bus.rising()
      self.drive_idle_sideband()
      await self.collect_pcrd_grant(pcrd)
      req.allow_retry = 0
      req.pcrd_type = pcrd
      await self.drive_req(req, alloc_id=False)

  # ==========================================================================
  # Raw-flit injection (verbatim item on the raw_channel).
  # ==========================================================================
  async def drive_raw_item(self, item):
    if not self.cfg.allow_raw_override:
      raise AssertionError(f"[{self.get_name()}] raw_override is disabled in cfg")
    ch = _I(item.raw_channel)
    if ch == int(RawChannel.REQ):
      await self._drive_raw(item, "req", item.raw_req)
    elif ch == int(RawChannel.RSP):
      await self._drive_raw(item, "rsp", item.raw_rsp)
    elif ch == int(RawChannel.DAT):
      await self._drive_raw(item, "dat", item.raw_dat)
    else:
      raise AssertionError(f"[{self.get_name()}] raw item has no raw channel")

  async def _drive_raw(self, item, channel, raw_value):
    bus = self.bus
    flitpend = 1 if getattr(item, "raw_flitpend", False) else 0
    await {"req": self.wait_req_credit,
           "rsp": self.wait_rsp_credit,
           "dat": self.wait_dat_credit}[channel]()

    await self.acquire_tx_flit()
    # Announced like any other flit. A raw item chooses the bit pattern and the
    # FLITPEND driven WITH the flit; the lead in front of it is the link-layer
    # obligation, and dropping it here would make every raw-injection test fail
    # a rule it is not about. The negative control that DOES want it dropped is
    # cfg.flit_without_flitpend, handled inside announce_flit.
    await self.announce_flit(channel)
    await bus.rising()
    self.drive_idle_sideband()
    # The FLIT's own window: opened here, retired through the shared point in
    # _complete_item, one begin paired with one end exactly as a normal request
    # does. A raw REQ whose opcode HAS a modeled completion gets a second,
    # independent window on top of this one -- see _raw_req_activity below.
    self.tx_activity_begin()
    bus.drive(**{f"tx{channel}flitpend": flitpend, f"tx{channel}flitv": 1})
    bus.sig[f"tx{channel}flit"].value = int(raw_value)

    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(**{f"tx{channel}flitpend": 0, f"tx{channel}flitv": 0})
    bus.drive_flit(channel, {})
    self.release_tx_flit()

    if channel == "req":
      self._raw_req_activity(raw_value)

  # A raw REQ carrying an opcode whose completion this tree models is
  # OUTSTANDING until that completion arrives, exactly like any other request:
  # the checker holds it so, and E 14.7.2 / D 13.7.2 requires TXSACTIVE to cover
  # every outstanding transaction. The flit-scoped window the raw path gave it
  # was sound only while no raw-injectable opcode had a modeled completion --
  # which stopped being true when WriteUniqueZero was classified, and the
  # comment saying so kept reading as settled..
  #
  # The opcode is ASKED, not assumed, and it is asked of the same classifier the
  # checker uses -- vip_chi_types_pkg.req_has_modeled_completion -- so
  # classifying an opcode changes this window with it. That is the whole reason
  # the classifier lives in the types package: a copy here would drift the next
  # time an opcode joins it, which is the shape of the defect rather than an
  # instance of it.
  def _raw_req_activity(self, raw_value):
    # The negative control reverts to the flit-scoped window, which is the
    # defect itself rather than an invented one -- see the knob.
    if self.cfg.raw_req_txsactive_flit_scoped_negctl:
      return
    f = unpack(self.bus.cfg, "req", int(raw_value))
    opcode = _I(f["opcode"])
    if not req_has_modeled_completion(opcode):
      return
    self.tx_activity_begin()
    cocotb.start_soon(self._raw_req_completion_window(
      opcode, _I(f["txnid"]), _I(f["returntxnid"]), _I(f["size"])))

  # Purely observational: it samples, and returns no credit and consumes no
  # flit. The raw path's contract is that the injector drives both ends, so a
  # watcher that started participating in the exchange would change the wire the
  # test is there to inspect.
  #
  # The TxnID is matched against the request's own AND its ReturnTxnID, because
  # a separated read returns its data under the latter. Accepting either is a
  # superset that cannot be wrong for this purpose: both are identifiers this
  # very request named, and no other transaction can answer to them while it is
  # in flight.
  async def _raw_req_completion_window(self, opcode, txn_id, return_txn_id,
                                       size):
    bus = self.bus
    on_dat = req_completion_uses_dat(opcode)
    # A DAT completion ends on its LAST beat. Closing on the first would drop
    # the sideband in the middle of the burst that is still retiring the
    # transaction.
    want_beats = chi_xfer_dat_beats(size, bus.cfg.data_bytes) if on_dat else 0
    seen = 0
    for _ in range(_RAW_COMPLETION_WATCH_CYCLES_C):
      await bus.rising()
      if on_dat:
        if bus.get("rxdatflitv"):
          d = bus.sample_flit("dat", "rx")
          if (_I(d["txnid"]) in (txn_id, return_txn_id)
              and _I(d["opcode"]) in (int(DatOpcode.COMP_DATA),
                                      int(DatOpcode.DATA_SEP_RESP))):
            seen += 1
            if seen >= want_beats:
              break
      elif bus.get("rxrspflitv"):
        r = bus.sample_flit("rsp", "rx")
        if (_I(r["txnid"]) == txn_id
            and is_final_rsp_completion(opcode, _I(r["opcode"]))):
          break
    self.tx_activity_end()

  # ==========================================================================
  # Multi-outstanding mixed pipeline (opt-in via cfg.multi_outstanding).
  #
  # One unified pipeline overlaps plain ReadNoSnp, WriteNoSnp Full/Ptl, atomics
  # and persist CMOs: reads / non-store atomics complete on inbound DAT, writes /
  # store atomics / persists on inbound RSP. Structure:
  #   * mixed_acceptor  -- the ONLY get_next_item() caller. pyUVM get_next_item is
  #                        blocking and there is no try_next_item, so a dedicated
  #                        coroutine pulls each request, item_done()s it AT
  #                        ACCEPTANCE (freeing the sequence to pipeline the next),
  #                        and stages it in self._accepted for the TX thread. The
  #                        completed item is handed back later via its _mo_evt.
  #   * mixed_tx_proc   -- sole TX + issue owner: issue-first up to depth, then
  #                        drive pending WriteData/operand, then CompAck, then
  #                        retire finished entries.
  #   * mixed_rsp_proc  -- write/atomic/persist completion + retry/PCrd monitor.
  #   * mixed_dat_proc  -- read / returning-atomic CompData monitor.
  # ==========================================================================
  def is_plain_read(self, req):
    return (_I(req.opcode) == int(ReqOpcode.READ_NO_SNP)) and not req.raw_override

  def is_plain_write(self, req):
    return (_I(req.opcode) in (int(ReqOpcode.WRITE_NO_SNP_FULL),
                               int(ReqOpcode.WRITE_NO_SNP_PTL))) and not req.raw_override

  def is_pipelined_atomic(self, req):
    return req_opcode_is_atomic(_I(req.opcode)) and not req.raw_override

  def is_pipelined_persist(self, req):
    return (_I(req.opcode) in (int(ReqOpcode.CLEAN_SHARED_PERSIST),
                               int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP))) and not req.raw_override

  async def seq_loop_mixed_pipelined(self):
    self._spawn(self.mixed_acceptor())
    self._spawn(self.mixed_rsp_proc())
    self._spawn(self.mixed_dat_proc())
    await self.mixed_tx_proc()

  async def mixed_acceptor(self):
    while True:
      req = await self.seq_item_port.get_next_item()
      # Ack at acceptance so finish_item() returns and the sequence pipelines the
      # next request; the retired item is returned later via _signal_mo_done().
      self.seq_item_port.item_done()
      self._accepted.append(req)

  def find_mixed_ctx_by_txn(self, txn):
    for i, c in enumerate(self.mx_ctx):
      if _I(c.item.txn_id) == txn:
        return i
    return -1

  def find_mixed_persist_ctx(self, rsp_src_id, rsp_tgt_id):
    for i, c in enumerate(self.mx_ctx):
      if (c.kind == _KIND_PERSIST and c.comp_seen and not c.persist_seen
          and c.req_tgt_id == rsp_src_id and c.req_src_id == rsp_tgt_id):
        return i
    return -1

  def find_mixed_read_by_completion(self, txn):
    for i, c in enumerate(self.mx_ctx):
      if ((c.kind == _KIND_READ) or
          (c.kind == _KIND_ATOMIC and self.req_expects_atomic_data_completion(c.item))):
        if self.expected_read_completion_txn_id(c.item) == txn:
          return i
    return -1

  def sample_mixed_overlap(self):
    n_rd = n_wr = 0
    for c in self.mx_ctx:
      if c.kind == _KIND_READ:
        n_rd += 1
      elif c.kind == _KIND_ATOMIC:
        pass  # bidirectional -- excluded from the read-vs-write concurrency metric
      else:
        n_wr += 1
    if n_rd > 0 and n_wr > 0 and len(self.mx_ctx) > self.cfg.observed_peak_mixed_inflight:
      self.cfg.observed_peak_mixed_inflight = len(self.mx_ctx)

  def retire_mixed(self):
    retired = False
    i = 0
    while i < len(self.mx_ctx):
      c = self.mx_ctx[i]
      if c.kind == _KIND_READ:
        done = (c.read_done and (_I(c.item.order) == 0 or c.receipt_seen) and
                (not _I(c.item.exp_comp_ack) or c.compack_sent))
      elif c.kind == _KIND_ATOMIC:
        if self.req_expects_atomic_data_completion(c.item):
          done = c.data_sent and c.read_done
        else:
          done = c.data_sent and c.comp_seen
        done = done and (not _I(c.item.exp_comp_ack) or c.compack_sent)
      elif c.kind == _KIND_PERSIST:
        # CleanSharedPersist is done on its Comp. The separated form owes BOTH
        # milestones -- Point of Coherency and Point of Persistence -- so
        # retiring on comp_seen alone would close the transaction while its
        # Persist was still in flight, and that Persist would then arrive
        # against a transaction the driver had forgotten. A CompPersist sets
        # both flags, so the combined form still retires on one flit.
        if self.req_expects_persist_sep_completion(c.item):
          done = c.comp_seen and c.persist_seen
        else:
          done = c.comp_seen
      else:  # WRITE
        done = (c.data_sent and c.comp_seen and
                (not _I(c.item.exp_comp_ack) or c.compack_sent))

      if done:
        self._signal_mo_done(c.item)
        self.free_txn_id(_I(c.item.txn_id))
        del self.mx_ctx[i]
        retired = True
      else:
        i += 1
    return retired

  async def mixed_tx_proc(self):
    bus = self.bus
    while True:
      self.sample_mixed_overlap()

      max_rd = self.cfg.max_outstanding_read if self.cfg.max_outstanding_read > 0 else 1
      max_wr = self.cfg.max_outstanding_write if self.cfg.max_outstanding_write > 0 else 1
      max_out = max(max_rd, max_wr)

      # 0) Re-issue a bounced entry whose PCrdType credit is now in hand.
      idx = -1
      for i, c in enumerate(self.mx_ctx):
        if (c.retry_pending and not c.retried and
            self.pcrd_pool.get(c.pcrd_type, 0) > 0):
          idx = i
          break
      if idx >= 0:
        c = self.mx_ctx[idx]
        self.pcrd_pool[c.pcrd_type] -= 1
        c.item.allow_retry = 0
        c.item.pcrd_type = c.pcrd_type
        c.retry_pending = False
        c.retried = True
        await self.drive_req(c.item, alloc_id=False)
        continue

      # 0b) Hand back credits nothing is waiting for. Gated on an IDLE pipeline --
      # no context outstanding and nothing accepted but unissued -- because that
      # is the only moment when "nothing can claim this credit" is knowable. A
      # bounced request still sits in mx_ctx with retry_pending set, so returning
      # a credit while any context is live risks giving away the one a re-issue
      # is about to need, and that request would then never go out again.
      if (self.cfg.return_unused_pcrd and not self.mx_ctx and not self._accepted
          and any(n > 0 for n in self.pcrd_pool.values())):
        await self.return_unused_pcrds()
        continue

      # 1) Issue-first: launch the next request if depth AND a REQ credit allow.
      if (len(self.mx_ctx) < max_out and self.req_lcrd.has_credit() and self._accepted):
        req = self._accepted.pop(0)
        if self.is_plain_read(req):
          await self.drive_req(req)
          self.mx_ctx.append(_MxCtx(_KIND_READ, req))
          continue
        elif self.is_plain_write(req):
          await self.drive_req(req)
          self.mx_ctx.append(_MxCtx(_KIND_WRITE, req))
          continue
        elif self.is_pipelined_atomic(req):
          await self.drive_req(req)
          self.mx_ctx.append(_MxCtx(_KIND_ATOMIC, req))
          continue
        elif self.is_pipelined_persist(req):
          await self.drive_req(req)
          self.mx_ctx.append(_MxCtx(_KIND_PERSIST, req))
          continue
        else:
          raise AssertionError(
            f"[{self.get_name()}] mixed pipeline supports ReadNoSnp / WriteNoSnp / "
            f"atomics / persist only (opcode 0x{_I(req.opcode):x})")

      # 2) Drive WriteData/operand for the first granted write/atomic.
      idx = -1
      for i, c in enumerate(self.mx_ctx):
        if c.kind in (_KIND_WRITE, _KIND_ATOMIC) and c.grant_seen and not c.data_sent:
          idx = i
          break
      if idx >= 0:
        await self.drive_dat(self.mx_ctx[idx].item)
        self.mx_ctx[idx].data_sent = True
        continue

      # 2b) Drive CompAck for the first completed exp_comp_ack write/atomic.
      idx = -1
      for i, c in enumerate(self.mx_ctx):
        if (c.kind in (_KIND_WRITE, _KIND_ATOMIC) and _I(c.item.exp_comp_ack) and
            c.data_sent and (c.comp_seen or c.read_done) and not c.compack_sent):
          idx = i
          break
        # A read owes the same acknowledgement, minus the data leg it has no
        # send side for. Only the pipelined opcodes reach here -- plain,
        # non-ordered ReadNoSnp, which Table 2-9 marks Optional -- so this fires
        # only when a test asks for the bit. It is written anyway because the
        # alternative is a context that never satisfies retire_mixed().
        if (c.kind == _KIND_READ and _I(c.item.exp_comp_ack) and
            c.read_done and not c.compack_sent):
          idx = i
          break
      if idx >= 0:
        c = self.mx_ctx[idx]
        await self.drive_comp_ack(_I(c.item.txn_id), c.req_src_id, c.req_tgt_id)
        c.compack_sent = True
        continue

      # 3) Retire every finished transaction.
      if self.retire_mixed():
        continue

      # 4) Nothing to do this cycle.
      await bus.rising()
      self.drive_idle_sideband()

  async def mixed_rsp_proc(self):
    bus = self.bus
    while True:
      while not bus.get("rxrspflitv"):
        await bus.rising()
        self.drive_idle_sideband()

      flit = bus.sample_flit("rsp", "rx")
      txn = flit["txnid"]
      op = flit["opcode"]
      self.schedule_rsp_credit_return()

      # PCrdGrant is credit-typed, not TxnID-tied: bank one credit and step off.
      if op == int(RspOpcode.PCRD_GRANT):
        self.bank_pcrd_grant(flit)
        await bus.rising()
        self.drive_idle_sideband()
        continue

      if op == int(RspOpcode.PERSIST):
        idx = self.find_mixed_persist_ctx(flit["srcid"], flit["tgtid"])
      else:
        idx = self.find_mixed_ctx_by_txn(txn)
      if idx < 0:
        if op == int(RspOpcode.PERSIST):
          raise AssertionError(
            f"[{self.get_name()}] Standalone Persist route "
            f"0x{flit['srcid']:x}->0x{flit['tgtid']:x} matches no outstanding "
            f"separated-persist transaction")
        raise AssertionError(
          f"[{self.get_name()}] RSP txn_id 0x{txn:x} matches no outstanding transaction")
      c = self.mx_ctx[idx]

      if op == int(RspOpcode.RETRY_ACK):
        if c.retried:
          raise AssertionError(
            f"[{self.get_name()}] second RetryAck for txn_id 0x{txn:x} "
            f"(re-issue must not be retryable)")
        c.retry_pending = True
        c.pcrd_type = flit["pcrdtype"]
        await bus.rising()
        self.drive_idle_sideband()
        continue

      if c.kind == _KIND_READ:
        if op != int(RspOpcode.READ_RECEIPT):
          raise AssertionError(
            f"[{self.get_name()}] read RSP txn_id 0x{txn:x} expected ReadReceipt, "
            f"got opcode 0x{op:x}")
        c.receipt_seen = True
        await bus.rising()
        self.drive_idle_sideband()
        continue

      if c.kind == _KIND_PERSIST:
        self.stamp_rsp_flit_on_req(c.item, flit)
        if op == int(RspOpcode.PERSIST):
          c.persist_seen = True
        elif op == int(RspOpcode.COMP_PERSIST):
          # Comp and Persist in one flit: both milestones at once.
          c.comp_seen = True
          c.persist_seen = True
        elif op == int(RspOpcode.COMP):
          c.comp_seen = True
        else:
          raise AssertionError(
            f"[{self.get_name()}] pipeline persist expects Persist/CompPersist/Comp, "
            f"got opcode 0x{op:x}")
        await bus.rising()
        self.drive_idle_sideband()
        continue

      # Writes and atomics: DBID grant on RSP and (split/store) a later Comp.
      self.stamp_rsp_flit_on_req(c.item, flit)
      if op == int(RspOpcode.COMP_DBID_RESP):
        c.dbid = flit["dbid"]
        c.grant_seen = True
        c.comp_seen = True
      elif op in (int(RspOpcode.DBID_RESP), int(RspOpcode.DBID_RESP_ORD)):
        c.dbid = flit["dbid"]
        c.grant_seen = True
      elif op == int(RspOpcode.COMP):
        c.comp_seen = True
      else:
        raise AssertionError(
          f"[{self.get_name()}] pipeline write/atomic expects CompDBIDResp or "
          f"DBIDResp+Comp, got opcode 0x{op:x}")

      await bus.rising()
      self.drive_idle_sideband()

  # The pipeline's DAT receive path, one beat at a time.
  #
  # Each beat is filed against the transaction its TxnID names and the transfer
  # retires on its OWN beat count, derived from the request Size. That is the
  # difference from collect_read_completion: with several reads outstanding a
  # completer may interleave their beats on the channel, and the FLITPEND
  # deassert then marks the end of the channel's activity rather than the end of
  # any one transfer. Counting beats per transaction is the only reading that
  # survives both shapes -- and it costs nothing on contiguous traffic, where the
  # count is reached on exactly the beat FLITPEND would have marked.
  async def mixed_dat_proc(self):
    bus = self.bus
    while True:
      while not bus.get("rxdatflitv"):
        await bus.rising()
        self.drive_idle_sideband()

      flit = bus.sample_flit("dat", "rx")
      idx = self.find_mixed_read_by_completion(flit["txnid"])
      if idx < 0:
        raise AssertionError(
          f"[{self.get_name()}] Mixed CompData TxnID 0x{flit['txnid']:x} "
          f"matches no outstanding read")

      ctx = self.mx_ctx[idx]
      r = ctx.item

      # Atomic data completions keep the contiguous collector: the returned size
      # is not the request Size (AtomicCompare returns half of it), so there is
      # no beat count to retire on, and the completer never interleaves them.
      if ctx.kind != _KIND_READ:
        await self.collect_read_completion(r)
        idx = self.find_mixed_ctx_by_txn(_I(r.txn_id))
        if idx < 0:
          raise AssertionError(
            f"[{self.get_name()}] Mixed read TxnID 0x{_I(r.txn_id):x} "
            f"vanished before completion")
        self.mx_ctx[idx].read_done = True
        continue

      self.schedule_dat_credit_return()
      ctx.dat_beats.append(flit)
      self.stamp_dat_beat_on_req(r, flit)

      expected = chi_xfer_dat_beats(_I(r.size), bus.cfg.data_bytes)
      complete = len(ctx.dat_beats) >= expected
      if complete:
        self.place_dat_beats(r, ctx.dat_beats)
        ctx.dat_beats = []

      await bus.rising()
      self.drive_idle_sideband()

      if complete:
        # Re-find by request TxnID: the queue may have shifted while this
        # coroutine yielded (only the TX thread deletes, and it will not retire
        # this read until read_done is set just below).
        idx = self.find_mixed_ctx_by_txn(_I(r.txn_id))
        if idx < 0:
          raise AssertionError(
            f"[{self.get_name()}] Mixed read TxnID 0x{_I(r.txn_id):x} "
            f"vanished before completion")
        self.mx_ctx[idx].read_done = True
