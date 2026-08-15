################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_scoreboard.sv.
#
# Standalone, always-on protocol scoreboard for the DUT-less VIP-on-VIP example.
# Four checkers share one requester-frame transaction table:
#   A - lifecycle / completion contract (per requester transaction)
#   B - cross-agent request fidelity (REQ observed at requester == at completer)
#   C - independent, predictable-only data integrity (write -> read)
#   E - ordered-stream acknowledgement order (per requester ordered stream)
#
# It subscribes in parallel to the same monitor analysis ports the observation
# FIFOs use, so the per-test FIFO draining is untouched. Errors are reported via
# self.logger.error (mirroring the SV uvm_error) AND counted in public n_*
# fields; pyUVM does not auto-fail on a logged error, so a test/harness inspects
# the counters (the negctl guard) or the scoreboard-error total for its verdict.
#
# In the integrated RN-I/SN-F cut only the rni_*/snf_req streams are wired; the
# proxy hrni*/hsnf* imps stay unconnected (route_check dormant, single SN).
#
################################################################################

from __future__ import annotations

import os

from pyuvm import uvm_component

from vip_chi_types_pkg import (
  Role, ReqOpcode, RspOpcode, DatOpcode, ReqOrder, RespErr,
  req_opcode_is_atomic, req_opcode_is_atomic_compare,
  req_opcode_is_atomic_returning_data, req_opcode_atomic_variant,
  CheckSeverity, CHECK_IDS_SB,
)
from vip_chi_analysis_imp import vip_chi_analysis_imp

# Rule names, spelled once. Every site below bumps a tally through one of these
# rather than a bare string, so a typo is an AttributeError at import rather than
# a rule that quietly tallies into a name nothing reports.
SB_TXN_COMPLETES = "CHI_SB_TXN_COMPLETES"
SB_RSP_HAS_OPEN_TXN = "CHI_SB_RSP_HAS_OPEN_TXN"
SB_DAT_HAS_OPEN_TXN = "CHI_SB_DAT_HAS_OPEN_TXN"
SB_TXNID_NOT_REUSED = "CHI_SB_TXNID_NOT_REUSED"
SB_COMPLETION_OPCODE_MODELLED = "CHI_SB_COMPLETION_OPCODE_MODELLED"
SB_REQ_RELAYED = "CHI_SB_REQ_RELAYED"
SB_REQ_ROUTED = "CHI_SB_REQ_ROUTED"
SB_READ_DATA_MATCHES = "CHI_SB_READ_DATA_MATCHES"
SB_ATOMIC_RETURN_MATCHES = "CHI_SB_ATOMIC_RETURN_MATCHES"
SB_READ_TAG_MATCHES = "CHI_SB_READ_TAG_MATCHES"
SB_READ_TAGOP_REPLAYED = "CHI_SB_READ_TAGOP_REPLAYED"
SB_TAGOP_STABLE_ACROSS_BEATS = "CHI_SB_TAGOP_STABLE_ACROSS_BEATS"
SB_ORDERED_ACK_IN_ORDER = "CHI_SB_ORDERED_ACK_IN_ORDER"

# Combined Write + CMO, and the subset whose CMO half is persistent.
_COMBINED_WRITE_CMO_C = {
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH),
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_INV),
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_INV),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP),
}
_COMBINED_CMO_PERSIST_C = {
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP),
}

# Rules that stand down with check_data, so the export can say "not exercised BY
# REQUEST" rather than reporting a knob the user turned off as a hole.
_SB_DATA_RULES_C = (
  SB_READ_DATA_MATCHES, SB_ATOMIC_RETURN_MATCHES, SB_READ_TAG_MATCHES,
  SB_READ_TAGOP_REPLAYED, SB_TAGOP_STABLE_ACROSS_BEATS,
)

# Which requester stream an observation arrived on (TxnID alone is not unique
# across the integrated pair and the two proxy RNs).
SB_STREAM_RNI = 0
SB_STREAM_HRNI0 = 1
SB_STREAM_HRNI1 = 2

# Coarse transaction class used to pick the completion contract.
SB_READ = 0
SB_WRITE = 1
SB_WRITE_NODATA = 2
SB_ATOMIC = 3
SB_PERSIST = 4
SB_PERSIST_SEP = 5
SB_PREFETCH = 6
SB_OTHER = 7

_OKAY = int(RespErr.OKAY)


class vip_chi_sb_ctx:
  """Per-transaction context (a class so the table and the DBID/sep-return
  side-indexes can hold handles to the same object)."""

  def __init__(self):
    self.stream = SB_STREAM_RNI
    self.requester_node = 0
    self.txn_id = 0
    self.addr = 0
    self.size = 0
    self.opcode = 0
    self.kind = SB_OTHER
    self.ordered = False
    self.exp_comp_ack = False
    self.allow_retry = False
    # Checker E position. order_val is the REQ Order field verbatim; ord_key names
    # the stream FIFO this transaction was enrolled in, so it can be withdrawn
    # again without searching every stream.
    self.order_val = 0
    self.ord_key = ""
    self.ord_enrolled = False
    self.sep_read = False
    self.return_nid = 0
    self.return_txn_id = 0
    # Required milestones.
    self.need_grant = False
    self.need_write_data = False
    self.need_read_data = False
    self.need_comp = False
    self.need_receipt = False
    self.need_persist = False
    self.need_compack = False
    # The CMO half of a combined Write + CMO. A separate milestone from the
    # write's own completion, because that is what it is on the wire: a
    # completer that answered a combined request with the write completion alone
    # would leave the CMO outstanding, and without this the scoreboard would
    # retire the transaction anyway and never notice.
    self.need_comp_cmo = False
    # Observed milestones.
    self.grant_seen = False
    self.write_data_sent = False
    self.read_data_seen = False
    self.comp_seen = False
    self.receipt_seen = False
    self.persist_seen = False
    self.compack_seen = False
    self.comp_cmo_seen = False
    self.retry_seen = False
    self.pcrd_seen = False
    self.dbid = 0
    self.retired = False
    # Checker C bookkeeping.
    self.wr_dat_item = None
    self.wr_committed = False
    self.comp_err = _OKAY
    self.atomic_old = []
    self.atomic_old_valid = False
    self.atomic_resolved = False

  def contract_met(self):
    return ((not self.need_comp_cmo or self.comp_cmo_seen)
            and (not self.need_grant or self.grant_seen)
            and (not self.need_write_data or self.write_data_sent)
            and (not self.need_read_data or self.read_data_seen)
            and (not self.need_comp or self.comp_seen)
            and (not self.need_receipt or self.receipt_seen)
            and (not self.need_persist or self.persist_seen)
            and (not self.need_compack or self.compack_seen))

  def reset_milestones(self):
    self.grant_seen = False
    self.write_data_sent = False
    self.read_data_seen = False
    self.comp_seen = False
    self.receipt_seen = False
    self.persist_seen = False
    self.compack_seen = False
    self.comp_cmo_seen = False
    self.retry_seen = False
    self.pcrd_seen = False
    self.retired = False
    self.wr_dat_item = None
    self.wr_committed = False
    self.comp_err = _OKAY
    self.atomic_old = []
    self.atomic_old_valid = False
    self.atomic_resolved = False


class vip_chi_scoreboard(uvm_component):

  def __init__(self, name, parent):
    super().__init__(name, parent)
    self.cfg = None                # ChiCfg (set by env in connect_phase)
    self.DATA_BYTES_C = 0
    self.dw = 0
    self.mask_dw = 0

    # Gating knobs (set by env from tb_cfg in connect_phase).
    self.enable = True             # master on/off (A + B + C + E)
    self.check_data = True         # Checker C on/off (A + B still run)
    self.check_order = True        # Checker E on/off (A + B + C still run)

    # Checker B HN-I routing prediction policy.
    self.route_check = False
    self.n_sn_ports = 1
    self.sn_addr_lsb = 12
    self.hni_sam = None

    # Analysis imps (allocated in build_phase).
    self.rni_req_sb = None
    self.rni_rsp_sb = None
    self.rni_dat_sb = None
    self.hrni0_req_sb = None
    self.hrni0_rsp_sb = None
    self.hrni0_dat_sb = None
    self.hrni1_req_sb = None
    self.hrni1_rsp_sb = None
    self.hrni1_dat_sb = None
    self.snf_req_sb = None
    self.hsnf0_req_sb = None
    self.hsnf1_req_sb = None

    # Shared transaction table + side-indexes.
    self.open_ctx = {}             # key: ctx_key -> ctx
    self.ctx_by_dbid = {}          # key: dbid_key -> ctx
    self.sep_ret_ctx = {}          # key: ctx_key(return) -> ctx

    # Checker C predicted image (observed writes only).
    self.pred_mem = {}             # addr -> byte (0..255)
    self.written = set()           # addr set

    # Checker C, MTE half: the predicted TAG image, alongside pred_mem/written
    # and committed by the same rule (an observed write that resolved OKAY).
    # Keyed by BEAT, not by byte, because a tag covers a whole beat's worth of
    # data in this VIP's model -- the completer stores one tag + tu per beat slot
    # and replays it. Predicting per byte would claim a granularity the model
    # does not have.
    #
    # What this checks is the store-and-replay path, which is what the VIP
    # implements: the tag that comes back must be the tag that went in. It
    # deliberately does NOT model TagOp semantics (Invalid / Transfer / Update /
    # Match), because the VIP does not either -- the completer replays TagOp
    # verbatim, and a checker that invented those semantics would be checking
    # itself.
    self.pred_tag = {}
    self.pred_tu = {}
    self.pred_tagop = {}
    self.tag_written = set()

    # Checker B canonical-key request multisets.
    self.int_req_cnt = {}
    self.int_cmp_cnt = {}
    self.hni_req_cnt = {}
    self.hni_cmp_cnt = {}
    self.hni_route_pred = {}
    self.hni_route_obs = {}

    # Checker E: one expected-acknowledgement FIFO per ordered stream. The key is
    # "stream_srcid_order" and the list holds TxnIDs in the order the requester
    # issued them; index 0 is what the completer owes an acknowledgement for next.
    self.ord_fifo = {}

    # Per-rule tallies, the scoreboard's half of the per-check registry.
    #
    # PASSES are the point. Every scoreboard check here counted only its
    # failures, which makes a rule that never ran and a rule that always holds
    # produce the identical log -- and the whole regression could not tell them
    # apart. A pass count is what turns "no errors" into "compared N times and
    # none differed", and it is what the cross-run aggregation reads.
    self.chk_pass = {r: 0 for r in CHECK_IDS_SB}
    self.chk_fail = {r: 0 for r in CHECK_IDS_SB}
    self.chk_severity = {r: CheckSeverity.ERROR for r in CHECK_IDS_SB}
    # An unmodelled completion opcode has always been a warning: a genuinely
    # wrong completion still surfaces as an incomplete at check_phase, so
    # failing here would double-report the same defect.
    self.chk_severity[SB_COMPLETION_OPCODE_MODELLED] = CheckSeverity.WARNING

    # Advisory tallies, deliberately NOT rules. They count what the
    # predictable-only discipline SKIPPED, which is neither a pass nor a
    # failure, and they are the denominator that makes a zero-mismatch run
    # readable.
    self.n_reads_skipped = 0
    self.n_tag_reads_skipped = 0
    self.n_tag_checked = 0

  # ==========================================================================
  def build_phase(self):
    self.rni_req_sb = vip_chi_analysis_imp("rni_req_sb", self, self.write_rni_req_sb)
    self.rni_rsp_sb = vip_chi_analysis_imp("rni_rsp_sb", self, self.write_rni_rsp_sb)
    self.rni_dat_sb = vip_chi_analysis_imp("rni_dat_sb", self, self.write_rni_dat_sb)
    self.hrni0_req_sb = vip_chi_analysis_imp("hrni0_req_sb", self, self.write_hrni0_req_sb)
    self.hrni0_rsp_sb = vip_chi_analysis_imp("hrni0_rsp_sb", self, self.write_hrni0_rsp_sb)
    self.hrni0_dat_sb = vip_chi_analysis_imp("hrni0_dat_sb", self, self.write_hrni0_dat_sb)
    self.hrni1_req_sb = vip_chi_analysis_imp("hrni1_req_sb", self, self.write_hrni1_req_sb)
    self.hrni1_rsp_sb = vip_chi_analysis_imp("hrni1_rsp_sb", self, self.write_hrni1_rsp_sb)
    self.hrni1_dat_sb = vip_chi_analysis_imp("hrni1_dat_sb", self, self.write_hrni1_dat_sb)
    self.snf_req_sb = vip_chi_analysis_imp("snf_req_sb", self, self.write_snf_req_sb)
    self.hsnf0_req_sb = vip_chi_analysis_imp("hsnf0_req_sb", self, self.write_hsnf0_req_sb)
    self.hsnf1_req_sb = vip_chi_analysis_imp("hsnf1_req_sb", self, self.write_hsnf1_req_sb)

  def set_cfg(self, cfg):
    self.cfg = cfg
    self.DATA_BYTES_C = cfg.data_bytes
    self.dw = cfg.data_bytes * 8
    self.mask_dw = (1 << self.dw) - 1

  # ==========================================================================
  # The per-rule tally.
  # ==========================================================================
  def _pass(self, rule, n=1):
    self.chk_pass[rule] += n

  def _fail(self, rule, msg):
    """Count a violation and report it.

    Reporting is unconditional, unlike the SVA checkers' severity handling, and
    the difference is deliberate. There, a rule turned OFF is counted but
    silent, which is what a negative control needs. Here the report IS the
    verdict -- the scoreboard raises a UVM error and the negative controls
    assert, through a report catcher, that the message was actually emitted.
    Suppressing it would delete the evidence those tests depend on, so severity
    on this side declares INTENT for the export and nothing more; see
    expect_failure.
    """
    self.chk_fail[rule] += 1
    if self.chk_severity[rule] is CheckSeverity.WARNING:
      self.logger.warning(msg)
    else:
      self.logger.error(msg)

  def expect_failure(self, rule: str) -> None:
    """Declare that this run provokes `rule` on purpose.

    Without it the cross-run aggregation reads a negative control as a genuine
    regression failure -- the run that PROVES a check fires would be reported as
    the check failing. Declared per rule rather than per checker so a second,
    unintended violation inside the same run still stands out.
    """
    self.chk_severity[rule] = CheckSeverity.OFF

  def rule_enabled(self, rule: str) -> bool:
    """Whether this run could evaluate `rule` at all.

    A rule standing down because its knob is off was not exercised BY REQUEST,
    which is a different thing from a hole, and the aggregation needs to be able
    to tell them apart: gating on a knob the user turned off would teach the
    reader to pass --allow-never and hide the real gaps with it.
    """
    if not self.enable:
      return False
    if rule in _SB_DATA_RULES_C:
      return self.check_data
    if rule == SB_ORDERED_ACK_IN_ORDER:
      return self.check_order
    if rule == SB_REQ_ROUTED:
      return self.route_check
    return True

  def not_exercised(self):
    """Enabled rules with neither a pass nor a failure, in registry order."""
    return [r for r in CHECK_IDS_SB
            if self.rule_enabled(r)
            and not self.chk_pass[r] and not self.chk_fail[r]]

  # Legacy tallies, now DERIVED from the registry rather than kept beside it.
  # One source of truth: a new check site that forgets to bump its rule can no
  # longer leave the summary line reading right while the export reads zero.
  @property
  def n_incomplete(self):
    return self.chk_fail[SB_TXN_COMPLETES]

  @property
  def n_orphan(self):
    return (self.chk_fail[SB_RSP_HAS_OPEN_TXN]
            + self.chk_fail[SB_DAT_HAS_OPEN_TXN])

  @property
  def n_wrong_opcode(self):
    return self.chk_fail[SB_COMPLETION_OPCODE_MODELLED]

  @property
  def n_reuse(self):
    return self.chk_fail[SB_TXNID_NOT_REUSED]

  @property
  def n_data_mismatch(self):
    return (self.chk_fail[SB_READ_DATA_MATCHES]
            + self.chk_fail[SB_ATOMIC_RETURN_MATCHES])

  @property
  def n_relay_mismatch(self):
    return self.chk_fail[SB_REQ_RELAYED]

  @property
  def n_route_mismatch(self):
    return self.chk_fail[SB_REQ_ROUTED]

  @property
  def n_tag_mismatch(self):
    return self.chk_fail[SB_READ_TAG_MATCHES]

  @property
  def n_tagop_replay_mismatch(self):
    return self.chk_fail[SB_READ_TAGOP_REPLAYED]

  @property
  def n_tagop_beat_mismatch(self):
    return self.chk_fail[SB_TAGOP_STABLE_ACROSS_BEATS]

  @property
  def n_order_violation(self):
    return self.chk_fail[SB_ORDERED_ACK_IN_ORDER]

  @property
  def n_order_checked(self):
    return self.chk_pass[SB_ORDERED_ACK_IN_ORDER]

  # ==========================================================================
  # Keys.
  # ==========================================================================
  def _ctx_key(self, stream, requester_node, txn_id):
    return "%d_%x_%x" % (int(stream), int(requester_node), int(txn_id))

  def _dbid_key(self, stream, dbid):
    return "%d_%x" % (int(stream), int(dbid))

  # Full canonical REQ identity - never addr/opcode alone.
  def _canon_key(self, item):
    return "%x_%x_%x_%x_%x_%d" % (
      int(item.src_id), int(item.tgt_id), int(item.txn_id),
      int(item.addr), int(item.opcode), int(item.size))

  # At a requester agent, TX flits carry ROLE_P (RN-I), RX flits the peer role
  # (SN-F). Direction, not opcode, distinguishes requester-sourced flits.
  def _is_outbound(self, item):
    return int(item.role) == int(Role.RNI)

  # ==========================================================================
  # Checker B - HN-I routing prediction helpers.
  # ==========================================================================
  def set_route_policy(self, sn_ports, addr_lsb, sam):
    self.n_sn_ports = sn_ports
    self.sn_addr_lsb = addr_lsb
    self.hni_sam = sam
    self.route_check = (sn_ports > 1)

  def _sn_port_of_addr(self, addr):
    if self.n_sn_ports <= 1:
      return 0
    if self.hni_sam is not None:
      s = self.hni_sam.lookup(int(addr))
      if s < 0 or s >= self.n_sn_ports:
        return -1
      return s
    return (int(addr) >> self.sn_addr_lsb) % self.n_sn_ports

  def _route_key(self, port, item):
    return "p%d|%s" % (int(port), self._canon_key(item))

  # ==========================================================================
  # Derive the completion contract from a requester REQ.
  # ==========================================================================
  def _set_contract(self, ctx, item):
    opc = int(item.opcode)

    ctx.ordered = (int(item.order) != int(ReqOrder.NONE))
    ctx.order_val = int(item.order)
    ctx.exp_comp_ack = bool(int(item.exp_comp_ack))
    ctx.allow_retry = bool(int(item.allow_retry))

    ctx.need_grant = ctx.need_write_data = ctx.need_read_data = False
    ctx.need_comp = ctx.need_receipt = ctx.need_persist = ctx.need_compack = False

    if req_opcode_is_atomic(opc):
      ctx.kind = SB_ATOMIC
      ctx.need_grant = True
      ctx.need_write_data = True
      if req_opcode_is_atomic_returning_data(opc):
        ctx.need_read_data = True
      else:
        ctx.need_comp = True
      return

    if opc in (int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP)):
      ctx.kind = SB_READ
      ctx.need_read_data = True
      if ctx.ordered:
        ctx.need_receipt = True
    elif opc in _COMBINED_WRITE_CMO_C:
      # A write, plus the CMO half's own completion. The persistent forms owe a
      # Persist as well, which the spec requires only AFTER the write data --
      # the ordering rule the whole family turns on.
      ctx.kind = SB_WRITE
      ctx.need_grant = True
      ctx.need_write_data = True
      ctx.need_comp = True
      ctx.need_comp_cmo = True
      ctx.need_persist = opc in _COMBINED_CMO_PERSIST_C
      ctx.need_compack = ctx.exp_comp_ack
    elif opc in (int(ReqOpcode.WRITE_NO_SNP_FULL), int(ReqOpcode.WRITE_NO_SNP_PTL)):
      ctx.kind = SB_WRITE
      ctx.need_grant = True
      ctx.need_write_data = True
      ctx.need_comp = True
      ctx.need_compack = ctx.exp_comp_ack
    elif opc == int(ReqOpcode.WRITE_NO_SNP_ZERO):
      ctx.kind = SB_WRITE_NODATA
      ctx.need_comp = True
    elif opc == int(ReqOpcode.CLEAN_SHARED_PERSIST):
      ctx.kind = SB_PERSIST
      ctx.need_comp = True
    elif opc == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP):
      ctx.kind = SB_PERSIST_SEP
      ctx.need_persist = True
      ctx.need_comp = True
    elif opc == int(ReqOpcode.PREFETCH_TGT):
      ctx.kind = SB_PREFETCH   # no completion
    else:
      ctx.kind = SB_OTHER      # e.g. PcrdReturn - no completion tracked

  # ==========================================================================
  # Checker E - ordered-stream acknowledgement order.
  #
  # A request carrying a non-zero Order field joins an ordered stream: the
  # requests one source issues with the same Order value are a sequence the
  # completer has taken on an ordering obligation for, and it must acknowledge
  # them in the order it received them. This VIP's requesters pipeline ordered
  # requests rather than stalling on each acknowledgement (see
  # observed_peak_outstanding in the ordered multi-outstanding tests), so the
  # obligation sits entirely on the completer side, which is what is checked.
  #
  # The observable is the FIRST inbound response of any kind for a transaction --
  # the ReadReceipt of an ordered read, the DBIDResp / CompDBIDResp of an ordered
  # write. That is the flit in which the completer commits to a position in the
  # stream, so that is what is compared; the data burst that follows may overlap
  # its neighbours freely and says nothing about ordering.
  #
  # Streams are keyed per requester stream AND per Order value, so two sources,
  # or one source mixing Request_Order with Request_Accepted traffic, do not
  # constrain each other.
  # ==========================================================================
  @staticmethod
  def _ord_stream_key(stream, src_id, order_val):
    return "%d_%x_%x" % (stream, int(src_id), int(order_val))

  def _ord_enroll(self, ctx):
    """Take the tail position in this transaction's stream. Requests that never
    draw a completion (prefetch, PCrdReturn) are left out: nothing would ever
    acknowledge them, so enrolling one would wedge the stream behind it."""
    if not self.check_order or not ctx.ordered or ctx.ord_enrolled:
      return
    if ctx.kind in (SB_PREFETCH, SB_OTHER):
      return
    ctx.ord_key = self._ord_stream_key(ctx.stream, ctx.requester_node, ctx.order_val)
    ctx.ord_enrolled = True
    self.ord_fifo.setdefault(ctx.ord_key, []).append(ctx.txn_id)

  def _ord_withdraw(self, ctx):
    """A RetryAck withdraws the request from its stream: it was not accepted, so
    the completer owes it nothing, and the re-issue takes a fresh position at the
    tail rather than holding one it never got."""
    if not ctx.ord_enrolled:
      return
    ctx.ord_enrolled = False
    q = self.ord_fifo.get(ctx.ord_key)
    if q is None or ctx.txn_id not in q:
      return
    q.remove(ctx.txn_id)
    if not q:
      del self.ord_fifo[ctx.ord_key]

  def _ord_observe(self, ctx):
    """The completer has acknowledged this transaction: it must be the one at the
    head of its stream."""
    if not ctx.ord_enrolled:
      return
    ctx.ord_enrolled = False
    q = self.ord_fifo.get(ctx.ord_key)
    if not q:
      return

    expected = q[0]
    if expected == ctx.txn_id:
      # Count the in-order acknowledgement as well as the violation: a check that
      # only ever tallies failures reads, in a passing log, exactly like a check
      # that never ran.
      self._pass(SB_ORDERED_ACK_IN_ORDER)
      q.pop(0)
    else:
      self._fail(SB_ORDERED_ACK_IN_ORDER,
        "Ordered stream out of order: stream=%d src=0x%x order=0x%x expected "
        "txn=0x%x to be acknowledged first, observed txn=0x%x" % (
          ctx.stream, ctx.requester_node, ctx.order_val, expected, ctx.txn_id))
      # Drop the transaction that jumped the queue from wherever it sits, so one
      # inversion costs one error instead of cascading down the rest of the stream.
      if ctx.txn_id in q:
        q.remove(ctx.txn_id)

    if not q:
      self.ord_fifo.pop(ctx.ord_key, None)

  # ==========================================================================
  # Checker A/C - requester REQ.
  # ==========================================================================
  def _handle_req(self, stream, item):
    if not self.enable or not self._is_outbound(item):
      return

    # Checker B: record the requester-issued REQ.
    if stream == SB_STREAM_RNI:
      self._bump(self.int_req_cnt, self._canon_key(item))
    else:
      self._bump(self.hni_req_cnt, self._canon_key(item))
      if self.route_check:
        self._bump(self.hni_route_pred,
                   self._route_key(self._sn_port_of_addr(item.addr), item))

    key = self._ctx_key(stream, item.src_id, item.txn_id)

    if key in self.open_ctx:
      ctx = self.open_ctx[key]
      if not ctx.retired:
        if ctx.retry_seen:
          # Legitimate retry re-issue (same TxnID) - reset and keep tracking. It
          # counts as a PASS of the reuse rule rather than as nothing at all:
          # re-using the ID of a refused request is the one case the rule has to
          # let through, so it is exactly where the rule earns its keep.
          self._pass(SB_TXNID_NOT_REUSED)
          ctx.reset_milestones()
          self._set_contract(ctx, item)
          ctx.addr = int(item.addr)
          ctx.size = int(item.size)
          self._ord_enroll(ctx)
          return
        self._fail(SB_TXNID_NOT_REUSED,
          "TxnID reuse while in flight: stream=%d src=0x%x txn=0x%x opcode=0x%x" % (
            stream, int(item.src_id), int(item.txn_id), int(item.opcode)))
        # fall through and overwrite with a fresh ctx
      else:
        self._pass(SB_TXNID_NOT_REUSED)
    else:
      self._pass(SB_TXNID_NOT_REUSED)

    ctx = vip_chi_sb_ctx()
    ctx.stream = stream
    ctx.requester_node = int(item.src_id)
    ctx.txn_id = int(item.txn_id)
    ctx.addr = int(item.addr)
    ctx.size = int(item.size)
    ctx.opcode = int(item.opcode)
    self._set_contract(ctx, item)
    self.open_ctx[key] = ctx
    self._ord_enroll(ctx)

    # Separated read: the DataSepResp leg returns on ReturnNID/ReturnTxnID.
    if int(item.opcode) == int(ReqOpcode.READ_NO_SNP_SEP):
      ctx.sep_read = True
      ctx.return_nid = int(item.return_nid)
      ctx.return_txn_id = int(item.return_txn_id)
      self.sep_ret_ctx[self._ctx_key(stream, item.return_nid, item.return_txn_id)] = ctx

    # No-completion requests (prefetch / pcrd-return) retire on issue but stay
    # in the table so a later reuse of the TxnID is still caught.
    self._check_and_retire(ctx)

  # ==========================================================================
  # Checker A - requester RSP.
  # ==========================================================================
  def _handle_rsp(self, stream, item):
    if not self.enable:
      return

    opc = int(item.rsp_opcode)
    opc_modelled = True

    # Outbound RSP from the requester == CompAck (keyed by src_id).
    if self._is_outbound(item):
      if opc == int(RspOpcode.COMP_ACK):
        key = self._ctx_key(stream, item.src_id, item.txn_id)
        if key in self.open_ctx:
          ctx = self.open_ctx[key]
          ctx.compack_seen = True
          self._check_and_retire(ctx)
      return

    # PCrdGrant is credit-typed, not TxnID-correlated: attach it to any open
    # retried ctx on this stream rather than risk a false orphan.
    if opc == int(RspOpcode.PCRD_GRANT):
      for c in self.open_ctx.values():
        if c.stream == stream and c.retry_seen and not c.retired:
          c.pcrd_seen = True
      return

    # Inbound completion (keyed by tgt_id == requester node).
    key = self._ctx_key(stream, item.tgt_id, item.txn_id)
    if key not in self.open_ctx:
      self._fail(SB_RSP_HAS_OPEN_TXN,
        "Orphan RSP (no open ctx): stream=%d tgt=0x%x txn=0x%x rsp_opcode=0x%x" % (
          stream, int(item.tgt_id), int(item.txn_id), opc))
      return
    self._pass(SB_RSP_HAS_OPEN_TXN)
    ctx = self.open_ctx[key]

    if opc == int(RspOpcode.COMP):
      ctx.comp_seen = True
      ctx.comp_err = int(item.rsp_resp_err)
    elif opc == int(RspOpcode.COMP_DBID_RESP):
      ctx.grant_seen = True
      ctx.comp_seen = True
      ctx.comp_err = int(item.rsp_resp_err)
      self._record_grant(ctx, item)
    elif opc in (int(RspOpcode.DBID_RESP), int(RspOpcode.DBID_RESP_ORD)):
      ctx.grant_seen = True
      self._record_grant(ctx, item)
    elif opc == int(RspOpcode.READ_RECEIPT):
      ctx.receipt_seen = True
    elif opc == int(RspOpcode.RESP_SEP_DATA):
      # Separated read's response leg; retirement is on its DataSepResp.
      ctx.comp_err = int(item.rsp_resp_err)
    elif opc == int(RspOpcode.COMP_CMO):
      ctx.comp_cmo_seen = True
    elif opc == int(RspOpcode.PERSIST):
      ctx.persist_seen = True
    elif opc == int(RspOpcode.COMP_PERSIST):
      ctx.comp_seen = True
      ctx.comp_err = int(item.rsp_resp_err)
    elif opc == int(RspOpcode.RETRY_ACK):
      ctx.retry_seen = True
      # Not an acknowledgement -- the request was refused, so it leaves its
      # ordered stream and rejoins at the tail when it is re-issued.
      self._ord_withdraw(ctx)
    else:
      # Unmodeled completion opcode: warn rather than fail (a genuinely wrong
      # completion still surfaces as an incomplete at check_phase).
      opc_modelled = False
      self._fail(SB_COMPLETION_OPCODE_MODELLED,
        "Unmodeled completion RSP opcode 0x%x for kind=%d stream=%d txn=0x%x" % (
          opc, ctx.kind, stream, int(item.txn_id)))

    # Every branch above except the else and the RetryAck: a refusal is not a
    # completion opcode, so counting it here would inflate the rule with flits
    # it does not judge.
    if opc_modelled and opc != int(RspOpcode.RETRY_ACK):
      self._pass(SB_COMPLETION_OPCODE_MODELLED)

    # Checker E: the first inbound response is the completer committing to this
    # transaction's position in its ordered stream. A no-op after that, and a
    # no-op for the RetryAck the branch above already withdrew.
    self._ord_observe(ctx)

    self._maybe_commit_write(ctx)
    self._resolve_atomic(ctx, None)   # store atomic completes on its Comp RSP
    self._check_and_retire(ctx)

  # ==========================================================================
  # Checker A/C - requester DAT.
  # ==========================================================================
  def _handle_dat(self, stream, item):
    if not self.enable:
      return

    if self._is_outbound(item):
      # Write / atomic-operand data: DBID and TxnID both carry the granted DBID,
      # so bind through the DBID side-index (try dbid then txnid).
      key = self._dbid_key(stream, item.dbid)
      if key not in self.ctx_by_dbid:
        key = self._dbid_key(stream, item.txn_id)
      if key in self.ctx_by_dbid:
        ctx = self.ctx_by_dbid[key]
        ctx.write_data_sent = True
        ctx.wr_dat_item = item
        self._maybe_commit_write(ctx)
        self._capture_atomic_old(ctx)
        self._resolve_atomic(ctx, None)
        self._check_and_retire(ctx)
      return

    # Inbound read-completion data (CompData / DataSepResp), keyed by tgt_id.
    key = self._ctx_key(stream, item.tgt_id, item.txn_id)
    if key in self.open_ctx:
      ctx = self.open_ctx[key]
    elif key in self.sep_ret_ctx:
      ctx = self.sep_ret_ctx[key]
    else:
      self._fail(SB_DAT_HAS_OPEN_TXN,
        "Orphan DAT (no open ctx): stream=%d tgt=0x%x txn=0x%x dat_opcode=0x%x" % (
          stream, int(item.tgt_id), int(item.txn_id), int(item.dat_opcode)))
      return
    self._pass(SB_DAT_HAS_OPEN_TXN)
    ctx.read_data_seen = True

    # Checker E: normally the ReadReceipt got here first and this is a no-op; it
    # is the acknowledgement only for an ordered transaction whose completer
    # answers on DAT alone.
    self._ord_observe(ctx)

    if self.check_data and ctx.kind == SB_READ:
      self._compare_read(ctx, item)
    elif self.check_data and ctx.kind == SB_ATOMIC:
      self._resolve_atomic(ctx, item)

    self._check_and_retire(ctx)

  # ==========================================================================
  # Record a granted DBID and seed the side-index for the coming write-DAT.
  # ==========================================================================
  def _record_grant(self, ctx, item):
    ctx.dbid = int(item.dbid)
    self.ctx_by_dbid[self._dbid_key(ctx.stream, item.dbid)] = ctx

  # ==========================================================================
  # Checker C - commit an observed write once the completion resolves OKAY.
  # ==========================================================================
  def _maybe_commit_write(self, ctx):
    if not self.check_data or ctx.wr_committed:
      return

    if ctx.kind == SB_WRITE_NODATA:
      if not ctx.comp_seen:
        return
      if ctx.comp_err != _OKAY:
        ctx.wr_committed = True   # rejected zero-write never landed
        return
      transfer_bytes = 1 << int(ctx.size)
      for k in range(transfer_bytes):
        a = ctx.addr + k
        self.pred_mem[a] = 0x00
        self.written.add(a)
      ctx.wr_committed = True
      return

    if ctx.kind != SB_WRITE:
      return
    if not ctx.write_data_sent or not ctx.comp_seen or ctx.wr_dat_item is None:
      return
    if ctx.comp_err != _OKAY:
      ctx.wr_committed = True   # resolved (rejected) - nothing to commit
      return

    dat = ctx.wr_dat_item
    for i in range(len(dat.data)):
      for j in range(self.DATA_BYTES_C):
        if i < len(dat.be) and ((int(dat.be[i]) >> j) & 1):
          a = ctx.addr + (i * self.DATA_BYTES_C) + j
          self.pred_mem[a] = (int(dat.data[i]) >> (8 * j)) & 0xFF
          self.written.add(a)
    self._commit_write_tags(ctx, dat)
    ctx.wr_committed = True

  # ==========================================================================
  # Checker C - atomic target-beat count (compare mutates the first half only).
  # ==========================================================================
  def _atomic_target_beats(self, ctx):
    operand_beats = len(ctx.wr_dat_item.data)
    if req_opcode_is_atomic_compare(ctx.opcode):
      return operand_beats // 2
    return operand_beats

  # CHI AtomicStore/Load[0:7] arithmetic variant over the full beat width.
  def _apply_atomic_variant_sb(self, variant, current_value, operand_value):
    m = self.mask_dw
    cur = current_value & m
    opd = operand_value & m
    if variant == 0:
      return (cur + opd) & m
    if variant == 1:
      return cur & (~opd & m)
    if variant == 2:
      return (cur ^ opd) & m
    if variant == 3:
      return (cur | opd) & m
    sign = 1 << (self.dw - 1)
    cur_s = cur - (1 << self.dw) if (cur & sign) else cur
    opd_s = opd - (1 << self.dw) if (opd & sign) else opd
    if variant == 4:
      return cur if cur_s > opd_s else opd
    if variant == 5:
      return cur if cur_s < opd_s else opd
    if variant == 6:
      return cur if cur > opd else opd
    if variant == 7:
      return cur if cur < opd else opd
    return cur

  # ==========================================================================
  # Checker C - snapshot the target pre-op value off pred_mem, then invalidate
  # the target range for the RMW window.
  # ==========================================================================
  def _capture_atomic_old(self, ctx):
    if not self.check_data or ctx.kind != SB_ATOMIC or ctx.wr_dat_item is None:
      return

    beat_count = self._atomic_target_beats(ctx)
    ctx.atomic_old = [0] * beat_count
    ctx.atomic_old_valid = True

    for i in range(beat_count):
      beat = 0
      for j in range(self.DATA_BYTES_C):
        a = ctx.addr + (i * self.DATA_BYTES_C) + j
        if a in self.written:
          beat |= (self.pred_mem[a] & 0xFF) << (8 * j)
        else:
          ctx.atomic_old_valid = False
      ctx.atomic_old[i] = beat

    # Invalidate the target range for the RMW window.
    for i in range(beat_count):
      for j in range(self.DATA_BYTES_C):
        a = ctx.addr + (i * self.DATA_BYTES_C) + j
        self.written.discard(a)
        self.pred_mem.pop(a, None)

  # ==========================================================================
  # Checker C - at the atomic completion, recompute + commit the post-op image
  # and compare a returning atomic's CompData against the captured pre-op value.
  # ==========================================================================
  def _resolve_atomic(self, ctx, ret_item):
    if (not self.check_data or ctx.kind != SB_ATOMIC or ctx.wr_dat_item is None
        or ctx.atomic_resolved):
      return
    if not ctx.write_data_sent:
      return  # operand not observed yet

    returns_data = req_opcode_is_atomic_returning_data(ctx.opcode)

    if returns_data:
      if ret_item is None:
        return  # CompData not arrived
    else:
      if not ctx.comp_seen:
        return  # Comp not arrived
    ctx.atomic_resolved = True

    if returns_data:
      err = (int(ret_item.dat_resp_err[0])
             if (ret_item is not None and len(ret_item.dat_resp_err) > 0) else _OKAY)
    else:
      err = ctx.comp_err

    # Errored or unpredictable: leave the target invalidated.
    if err != _OKAY or not ctx.atomic_old_valid:
      return

    beat_count = self._atomic_target_beats(ctx)
    is_compare = req_opcode_is_atomic_compare(ctx.opcode)
    is_swap = (ctx.opcode == int(ReqOpcode.ATOMIC_SWAP))
    variant = req_opcode_atomic_variant(ctx.opcode)

    # A returning atomic returns the pre-op value on CompData: compare it against
    # the captured pre-op image, byte-granular.
    if returns_data and ret_item is not None:
      n = min(beat_count, len(ret_item.data))
      for i in range(n):
        for j in range(self.DATA_BYTES_C):
          exp_b = (ctx.atomic_old[i] >> (8 * j)) & 0xFF
          got_b = (int(ret_item.data[i]) >> (8 * j)) & 0xFF
          if got_b != exp_b:
            self._fail(SB_ATOMIC_RETURN_MATCHES,
              "Atomic return mismatch stream=%d txn=0x%x addr=0x%x exp=0x%x got=0x%x" % (
                ctx.stream, ctx.txn_id,
                ctx.addr + (i * self.DATA_BYTES_C) + j, exp_b, got_b))
          else:
            self._pass(SB_ATOMIC_RETURN_MATCHES)

    # AtomicCompare stores the swap half only on a full-target match.
    compare_match = True
    if is_compare:
      for k in range(beat_count):
        if ctx.atomic_old[k] != (int(ctx.wr_dat_item.data[k]) & self.mask_dw):
          compare_match = False

    # Recompute and commit the post-op value so a later read-back is predictable.
    for i in range(beat_count):
      if is_compare:
        new_beat = (int(ctx.wr_dat_item.data[i + beat_count]) & self.mask_dw) \
          if compare_match else ctx.atomic_old[i]
      elif is_swap:
        new_beat = int(ctx.wr_dat_item.data[i]) & self.mask_dw
      else:
        new_beat = self._apply_atomic_variant_sb(
          variant, ctx.atomic_old[i], int(ctx.wr_dat_item.data[i]))

      for j in range(self.DATA_BYTES_C):
        a = ctx.addr + (i * self.DATA_BYTES_C) + j
        self.pred_mem[a] = (new_beat >> (8 * j)) & 0xFF
        self.written.add(a)

  # ==========================================================================
  # Checker C - predictable-only read compare (skip bytes never observed).
  # ==========================================================================
  def _compare_read(self, ctx, item):
    # Error read data is don't-care.
    if len(item.dat_resp_err) > 0 and int(item.dat_resp_err[0]) != _OKAY:
      return

    for i in range(len(item.data)):
      for j in range(self.DATA_BYTES_C):
        a = ctx.addr + (i * self.DATA_BYTES_C) + j
        if a not in self.written:
          self.n_reads_skipped += 1
          continue
        got = (int(item.data[i]) >> (8 * j)) & 0xFF
        if got != self.pred_mem[a]:
          self._fail(SB_READ_DATA_MATCHES,
            "Data mismatch stream=%d txn=0x%x addr=0x%x exp=0x%x got=0x%x" % (
              ctx.stream, ctx.txn_id, a, self.pred_mem[a], got))
        else:
          self._pass(SB_READ_DATA_MATCHES)

    self._compare_read_tags(ctx, item)

  # ==========================================================================
  # Checker C, MTE half - the tag rules.
  #
  # The VIP has kept a per-beat tag store and replayed it since the exact-CHI-E
  # completer was written, and nothing ever checked what came back. A model
  # nothing checks is the same defect as a check nothing exercises, seen from
  # the other side: it can be wrong for a whole regression without one test
  # noticing.
  # ==========================================================================
  def _compare_read_tags(self, ctx, item):
    if not self.check_data:
      return

    tagops = getattr(item, "dat_tagop_beats", []) or []

    # Rule 1: one TagOp for the whole transfer.
    #
    # This was recorded as UNREACHABLE on this testbench when it was written, and
    # that was WRONG. The claim was that the only MTE-capable link here is the
    # 64-byte CHI-E one and CHI's maximum transfer Size is also 64 bytes, so
    # every transfer carrying TAGS is a single beat -- true, and irrelevant,
    # because the loop below does not require tags. dat_tagop_beats is sized per
    # beat for EVERY data transfer, so any multi-beat read exercises this rule,
    # and the whole CHI-D regression does: 36 runs, comparing TagOp zero against
    # TagOp zero across four beats.
    #
    # Naming the rule in the registry is what found that out, on the first sweep
    # after it was named. What remains genuinely out of reach here is the FAILING
    # direction -- a multi-beat burst whose beats carry disagreeing non-zero
    # TagOps -- because no link in this testbench is both MTE-capable and narrow
    # enough to burst. That is why the M3.1 negative control could not break this
    # rule, and it is a statement about the negative control, not about whether
    # the rule runs. Rule 3 below is the half a control can break.
    if len(tagops) > 1:
      first = int(tagops[0])
      agreed = True
      for i, op in enumerate(tagops):
        if int(op) != first:
          agreed = False
          self._fail(SB_TAGOP_STABLE_ACROSS_BEATS,
            "TagOp mismatch across beats stream=%d txn=0x%x beat=%d exp=0x%x "
            "got=0x%x" % (ctx.stream, ctx.txn_id, i, first, int(op)))
          break   # one report per transfer, not one per remaining beat
      if agreed:
        self._pass(SB_TAGOP_STABLE_ACROSS_BEATS)

    # Rule 2: the tag that comes back is the tag that went in. Same
    # predictable-only discipline as the data compare -- a beat whose tag this
    # scoreboard never observed being written is skipped, because the completer
    # synthesizes tagging the scoreboard did not originate.
    for i in range(len(item.tag)):
      slot = ctx.addr + (i * self.DATA_BYTES_C)
      if slot not in self.tag_written:
        self.n_tag_reads_skipped += 1
        continue
      self.n_tag_checked += 1
      matched = True
      if int(item.tag[i]) != self.pred_tag[slot]:
        matched = False
        self._fail(SB_READ_TAG_MATCHES,
          "Tag mismatch stream=%d txn=0x%x addr=0x%x exp=0x%x got=0x%x" % (
            ctx.stream, ctx.txn_id, slot, self.pred_tag[slot], int(item.tag[i])))
      if i < len(item.tu) and int(item.tu[i]) != self.pred_tu[slot]:
        matched = False
        self._fail(SB_READ_TAG_MATCHES,
          "TagUpdate mismatch stream=%d txn=0x%x addr=0x%x exp=0x%x got=0x%x" % (
            ctx.stream, ctx.txn_id, slot, self.pred_tu[slot], int(item.tu[i])))
      if matched:
        self._pass(SB_READ_TAG_MATCHES)

      # Rule 3: the TagOp that comes back is the TagOp that went in. The
      # reachable half of rule 1's concern -- it needs only ONE beat, so unlike
      # rule 1 it is exercised on this testbench's 64-byte MTE link.
      if i < len(tagops):
        if int(tagops[i]) != self.pred_tagop[slot]:
          self._fail(SB_READ_TAGOP_REPLAYED,
            "TagOp replay mismatch stream=%d txn=0x%x addr=0x%x exp=0x%x "
            "got=0x%x" % (ctx.stream, ctx.txn_id, slot, self.pred_tagop[slot],
                          int(tagops[i])))
        else:
          self._pass(SB_READ_TAGOP_REPLAYED)

  def _commit_write_tags(self, ctx, item):
    """Commit an observed write's tagging, under the same rule as the data."""
    if not self.check_data or item is None:
      return
    tagops = getattr(item, "dat_tagop_beats", []) or []
    for i in range(len(item.tag)):
      slot = ctx.addr + (i * self.DATA_BYTES_C)
      self.pred_tag[slot] = int(item.tag[i])
      self.pred_tu[slot] = int(item.tu[i]) if i < len(item.tu) else 0
      self.pred_tagop[slot] = (int(tagops[i]) if i < len(tagops)
                               else int(getattr(item, "dat_tagop", 0)))
      self.tag_written.add(slot)

  # ==========================================================================
  # Retire when the contract is met; drop the DBID/sep-return index entries.
  # ==========================================================================
  def _check_and_retire(self, ctx):
    if ctx.retired or not ctx.contract_met():
      return
    ctx.retired = True
    # The pass half of the completion rule. Its failure half fires once, at
    # check_phase, on whatever is left open -- so without this the rule would
    # report zero of both on every clean run and be indistinguishable from a
    # scoreboard that had stopped tracking transactions altogether.
    self._pass(SB_TXN_COMPLETES)
    dkey = self._dbid_key(ctx.stream, ctx.dbid)
    if self.ctx_by_dbid.get(dkey) is ctx:
      del self.ctx_by_dbid[dkey]
    if ctx.sep_read:
      skey = self._ctx_key(ctx.stream, ctx.return_nid, ctx.return_txn_id)
      if self.sep_ret_ctx.get(skey) is ctx:
        del self.sep_ret_ctx[skey]

  # ==========================================================================
  # Checker B - completer-side REQ recording.
  # ==========================================================================
  def _handle_cmp_req(self, hni, port, item):
    if not self.enable:
      return
    if hni:
      self._bump(self.hni_cmp_cnt, self._canon_key(item))
      if self.route_check:
        self._bump(self.hni_route_obs, self._route_key(port, item))
    else:
      self._bump(self.int_cmp_cnt, self._canon_key(item))

  @staticmethod
  def _bump(d, k):
    d[k] = d.get(k, 0) + 1

  # ==========================================================================
  # Analysis imp write callbacks.
  # ==========================================================================
  def write_rni_req_sb(self, item):
    self._handle_req(SB_STREAM_RNI, item)

  def write_rni_rsp_sb(self, item):
    self._handle_rsp(SB_STREAM_RNI, item)

  def write_rni_dat_sb(self, item):
    self._handle_dat(SB_STREAM_RNI, item)

  def write_hrni0_req_sb(self, item):
    self._handle_req(SB_STREAM_HRNI0, item)

  def write_hrni0_rsp_sb(self, item):
    self._handle_rsp(SB_STREAM_HRNI0, item)

  def write_hrni0_dat_sb(self, item):
    self._handle_dat(SB_STREAM_HRNI0, item)

  def write_hrni1_req_sb(self, item):
    self._handle_req(SB_STREAM_HRNI1, item)

  def write_hrni1_rsp_sb(self, item):
    self._handle_rsp(SB_STREAM_HRNI1, item)

  def write_hrni1_dat_sb(self, item):
    self._handle_dat(SB_STREAM_HRNI1, item)

  def write_snf_req_sb(self, item):
    self._handle_cmp_req(False, 0, item)

  def write_hsnf0_req_sb(self, item):
    self._handle_cmp_req(True, 0, item)

  def write_hsnf1_req_sb(self, item):
    self._handle_cmp_req(True, 1, item)

  # ==========================================================================
  # Flush all in-flight state on reset.
  # ==========================================================================
  def handle_reset(self):
    self.open_ctx.clear()
    self.ctx_by_dbid.clear()
    self.sep_ret_ctx.clear()
    self.pred_mem.clear()
    self.written.clear()
    self.int_req_cnt.clear()
    self.int_cmp_cnt.clear()
    self.hni_req_cnt.clear()
    self.hni_cmp_cnt.clear()
    self.hni_route_pred.clear()
    self.hni_route_obs.clear()
    self.ord_fifo.clear()

  # ==========================================================================
  # Checker B multiset compare between requester and completer views.
  # ==========================================================================
  def _check_relay(self, label, req_cnt, cmp_cnt, rule):
    for k, want in req_cnt.items():
      seen = cmp_cnt.get(k, 0)
      if seen < want:
        self._fail(rule,
          "%s: request key=%s issued %d time(s) but observed at completer %d time(s)" % (
            label, k, want, seen))
      else:
        # One pass per request key that arrived, so a run in which the two views
        # simply never met -- no requester traffic, or a completer imp nothing
        # connected -- cannot read as a clean compare.
        self._pass(rule)
    for k, seen in cmp_cnt.items():
      issued = req_cnt.get(k, 0)
      if seen > issued:
        self._fail(rule,
          "%s: phantom request key=%s at completer %d time(s) but issued %d time(s)" % (
            label, k, seen, issued))

  # ==========================================================================
  # Final checks: incomplete transactions + request fidelity.
  # ==========================================================================
  def check_phase(self):
    if not self.enable:
      return

    for ctx in self.open_ctx.values():
      if not ctx.retired:
        self._fail(SB_TXN_COMPLETES,
          "Incomplete transaction stream=%d node=0x%x txn=0x%x opcode=0x%x kind=%d "
          "(grant=%d wdat=%d rdat=%d comp=%d rcpt=%d prst=%d cack=%d)" % (
            ctx.stream, ctx.requester_node, ctx.txn_id, ctx.opcode, ctx.kind,
            ctx.grant_seen, ctx.write_data_sent, ctx.read_data_seen, ctx.comp_seen,
            ctx.receipt_seen, ctx.persist_seen, ctx.compack_seen))

    self._check_relay("Checker-B integrated", self.int_req_cnt,
                      self.int_cmp_cnt, SB_REQ_RELAYED)
    self._check_relay("Checker-B HN-I proxy", self.hni_req_cnt,
                      self.hni_cmp_cnt, SB_REQ_RELAYED)

    if self.route_check:
      self._check_relay("Checker-B HN-I routing", self.hni_route_pred,
                        self.hni_route_obs, SB_REQ_ROUTED)

    self.logger.info(
      "scoreboard summary: incomplete=%d orphan=%d wrong_opcode=%d reuse=%d "
      "data_mismatch=%d relay_mismatch=%d route_mismatch=%d "
      "(reads_skipped_unpredictable=%d)" % (
        self.n_incomplete, self.n_orphan, self.n_wrong_opcode, self.n_reuse,
        self.n_data_mismatch, self.n_relay_mismatch, self.n_route_mismatch,
        self.n_reads_skipped))

    # The MTE tag half on its OWN line, for the same reason the ordered-stream
    # summary below is: appended to the line above it falls past the report
    # server's wrap column, and a wrapped field name is a field nobody can sweep
    # for. tag_checked is on it deliberately -- zero mismatches out of zero
    # comparisons is not a pass, and only the checked count can tell them apart.
    self.logger.info(
      "scoreboard tag summary: tag_checked=%d tag_mismatch=%d "
      "tagop_replay_mismatch=%d tagop_beat_mismatch=%d "
      "(tag_reads_skipped_unpredictable=%d)" % (
        self.n_tag_checked, self.n_tag_mismatch,
        self.n_tagop_replay_mismatch, self.n_tagop_beat_mismatch,
        self.n_tag_reads_skipped))

    # Checker E on its own line, deliberately: appended to the summary above it
    # fell past the report server's wrap column, which split the field name from
    # its value and made the tally impossible to grep for across a regression --
    # exactly the sweep an ordered-stream check needs to prove it is not vacuous.
    self.logger.info(
      "ordered-stream summary: order_violation=%d order_in_order=%d" % (
        self.n_order_violation, self.n_order_checked))

  # Checker E accessors: the violation count for a negative control, and the
  # in-order tally so a positive test can require that the check actually ran.
  def get_order_violation_count(self):
    return self.n_order_violation

  def get_order_checked_count(self):
    return self.n_order_checked

  # ==========================================================================
  # The per-rule report and its export, in the same shape and the same CSV
  # schema as the SVA checkers' -- which is what lets one aggregation script
  # read both and gate on both.
  # ==========================================================================
  def report_checks(self, log=None) -> None:
    log = log or self.logger
    missing = self.not_exercised()
    log.info("VIP_CHI SB CHECK VACUITY: not_exercised=%d of=%d" % (
      len(missing), sum(1 for r in CHECK_IDS_SB if self.rule_enabled(r))))
    for rule in missing:
      # One line per rule: the report server wraps at a fixed column, so a line
      # carrying a list loses everything past the wrap.
      log.info("  SB CHECK NOT EXERCISED  %s" % rule)

  def export_check_csv(self, path: str, run_name: str) -> None:
    """Append this run's scoreboard tallies to the shared check-tally CSV."""
    new = not os.path.exists(path)
    with open(path, "a", encoding="utf-8") as fh:
      if new:
        fh.write("run,bind,check,enabled,severity,passes,fails\n")
      for rule in CHECK_IDS_SB:
        fh.write("%s,%s,%s,%d,%s,%d,%d\n" % (
          run_name, self.get_name(), rule, int(self.rule_enabled(rule)),
          self.chk_severity[rule].name, self.chk_pass[rule],
          self.chk_fail[rule]))

  # Total hard-error count (excludes the advisory reads_skipped / wrong_opcode).
  def total_errors(self):
    return (self.n_incomplete + self.n_orphan + self.n_reuse
            + self.n_data_mismatch + self.n_relay_mismatch + self.n_route_mismatch
            + self.n_order_violation)
