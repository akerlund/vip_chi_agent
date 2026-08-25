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
  CACHE_LINE_BYTES, chi_xfer_dat_beats, mask, req_final_state, snoop_for_req,
  snp_do_not_go_to_sd_required, snp_opcode_is_forwarding,
  snp_ret_to_src_must_be_zero,
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
    # TXSACTIVE outstanding-window state, per RN-facing port.
    #
    # ONE OWNER. This wire used to have two: rn_credit_loop drove it from
    # rn_link_up[p] on every cycle, and every send path pulsed it around its own
    # flit. The level was therefore decided by whichever drive ran last, and it
    # showed -- with the HN-F endpoint bound for the first time, THIS port
    # reported CHI_TXSACTIVE_DEASSERT_BOUNDED and the SystemVerilog port did
    # not, from the same source.
    #
    # Now rn_credit_loop is the only writer and it reads this count. A
    # transaction brackets itself with begin/end, and the COUNT -- not any one
    # flit -- decides the level, which is what makes overlapping transactions
    # correct. Same shape as vip_chi_driver_rni's tx_activity_begin/end/tick.
    #
    # Opened at capture and closed when service_req returns, which is 14.7.2's
    # "until after the final completing flit is sent OR RECEIVED":
    # service_coherent_read awaits the CompAck before returning, so the CompAck
    # is inside the window rather than after it.
    self.rn_tx_active_count = [0] * n_rn
    self.rn_tx_active_extend = [0] * n_rn
    self.rn_tx_dispatch_open = False
    self.rn_rsp_lcrdv_pending = [0] * n_rn
    self.rn_dat_lcrdv_pending = [0] * n_rn
    self.rn_link_up = [False] * n_rn
    # One-shot latch per RN port for cfg.flitpend_without_valid: the control
    # fires once per link so the count a test asserts on is unambiguous.
    self.rn_flitpend_negctl_done = [False] * n_rn
    # One-shot latch for cfg.flit_without_flitpend, shared across both link
    # directions: the control drops the announcement in front of exactly ONE
    # flit anywhere on this driver, so the rest of the run is legal traffic the
    # same rule must pass. Not per port -- one violation is what the rule's
    # count is asserted against. See announce_rn_flit.
    self.flit_without_pend_done = False

    self.sn_rsp_lcrdv_pending = [0] * n_sn
    self.sn_dat_lcrdv_pending = [0] * n_sn
    self.sn_link_up = [False] * n_sn

    self.directory = {}       # line -> [per-port state int]
    self.excl_monitor = {}    # line -> [per-port bool]
    self.snp_txn_ctr = 0
    # One-shot latches for the three SNP field negative controls, per RN port and
    # for the same reason as the SV driver's: a control that fires on every snoop
    # makes the count a test asserts on depend on how many snoops the traffic
    # happened to produce.
    self._snp_fwd_negctl_done: set = set()
    self._snp_fwd_tgt_negctl_done: set = set()
    self._snp_rts_negctl_done: set = set()
    self._snp_sd_negctl_done: set = set()
    self.dn_txn_ctr = 0
    # A CompAck taken off the RSP channel by collect_snp_response before
    # collect_comp_ack got to it. One slot per port is enough: an RN-F runs its
    # coherent transactions serially, so it never owes two acknowledgements at
    # once, and the home never leaves more than one outstanding either.
    self.comp_ack_seen_early = [False] * n_rn
    self.comp_ack_early_txn = [0] * n_rn

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
    self.comp_ack_seen_early = [False] * len(self.rn_buses)
    self.comp_ack_early_txn = [0] * len(self.rn_buses)

  def drive_rn_idle_sideband(self, p):
    # This home transmits toward the RN, so those channels are its TXLINK on this
    # port and E section 14.6.1 / D 13.6.1 makes their state "controlled by" this
    # component -- it has to ask for the link. Until now txlinkactivereq was
    # written on this port in exactly one place, as 0 in reset_outputs, and the
    # home sent on the strength of the RN's request. The SN-facing port already
    # does it correctly, which is what made the omission easy to miss.
    #
    # Section 14.6.3 orders the two outputs -- the acknowledge may not assert
    # before the request, nor deassert before it. The acknowledge here lags the
    # request by exactly one cycle in BOTH directions, which satisfies both.
    # Rising together would also be permitted -- the section bans only changing
    # BEFORE -- but it is not what this drives. The lag term reads the wire, not
    # a saved copy, so repeated calls in one cycle cannot collapse the stagger.
    rn = self.rn_buses[p]
    # The acknowledge is a ONE-CYCLE DELAY of our own request, taken off the
    # wire: the drive is non-blocking, so a wire read at cycle T carries what was
    # driven at T-1 and the acknowledge lands exactly one cycle behind the
    # request, rising and falling. It reads nothing but wires, so it does not
    # care how many tasks call this in one cycle.
    # 14.6.3's requirement on the OBSERVER: while the peer's two outputs have
    # arrived out of order and the second has not yet followed, neither of our
    # outputs may move. This writer recomputes its intent every cycle, so
    # SKIPPING is the whole hold -- an unwritten signal keeps its value and the
    # same intent is re-derived next cycle. It must NOT re-drive the wires
    # instead: txlinkactivereq is written by the activation path, and a writer
    # that seizes a signal it does not own loses that path's one-shot request,
    # which hung tc_chi_coh_d_reset_mid_snoop. ChiBus owns the flag; see there.
    if rn.input_race_hold():
      return

    want_link = bool(rn.get("rxlinkactivereq"))

    # 14.6.3's fourth ordering binds US, not the peer: "the deassertion of TXREQ
    # must not occur before the assertion of RXACK". The acknowledge lags the
    # request by one cycle by construction, so a request held for only ONE cycle
    # is withdrawn before its own acknowledge has risen -- breaking that ordering
    # and then, a cycle later, the first one as the acknowledge rises against a
    # request that is already down. Reachable whenever the peer withdraws its
    # request the cycle after raising it, which tc_chi_lasm_illegal_transition
    # does on purpose. Table 14-2 says the same from the state machine's side:
    # the transmitter "remains in the ACTIVATE state while it is waiting for the
    # receiver to acknowledge".
    #
    # Holding the request until our own acknowledge is up is the minimum that
    # satisfies the section, and it cannot stall -- the acknowledge IS this
    # request, one cycle later.
    if rn.get("txlinkactivereq") and not rn.get("txlinkactiveack"):
      want_link = True

    rn.drive(txlinkactivereq=1 if want_link else 0,
             txlinkactiveack=1 if rn.get("txlinkactivereq") else 0)

  def drive_sn_idle_sideband(self, s):
    # Ordered against our own request rather than mirrored, now that the SN
    # raises one. E section 14.6.3 / D 13.6.3: the acknowledge may not assert
    # before the request, nor deassert before it. Mirroring was safe only while
    # the peer's request was identically zero.
    # The plain mirror, which is ALREADY the one-cycle delay 14.6.3 wants: the
    # drive is non-blocking. An earlier attempt gated it on a saved copy of our
    # own request and broke the invariant, because an attribute is not a wire.
    sn = self.sn_buses[s]
    # 14.6.3's requirement on the OBSERVER: while the peer's two outputs have
    # arrived out of order and the second has not yet followed, neither of our
    # outputs may move. This writer recomputes its intent every cycle, so
    # SKIPPING is the whole hold -- an unwritten signal keeps its value and the
    # same intent is re-derived next cycle. It must NOT re-drive the wires
    # instead: txlinkactivereq is written by the activation path, and a writer
    # that seizes a signal it does not own loses that path's one-shot request,
    # which hung tc_chi_coh_d_reset_mid_snoop. ChiBus owns the flag; see there.
    if sn.input_race_hold():
      return

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
      # Transmit arbitration here is by OWNERSHIP, not by a lock, and that is a
      # decision rather than an omission.
      #
      # The SN-F once dropped a response it had already decided to send:
      # two of its threads drove the same channel in the same cycle and the later
      # assignment silently replaced the earlier flit. The RN-I and SN-F answer that
      # with a one-deep semaphore. This driver answers it by structure -- EVERY flit
      # this home sends leaves through the single serial response_engine below, and the
      # level signals have exactly one writing loop each (txsactive and the L-credit
      # valids from rn_credit_loop / sn_credit_loop, the activation handshake from
      # rn_activate / sn_activate).
      #
      # So the invariant to preserve when adding a thread here: no channel may acquire
      # a second writer. A new coroutine that sends a flit outside response_engine
      # reintroduces in this driver, and unlike the RN-I there is no lock to
      # catch it -- audited 2026-08-24, and the audit is only as good as this rule.
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

  def snoop_for(self, opcode, fwd=False):
    """The snoop this home sends for a request, from IHI 0050 E Table 4-5 / D
    Table 4-3 by way of snoop_for_req().

    Every snoop this driver originates goes through here, so the request->snoop
    correspondence lives in one table instead of being spelled out at nine call
    sites. It replaced a single is_unique bit, and a bit cannot express Table
    4-5: the table has a distinct row per request and this home had two, so
    ReadClean took the not-unique branch and was snooped as though it were a
    ReadShared.

    `fwd` selects the Direct Cache Transfer column, which is where the actual
    violation was -- SnpShared for a ReadClean is permitted by the bullet under
    the table, SnpSharedFwd is not, and the DCT path could hand the requester a
    forwarded CompData_SD_PD that Table 4-14 does not list for ReadClean.
    """
    # Negative-control hook: put ReadClean back on the shared branch the
    # is_unique bit used to send it down. SnpShared is legal for a ReadClean and
    # SnpSharedFwd is not, so the SAME knob gives catalogue rule D8 one case it
    # must pass and one it must fail.
    if (self.cfg.hnf_snoop_shared_for_read_clean and
        _I(opcode) == int(ReqOpcode.READ_CLEAN)):
      return int(SnpOpcode.SHARED_FWD) if fwd else int(SnpOpcode.SHARED)
    return snoop_for_req(_I(opcode), fwd)

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
  # The counted primitive. Every window on this port is one increment here and
  # one decrement in rn_window_close, and the credit loop reads nothing but the
  # count -- so two windows open at once hold the sideband up for as long as the
  # LONGER of them, with no ordering between them and no writer but the loop.
  #
  # Assertion is immediate so the sideband rises in the cycle the window opens;
  # only the DROP waits for the per-cycle pass in rn_credit_loop.
  def rn_window_open(self, p):
    self.rn_tx_active_count[p] += 1
    self.rn_tx_active_extend[p] = 0
    self.rn_buses[p].drive(txsactive=1)

  def rn_window_close(self, p):
    if self.rn_tx_active_count[p]:
      self.rn_tx_active_count[p] -= 1
    if self.rn_tx_active_count[p] == 0:
      self.rn_tx_active_extend[p] = max(
        0, int(self.cfg.txsactive_extend_max_cycles))

  # The REQUEST window: one per dispatch, opened at capture and retired when the
  # service path is done with the RN link.
  def rn_tx_activity_begin(self, p):
    self.rn_window_open(p)

  # Idempotent within one dispatch. response_engine calls this after every
  # service path so none can forget to retire its window, but a path whose
  # remaining work is on the SN link closes early -- see service_writeback --
  # and the end-of-dispatch call then does nothing. Because the engine is
  # serial, one flag is enough to tell the two apart.
  #
  # The flag guards the REQUEST window alone. A snoop window opened by
  # drive_snoop retires through rn_window_close directly, so an early request
  # retire cannot swallow it and a snoop cannot consume the request's close:
  # 14.7.2 asks for the OR of the two, which is what two independent
  # contributions to one count express.
  def rn_tx_activity_end(self, p):
    if not self.rn_tx_dispatch_open:
      return
    self.rn_tx_dispatch_open = False
    self.rn_window_close(p)

  async def rn_credit_loop(self, p):
    rn = self.rn_buses[p]
    while True:
      await rn.rising()
      self.drive_rn_idle_sideband(p)
      # The only write to this wire. Asserted while anything is outstanding,
      # then held for cfg.txsactive_extend_max_cycles past the close, modelling
      # a node that speculates on more traffic -- the RN-I's shape exactly.
      active = (self.rn_tx_active_count[p] != 0
                or self.rn_tx_active_extend[p] != 0)
      rn.drive(txsactive=1 if active else 0,
               txreqlcrdv=1 if self.rn_req_lcrdv_pending[p] else 0,
               txrsplcrdv=1 if self.rn_rsp_lcrdv_pending[p] else 0,
               txdatlcrdv=1 if self.rn_dat_lcrdv_pending[p] else 0)
      if self.rn_tx_active_count[p] == 0 and self.rn_tx_active_extend[p]:
        self.rn_tx_active_extend[p] -= 1
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
    """Bring one RN-facing port up, in the two steps 14.6.1 keeps separate.

    The receive credits go out on the peer's request, because they belong to
    this home's RECEIVE link and advertising them is how that link bootstraps --
    ACTIVATE is the state a receiver grants its initial budget in.

    The transmit gate waits for the peer's ACKNOWLEDGE, because that is what
    puts this home's TRANSMIT link in RUN, and RSP, DAT and SNP are its payload.
    The two used to be one step keyed off the peer's request alone, which is
    invisible while the peer acknowledges promptly -- two cycles apart -- and
    wrong the moment it does not: the home would send into a transmit link still
    in ACTIVATE. That is the collapse the per-direction state machines exist to
    separate, seen from the driver rather than the checker.
    """
    rn = self.rn_buses[p]
    while rn.rst_n.value and not rn.get("rxlinkactivereq"):
      await rn.rising()
    self.rn_req_lcrdv_pending[p] += self.cfg.initial_req_credits
    self.rn_rsp_lcrdv_pending[p] += self.cfg.initial_rsp_credits
    self.rn_dat_lcrdv_pending[p] += self.cfg.initial_dat_credits

    while rn.rst_n.value and not rn.get("rxlinkactiveack"):
      await rn.rising()

    self.rn_link_up[p] = True
    await self.drive_snp_flitpend_negctl(p)

  async def drive_snp_flitpend_negctl(self, p):
    """Raise SNP FLITPEND for one cycle with no snoop behind it.

    The SNP twin of the REQ/RSP pulse in the requester driver, and it exists for
    the same reason: CHI_SNP_VALID_REQUIRES_PEND had never once been evaluated
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
      # Opened at capture, not at dispatch: a buffered request is already
      # outstanding while it waits its turn in work_q, and 14.7.2 wants the
      # sideband asserted before or in the cycle of the first Response flit,
      # which is later than this.
      self.rn_tx_activity_begin(p)
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

  # Each of these holds the flit for its channel's configured transmit delay
  # before taking the credit. See the RN-I twin for why the delay lands before
  # the credit and why L-credit returns are excluded.
  #
  # wait_rn_snp_send_credit is deliberately NOT delayed: there is no
  # snp_valid_delay knob, and inventing one here would put a shape on the snoop
  # channel that no configuration can see or turn off.
  async def wait_sn_req_send_credit(self, s):
    sn = self.sn_buses[s]
    for _ in range(self.cfg.draw_req_valid_delay()):
      await sn.rising()
    while not self.sn_req_send[s].try_acquire_credit():
      await sn.rising()

  async def wait_sn_dat_send_credit(self, s):
    sn = self.sn_buses[s]
    for _ in range(self.cfg.draw_dat_valid_delay()):
      await sn.rising()
    while not self.sn_dat_send[s].try_acquire_credit():
      await sn.rising()

  async def downstream_read(self, addr, size):
    sn = self.sn_buses[0]
    s = 0
    self.dn_dat_valid = False
    self.dn_dat_beats = []

    # A first attempt, so AllowRetry must be asserted: IHI 0050 E section 2.9.4 /
    # D section 2.9.4 permit it deasserted only on a transaction spending a
    # pre-allocated P-Credit, or on PrefetchTgt. Leaving it out of the field dict
    # left the bit clear, which told the SN-F this request was already carrying a
    # credit it had never granted -- and made a RetryAck impossible for a
    # completer that is entitled to give one.
    #
    # This HN-F does not yet absorb a RetryAck on its downstream link, so a
    # completer that exercises the option will wedge it. That is a gap in the
    # model rather than a reason to keep the flit non-conformant: nothing in the
    # regression configures an SN-F to bounce these, and an SN-F only bounces a
    # request whose AllowRetry is set, so the honest field value is the one that
    # exposes the gap rather than the one that hides it.
    fields = {
      "opcode": int(ReqOpcode.READ_NO_SNP), "addr": _I(addr), "size": _I(size),
      "txnid": self.alloc_dn_txn(), "srcid": 0,
      "tgtid": _I(self.cfg.hnf_downstream_snf_id),
      "allowretry": 1,
    }
    await self.wait_sn_req_send_credit(s)
    await self.announce_sn_flit(s, "req")
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

    # A first attempt, so AllowRetry must be asserted: IHI 0050 E section 2.9.4 /
    # D section 2.9.4 permit it deasserted only on a transaction spending a
    # pre-allocated P-Credit, or on PrefetchTgt. Leaving it out of the field dict
    # left the bit clear, which told the SN-F this request was already carrying a
    # credit it had never granted -- and made a RetryAck impossible for a
    # completer that is entitled to give one.
    #
    # This HN-F does not yet absorb a RetryAck on its downstream link, so a
    # completer that exercises the option will wedge it. That is a gap in the
    # model rather than a reason to keep the flit non-conformant: nothing in the
    # regression configures an SN-F to bounce these, and an SN-F only bounces a
    # request whose AllowRetry is set, so the honest field value is the one that
    # exposes the gap rather than the one that hides it.
    req_fields = {
      "opcode": int(ReqOpcode.WRITE_NO_SNP_FULL), "addr": _I(addr), "size": _I(size),
      "txnid": self.alloc_dn_txn(), "srcid": 0,
      "tgtid": _I(self.cfg.hnf_downstream_snf_id),
      "allowretry": 1,
    }
    await self.wait_sn_req_send_credit(s)
    await self.announce_sn_flit(s, "req")
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
      await self.announce_sn_flit(s, "dat")
      await sn.rising()
      sn.drive(txdatflitpend=1 if i != (n_beats - 1) else 0, txdatflitv=1)
      sn.drive_flit("dat", dat_fields)
      await sn.rising()
      sn.drive(txdatflitpend=0, txdatflitv=0)
      sn.drive_flit("dat", {})

  # ==========================================================================
  # RN-facing send-credit waits.
  # ==========================================================================
  async def announce_rn_flit(self, p, channel):
    """Raise FLITPEND for the cycle before a flit goes out on an RN port.

    E section 14.4 / D section 13.4 require the signal asserted exactly one
    cycle before a flit is sent -- a look-ahead a receiver uses to ungate its
    capture path. Every beat of a burst is announced, not only the first: the
    gap cycle after each beat drops FLITPEND, so nothing carries the lead
    across. The value driven WITH each beat keeps its burst meaning (more beats
    follow), which is what the snoopee and the monitor read to find the last one.
    """
    rn = self.rn_buses[p]

    # The one gate every RN-facing flit passes, so the transmit link is checked
    # once rather than in each of the three send paths.
    # cfg.hnf_send_before_tx_link_negctl stands it down.
    while not self.rn_link_up[p] and not self.cfg.hnf_send_before_tx_link_negctl:
      await rn.rising()
      self.drive_rn_idle_sideband(p)

    await rn.rising()
    self.drive_rn_idle_sideband(p)
    # Negative control (cfg.flit_without_flitpend): skip the announcement once,
    # so exactly one flit goes out with FLITPEND low in the cycle before it and
    # CHI_*_VALID_REQUIRES_PEND has a real violation to catch on THIS driver's
    # flits. Returning without driving leaves FLITPEND at the 0 the previous
    # send cleared it to.
    #
    # The homes announced INLINE previously, so the control reached the
    # requesters and nothing else -- and check_cfg_parity passed throughout,
    # because the config SURFACE matched and which drivers READ the knob is
    # behaviour no gate compared. scripts/check_flitpend_negctl.py compares it
    # now.
    if self.cfg.flit_without_flitpend and not self.flit_without_pend_done:
      self.flit_without_pend_done = True
      return
    rn.drive(**{f"tx{channel}flitpend": 1})

  async def announce_sn_flit(self, s, channel):
    """The downstream twin of announce_rn_flit."""
    sn = self.sn_buses[s]
    await sn.rising()
    # Negative control (cfg.flit_without_flitpend): skip the announcement once,
    # so exactly one flit goes out with FLITPEND low in the cycle before it and
    # CHI_*_VALID_REQUIRES_PEND has a real violation to catch on THIS driver's
    # flits. Returning without driving leaves FLITPEND at the 0 the previous
    # send cleared it to.
    #
    # The homes announced INLINE previously, so the control reached the
    # requesters and nothing else -- and check_cfg_parity passed throughout,
    # because the config SURFACE matched and which drivers READ the knob is
    # behaviour no gate compared. scripts/check_flitpend_negctl.py compares it
    # now.
    if self.cfg.flit_without_flitpend and not self.flit_without_pend_done:
      self.flit_without_pend_done = True
      return
    sn.drive(**{f"tx{channel}flitpend": 1})

  async def wait_rn_rsp_send_credit(self, p):
    rn = self.rn_buses[p]
    # The credit loop below keeps the sideband driven every cycle it waits, so
    # the delay has to as well -- otherwise a delayed RSP stops this port's
    # queued LCRDV pulses for the length of the delay, back-pressuring the RN as
    # a side effect of shaping our own transmit timing.
    for _ in range(self.cfg.draw_rsp_valid_delay()):
      await rn.rising()
      self.drive_rn_idle_sideband(p)
    while not self.rn_rsp_send[p].try_acquire_credit():
      await rn.rising()
      self.drive_rn_idle_sideband(p)

  async def wait_rn_dat_send_credit(self, p):
    rn = self.rn_buses[p]
    for _ in range(self.cfg.draw_dat_valid_delay()):
      await rn.rising()
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
        self.rn_tx_dispatch_open = True
        await self.service_req(p, req)
        # Closed here rather than inside the service coroutines, so every
        # dispatch path retires exactly one window and none can forget to.
        self.rn_tx_activity_end(p)
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
      await self.service_cmo_invalidate(p, req, self.snoop_for(req["opcode"]))
    elif op == int(ReqOpcode.MAKE_INVALID):
      await self.service_cmo_invalidate(p, req, self.snoop_for(req["opcode"]))
    elif op == int(ReqOpcode.READ_ONCE):
      await self.service_read_once(p, req)
    elif op in (int(ReqOpcode.WRITE_UNIQUE_FULL), int(ReqOpcode.WRITE_UNIQUE_PTL)):
      await self.service_write_unique(p, req)
    elif op == int(ReqOpcode.WRITE_UNIQUE_ZERO):
      await self.service_write_unique_zero(p, req)
    elif op == int(ReqOpcode.WRITE_EVICT_OR_EVICT):
      await self.service_write_evict_or_evict(p, req)
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
      await self.drive_snoop(k, line, self.snoop_for(req["opcode"]))
      entry[k] = int(Resp.I)
    # The requester ends up holding the line Unique-Dirty, so that is what the
    # directory records.
    entry[p] = int(Resp.UD_PD)
    self.directory[line] = entry
    self.excl_monitor.pop(line, None)
    # The COMPLETION, however, is Comp_UC and not Comp_UD_PD. IHI 0050 E Table
    # 4-19 (D Table 4-13) gives MakeUnique a final state of UD from every
    # permitted initial state and a completion response of Comp_UC: the requester
    # becomes Dirty by its own act of overwriting the whole line, not by being
    # handed anyone's dirty data, and Comp_UD_PD is reserved for the case where
    # "responsibility for a Dirty cache line is being passed" (Table 4-7).
    #
    # Sending UD_PD here was not merely an odd choice of encoding. Issue D does
    # not define UD_PD for a data-less completion at all -- D Table 4-5 permits
    # exactly Comp_I, Comp_UC and Comp_SC -- so the CHI-D cut of this home was
    # driving a Resp value the issue it implements has no meaning for.
    await self.drive_rn_rsp(p, int(RspOpcode.COMP), _I(req["txnid"]), 0,
                            int(Resp.UD_PD) if self.cfg.hnf_comp_resp_negctl
                            else int(Resp.UC),
                            _I(req["tgtid"]), _I(req["srcid"]))
    await self.await_comp_ack(p, req, line)

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
      await self.drive_snoop(k, line, self.snoop_for(req["opcode"]))

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
    await self.await_comp_ack(p, req, line)

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
        await self.drive_snoop(k, line, self.snoop_for(req["opcode"]))
    await self.drive_coherent_read_compdata(p, req, int(Resp.I))
    await self.await_comp_ack(p, req, line)

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
      await self.drive_snoop(k, line, self.snoop_for(req["opcode"]))
      entry[k] = int(Resp.I)
    # Grant the requester Unique-Clean on the wire; record the join in the
    # filter. Table 4-19 gives CleanUnique an SD row whose final state is UD, so
    # writing a flat UC here would lose a dirty copy -- Table 4-14 footnote b.
    entry[p] = req_final_state(_I(req["opcode"]), entry[p], int(Resp.UC))
    self.directory[line] = entry
    self.excl_monitor.pop(line, None)

    rerr = int(RespErr.EXOKAY) if (is_excl and won) else int(RespErr.OKAY)
    await self.drive_rn_rsp(p, int(RspOpcode.COMP), _I(req["txnid"]), 0,
                            int(Resp.UC), _I(req["tgtid"]), _I(req["srcid"]), rerr)
    await self.await_comp_ack(p, req, line)

  # ==========================================================================
  # Coherent read: snoop the other holders as the request demands, grant the
  # requester, record the directory, return CompData from memory.
  # ==========================================================================
  async def service_coherent_read(self, p, req):
    line = self.line_addr(req["addr"])
    is_unique = self.req_opcode_is_unique_read(_I(req["opcode"]))
    entry = self._dir_entry(line)

    # Negative control: retire the window at the START of service instead of at
    # the end of the dispatch. The end-of-dispatch call in response_engine then
    # finds it already closed and does nothing, so the sideband is low for the
    # whole snoop-and-complete sequence with the request still outstanding.
    if self.cfg.hnf_txsactive_early_drop_negctl:
      self.rn_tx_activity_end(p)

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
        await self.await_comp_ack(p, req, line)
        return

    for k in range(len(self.rn_buses)):
      if k == p or self.cfg.hnf_suppress_snoops:
        continue
      cur_k = entry[k]
      if cur_k == int(Resp.I):
        continue
      if is_unique:
        await self.drive_snoop(k, line, self.snoop_for(req["opcode"]))
        entry[k] = int(Resp.I)
        if line in self.excl_monitor:
          self.excl_monitor[line][k] = False
      # A non-unique read downgrades a Unique holder and leaves an
      # already-Shared one alone. The OPCODE now comes from Table 4-5 rather
      # than from this branch: SnpShared for a ReadShared, SnpClean for a
      # ReadClean. The two resolve the snoopee identically in this model (both
      # end SC, both return dirty data if it had any), which is why one opcode
      # served both for so long -- the difference the spec draws is in what the
      # snoopee is PERMITTED to do, not in what this RN-F does.
      elif cur_k in (int(Resp.UC), int(Resp.UD_PD)):
        await self.drive_snoop(k, line, self.snoop_for(req["opcode"]))
        entry[k] = int(Resp.SC)

    granted = self.granted_state_for(_I(req["opcode"]))
    # The GRANT goes on the wire; the SNOOP FILTER records the join of the grant
    # with what this port already held. IHI 0050 E Table 4-14 footnote b is
    # explicit that the two are different: "a Home that uses a Snoop filter to
    # track the cached state at the Requester must not downgrade the state of the
    # cache line in the Snoop filter based on the state in the response to the
    # Requester." A UD holder issuing ReadClean receives CompData_SC and stays UD,
    # and a filter that wrote SC would then believe the only dirty copy in the
    # system is clean -- and could serve a later reader from memory without
    # asking for it.
    entry[p] = req_final_state(_I(req["opcode"]), entry[p], granted)
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
    await self.await_comp_ack(p, req, line)

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

    # The RN-facing transaction ends with the CopyBackWrData just collected:
    # 14.7.2 requires TXSACTIVE held until after the final completing flit is
    # sent or received, and that flit has been received. Everything below runs
    # on the SN link, whose own TXSACTIVE covers it, so the RN-facing window is
    # retired here rather than held across a downstream round trip in which the
    # RN link is silent.
    self.rn_tx_activity_end(p)

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
  # ==========================================================================
  # WriteUniqueZero: a full-line store of ZERO with no data on the wire.
  #
  # The snoopable twin of WriteNoSnpZero. The line is being overwritten in its
  # entirety, so every other holder is invalidated first and the home then zeroes
  # the line itself -- there is no write data to wait for, which is the whole
  # point of the opcode and the one thing that makes it different from a
  # WriteUniqueFull carrying zeros.
  #
  # SnpCleanInvalid rather than SnpMakeInvalid, matching service_write_unique.
  # The specification permits SnpMakeInvalid here, but only when the home knows
  # the snoopee holds no dirty tags -- a condition this directory does not track,
  # and the discarded data costs nothing because the line is about to be zeroed.
  #
  # Completion is CompDBIDResp. The specification also allows separate DBIDResp
  # and Comp; the combined form is used because it is what every other write in
  # this home already sends, and a DBID is still returned even though no data
  # will ever be sent against it.
  # ==========================================================================
  async def service_write_unique_zero(self, p, req):
    line = self.line_addr(req["addr"])
    entry = self._dir_entry(line)
    for k in range(len(self.rn_buses)):
      if k == p or self.cfg.hnf_suppress_snoops:
        continue
      if entry[k] == int(Resp.I):
        continue
      await self.drive_snoop(k, line, self.snoop_for(req["opcode"]))

    # The line is invalid everywhere; the zeroing writer does not own it either.
    self.directory[line] = [int(Resp.I)] * len(self.rn_buses)
    # The write changed the line's data -> every exclusive reservation is broken.
    self.excl_monitor.pop(line, None)

    db = self.rn_buses[0].cfg.data_bytes
    lb = self.line_beats()
    self.mem.wr_be(line, [0] * lb, [mask(self.rn_buses[0].cfg.be_width)] * lb)
    for b in range(lb):
      self._mark_row(line + b * db)

    await self.drive_rn_rsp(p, int(RspOpcode.COMP_DBID_RESP), _I(req["txnid"]),
                            _I(req["txnid"]), int(Resp.I),
                            _I(req["tgtid"]), _I(req["srcid"]))

  # ==========================================================================
  # WriteEvictOrEvict: the one CopyBack whose SHAPE the home chooses.
  #
  # The requester is handing back a CLEAN line that a downstream cache may want.
  # The home decides, "based on its own heuristics", whether that is worth the
  # data transfer:
  #
  #   * want it    -> CompDBIDResp, and the requester sends CopyBackWrData. No
  #                   explicit CompAck follows: the specification states that the
  #                   CopyBackWriteData message IS the implicit acknowledgement,
  #                   which is why this leg must not wait for one.
  #   * decline it -> Comp, and the requester answers with an explicit CompAck.
  #                   The transaction degenerates into an Evict.
  #
  # "Its own heuristics" is not something a test can predict, so the choice is a
  # config knob here rather than a random draw: both legs are reachable, each
  # deterministically, and a test can assert which one it asked for. That is the
  # difference between a modelled choice and an unverifiable one.
  # ==========================================================================
  async def service_write_evict_or_evict(self, p, req):
    line = self.line_addr(req["addr"])

    # Either way the requester ends up without the line.
    if line in self.directory:
      self.directory[line][p] = int(Resp.I)

    if not self.cfg.hnf_write_evict_request_data:
      await self.drive_rn_rsp(p, int(RspOpcode.COMP), _I(req["txnid"]), 0,
                              int(Resp.I), _I(req["tgtid"]), _I(req["srcid"]))
      await self.collect_comp_ack(p, _I(req["txnid"]))
      return

    await self.drive_rn_rsp(p, int(RspOpcode.COMP_DBID_RESP), _I(req["txnid"]),
                            _I(req["txnid"]), int(Resp.I),
                            _I(req["tgtid"]), _I(req["srcid"]))

    expected_beats = chi_xfer_dat_beats(_I(req["size"]),
                                        self.rn_buses[0].cfg.data_bytes)
    await self.collect_write_data(p, _I(req["txnid"]), line, expected_beats,
                                  int(DatOpcode.COPY_BACK_WR_DATA),
                                  _I(req["srcid"]), _I(req["tgtid"]),
                                  "WriteEvictOrEvict")

  # ==========================================================================
  # Wait for the explicit CompAck that closes the no-data leg of a
  # WriteEvictOrEvict. Same shape as collect_snp_response: any other flit on this
  # port while the serial engine is waiting means per-line concurrency arrived
  # without per-TxnID routing, so it is an error rather than silently dropped.
  # ==========================================================================
  async def collect_comp_ack(self, p, txn):
    # The ack may already have been taken off the wire by collect_snp_response:
    # once the home is permitted to snoop while an acknowledgement is still
    # outstanding -- which is exactly the window section 2.8.3 rule 2 is about --
    # the two collectors are both live on the same RSP channel, and whichever
    # reaches the flit first has to keep it.
    if self.comp_ack_seen_early[p] and self.comp_ack_early_txn[p] == _I(txn):
      self.comp_ack_seen_early[p] = False
      return
    rn = self.rn_buses[p]
    while True:
      if rn.get("rxrspflitv"):
        rflit = rn.sample_flit("rsp", "rx")
        self.rn_rsp_lcrdv_pending[p] += 1
        if (rflit["opcode"] == int(RspOpcode.COMP_ACK)
            and _I(rflit["txnid"]) == _I(txn)):
          await rn.rising()
          self.drive_rn_idle_sideband(p)
          break
        raise AssertionError(
          f"[{self.get_name()}] port {p}: unexpected RSP (opcode "
          f"0x{rflit['opcode']:x} TxnID 0x{_I(rflit['txnid']):x}) while awaiting "
          f"CompAck for TxnID 0x{_I(txn):x}")
      await rn.rising()
      self.drive_rn_idle_sideband(p)

  async def await_comp_ack(self, p, req, line):
    """Close a completion by waiting for the CompAck the requester owes it.

    IHI 0050 E section 2.8.3 rule 2: "An HN-F, except in the case of ReadOnce*,
    waits for CompAck before sending a subsequent snoop to the same address."
    This home satisfies that rule the simplest way there is -- it does not start
    the next request at all until the acknowledgement is in. Waiting longer than
    required is always legal for a completer, and it costs nothing here because
    the response engine is serial anyway.

    The rule itself is NOT enforced by this coroutine, and deliberately so.
    Satisfying an ordering requirement by construction is not the same as
    checking it, and a VIP whose only statement of the rule is the code that
    happens to obey it cannot tell you when a peer breaks it. The judgement
    lives in the coherency checker (rule D9), which reads the snoop and the
    acknowledgement off the wire and knows nothing about how either got there.
    """
    if not _I(req["expcompack"]):
      return

    # Negative control for rule D9: put one snoop inside the window the rule
    # protects. SnpOnce is chosen because it leaves the snoopee's state and data
    # exactly as they were -- the only thing wrong with this snoop is WHEN it is
    # sent, which is the one property under test. Section 4.4 permits a home to
    # snoop spontaneously, so nothing else about the flit is illegal. ReadOnce is
    # skipped because the section names it as the exception.
    if (self.cfg.hnf_snoop_before_comp_ack
        and _I(req["opcode"]) != int(ReqOpcode.READ_ONCE)):
      await self.drive_snoop(p, line, int(SnpOpcode.ONCE))

    await self.collect_comp_ack(p, _I(req["txnid"]))

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
    await self.announce_rn_flit(p, "rsp")
    await rn.rising()
    self.drive_rn_idle_sideband(p)
    rn.drive(txrspflitpend=0, txrspflitv=1)
    rn.drive_flit("rsp", fields)
    await rn.rising()
    self.drive_rn_idle_sideband(p)
    rn.drive(txrspflitv=0)
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
    # IHI 0050 E 13.10.35 makes DoNotGoToSD mandatory-one on the invalidating
    # snoops and on SnpCleanShared; D 12.9.32 lets the same bit take any value
    # there, so drive a one only where the specification requires it and leave
    # the CHI-D wire value as it was.
    fields = {
      "opcode": op, "addr": _I(line), "txnid": snp_txn, "srcid": 0,
      "fwdnid": fwd_nid, "fwdtxnid": fwd_txn,
      "donotgotosd": int(snp_do_not_go_to_sd_required(rn.cfg.issue, op)),
    }

    # The field negative controls. Each corrupts one field of an otherwise
    # ordinary snoop and fires once per port, and each is gated on the opcode
    # actually being one the rule judges -- a control that sets RetToSrc on a
    # SnpShared, or clears DoNotGoToSD on a SnpOnce, would provoke nothing and
    # pass for it. The fwd pair below are gated on OPPOSITE senses of the same
    # predicate for that reason: the zero rule needs a snoop with no requester to
    # name, the value rule a snoop that has one.
    if (self.cfg.hnf_snp_fwd_fields_negctl
        and k not in self._snp_fwd_negctl_done
        and not snp_opcode_is_forwarding(op)):
      self._snp_fwd_negctl_done.add(k)
      fields["fwdnid"] = 1
      self.logger.info(
        f"SNP negctl: FwdNID on non-Forward snoop opcode 0x{int(op):x}")

    # Plus one rather than a constant: the corrupted value must differ from the
    # correct one whatever the correct one is, and every requester on this bench
    # drives SrcID zero -- so a constant zero would corrupt nothing and a
    # constant one would stop working the day a test gives them real Node IDs.
    if (self.cfg.hnf_snp_fwd_target_negctl
        and k not in self._snp_fwd_tgt_negctl_done
        and snp_opcode_is_forwarding(op)):
      self._snp_fwd_tgt_negctl_done.add(k)
      # Masked to the field width so the increment WRAPS rather than
      # overflowing, which is what the SV cast does and is the only form that
      # stays inside the flit at the top of the range.
      fields["fwdnid"] = (_I(fwd_nid) + 1) & mask(rn.cfg.node_id_width)
      fields["fwdtxnid"] = (_I(fwd_txn) + 1) & mask(rn.cfg.txn_id_width)
      self.logger.info(
        f"SNP negctl: FwdNID/FwdTxnID on forwarding snoop opcode 0x{int(op):x} "
        "name a different requester than the one it was sent for")

    if (self.cfg.hnf_snp_ret_to_src_negctl
        and k not in self._snp_rts_negctl_done
        and snp_ret_to_src_must_be_zero(op)):
      self._snp_rts_negctl_done.add(k)
      fields["rettosrc"] = 1
      self.logger.info(
        f"SNP negctl: RetToSrc on snoop opcode 0x{int(op):x}, which must carry zero")

    if (self.cfg.hnf_snp_do_not_go_to_sd_negctl
        and k not in self._snp_sd_negctl_done
        and snp_do_not_go_to_sd_required(rn.cfg.issue, op)):
      self._snp_sd_negctl_done.add(k)
      fields["donotgotosd"] = 0
      self.logger.info(
        f"SNP negctl: DoNotGoToSD cleared on snoop opcode 0x{int(op):x}, "
        "which must carry one")
    await self.wait_rn_snp_send_credit(k)
    await self.announce_rn_flit(k, "snp")
    await rn.rising()
    self.drive_rn_idle_sideband(k)
    # The snoop's TXSACTIVE window opens HERE, in the cycle the flit is
    # presented, and not one line earlier. E 14.7.2 / D 13.7.2 asks for the
    # sideband "before or in the same cycle in which its initiating Snoop or
    # SnpDVMOp flit is sent" -- the same cycle satisfies it, and opening any
    # sooner covers the wait for a snoop credit above, which is unbounded. On a
    # link whose peer withholds snoop credit that wait IS the whole test:
    # tc_chi_coh_{d,e}_snp_backpressure held the sideband up over 17 idle cycles
    # with the request being serviced on the OTHER port, and
    # TXSACTIVE_DEASSERT_BOUNDED reported it -- correctly. A sideband raised
    # before there is anything on the wire to justify it is the over-assertion
    # that rule exists to catch.
    #
    # Closed by the caller, after the last response beat. The window is not
    # symmetric in this file for the same reason it is not symmetric in the
    # clause: the open is pinned to the flit, the close to the response.
    self.rn_window_open(k)
    rn.drive(txsnpflitpend=0, txsnpflitv=1)
    rn.drive_flit("snp", fields)
    await rn.rising()
    self.drive_rn_idle_sideband(k)
    rn.drive(txsnpflitv=0)
    rn.drive_flit("snp", {})
    return snp_txn

  # E 14.7.2 / D 13.7.2 makes the snoop a TXSACTIVE window in its own right:
  # asserted "before or in the same cycle in which its initiating Snoop or
  # SnpDVMOp flit is sent", held "until after the final completing flit is sent,
  # which will be either SnpResp or SnpRespData". send_snoop_flit opens it in
  # the flit cycle; the close belongs here, where the response has been
  # collected -- in a finally, so a snoopee that answers with something
  # unexpected does not leave the sideband stuck high for the rest of the run.
  async def drive_snoop(self, k, line, op):
    snp_txn = await self.send_snoop_flit(k, line, op)
    try:
      await self.collect_snp_response(k, snp_txn, line)
    finally:
      self.rn_window_close(k)

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

        # A CompAck for an earlier completion is not a concurrency defect: it is
        # the acknowledgement this home is about to wait for, arriving while a
        # snoop it should not have sent yet is still outstanding. Stash it for
        # collect_comp_ack instead of raising -- the raise below is for flits
        # that genuinely have nowhere to go. Reachable only under the
        # hnf_snoop_before_comp_ack negative control, which is the point: the
        # rule is judged from the wire, so the wire has to survive breaking it.
        if _I(rflit["opcode"]) == int(RspOpcode.COMP_ACK):
          self.comp_ack_seen_early[k] = True
          self.comp_ack_early_txn[k] = _I(rflit["txnid"])
          await rn.rising()
          self.drive_rn_idle_sideband(k)
          continue

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
      await self.announce_rn_flit(p, "dat")
      await rn.rising()
      self.drive_rn_idle_sideband(p)
      rn.drive(txdatflitpend=1 if beat_index != (beat_count - 1) else 0,
               txdatflitv=1)
      rn.drive_flit("dat", fields)
      await rn.rising()
      self.drive_rn_idle_sideband(p)
      rn.drive(txdatflitpend=0, txdatflitv=0)
      rn.drive_flit("dat", {})

    await rn.rising()
    self.drive_rn_idle_sideband(p)

  # ==========================================================================
  # DCT coherent read: forwarding snoop to the single peer holder; relay its
  # forwarded data to the requester as CompData (not re-read from memory).
  # ==========================================================================
  async def service_coherent_read_fwd(self, p, req, line, fwd_k, is_unique, entry_in):
    entry = list(entry_in)
    granted = self.granted_state_for(_I(req["opcode"]))
    fwd_op = self.snoop_for(req["opcode"], fwd=True)
    snoopee_next = int(Resp.I) if is_unique else int(Resp.SC)

    # The forwarding snoop goes out on the SNOOPEE's link, not the requester's,
    # so the request window opened at capture covers the wrong port entirely.
    # Its own window, on fwd_k, opened in send_snoop_flit -- see drive_snoop.
    snp_txn = await self.send_snoop_flit(fwd_k, line, fwd_op,
                                        _I(req["srcid"]), _I(req["txnid"]))
    try:
      fwd_beats = await self.collect_fwd_resp_data(fwd_k, snp_txn, line)
    finally:
      self.rn_window_close(fwd_k)
    await self.drive_relayed_compdata(p, req, granted, fwd_beats)

    # The requester's entry is the join, not the grant -- Table 4-14 footnote b,
    # as in service_coherent_read above.
    entry[fwd_k] = snoopee_next
    entry[p] = req_final_state(_I(req["opcode"]), entry[p], granted)
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
      await self.announce_rn_flit(p, "dat")
      await rn.rising()
      self.drive_rn_idle_sideband(p)
      rn.drive(txdatflitpend=1 if beat_index != (beat_count - 1) else 0,
               txdatflitv=1)
      rn.drive_flit("dat", fields)
      await rn.rising()
      self.drive_rn_idle_sideband(p)
      rn.drive(txdatflitpend=0, txdatflitv=0)
      rn.drive_flit("dat", {})

    await rn.rising()
    self.drive_rn_idle_sideband(p)

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
