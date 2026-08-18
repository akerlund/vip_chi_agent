################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_driver_snf.sv (serial auto-responder path).
#
# SN-F completer. driver_start() forks the credit loop, activates the link, and
# runs seq_loop(): each cycle it samples the REQ channel and, on an inbound
# request, returns the REQ credit and drives the opcode-specific auto response:
#   * ReadNoSnp[Sep]        -> (ordered: ReadReceipt) + CompData/DataSepResp burst
#   * WriteNoSnp{Full,Ptl}  -> CompDBIDResp (or split DBIDResp+Comp), collect the
#                              DAT burst, commit into vip_mem, optional CompAck
#   * WriteNoSnpZero        -> zero the byte range, Comp
# Address-range DECERR/DERR injection mirrors the SV completer. Atomics and the
# separated-persist completions are Tier B and not dispatched here yet.
#
# Same ChiBus timing discipline as the RN-I driver: `@(snf_cb)` -> rising(),
# `snf_cb.rx*` -> get(), `snf_cb.tx* <=` -> drive()/drive_flit().
#
################################################################################

from __future__ import annotations

import random

import cocotb

from pyuvm import uvm_driver, ConfigDB

from vip_chi_types_pkg import (
  Role, ReqOpcode, RspOpcode, DatOpcode, Resp, RespErr, RawChannel,
  DatInterleavePolicy,
  chi_xfer_dat_beats, req_opcode_is_atomic, req_opcode_is_atomic_compare,
  req_opcode_is_atomic_returning_data, req_opcode_atomic_variant, mask,
)
from vip_chi_if import ChiBus
from vip_chi_lcrd_mgr import VipChiLcrdMgr
from vip_chi_cfg_agent import VipChiCfgAgent
from vip_mem import vip_mem

_I = int

_AUTO_READ = {int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP)}
# Combined Write + CMO (Issue E). One request carrying both a write and a cache
# maintenance operation to the same address, which the completer must apply IN
# THAT ORDER -- the CMO acts on the state the write leaves behind.
#
# The write half is an ordinary WriteNoSnp Full/Ptl, so these take the same auto
# write path; Full vs Ptl needs no branch because the write commits through the
# byte enables either way. What the combined form adds is the CMO half of the
# completion, driven after the data commits.
_COMBINED_WRITE_CMO = {
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH),
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_INV),
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_INV),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP),
}

# The combined forms whose CMO half is PERSISTENT, which is the one that adds an
# observable response rather than only a CompCMO. A memory node has no cache, so
# CleanSh and CleanInv complete with no state change; the persist leg is the half
# a test can actually watch land in the wrong order.
_COMBINED_CMO_PERSIST = {
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP),
}

_AUTO_WRITE = ({int(ReqOpcode.WRITE_NO_SNP_FULL), int(ReqOpcode.WRITE_NO_SNP_PTL)}
               | _COMBINED_WRITE_CMO)
_AUTO_WRITE_ZERO = {int(ReqOpcode.WRITE_NO_SNP_ZERO)}
_AUTO_PERSIST = {int(ReqOpcode.CLEAN_SHARED_PERSIST),
                 int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP)}


class vip_chi_driver_snf(uvm_driver):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.bus = None
    self.cfg = None
    self.role = Role.SNF
    self.mem = None
    self.mem_rows_written = set()
    # CHI-E MTE tag store: row index -> (dat_tagop, tag, tu), captured from write
    # DAT beats and replayed on the auto-read CompData so tags round-trip.
    self.tag_mem = {}

    self.rsp_lcrd = VipChiLcrdMgr("rsp_lcrd_mgr")
    self.dat_lcrd = VipChiLcrdMgr("dat_lcrd_mgr")
    self.req_lcrdv_pending = 0
    self.rsp_lcrdv_pending = 0
    self.dat_lcrdv_pending = 0
    self.retries_issued = 0

    # Buffered inbound REQ flits awaiting an auto-response, used only on the
    # multi-outstanding path so a pipelined REQ arriving mid-response is queued
    # rather than dropped.
    self.captured_reqs = []
    # One-shot latch for cfg.snf_reorder_ordered_service (see req_response_loop):
    # the negative control inverts a single pair, so the ordered-stream check has
    # exactly one violation to report.
    self.ordered_swap_done = False

    # What actually reached the DAT wire, for a test to check the emission
    # against. dat_beat_txn_log is the TxnID of every beat this driver has sent,
    # in order; n_dat_stream_switches counts the points in an interleaved
    # emission where the next beat came from a different transfer than the last.
    #
    # Zero switches means the beats went out contiguously -- which is what makes
    # this the anti-vacuity handle for the interleaving test: without it, a test
    # that asserts "the payload reassembled correctly" passes just as happily
    # when no interleaving ever happened.
    self.dat_beat_txn_log = []
    self.n_dat_stream_switches = 0

    self._driver_tasks = []
    self.agent_owned = False

    # TXSACTIVE outstanding-window state. See tx_activity_begin().
    self.tx_active_count = 0
    self._tx_active_extend = 0

  # ==========================================================================
  # TXSACTIVE outstanding-window drive.
  #
  # Deliberately the same shape as vip_chi_driver_rni's -- same method names,
  # same counter semantics -- rather than a shared base: the SV SN-F does not
  # inherit the SV RN-I either, and the two flows are kept structurally
  # parallel so a reader can diff them.
  #
  # TXSACTIVE must span the whole window in which this node may have snoopable
  # transactions outstanding, not bracket each flit. For a completer that
  # window runs from taking a request off the wire to finishing its last
  # completion flit, so the count -- not any one response -- decides the level.
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

  # Called once per cycle from credit_loop, so the extension counts cycles
  # rather than callers.
  def tx_activity_tick(self):
    if self.tx_active_count > 0:
      return
    if self._tx_active_extend > 0:
      self._tx_active_extend -= 1
      return
    self.bus.drive(txsactive=0)

  # ==========================================================================
  def build_phase(self):
    self.bus = ConfigDB().get(self, "", "vif")
    try:
      self.cfg = ConfigDB().get(self, "", "cfg")
    except Exception:
      self.cfg = VipChiCfgAgent("default_cfg")
      self.cfg.role = Role.SNF
    cfg = self.bus.cfg
    self.mem = vip_mem("mem", row_bytes=cfg.data_bytes, addr_width=cfg.addr_width)
    self.mem.reset()
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
    self.rsp_lcrd.reset(self.cfg.rsp_send_credit_cap, 0)
    self.dat_lcrd.reset(self.cfg.dat_send_credit_cap, 0)
    self.req_lcrdv_pending = 0
    self.rsp_lcrdv_pending = 0
    self.dat_lcrdv_pending = 0
    # Credits advertised to the peer and not yet spent -- the half of quiescence
    # a sender cannot see from its own send pools. See _link_drained().
    self.req_lcrd_granted = 0
    self.rsp_lcrd_granted = 0
    self.dat_lcrd_granted = 0
    # Set while the peer has withdrawn its activation request and this node is
    # handing its credits back. Suppresses NEW grants: a receiver may not issue
    # L-credits once the link is coming down, and a drain racing a credit loop
    # that keeps refilling the pool would never converge.
    self.link_deactivating = False
    # Countdowns for the two negative controls: one holds ACTIVATE by withholding
    # the acknowledge, the other holds DEACTIVATE past its drain by withholding
    # the drop.
    self.activate_stall_remaining = int(self.cfg.lasm_stall_activation_cycles)
    self.deactivate_stall_remaining = 0
    # Shadow of the acknowledge last driven, so the bring-up wait and the
    # deactivation tracker read one value rather than re-deriving it. Mirrors the
    # SV port, where a clocking-block output cannot be sampled at all.
    self.ack_driven = False

  def schedule_initial_credit_grants(self):
    self.req_lcrdv_pending += self.cfg.initial_req_credits
    self.rsp_lcrdv_pending += self.cfg.initial_rsp_credits
    self.dat_lcrdv_pending += self.cfg.initial_dat_credits

  def schedule_req_credit_return(self):
    self.req_lcrdv_pending += 1

  def schedule_rsp_credit_return(self):
    self.rsp_lcrdv_pending += 1

  def schedule_dat_credit_return(self):
    self.dat_lcrdv_pending += 1

  # ==========================================================================
  # Interface reset.
  # ==========================================================================
  def reset_outputs(self):
    bus = self.bus
    bus.drive(txlinkactivereq=0, txlinkactiveack=0, txsactive=0)
    self.ack_driven = False
    bus.drive(txreqlcrdv=0)
    bus.drive(txrspflitpend=0, txrspflitv=0, txrsplcrdv=0)
    bus.drive_flit("rsp", {})
    bus.drive(txdatflitpend=0, txdatflitv=0, txdatlcrdv=0)
    bus.drive_flit("dat", {})
    if self.mem is not None:
      self.mem.reset()
    self.mem_rows_written = set()
    self.tag_mem = {}

  def reset_vif(self):
    self.reset_outputs()

  def handle_reset(self):
    self._kill_driver_tasks()
    self.retries_issued = 0
    self.captured_reqs = []
    self.ordered_swap_done = False
    self.dat_beat_txn_log = []
    self.n_dat_stream_switches = 0
    self.tx_active_count = 0
    self._tx_active_extend = 0
    self.reset_credit_state()
    self.reset_outputs()

  def drive_idle_sideband(self):
    """The acknowledge follows the peer's request -- except while coming down.

    A receiver may only drop LINKACTIVEACK once every L-credit it advertised has
    come back. Mirroring the request one cycle later would put the link in STOP
    with credits still banked at both ends, which is precisely the state
    CHI_LCRD_QUIESCENT_IN_STOP exists to report: the two ends would disagree
    about what the peer may send after the next bring-up, and the first flit
    across the reactivated link would go out unauthorised.

    So DEACTIVATE is held -- ack high, request low -- for exactly as long as the
    drain takes. cfg.lasm_stall_deactivation_cycles then holds it longer still,
    which is the negative control for the deactivation timeout; and
    cfg.lasm_stall_activation_cycles withholds the acknowledge in the other
    direction, which is the control for the activation timeout.
    """
    if self.bus.get("rxlinkactivereq"):
      self.ack_driven = self.activate_stall_remaining == 0
    else:
      self.ack_driven = not self._link_drained()
    self.bus.drive(txlinkactiveack=1 if self.ack_driven else 0)

  def _rx_req_is_lcrd_return(self, req):
    """An inbound L-credit return is a link-layer flit, not a request.

    It consumes the credit it hands back and nothing else, so the response loops
    must not open a TXSACTIVE window for it, queue it, or try to answer it -- a
    completer that treated one as a transaction would sit claiming an
    outstanding response to a request that was never made, which is exactly what
    CHI_LINK_DEACTIVATE_WHEN_IDLE then reports against it.

    Nor is the credit re-granted: the peer is handing it back, so advertising it
    again would refill the pool the tear-down is emptying. The credit-loop
    accounting (req_lcrd_granted) already retires it.
    """
    return int(req.get("opcode", -1)) == 0

  def _link_drained(self):
    """Both halves of quiescence at this endpoint.

    Nothing this node still holds, and nothing it advertised that the peer still
    holds.
    """
    if self.deactivate_stall_remaining:
      return False
    return not (self.req_lcrd_granted or self.rsp_lcrd_granted
                or self.dat_lcrd_granted
                or self.rsp_lcrd.available or self.dat_lcrd.available)

  # ==========================================================================
  # Backing-store row bookkeeping (served data falls back to a deterministic
  # pattern for untouched rows so untouched-address smokes stay stable).
  # ==========================================================================
  def _row_index(self, addr):
    return _I(addr) // self.bus.cfg.data_bytes

  def _mark_row(self, addr):
    self.mem_rows_written.add(self._row_index(addr))

  def _has_row(self, addr):
    return self._row_index(addr) in self.mem_rows_written

  def _addr_in_range(self, addr, base, limit):
    a = _I(addr) & ((1 << self.bus.cfg.addr_width) - 1)
    return base <= a <= limit

  def decerr_check(self, addr):
    return any(self._addr_in_range(addr, b, l) for b, l in self.cfg.decerr_ranges)

  def derr_check(self, addr):
    if self.decerr_check(addr):
      return False
    return any(self._addr_in_range(addr, b, l) for b, l in self.cfg.derr_ranges)

  def auto_read_data(self, addr, beat_index):
    dw = self.bus.cfg.data_bytes * 8
    return (_I(addr) + beat_index) & ((1 << dw) - 1)

  # Beat position carried by the send_index'th DAT beat of a read burst. CHI
  # places a beat by its DataID rather than by its position in the burst, so the
  # completer may send the positions in any order as long as each beat carries
  # the payload belonging to the DataID it announces.
  #
  #   default                    : ascending, 0 .. beat_count-1
  #   cfg.snf_reverse_dat_beats  : descending, beat_count-1 .. 0
  #   cfg.snf_duplicate_dat_beat : the last send repeats position 0, so one
  #     position is delivered twice and the last position never at all -- the
  #     negative control for the monitor's duplicate/missing DataID checks
  #
  # A single-beat transfer has nothing to reorder, so both knobs are inert.
  def dat_beat_position(self, send_index, beat_count):
    if beat_count <= 1:
      return send_index
    if self.cfg.snf_duplicate_dat_beat and send_index == (beat_count - 1):
      return 0
    if self.cfg.snf_reverse_dat_beats:
      return beat_count - 1 - send_index
    return send_index

  def read_data_beat(self, addr, beat_index):
    beat_addr = _I(addr) + beat_index * self.bus.cfg.data_bytes
    if self._has_row(beat_addr):
      return _I(self.mem.rd_addr(beat_addr))
    return self.auto_read_data(addr, beat_index)

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
    self._spawn(self.deactivate_drain())
    await self.activate_link()
    # Manual completion injection runs alongside the wire-observing auto-responder
    # (SV polls try_next_item inside the serial loop; pyUVM has no non-blocking
    # poll, so the manual path is a dedicated coroutine that blocks on the SN-F
    # sequencer). Tests that inject manual completions keep the RN-I idle, so the
    # two never contend for the RSP/DAT channels.
    self._spawn(self.manual_dispatch_loop())
    if self.cfg.multi_outstanding:
      await self.seq_loop_buffered()
    else:
      await self.seq_loop()

  # ==========================================================================
  # Manual SN-F completion dispatch (vip_chi_pipelined_seq): pull each pre-built
  # completion item off the sequencer and drive it verbatim. Channel select
  # mirrors the SV: raw_override -> raw relay, data present -> DAT, else RSP.
  # ==========================================================================
  async def manual_dispatch_loop(self):
    while True:
      item = await self.seq_item_port.get_next_item()
      # A manually injected completion is outbound activity that no captured
      # request accounts for, so it opens a window of its own.
      self.tx_activity_begin()
      try:
        if getattr(item, "raw_override", False):
          await self.drive_raw_item(item)
        elif len(item.data) > 0:
          await self.drive_dat_item(item)
        else:
          await self.drive_rsp_item(item)
      finally:
        self.tx_activity_end()
      self.seq_item_port.item_done()

  # --------------------------------------------------------------------------
  async def credit_loop(self):
    bus = self.bus
    while True:
      await bus.rising()
      self.track_deactivation()
      self.drive_idle_sideband()
      self.tx_activity_tick()
      grant = not self.link_deactivating
      bus.drive(txreqlcrdv=1 if (self.req_lcrdv_pending and grant) else 0)
      bus.drive(txrsplcrdv=1 if (self.rsp_lcrdv_pending and grant) else 0)
      bus.drive(txdatlcrdv=1 if (self.dat_lcrdv_pending and grant) else 0)
      if self.req_lcrdv_pending and grant:
        self.req_lcrdv_pending -= 1
        self.req_lcrd_granted += 1
      if self.rsp_lcrdv_pending and grant:
        self.rsp_lcrdv_pending -= 1
        self.rsp_lcrd_granted += 1
      if self.dat_lcrdv_pending and grant:
        self.dat_lcrdv_pending -= 1
        self.dat_lcrd_granted += 1

      # Every inbound flit spends one of the credits advertised above, INCLUDING
      # an L-credit return: the return is itself a flit and consumes the credit
      # it hands back. That is what lets the drain converge with no separate
      # accounting for the two kinds.
      if bus.get("rxreqflitv") and self.req_lcrd_granted:
        self.req_lcrd_granted -= 1
      if bus.get("rxrspflitv") and self.rsp_lcrd_granted:
        self.rsp_lcrd_granted -= 1
      if bus.get("rxdatflitv") and self.dat_lcrd_granted:
        self.dat_lcrd_granted -= 1

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
  # take the credit. See the RN-I twin for why the delay lands before the credit
  # and why L-credit returns are excluded.
  # --------------------------------------------------------------------------
  async def wait_channel_delay(self, cycles):
    bus = self.bus
    for _ in range(cycles):
      await bus.rising()
      self.drive_idle_sideband()

  async def wait_rsp_credit(self):
    await self.wait_channel_delay(self.cfg.draw_rsp_valid_delay())
    await self.wait_for_credit(self.rsp_lcrd)

  async def wait_dat_credit(self):
    await self.wait_channel_delay(self.cfg.draw_dat_valid_delay())
    await self.wait_for_credit(self.dat_lcrd)

  # --------------------------------------------------------------------------
  async def activate_link(self):
    bus = self.bus
    while True:
      await bus.rising()
      self.drive_idle_sideband()
      if bus.in_reset() or bus.get("rxlinkactivereq"):
        break
    # The acknowledge may be withheld here by cfg.lasm_stall_activation_cycles;
    # see drive_idle_sideband, which is where the suppression lives because the
    # credit loop drives the same signal every cycle and would otherwise raise it
    # straight back.
    while not (bus.in_reset() or self.ack_driven):
      await bus.rising()
      self.drive_idle_sideband()
    self.schedule_initial_credit_grants()

  # --------------------------------------------------------------------------
  def track_deactivation(self):
    """Follow the peer's activation request into and back out of deactivation.

    The completer has no deactivation request of its own to make -- it reacts.
    Everything it must do is a consequence of the request going away: stop
    granting, hand back what it holds, and only then let the acknowledge fall.
    """
    req = self.bus.get("rxlinkactivereq")
    if not req and self.ack_driven:
      if not self.link_deactivating:
        self.link_deactivating = True
        self.deactivate_stall_remaining = int(
          self.cfg.lasm_stall_deactivation_cycles)
        # Queued-but-unsent grants are dropped rather than carried across the
        # gap: they were promises about a link that no longer exists, and
        # re-activation advertises a fresh budget.
        self.req_lcrdv_pending = 0
        self.rsp_lcrdv_pending = 0
        self.dat_lcrdv_pending = 0
      if self.deactivate_stall_remaining:
        self.deactivate_stall_remaining -= 1
    elif req:
      if self.link_deactivating:
        self.link_deactivating = False
        self.deactivate_stall_remaining = 0
        self.schedule_initial_credit_grants()
      # The activation stall re-arms on each fresh request and counts down while
      # the request is up, so it delays every bring-up rather than only the
      # first -- a test that deactivates and reactivates stalls both times.
      if self.activate_stall_remaining:
        self.activate_stall_remaining -= 1
    else:
      # Request low and acknowledge already low: the link is at rest in STOP.
      # Re-arm the stall for the next bring-up.
      self.activate_stall_remaining = int(self.cfg.lasm_stall_activation_cycles)

  # --------------------------------------------------------------------------
  async def deactivate_drain(self):
    """Hand back every send-side L-credit this node holds, once asked to.

    A separate task rather than a step in the credit loop, because a credit
    return is a FLIT and the SN-F drives flits from exactly one place. The guards
    below are what keep it that way:

      * the link must be in DEACTIVATE, which the requester only enters after
        every one of its transactions has retired, so the response loop has
        nothing left to send; and
      * tx_active_count must be zero, which closes the one-cycle tail where the
        requester has seen its last completion but this node is still driving its
        final flit.
    """
    bus = self.bus
    while True:
      while not (self.link_deactivating and not self.tx_active_count
                 and (self.rsp_lcrd.available or self.dat_lcrd.available)):
        await bus.rising()
        self.drive_idle_sideband()

      for channel, lcrd in (("rsp", self.rsp_lcrd), ("dat", self.dat_lcrd)):
        while lcrd.try_acquire_credit():
          await self.drive_lcrd_return(channel)

  async def drive_lcrd_return(self, channel):
    """One L-credit return flit.

    All fields zero: the opcode is the whole message, and a return names no
    address, no TxnID and no data.
    """
    bus = self.bus
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(**{f"tx{channel}flitpend": 0, f"tx{channel}flitv": 1})
    bus.drive_flit(channel, {"opcode": 0})
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(**{f"tx{channel}flitv": 0})
    bus.drive_flit(channel, {})

  # ==========================================================================
  # Main serial responder loop (auto-responder path).
  #
  # The SN-F is a pure completer here: it samples the REQ channel every cycle and
  # drives the opcode-specific auto response. The SV loop also polls the
  # sequencer (try_next_item) for manual SN-F RSP/DAT items; pyUVM's seq_item
  # port has no non-blocking poll, so manual SN-F sequences (drive_rsp_item /
  # drive_dat_item / drive_raw_item) are a Tier-B concern and this A2 loop is
  # purely the wire-observing auto-responder.
  # ==========================================================================
  async def seq_loop(self):
    bus = self.bus
    while True:
      await bus.rising()
      self.drive_idle_sideband()

      if not bus.get("rxreqflitv"):
        continue

      req = bus.sample_flit("req", "rx")
      if self._rx_req_is_lcrd_return(req):
        continue
      self.schedule_req_credit_return()
      # The window opens when the request comes off the wire -- from here until
      # the last completion flit this node owes a response, which is exactly
      # what TXSACTIVE reports.
      self.tx_activity_begin()
      try:
        await self.dispatch_auto_response(req)
      finally:
        self.tx_activity_end()

  # ==========================================================================
  # Buffered responder loop (opt-in via cfg.multi_outstanding): one coroutine
  # captures every inbound REQ into a queue (returning its REQ credit at once),
  # a second drains the queue and drives each auto-response. Decoupling capture
  # from response means a request that arrives while an earlier burst is still
  # being driven is buffered rather than dropped -- which is what lets the RN-I
  # keep several transactions outstanding.
  # ==========================================================================
  async def seq_loop_buffered(self):
    self._spawn(self.req_capture_loop())
    await self.req_response_loop()

  async def req_capture_loop(self):
    bus = self.bus
    while True:
      await bus.rising()
      self.drive_idle_sideband()
      if bus.get("rxreqflitv"):
        req = bus.sample_flit("req", "rx")
        if self._rx_req_is_lcrd_return(req):
          continue
        self.schedule_req_credit_return()
        self.captured_reqs.append(req)
        # Opened at capture, not at dispatch: a buffered request is already
        # outstanding while it waits its turn in the queue, and the sideband
        # has to say so.
        self.tx_activity_begin()

  # Head-of-queue reads this responder may complete together, or [] for none.
  #
  # Only a RUN of reads at the head qualifies, and the walk stops at the first
  # request that is not one. Reordering across an intervening write would be a
  # separate decision with its own ordering consequences; interleaving is meant
  # to change the shape of the DATA on the channel, not the order in which
  # requests are served.
  def _head_read_run(self):
    group = []
    for req in self.captured_reqs:
      # A request that is about to be retried has no data leg at all.
      if req["opcode"] not in _AUTO_READ or self.should_auto_retry(req):
        break
      group.append(req)
    return group

  async def _interleave_group(self):
    depth = self.cfg.dat_interleave_depth
    if depth <= 1 or not self._head_read_run():
      return []

    # Hold briefly for the rest of the group -- see
    # cfg.dat_interleave_gather_cycles for why a window is needed at all.
    for _ in range(self.cfg.dat_interleave_gather_cycles):
      if len(self._head_read_run()) >= depth:
        break
      await self.bus.rising()
      self.drive_idle_sideband()

    group = self._head_read_run()[:depth]
    # One stream is not an interleaving; fall through to the ordinary path so a
    # lone read still produces exactly the wire it always did.
    return group if len(group) >= 2 else []

  async def req_response_loop(self):
    bus = self.bus
    while True:
      if self.captured_reqs:
        # Negative control (cfg.snf_reorder_ordered_service): serve the second of
        # two queued ordered requests first. Every transaction still completes
        # correctly on its own -- only the order the completer acknowledges them
        # in is wrong, which is exactly the fault the ordered-stream check exists
        # to catch and the only fault it should catch. It fires ONCE, so the check
        # has exactly one inversion to report and the count a negative control
        # asserts on is unambiguous.
        if (self.cfg.snf_reorder_ordered_service and not self.ordered_swap_done
            and len(self.captured_reqs) >= 2
            and self.req_has_ordering(self.captured_reqs[0])
            and self.req_has_ordering(self.captured_reqs[1])):
          self.ordered_swap_done = True
          req = self.captured_reqs.pop(1)
        else:
          group = await self._interleave_group()
          if group:
            del self.captured_reqs[:len(group)]
            try:
              await self.drive_interleaved_reads(group)
            finally:
              # One activity close per request served, not one per call: TXSACTIVE
              # counts outstanding transactions, and this call retired several.
              for _ in group:
                self.tx_activity_end()
            continue
          req = self.captured_reqs.pop(0)
        try:
          await self.dispatch_auto_response(req)
        finally:
          self.tx_activity_end()
      else:
        await bus.rising()
        self.drive_idle_sideband()

  # ==========================================================================
  # Drive the SN-F auto-response for one REQ (already off the wire, credit
  # already returned by the caller). Shared by the serial and buffered loops.
  # ==========================================================================
  async def dispatch_auto_response(self, req):
    if self.should_auto_retry(req):
      self.retries_issued += 1
      await self.drive_auto_retry(req)
      return

    op = req["opcode"]
    if op in _AUTO_READ:
      await self.drive_auto_read_compdata(req)
    elif op == int(ReqOpcode.PREFETCH_TGT):
      return  # PrefetchTgt is a hint with no completion
    elif op in _AUTO_PERSIST:
      await self.drive_auto_persist_rsp(req)
    elif req_opcode_is_atomic(op):
      await self.drive_auto_atomic_completion(req)
    elif op in _AUTO_WRITE_ZERO:
      await self.drive_auto_write_zero_comp(req)
    elif op in _AUTO_WRITE:
      await self.drive_auto_write_comp(req)

  # ==========================================================================
  # Persist CMO auto-response. Carries no data and grants no DBID.
  #
  # CleanSharedPersist takes a single Comp. CleanSharedPersistSep has exactly two
  # legal completions, and this drives one of them:
  #
  #   * Comp then Persist -- the request reached the Point of Coherency, then it
  #     reached the Point of Persistence. Two milestones, two responses. Default.
  #   * a single CompPersist, the two combined. cfg.combined_persist_rsp.
  #
  # It used to drive Persist then CompPersist, which is neither: the requester
  # never received a bare Comp, and persistence was signalled twice -- once alone
  # and again inside the combined response.
  # ==========================================================================
  async def drive_auto_persist_rsp(self, req):
    is_sep = req["opcode"] == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP)
    base = {
      "srcid": req["tgtid"], "tgtid": req["srcid"], "txnid": req["txnid"],
      "qos": req["qos"], "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
    }

    if is_sep and self.cfg.combined_persist_rsp:
      await self.drive_rsp(dict(base, opcode=int(RspOpcode.COMP_PERSIST)))
      return

    await self.drive_rsp(dict(base, opcode=int(RspOpcode.COMP)))

    if is_sep:
      # Persist is not tied to a TxnID.
      await self.drive_rsp(dict(base, txnid=0, opcode=int(RspOpcode.PERSIST)))

  # ==========================================================================
  # Opcode classifiers / helpers.
  # ==========================================================================
  def req_has_ordering(self, req):
    return req["order"] != 0

  def should_auto_retry(self, req):
    return (self.retries_issued < self.cfg.force_retry_count) and req["allowretry"]

  # ==========================================================================
  # RSP / DAT flit drivers (shared by auto responses and manual items).
  # ==========================================================================
  async def drive_rsp(self, fields):
    bus = self.bus
    await self.wait_rsp_credit()
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(txrspflitpend=0, txrspflitv=1)
    bus.drive_flit("rsp", fields)
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(txrspflitv=0)
    bus.drive_flit("rsp", {})

  async def drive_rsp_item(self, rsp):
    fields = {
      "dbid": _I(rsp.dbid), "fwdstate": _I(rsp.fwd_state),
      "resp": _I(rsp.rsp_resp), "resperr": _I(rsp.rsp_resp_err),
      "opcode": _I(rsp.rsp_opcode), "txnid": _I(rsp.txn_id),
      "srcid": _I(rsp.src_id), "tgtid": _I(rsp.tgt_id),
      "pcrdtype": _I(rsp.pcrd_type), "qos": _I(rsp.qos),
    }
    await self.drive_rsp(fields)

  async def drive_dat_item(self, rsp):
    bus = self.bus
    n = len(rsp.data)
    for i in range(n):
      fields = {
        "data": _I(rsp.data[i]), "be": _I(rsp.be[i]),
        "dataid": i, "ccid": 0, "dbid": _I(rsp.dbid),
        "resp": _I(rsp.dat_resp[i]) if i < len(rsp.dat_resp) else _I(rsp.rsp_resp),
        "resperr": _I(rsp.dat_resp_err[i]) if i < len(rsp.dat_resp_err) else _I(rsp.rsp_resp_err),
        "opcode": _I(rsp.dat_opcode), "txnid": _I(rsp.txn_id),
        "srcid": _I(rsp.src_id), "tgtid": _I(rsp.tgt_id), "qos": _I(rsp.qos),
      }
      if bus.cfg.is_e:
        fields["tagop"] = _I(rsp.dat_tagop)
        fields["tag"] = _I(rsp.tag[i]) if i < len(rsp.tag) else 0
        fields["tu"] = _I(rsp.tu[i]) if i < len(rsp.tu) else 0
      await self.wait_dat_credit()
      await bus.rising()
      self.drive_idle_sideband()
      bus.drive(txdatflitpend=1 if i != (n - 1) else 0, txdatflitv=1)
      bus.drive_flit("dat", fields)
      await bus.rising()
      self.drive_idle_sideband()
      bus.drive(txdatflitpend=0, txdatflitv=0)
      bus.drive_flit("dat", {})
    await bus.rising()
    self.drive_idle_sideband()

  # ==========================================================================
  # Auto responses.
  # ==========================================================================
  async def drive_auto_read_receipt(self, req):
    await self.drive_rsp({
      "opcode": int(RspOpcode.READ_RECEIPT), "srcid": req["tgtid"],
      "tgtid": req["srcid"], "txnid": req["txnid"], "qos": req["qos"],
      "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
    })

  async def drive_auto_retry(self, req):
    pcrd = 0x1
    await self.drive_rsp({
      "opcode": int(RspOpcode.RETRY_ACK), "srcid": req["tgtid"],
      "tgtid": req["srcid"], "txnid": req["txnid"], "qos": req["qos"],
      "pcrdtype": pcrd, "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
    })
    await self.drive_rsp({
      "opcode": int(RspOpcode.PCRD_GRANT), "srcid": req["tgtid"],
      "tgtid": req["srcid"], "txnid": 0, "qos": req["qos"],
      "pcrdtype": pcrd, "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
    })

  async def drive_auto_write_comp(self, req):
    bus = self.bus
    cfg = self.bus.cfg
    req_addr = req["addr"]
    req_txn = req["txnid"]
    req_src = req["srcid"]
    req_tgt = req["tgtid"]
    beat_count = chi_xfer_dat_beats(req["size"], cfg.data_bytes)
    is_decerr = self.decerr_check(req_addr)

    err = int(RespErr.NDERR) if is_decerr else int(RespErr.OKAY)
    split = self.cfg.split_write_rsp
    if split:
      grant_err = int(RespErr.OKAY)
      if cfg.is_e and self.cfg.ordered_dbid_resp and self.req_has_ordering(req):
        grant_op = int(RspOpcode.DBID_RESP_ORD)
      else:
        grant_op = int(RspOpcode.DBID_RESP)
    else:
      grant_err = err
      grant_op = int(RspOpcode.COMP_DBID_RESP)

    await self.drive_rsp({
      "opcode": grant_op, "srcid": req_tgt, "tgtid": req_src,
      "txnid": req_txn, "dbid": req_txn, "qos": req["qos"],
      "resp": int(Resp.I), "resperr": grant_err,
    })

    write_data, write_be, write_tags = [], [], []
    for beat_index in range(beat_count):
      while not bus.get("rxdatflitv"):
        await bus.rising()
        self.drive_idle_sideband()
      flit = bus.sample_flit("dat", "rx")
      if flit["txnid"] != req_txn:
        raise AssertionError(
          f"[{self.get_name()}] Write DAT txnid 0x{flit['txnid']:x} "
          f"!= granted DBID 0x{req_txn:x}")
      if flit["dbid"] != req_txn:
        raise AssertionError(
          f"[{self.get_name()}] Write DAT dbid 0x{flit['dbid']:x} "
          f"!= granted DBID 0x{req_txn:x}")
      if flit["srcid"] != req_src or flit["tgtid"] != req_tgt:
        raise AssertionError(
          f"[{self.get_name()}] Write DAT src/tgt 0x{flit['srcid']:x}->"
          f"0x{flit['tgtid']:x} != expected 0x{req_src:x}->0x{req_tgt:x}")
      self.schedule_dat_credit_return()
      write_data.append(flit["data"])
      write_be.append(flit["be"])
      if cfg.is_e:
        write_tags.append((flit.get("tagop", 0), flit.get("tag", 0), flit.get("tu", 0)))
      if not bus.get("rxdatflitpend"):
        break
      await bus.rising()
      self.drive_idle_sideband()

    if not is_decerr:
      self.mem.wr_be(req_addr, write_data, write_be)
      for i in range(len(write_data)):
        self._mark_row(req_addr + i * cfg.data_bytes)
        if cfg.is_e and i < len(write_tags):
          self.tag_mem[self._row_index(req_addr + i * cfg.data_bytes)] = write_tags[i]

    if split:
      await self.drive_rsp({
        "opcode": int(RspOpcode.COMP), "srcid": req_tgt, "tgtid": req_src,
        "txnid": req_txn, "dbid": req_txn, "qos": req["qos"],
        "resp": int(Resp.I), "resperr": err,
      })

    # The CMO half, and it goes HERE for a reason the spec states outright: the
    # combined request is one request carrying two operations to the same
    # address, and the CMO acts on the state the write leaves behind. Driving it
    # before the data had landed would answer for a cache maintenance that had
    # not happened yet.
    if req["opcode"] in _COMBINED_WRITE_CMO:
      await self.drive_combined_cmo_rsp(req, err)

    if req["expcompack"]:
      await self.wait_for_comp_ack(req_txn, req_src, req_tgt)

  async def drive_combined_cmo_rsp(self, req, err):
    """The CMO half of a combined Write + CMO completion.

    The write half completes as any write does (Comp / CompDBIDResp). The CMO
    half is a SEPARATE response -- CompCMO -- and a completer that answered a
    combined request with the write completion alone would leave the CMO
    permanently outstanding at the requester.

    For the persistent forms the spec additionally requires a Persist response
    AFTER the write data is received, which is the ordering rule this whole
    family turns on. Persist and CompCMO may be combined into a single
    CompPersist when both target the same node; they are kept separate here
    because two observable events are what a test can check an order between,
    and the combined encoding would collapse exactly the evidence.
    """
    base = {
      "srcid": req["tgtid"], "tgtid": req["srcid"], "txnid": req["txnid"],
      "dbid": req["txnid"], "qos": req["qos"], "resp": int(Resp.I),
      "resperr": err,
    }
    await self.drive_rsp(dict(base, opcode=int(RspOpcode.COMP_CMO)))

    if req["opcode"] in _COMBINED_CMO_PERSIST:
      # Persist is not tied to a TxnID.
      await self.drive_rsp(dict(base, txnid=0, opcode=int(RspOpcode.PERSIST)))

  async def drive_auto_write_zero_comp(self, req):
    cfg = self.bus.cfg
    req_addr = req["addr"]
    is_decerr = self.decerr_check(req_addr)
    transfer_bytes = 1 << req["size"]
    beat_count = chi_xfer_dat_beats(req["size"], cfg.data_bytes)

    if not is_decerr:
      remaining = transfer_bytes
      zero_data, zero_be = [], []
      for _ in range(beat_count):
        zero_data.append(0)
        n = min(remaining, cfg.data_bytes)
        zero_be.append((1 << n) - 1)
        remaining -= n
      self.mem.wr_be(req_addr, zero_data, zero_be)
      first_row = self._row_index(req_addr)
      last_row = self._row_index(req_addr + transfer_bytes - 1)
      for row in range(first_row, last_row + 1):
        self.mem_rows_written.add(row)

    # The response to WriteNoSnpZero is DBIDResp and a Comp, or a combined
    # CompDBIDResp. A bare Comp is neither, and that is what this drove: the
    # request carries no write data, so the DBID looks pointless and was simply
    # left out -- but the completion form is normative regardless of whether the
    # requester ever uses the buffer it is granted.
    #
    # cfg.split_write_rsp already means "grant and complete separately" for
    # ordinary writes, so the zero write follows the same switch rather than
    # inventing a second one.
    base = {
      "srcid": req["tgtid"], "tgtid": req["srcid"], "txnid": req["txnid"],
      "dbid": req["txnid"], "qos": req["qos"], "resp": int(Resp.I),
    }
    err = int(RespErr.NDERR) if is_decerr else int(RespErr.OKAY)

    if not self.cfg.split_write_rsp:
      await self.drive_rsp(dict(base, opcode=int(RspOpcode.COMP_DBID_RESP), resperr=err))
      return

    await self.drive_rsp(dict(base, opcode=int(RspOpcode.DBID_RESP), resperr=int(RespErr.OKAY)))
    await self.drive_rsp(dict(base, opcode=int(RspOpcode.COMP), resperr=err))

  # The read completion is in three pieces so the interleaved emitter can reuse
  # two of them unchanged: the RSP prelude a read may owe before any data, the
  # list of beats its data leg consists of, and the emission of one beat.
  #
  # Splitting it is what keeps the two paths honestly identical -- an interleaved
  # beat is the same flit the contiguous path would have sent, placed at a
  # different moment, rather than a second construction of the same thing that
  # can drift from it.

  # RSP flits owed before the data leg. Ordered reads take a ReadReceipt;
  # ReadNoSnpSep additionally takes RespSepData on RSP to the requester, separate
  # from the DataSepResp data leg that goes to ReturnNID/ReturnTxnID.
  async def drive_read_prelude(self, req, resp_code, resp_err):
    if self.req_has_ordering(req):
      await self.drive_auto_read_receipt(req)
    if req["opcode"] == int(ReqOpcode.READ_NO_SNP_SEP):
      await self.drive_rsp({
        "opcode": int(RspOpcode.RESP_SEP_DATA), "srcid": req["tgtid"],
        "tgtid": req["srcid"], "txnid": req["txnid"], "dbid": req["txnid"],
        "qos": req["qos"], "resp": resp_code, "resperr": resp_err,
      })

  # Every DAT flit of one read, in the order this completer intends to send
  # them. Pure: it reads memory and the config but touches neither the wire nor
  # the clock, so the interleaver can build several reads' beats up front and
  # then decide the order they go out in.
  def build_read_beats(self, req, resp_code, resp_err):
    cfg = self.bus.cfg
    req_addr = req["addr"]
    is_sep = (req["opcode"] == int(ReqOpcode.READ_NO_SNP_SEP))
    rsp_txn = req["returntxnid"] if is_sep else req["txnid"]
    rsp_tgt = req["returnnid"] if is_sep else req["srcid"]
    is_decerr = self.decerr_check(req_addr)
    beat_count = chi_xfer_dat_beats(req["size"], cfg.data_bytes)
    dat_op = int(DatOpcode.DATA_SEP_RESP) if is_sep else int(DatOpcode.COMP_DATA)
    be_all = (1 << cfg.be_width) - 1

    beats = []
    for send_index in range(beat_count):
      # Which beat position this send carries. The knobs move the position
      # without touching the payload, so a beat always carries the data
      # belonging to the DataID it announces.
      beat_index = self.dat_beat_position(send_index, beat_count)
      fields = {
        "data": 0 if is_decerr else self.read_data_beat(req_addr, beat_index),
        "be": 0 if is_decerr else be_all,
        "dataid": beat_index, "ccid": 0, "dbid": rsp_txn,
        "resp": resp_code, "resperr": resp_err, "opcode": dat_op,
        "homenid": req["tgtid"], "txnid": rsp_txn, "srcid": req["tgtid"],
        "tgtid": rsp_tgt, "qos": req["qos"],
      }
      if cfg.is_e:
        tg = self.tag_mem.get(self._row_index(req_addr + beat_index * cfg.data_bytes))
        fields["tagop"], fields["tag"], fields["tu"] = tg if tg is not None else (0, 0, 0)
        # Negative control (cfg.snf_corrupt_tag). Two independent breakages,
        # because the two reachable rules fail independently:
        #   the TAG comes back wrong   -- a corrupt tag store.
        #   the TAGOP comes back wrong -- a completer that invented a TagOp
        #                                 instead of replaying the stored one.
        # Both on the same beat, and that is forced by the link rather than
        # chosen: the only MTE-capable link here is 64 bytes and CHI's maximum
        # transfer Size is 64 bytes, so every MTE transfer has exactly one beat.
        if self.cfg.snf_corrupt_tag and tg is not None:
          fields["tag"] ^= 1
          fields["tagop"] ^= 1
      beats.append(fields)
    return beats

  # One DAT beat on the wire. `more_to_come` drives FLITPEND, which CHI defines
  # as "a flit may be sent next cycle" -- a property of the CHANNEL, not of any
  # one transaction -- so under interleaving it stays asserted across a stream
  # change and drops only on the last beat this emitter will send.
  async def emit_dat_beat(self, fields, more_to_come):
    bus = self.bus
    self.dat_beat_txn_log.append(fields.get("txnid", 0))
    await self.wait_dat_credit()
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(txdatflitpend=1 if more_to_come else 0, txdatflitv=1)
    bus.drive_flit("dat", fields)
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(txdatflitpend=0, txdatflitv=0)
    bus.drive_flit("dat", {})

  def _read_resp_codes(self, req):
    if self.decerr_check(req["addr"]):
      return int(Resp.I), int(RespErr.NDERR)
    if self.derr_check(req["addr"]):
      return int(Resp.I), int(RespErr.DERR)
    return int(Resp.I), int(RespErr.OKAY)

  async def drive_auto_read_compdata(self, req):
    resp_code, resp_err = self._read_resp_codes(req)
    await self.drive_read_prelude(req, resp_code, resp_err)
    beats = self.build_read_beats(req, resp_code, resp_err)
    for i, fields in enumerate(beats):
      await self.emit_dat_beat(fields, i != (len(beats) - 1))
    await self.bus.rising()
    self.drive_idle_sideband()

  # ==========================================================================
  # Several reads completed together, one beat at a time (cfg.dat_interleave_*).
  #
  # The preludes go out first and in request order: the ReadReceipt of an ordered
  # read is the acknowledgement that fixes its position in the ordered stream, so
  # interleaving the DATA must not disturb the order the receipts were sent in.
  # Only the data leg is interleaved.
  # ==========================================================================
  async def drive_interleaved_reads(self, reqs):
    streams = []
    for req in reqs:
      resp_code, resp_err = self._read_resp_codes(req)
      await self.drive_read_prelude(req, resp_code, resp_err)
      streams.append(self.build_read_beats(req, resp_code, resp_err))

    pos = [0] * len(streams)
    total = sum(len(s) for s in streams)
    cursor = 0
    prev_pick = -1
    for sent in range(total):
      eligible = [i for i in range(len(streams)) if pos[i] < len(streams[i])]
      if self.cfg.dat_interleave_policy == DatInterleavePolicy.RANDOM:
        pick = random.choice(eligible)
      else:
        # Round-robin: the first eligible stream at or after the cursor, wrapping
        # to the first eligible one when the tail has drained. Skipping drained
        # streams rather than stalling on them is what keeps the emitter making
        # progress when the reads have different sizes.
        pick = next((i for i in eligible if i >= cursor), eligible[0])
      cursor = (pick + 1) % len(streams)
      if prev_pick >= 0 and pick != prev_pick:
        self.n_dat_stream_switches += 1
      prev_pick = pick
      fields = streams[pick][pos[pick]]
      pos[pick] += 1
      await self.emit_dat_beat(fields, sent != (total - 1))
    await self.bus.rising()
    self.drive_idle_sideband()

  def _apply_atomic_variant(self, variant, current, operand):
    dw = self.bus.cfg.data_bytes * 8
    m = mask(dw)
    cur = current & m
    opd = operand & m
    # signed views
    sign = 1 << (dw - 1)
    cur_s = cur - (1 << dw) if cur & sign else cur
    opd_s = opd - (1 << dw) if opd & sign else opd
    if variant == 0:
      return (cur + opd) & m
    if variant == 1:
      return (cur & (~opd & m)) & m
    if variant == 2:
      return (cur ^ opd) & m
    if variant == 3:
      return (cur | opd) & m
    if variant == 4:
      return cur if cur_s > opd_s else opd
    if variant == 5:
      return cur if cur_s < opd_s else opd
    if variant == 6:
      return cur if cur > opd else opd
    if variant == 7:
      return cur if cur < opd else opd
    raise AssertionError(f"[{self.get_name()}] unsupported atomic variant {variant}")

  async def drive_auto_atomic_completion(self, req):
    bus = self.bus
    cfg = self.bus.cfg
    req_addr = req["addr"]
    req_txn = req["txnid"]
    req_src = req["srcid"]
    req_tgt = req["tgtid"]
    op = req["opcode"]
    beat_count = chi_xfer_dat_beats(req["size"], cfg.data_bytes)
    returns_data = req_opcode_is_atomic_returning_data(op)
    is_compare = req_opcode_is_atomic_compare(op)
    # AtomicCompare Size spans compare+swap; the RMW granule is the first half.
    granule = (beat_count // 2) if is_compare else beat_count
    variant = req_opcode_atomic_variant(op)
    is_decerr = self.decerr_check(req_addr)
    is_derr = self.derr_check(req_addr)

    err = int(RespErr.NDERR) if is_decerr else int(RespErr.OKAY)
    # Returning-data atomics always split (DBID grant, then CompData); non-return
    # atomics split only when split_write_rsp is set, else combined CompDBIDResp.
    if returns_data or self.cfg.split_write_rsp:
      grant_err = int(RespErr.OKAY)
      if cfg.is_e and self.cfg.ordered_dbid_resp and self.req_has_ordering(req):
        grant_op = int(RspOpcode.DBID_RESP_ORD)
      else:
        grant_op = int(RspOpcode.DBID_RESP)
    else:
      grant_err = err
      grant_op = int(RspOpcode.COMP_DBID_RESP)

    await self.drive_rsp({
      "opcode": grant_op, "srcid": req_tgt, "tgtid": req_src,
      "txnid": req_txn, "dbid": req_txn, "qos": req["qos"],
      "resp": int(Resp.I), "resperr": grant_err,
    })

    operand = []
    for _ in range(beat_count):
      while not bus.get("rxdatflitv"):
        await bus.rising()
        self.drive_idle_sideband()
      flit = bus.sample_flit("dat", "rx")
      if flit["txnid"] != req_txn or flit["dbid"] != req_txn:
        raise AssertionError(f"[{self.get_name()}] atomic DAT id mismatch")
      if flit["srcid"] != req_src or flit["tgtid"] != req_tgt:
        raise AssertionError(f"[{self.get_name()}] atomic DAT src/tgt mismatch")
      self.schedule_dat_credit_return()
      operand.append(flit["data"])
      if not bus.get("rxdatflitpend"):
        break
      await bus.rising()
      self.drive_idle_sideband()

    # AtomicCompare needs both the compare and swap halves; a short DAT burst
    # (flitpend dropped early) would silently corrupt the compare below.
    if is_compare and len(operand) != beat_count:
      raise AssertionError(
        f"[{self.get_name()}] AtomicCompare expected {beat_count} operand beats, "
        f"got {len(operand)}")

    old = [0 if is_decerr else self.read_data_beat(req_addr, b) for b in range(granule)]

    if not is_decerr:
      if is_compare:
        match = all(old[b] == operand[b] for b in range(granule))
        new = [operand[b + granule] if match else old[b] for b in range(granule)]
      elif op == int(ReqOpcode.ATOMIC_SWAP):
        new = [operand[b] for b in range(beat_count)]
      else:
        new = [self._apply_atomic_variant(variant, old[b], operand[b])
               for b in range(beat_count)]
      be_all = (1 << cfg.be_width) - 1
      self.mem.wr_be(req_addr, new, [be_all] * granule)
      for i in range(len(new)):
        self._mark_row(req_addr + i * cfg.data_bytes)

    if returns_data:
      resp_err = err if is_decerr else (int(RespErr.DERR) if is_derr else int(RespErr.OKAY))
      be_all = (1 << cfg.be_width) - 1
      for b in range(granule):
        fields = {
          "data": old[b], "be": 0 if is_decerr else be_all,
          "dataid": b, "ccid": 0, "dbid": req_txn,
          "resp": int(Resp.I), "resperr": resp_err,
          "opcode": int(DatOpcode.COMP_DATA), "homenid": req_tgt,
          "txnid": req_txn, "srcid": req_tgt, "tgtid": req_src, "qos": req["qos"],
        }
        await self.wait_dat_credit()
        await bus.rising()
        self.drive_idle_sideband()
        bus.drive(txdatflitpend=1 if b != (granule - 1) else 0, txdatflitv=1)
        bus.drive_flit("dat", fields)
        await bus.rising()
        self.drive_idle_sideband()
        bus.drive(txdatflitpend=0, txdatflitv=0)
        bus.drive_flit("dat", {})
      await bus.rising()
      self.drive_idle_sideband()
    elif self.cfg.split_write_rsp:
      await self.drive_rsp({
        "opcode": int(RspOpcode.COMP), "srcid": req_tgt, "tgtid": req_src,
        "txnid": req_txn, "dbid": req_txn, "qos": req["qos"],
        "resp": int(Resp.I), "resperr": err,
      })

    if req["expcompack"]:
      await self.wait_for_comp_ack(req_txn, req_src, req_tgt)

  async def wait_for_comp_ack(self, req_txn, req_src, req_tgt):
    bus = self.bus
    cycles = 0
    while not bus.get("rxrspflitv"):
      await bus.rising()
      self.drive_idle_sideband()
      cycles += 1
      if self.cfg.compack_timeout_cycles > 0 and cycles >= self.cfg.compack_timeout_cycles:
        raise AssertionError(
          f"[{self.get_name()}] Timed out waiting {cycles} cycles for CompAck "
          f"on txnid 0x{req_txn:x}")
    flit = bus.sample_flit("rsp", "rx")
    if flit["opcode"] != int(RspOpcode.COMP_ACK):
      raise AssertionError(
        f"[{self.get_name()}] Expected CompAck, got opcode 0x{flit['opcode']:x}")
    if flit["txnid"] != req_txn:
      raise AssertionError(
        f"[{self.get_name()}] CompAck txnid 0x{flit['txnid']:x} != 0x{req_txn:x}")
    if flit["srcid"] != req_src or flit["tgtid"] != req_tgt:
      raise AssertionError(
        f"[{self.get_name()}] CompAck src/tgt 0x{flit['srcid']:x}->0x{flit['tgtid']:x} "
        f"did not match expected 0x{req_src:x}->0x{req_tgt:x}")
    self.schedule_rsp_credit_return()

  # ==========================================================================
  # Raw-flit injection (RSP/DAT only for the completer).
  # ==========================================================================
  async def drive_raw_item(self, item):
    if not self.cfg.allow_raw_override:
      raise AssertionError(f"[{self.get_name()}] raw_override is disabled in cfg")
    bus = self.bus
    ch = _I(item.raw_channel)
    if ch == int(RawChannel.RSP):
      channel, raw_value = "rsp", item.raw_rsp
    elif ch == int(RawChannel.DAT):
      channel, raw_value = "dat", item.raw_dat
    else:
      raise AssertionError(
        f"[{self.get_name()}] SN-F raw_override only supports RSP or DAT")
    flitpend = 1 if getattr(item, "raw_flitpend", False) else 0
    await (self.wait_rsp_credit() if channel == "rsp" else self.wait_dat_credit())
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(**{f"tx{channel}flitpend": flitpend, f"tx{channel}flitv": 1})
    bus.sig[f"tx{channel}flit"].value = int(raw_value)
    await bus.rising()
    self.drive_idle_sideband()
    bus.drive(**{f"tx{channel}flitpend": 0, f"tx{channel}flitv": 0})
    bus.drive_flit(channel, {})
