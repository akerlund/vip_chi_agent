################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of sv/vip_chi_sva.sv -- CHI REQ/RSP/DAT protocol checker.
#
# The SV concurrent assertions become a per-clock-edge monitor coroutine, the
# same idiom the vip_axi4_agent sibling uses (py/sva/bind_axi4_rd.py). Every
# reported violation increments `self.errors` and names its rule and its
# IHI 0050 clause; tests assert errors == 0.
#
# Two layers, in the order they appear below:
#
#   link        -- judged from a single sample: flit/credit gating on link
#                  state, FLITPEND, reset idle, deactivation, the L-credit
#                  shadow, and the post-reset restart window.
#   transaction -- tracked across cycles: TxnID reuse, write data against its
#                  DBID grant, CompAck ordering, DAT burst placement and beat
#                  counts, completion timeouts, atomic data return, and
#                  ordered-read receipts.
#
# The SV transaction checks live in an always_ff, so within one cycle every
# state read sees the value from the start of that cycle. This port reproduces
# that with _post/_flush rather than mutating in place; see the comment there
# for why it matters.
#
# Start with: cocotb.start_soon(bind_chi(bus).run())
#
# ---------------------------------------------------------------------------
# X-propagation checks are absent BY DESIGN
# ---------------------------------------------------------------------------
# Verilator is 2-state, so a net cannot hold X and a check for it could never
# fire. Three SV checks are therefore not ported, and are listed here so the
# omission is a recorded decision rather than a gap someone re-derives later:
#
#   p_req_known_when_valid   "txreqflit contains X/Z while valid"
#   p_rsp_known_when_valid   "txrspflit contains X/Z while valid"
#   p_dat_known_when_valid   "txdatflit contains X/Z while valid"
#
# Everything else in vip_chi_sva.sv has a 2-state meaning and is portable.
#
# ---------------------------------------------------------------------------
# Severity control is deliberately NOT ported
# ---------------------------------------------------------------------------
# The AXI4 sibling routes its checks through a registry offering per-rule
# disable/warn. The CHI SV checker has no such package -- it reports through
# plain $error -- so building one here would give the Python port a control
# plane the SV port lacks, which is the exact divergence this layer exists to
# prevent. A plain counter, and a per-rule tally for the summary, matches the
# SV behaviour. If severity control is wanted, it belongs in sv/ first.
#
################################################################################

from __future__ import annotations

import logging
import os
import subprocess

from cocotb.triggers import RisingEdge

from sva.check_spec import check_spec
from vip_chi_types_pkg import (
  CHECK_IDS,
  CHECK_IDS_MAIN,
  CHECK_IDS_SV_ONLY,
  CheckSeverity,
  DatOpcode,
  Issue,
  LasmState,
  ReqOpcode,
  ReqOrder,
  RespErr,
  Role,
  RspOpcode,
  chi_xfer_dat_beats,
  exp_comp_ack_required, exp_comp_ack_prohibited,
  flit_layout,
  lasm,
  lasm_legal_step,
  atomic_size_legal,
  req_order_legal,
  req_attr_combination_legal,
  req_allocate_permitted,
  req_likely_shared_permitted,
  req_size_fixed_64b, REQ_SIZE_64B,
  comp_resp_legal,
  req_excl_permitted, req_endian_applicable, req_tagop_permitted_mask,
  req_return_nid_applicable, req_return_txn_id_applicable,
  dat_home_nid_applicable, dat_cbusy_applicable,
  SnpAttrReq, snp_attr_requirement, req_bit17_is_dodwt,
  req_opcode_is_atomic,
  req_opcode_is_atomic_compare,
  req_opcode_is_coherent_read,
  req_opcode_is_coherent_write_data,
  req_opcode_is_coherent_rsp_only,
  req_has_modeled_completion,
  req_completion_uses_dat,
  is_final_rsp_completion,
  PLAIN_COMPLETION_RSP_OPCODES_C,
  req_opcode_is_atomic_returning_data,
  req_opcode_is_combined_write_cmo,
)

# The protocol maximum, not a shadow-counter bound. IHI 0050 E 14.2.1 /
# D 13.2.1: "The minimum number of L-Credits that a receiver can provide is one.
# The maximum number of L-Credits that a receiver can provide is 15." One LCRDV
# signal per channel, so the bound is per channel.
#
# This was 64, which is not a number the specification contains -- and the
# comment that stood here said so, calling it a bound on "the shadow counter, not
# the protocol". At 64 the overflow rule could not fire on any
# conformant-looking peer: a receiver granting 16 through 64 credits was
# over-granting and reported as fine, so the rule was a false NEGATIVE rather
# than a false alarm.
_LCRD_MAX_C = 15
_REQ_SEND_CAP_C = _LCRD_MAX_C
_RSP_SEND_CAP_C = _LCRD_MAX_C
_DAT_SEND_CAP_C = _LCRD_MAX_C

# Cycles allowed between reset release and the link activating, mirroring the
# SV LINK_ACT_WINDOW_P default. Must comfortably exceed
# cfg_agent.link_act_delay_max plus the req->ack handshake.
_LINK_ACT_WINDOW_C = 32

# The four legal LASM edges, in cycle order, mirroring the transition bins of
# cg_lasm in the SV checker.
_LASM_LEGAL_EDGES_C = (
  (LasmState.STOP, LasmState.ACTIVATE),
  (LasmState.ACTIVATE, LasmState.RUN),
  (LasmState.RUN, LasmState.DEACTIVATE),
  (LasmState.DEACTIVATE, LasmState.STOP),
)

# Channels carrying a flit/credit pair in this checker. SNP lives in
# bind_chi_snp.py, matching the SV split across two bind modules.
_CHANNELS_C = ("req", "rsp", "dat")

_CAPS_C = {
  "req": _REQ_SEND_CAP_C,
  "rsp": _RSP_SEND_CAP_C,
  "dat": _DAT_SEND_CAP_C,
}

# Cycles a request may wait for its completion before the checker calls it a
# hang, mirroring the SV TIMEOUT_CYCLES_P default.
_TIMEOUT_CYCLES_C = 1024

# Idle cycles a sender may keep TXSACTIVE up past the close of its outstanding
# window before CHI_TXSACTIVE_DEASSERT_BOUNDED calls it stuck. Deliberately
# loose: a checker watching the wire cannot see the moment the SENDER considers
# a transaction retired, only the moment its last flit went by, so the bound has
# to clear that gap. It is a stuck-signal check, not a latency measurement --
# cfg.txsactive_extend_max_cycles is what a test tightens or extends.
_TXSACTIVE_SETTLE_CYCLES_C = 16

# Which end of a link a bind sits on, which is what decides whether a request
# arrives on rxreq or leaves on txreq. Every transaction-level rule is gated on
# one of these two, so a role in NEITHER leaves a bind checking the structural
# rules only -- enabled, reporting, and silent on everything that needs a
# transaction.
#
# HN-I is a completer, and the SV interface says so in as many words: its
# RN-facing clocking block mirrors snf_cb verbatim because a home node, on the
# link that faces the RN, plays the completer role. Its SN-facing ports are
# separate interfaces declared RNI and land in the requester set on their own.
_REQUESTER_ROLES_C = (Role.RNI, Role.RNF)
_COMPLETER_ROLES_C = (Role.SNF, Role.HNF, Role.HNI)

# Flit fields this checker reads, per channel. Only these are sliced out of the
# raw flit: unpacking the whole DAT flit every beat would drag the multi-hundred
# bit `data` field through a big-int shift for a checker that never looks at it.
_FLIT_FIELDS_C = {
  "req": ("opcode", "txnid", "srcid", "tgtid", "returnnid", "returntxnid",
          "size", "expcompack", "order", "memattr", "snpattr", "likelyshared",
          "excl", "endian", "tagop", "addr", "ns", "allowretry", "pcrdtype",
          "lpid", "mpam", "groupidext"),
  # pcrdtype is read by _credit_grants, not by a field-legality rule: a field
  # this map omits raises KeyError at run time rather than standing its reader
  # down, so every reader of a channel has to be represented here.
  #
  # srcid and tgtid are the in-flight shadow's key, section 2.5's scope. They
  # were ABSENT before that re-key, and their absence is why the SrcID
  # scoping that finding recorded as done had no effect: the reader guarded
  # itself with `"srcid" in f`, got None on every flit, and compared None to
  # None -- so the rule went on enforcing "unique per link", which is stricter
  # than what section 2.5 states. A whitelist that silently yields None is worse
  # than one that raises; the guard is gone with the omission.
  "rsp": ("opcode", "txnid", "srcid", "tgtid", "dbid", "resperr", "resp",
          "pcrdtype"),
  "dat": ("opcode", "txnid", "srcid", "tgtid", "dbid", "dataid", "homenid",
          "cbusy"),
  # Two fields, for one rule: the snoop limb of TXSACTIVE_COVERS_OUTSTANDING
  # needs to pair a snoop with its response, and the TxnID is what pairs them.
  # The opcode is here to tell a snoop from an L-credit return, which carries no
  # transaction and opens no window -- see _snp_flit_or_none. The SNP channel's
  # own rules stay in bind_chi_snp with its own slice map; this is not the
  # beginning of a second snoop checker here.
  "snp": ("opcode", "txnid"),
}

# Opcode classes, mirroring the SV req_opcode_is_* / is_write_* functions.
#
# The four completion classifiers that used to sit here now live in
# vip_chi_types_pkg, imported above. They moved because the raw-injection path
# in the requester driver needs the same answer this checker does, and a second
# copy of it drifts the moment an opcode is classified -- where
# exactly that happened. The sets below are the ones only this checker reads.
_NON_COHERENT_WRITE_OPCODES_C = frozenset({
  int(ReqOpcode.WRITE_NO_SNP_PTL), int(ReqOpcode.WRITE_NO_SNP_FULL),
  int(ReqOpcode.WRITE_NO_SNP_ZERO),
})
_ORDERED_READ_OPCODES_C = frozenset({
  int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP),
})
_WRITE_DAT_OPCODES_C = frozenset({
  int(DatOpcode.NON_COPY_BACK_WR_DATA), int(DatOpcode.NCB_WR_DATA_COMP_ACK),
  int(DatOpcode.COPY_BACK_WR_DATA),
})
_READ_COMPLETION_DAT_OPCODES_C = frozenset({
  int(DatOpcode.COMP_DATA), int(DatOpcode.DATA_SEP_RESP),
})
# Grant responses: each carries a DBID authorizing the write data that follows.
_DBID_GRANT_OPCODES_C = frozenset({
  int(RspOpcode.DBID_RESP), int(RspOpcode.DBID_RESP_ORD),
  int(RspOpcode.COMP_DBID_RESP),
})
# --------------------------------------------------------------------------- #
# The flits that end a snoop transaction, by the channel each arrives on. E
# 14.7.2 / D 13.7.2 names them where it states the ICN's snoop obligation: the
# window is held "until after the final completing flit is sent, which will be
# either SnpResp or SnpRespData".
#
# The Fwded forms are in both sets and belong there. A forwarding snoop sends
# the DATA to the requester, but the snoopee still answers the HOME -- with
# SnpRespFwded when it forwarded clean data, SnpRespDataFwded when the home
# wanted a copy too. Either way the flit that closes the home's window arrives
# on the home's own link, which is the only link this bind can see.
_SNP_RESP_RSP_OPCODES_C = frozenset({
  int(RspOpcode.SNP_RESP), int(RspOpcode.SNP_RESP_FWDED),
})
_SNP_RESP_DAT_OPCODES_C = frozenset({
  int(DatOpcode.SNP_RESP_DATA), int(DatOpcode.SNP_RESP_DATA_PTL),
  int(DatOpcode.SNP_RESP_DATA_FWDED),
})

# Appendix A Table A-4 field legality, for the fields the table marks zero.
#
# Table A-1 gives the vocabulary and the distinction that matters here:
#
#   0     the field is applicable but must be set to zero
#   0 a   the field is INAPPLICABLE to this message and must be set to zero
#   Y     applicable, carries a value -- nothing to assert
#   -     not applicable, and NOT required to be zero -- asserting on it is a
#         false positive waiting for stimulus
#   X     don't care -- likewise not assertable
#
# Only `0` and `0 a` are assertable and they impose the same obligation, so the
# three sets below merge them. `-` and `X` are deliberately absent: that is why
# Persist.DBID, which A-4 marks `-`, is not checked even though the driver copies
# the request's TxnID into it.
#
# Source: IHI0050E_a, Table A-4 Response message field mappings, page A-469.
#
# Two opcodes A-4 also marks are absent because this VIP does not model them:
#   StashDone  TxnID = 0 a   Stash is excluded from this VIP by declaration
#   TagMatch   TxnID = 0 a   Add RspOpcode.TAG_MATCH (0x0A) to the TxnID set
#                            when it is introduced. TagMatch is a response to a
#                            request and so is naturally built by copying the
#                            request's TxnID, which this rule forbids.
# --------------------------------------------------------------------------- #
_A4_TXNID_ZERO_RSP_OPCODES_C = frozenset({
  int(RspOpcode.PERSIST), int(RspOpcode.PCRD_GRANT),
})
# A-4's RespErr column reads `0` for exactly these six: none carries error
# status. The completion that DOES carry it for a write is CompDBIDResp
# (RespErr = Y), which is why a completer must not copy its buffer grant's
# RespErr onto the completion, or the reverse.
_A4_RESPERR_ZERO_RSP_OPCODES_C = frozenset({
  int(RspOpcode.COMP_ACK), int(RspOpcode.RETRY_ACK),
  int(RspOpcode.PCRD_GRANT), int(RspOpcode.READ_RECEIPT),
  int(RspOpcode.DBID_RESP), int(RspOpcode.DBID_RESP_ORD),
})
# Everything above, plus two. CompDBIDResp is the one A-4 marks plain `0` rather
# than `0 a`, and section 4 says why in words: "The Resp field of a Comp or
# CompDBIDResp response must be set to zero for a Write transaction completion"
# -- cache state travels on the WriteData, not on the completion. Persist is
# `0 a`. Comp is NOT here: A-4 gives it Resp = Y, because the same opcode
# completes reads and dataless transactions where the field carries cache state.
_A4_RESP_ZERO_RSP_OPCODES_C = frozenset(
  _A4_RESPERR_ZERO_RSP_OPCODES_C
  | {int(RspOpcode.COMP_DBID_RESP), int(RspOpcode.PERSIST)}
)
# A-4 lists DBID, TagGroupID, StashGroupID and PGroupID as four NAMES over one
# shared group of packet bits; the table header brackets them under a single `CF`
# (combined field) marker. Most rows mark each name separately. PCrdGrant instead
# carries one `0 a` spanning the whole group, which marks the shared field as a
# whole inapplicable and required to be zero.
#
# Only DBID is checked: it is the only one of the four names this VIP models on
# the RSP flit. Persist is deliberately absent -- A-4 gives Persist DBID `-`, not
# applicable and NOT required to be zero, which is why the driver may legally put
# the request's TxnID there.
_A4_DBID_ZERO_RSP_OPCODES_C = frozenset({int(RspOpcode.PCRD_GRANT)})
# The rule's ANTECEDENT: opcodes for which A-4 marks at least one field zero.
# Kept separate from the three sets above, and used as an enclosing guard rather
# than folded into the check, because _chk counts a pass on every call. Fold it
# in and every Comp, DBID grant and SnpResp on the link counts as a pass for a
# rule that never applied to it -- the tally reports thousands of hits, the
# vacuity report calls the rule exercised, and the opcodes it actually governs
# may never have been driven at all.
_A4_ZERO_FIELD_RSP_OPCODES_C = frozenset(
  _A4_TXNID_ZERO_RSP_OPCODES_C
  | _A4_RESPERR_ZERO_RSP_OPCODES_C
  | _A4_RESP_ZERO_RSP_OPCODES_C
  | _A4_DBID_ZERO_RSP_OPCODES_C
)


def _completion_txn_for_req(opcode: int, req_txn_id: int,
                            return_txn_id: int) -> int:
  """The TxnID the completion will carry.

  ReadNoSnpSep returns its data under ReturnTxnID rather than the request's own
  TxnID, so the DAT-side bookkeeping must be keyed by that instead.
  """
  if int(opcode) == int(ReqOpcode.READ_NO_SNP_SEP):
    return int(return_txn_id)
  return int(req_txn_id)


def _expected_completion_dat_opcode(opcode: int) -> int:
  if int(opcode) == int(ReqOpcode.READ_NO_SNP_SEP):
    return int(DatOpcode.DATA_SEP_RESP)
  return int(DatOpcode.COMP_DATA)


def _flit_slices(cfg):
  """{channel: {field: (shift, mask)}} for the fields this checker reads.

  Flits are packed MSB-first, so a field's shift is the total width of every
  field below it.
  """
  out = {}
  for channel, wanted in _FLIT_FIELDS_C.items():
    layout = flit_layout(cfg, channel)
    pos = sum(w for _, w in layout)
    slices = {}
    for name, width in layout:
      pos -= width
      if name in wanted:
        slices[name] = (pos, (1 << width) - 1)
    out[channel] = slices
  return out


# Export tags claimed so far, keyed on (run, tag).
#
# The tag is the ONLY thing in an exported row that says which bind produced it,
# so two binds sharing one tag do not lose rows -- they merge, and every per-bind
# question the export exists to answer is then answered about the wrong
# interface. That is a silent failure: the file is well formed, the row count is
# right, and nothing in it says a name was reused.
#
# Keyed on the run, not the tag alone, for two reasons: the aggregation is a
# union over a whole sweep, so the same tag in every run is the normal case; and
# this flow runs the entire regression in ONE process, so a registry that did not
# reset per run would report a collision on the second test.
_EXPORT_TAGS_CLAIMED: set[tuple[str, str]] = set()


def claim_export_tag(run_name: str, tag: str) -> bool:
  """Claim `tag` for `run_name`. False if some other bind already took it."""
  key = (run_name, tag)
  if key in _EXPORT_TAGS_CLAIMED:
    return False
  _EXPORT_TAGS_CLAIMED.add(key)
  return True


# The revision that produced a tally row, so a cross-source comparison can be
# exact rather than a proxy on file age.
#
# check_vacuity.py compares two ports' CSVs against each other, and both of the
# sections that do so are meaningless if the inputs describe different code. It
# warned on a >1h age gap, which caught the case that had actually happened
# twice -- but age is the wrong measurement: it misses two sweeps run minutes
# apart across a rebuild, and it false-positives on a deliberately archived
# comparison. The revision answers the real question.
#
# "dirty" is appended when the tree has uncommitted changes, because during
# development that is the normal state and two sweeps of the same commit can
# still be of different code. It is a weaker guarantee than the hash and it is
# labelled as one rather than being silently dropped.
#
# Unknown rather than fatal when git is unavailable or this is not a checkout:
# the export is a reporting aid, and a checker that refused to write its tallies
# because it could not name a commit would be worse than one that says so.
_REVISION_CACHE: list[str] = []


def source_revision() -> str:
  if _REVISION_CACHE:
    return _REVISION_CACHE[0]
  rev = "unknown"
  try:
    root = os.path.dirname(os.path.dirname(os.path.dirname(
      os.path.abspath(__file__))))
    head = subprocess.run(["git", "-C", root, "rev-parse", "--short", "HEAD"],
                          capture_output=True, text=True, timeout=10)
    if head.returncode == 0:
      rev = head.stdout.strip()
      status = subprocess.run(["git", "-C", root, "status", "--porcelain"],
                              capture_output=True, text=True, timeout=10)
      if status.returncode == 0 and status.stdout.strip():
        rev += "-dirty"
  except (OSError, subprocess.SubprocessError):
    pass
  _REVISION_CACHE.append(rev)
  return rev


class bind_chi:
  """CHI link-layer protocol checker for one interface.

  Sampling discipline: every check reads the values captured at a rising edge,
  so a rule expressed in SV as `a |-> b` becomes "if a, require b" on the same
  sample, and one expressed as `a |=> b` compares the previous sample against
  the current one.
  """

  def __init__(self, bus, name: str = "bind_chi",
               checks_enable: bool | None = None,
               enable_completion_timeout: bool = True,
               multi_source_link: bool = False,
               txsactive_from_link_up: bool = False,
               hand_driven_link: bool = False,
               timeout_cycles: int = _TIMEOUT_CYCLES_C,
               tb_cfg=None):
    self.bus = bus
    self.log = logging.getLogger(name)
    self.errors = 0
    # Per-rule fire counts, so a summary can say which rule fired rather than
    # only how many times something did.
    self.fail_count: dict[str, int] = {}
    self.pass_count: dict[str, int] = {}
    self.init_check_control()
    # None means "gate on this interface's own link activity", mirroring the
    # inline checks_enable expression on each SV bind: an interface whose agent
    # never activates its link raises no spurious violations. A bool forces the
    # gate, which is what the negative-control test uses.
    self._checks_enable = checks_enable
    self._lcrd = {}
    # An observed, unresolved input race, and what it was. See
    # _check_input_race: the state is what distinguishes a race from an ordinary
    # step, because the four input combinations are all legal Rx states.
    self._input_race_pending = False
    self._input_race_why = ""
    # Sticky "this interface has carried link traffic at least once". Gates the
    # reset-restart check only; deliberately NOT cleared by _reset_state, since
    # surviving reset is exactly what makes it usable as that gate.
    self._link_ever_active = False

    # The completion timeout stands down on a link whose completions this
    # checker cannot see end to end -- a coherent RN-F link, where the HN-F may
    # answer from another RN-F's snoop data. Mirrors ENABLE_COMPLETION_TIMEOUT_P.
    self._enable_completion_timeout = enable_completion_timeout
    # A rule this checker was constructed without is not enabled here either.
    # check_enable is what the tally CSV exports as the `enabled` column, so
    # leaving it True publishes a rule that CANNOT evaluate on this bind as one
    # that is enabled and simply never fired -- the difference between "this
    # link stands this check down on purpose" and "this check found no traffic",
    # which a vacuity report cannot recover from the outside.
    #
    # Set here rather than in init_check_control, which runs before this
    # attribute exists. Mirrors ENABLE_COMPLETION_TIMEOUT_P in the SV bind,
    # which gates the same single rule.
    if not enable_completion_timeout:
      self.check_enable["CHI_COMPLETION_FOLLOWS_REQ"] = False

    # `multi_source_link` no longer stands the TxnID-reuse rules down. It used
    # to, because the shadow was keyed by TxnID alone and could not hold two
    # sources' claims on the same value at once -- which section 2.5 makes a
    # legal situation, so the rule had to be silent rather than wrong. The
    # shadow is now keyed by (SrcID, TxnID) and represents it directly, so a
    # fan-in link is CHECKED instead of excused.
    #
    # The parameter is kept: it still records that a link carries more than one
    # source, which is a fact about the topology rather than about this rule,
    # and removing it would silently change every testbench that sets it.

    # This endpoint drives TXSACTIVE from link-up rather than from its
    # outstanding window, so the sideband is a constant while the link is up.
    # Legal -- section 14.7.2's obligation is a lower bound -- but exactly what
    # TXSACTIVE_DEASSERT_BOUNDED exists to report, so it would fire on every run
    # rather than on a defect. The driver behavior is.
    if txsactive_from_link_up:
      self.check_enable["CHI_TXSACTIVE_DEASSERT_BOUNDED"] = False

    # This link is driven by a testcase directly, without the driver's credit and
    # FLITPEND machinery. It raises FLITV with no preceding FLITPEND, consumes
    # credit that was never granted, and never retires the transaction it starts,
    # so the flit-protocol rules report facts about the testcase rather than about
    # the VIP. LASM, reset-idle, known-when-valid and link gating stay live.
    #
    # Only the SV harness has such a link today (the A0 smoke pair). The keyword
    # exists here so the two ports' checker APIs stay the same shape, which is
    # what stops the next hand-driven link from being bound in one port only.
    if hand_driven_link:
      for _rule in ("CHI_REQ_VALID_REQUIRES_PEND", "CHI_RSP_VALID_REQUIRES_PEND",
                    "CHI_DAT_VALID_REQUIRES_PEND", "CHI_LCRD_OVERFLOW",
                    "CHI_LCRD_UNDERFLOW", "CHI_LCRD_QUIESCENT_IN_STOP",
                    "CHI_TXNID_REUSE_REQUESTER", "CHI_TXNID_REUSE_COMPLETER",
                    "CHI_TXSACTIVE_COVERS_OUTSTANDING",
                    "CHI_TXSACTIVE_DEASSERT_BOUNDED"):
        self.check_enable[_rule] = False
    self._timeout_cycles = timeout_cycles
    # Read live each cycle rather than latched at build, mirroring the SV top,
    # which re-reads tb_cfg every clock so a testcase can raise the knob before
    # its traffic starts.
    self.tb_cfg = tb_cfg

    role = getattr(bus, "role", None)
    self._is_requester = role in _REQUESTER_ROLES_C
    self._is_completer = role in _COMPLETER_ROLES_C
    self._is_rni = role == Role.RNI
    self._is_snf = role == Role.SNF
    # The direction a completion travels on: inbound at a requester, outbound at
    # a completer. Requests travel the other way.
    self._req_dir = "tx" if self._is_requester else "rx"
    self._completion_dir = "rx" if self._is_requester else "tx"

    self._slices = _flit_slices(bus.cfg)
    self._data_id_mask = (1 << bus.cfg.data_id_width) - 1
    self._data_bytes = bus.cfg.data_bytes
    # Cached with the other cfg-derived values rather than read at check time:
    # the REQ bit-17 rule needs the issue on every request, and reaching through
    # self.bus mid-check couples a pure classifier to bus liveness.
    self._issue = bus.cfg.issue

    # LASM coverage accumulates over the whole run and is deliberately NOT
    # cleared by _reset_state: a link that was torn down and brought back up
    # covered those edges, and forgetting them at the reset would understate
    # what the run exercised. Seeded by init_check_control below.

    self._reset_state()

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------
  @staticmethod
  def _inflight_key(src, txn):
    """The in-flight shadow's key: (SrcID, TxnID), section 2.5's scope.

    Indexed rather than `.get()`: both fields are in _FLIT_FIELDS_C, and if one
    is ever dropped from it this must raise where the omission happened rather
    than quietly key everything on None -- which is precisely the failure this
    re-key was built to undo.
    """
    return (int(src), int(txn))

  def _chk(self, rule: str, ok: bool, msg: str) -> None:
    """One check site: count the evaluation, and report it if it did not hold.

    `ok` is the violation predicate negated under the enclosing guard -- the
    guard is the antecedent. A condition that IS the antecedent belongs in an
    enclosing `if`, not folded in here, or the pass would be counted on traffic
    the rule never applied to and the rule would look exercised in a run that
    never reached it.

    A DISABLED rule is skipped entirely -- neither pass nor fail is counted --
    so the vacuity report shows it as not exercised rather than as quietly
    holding. A rule at severity OFF is different: it still evaluates and still
    counts, and only its report is suppressed. Conflating the two would make
    "I turned this down" read the same as "this never ran".
    """
    if not self.check_enable.get(rule, True):
      return
    if ok:
      self.pass_count[rule] = self.pass_count.get(rule, 0) + 1
    else:
      self._err(rule, msg)

  def _err(self, rule: str, msg: str) -> None:
    # The clause comes from the rule, not from the call site: see
    # sva/check_spec.py. A rule that claims no clause -- the X/Z ones --
    # reports without a reference rather than with an empty one.
    where = check_spec(rule)
    where = f" IHI 0050 {where}." if where else ""
    self.fail_count[rule] = self.fail_count.get(rule, 0) + 1
    severity = self.check_severity.get(rule, CheckSeverity.ERROR)
    if severity is CheckSeverity.OFF:
      # Counted, not reported, and not a run failure. This is what a negative
      # control uses to prove its rule fires: the tally still moves, so the test
      # can assert on it, but the deliberate violation does not read as a bug.
      # Logged at info so the run still SHOWS what happened -- silence here would
      # make a provoked failure and a suppressed real one look identical.
      self.log.info(f"EXPECTED {rule}: {msg}.{where}")
      return
    if severity is CheckSeverity.WARNING:
      # Demoted by the USER, so it must not fail the run -- but it is still a
      # violation and still visible, unlike OFF.
      self.log.warning(f"{rule}: {msg}.{where}")
      return
    self.errors += 1
    self.log.error(f"{rule}: {msg}.{where}")

  # ---------------------------------------------------------------------------
  # Per-check control
  # ---------------------------------------------------------------------------
  def init_check_control(self) -> None:
    """Seed the per-check enable and severity maps, then apply the environment.

    A separate method rather than inline in __init__ because tc_chi_sva_smoke
    builds a checker through __new__ to drive the check functions directly
    without a bus. Every field the registry needs therefore has to be reachable
    from one call the hand-built path can make too -- otherwise each new field
    added here silently breaks that test with an AttributeError, which is
    exactly what happened twice while this was being written.

    Seeded from the whole canonical registry rather than filled in as rules
    fire, so a rule can be disabled before it has ever been evaluated -- and so
    the vacuity report has the full universe to compare against.
    """
    self.check_enable: dict[str, bool] = {r: True for r in self._owned_rules()}
    self.check_severity: dict[str, CheckSeverity] = {
      r: CheckSeverity.ERROR for r in self._owned_rules()
    }
    self._lasm_state_seen = {st: 0 for st in LasmState}
    self._lasm_edge_seen = {edge: 0 for edge in _LASM_LEGAL_EDGES_C}

    self._apply_check_plusargs()

  @staticmethod
  def _owned_rules():
    """The rules this checker is responsible for reporting on.

    Split from the full registry so each checker's vacuity report lists only its
    own rules: bind_chi has nothing to say about whether the SNP channel was
    exercised, and printing the other's rules as "not exercised" would be a
    false alarm on every non-coherent run.

    The X/Z rules are excluded for the same reason rather than reported as
    never exercised: Verilator is 2-state, so this port cannot own them at all,
    and listing them would put four permanent entries in a report whose value
    depends on the reader treating every entry as worth chasing.
    """
    return tuple(r for r in CHECK_IDS_MAIN if r not in CHECK_IDS_SV_ONLY)

  def _apply_check_plusargs(self) -> None:
    """Honour VIP_CHI_DISABLE_CHECK / VIP_CHI_WARN_CHECK from the environment.

    The SV port reads plusargs; cocotb has no plusarg equivalent that reaches a
    plain coroutine, so the environment is the analog. Same names, same
    comma-separated value, so a run script can set one variable and drive both
    flows.

    An unknown name is a hard error rather than a shrug: the entire value of
    naming checks is that you can address one, and a silently-ignored typo means
    the user believes a check is off when it is still firing -- or worse,
    believes it is on when they meant to disable it.
    """
    for var, apply in (
      ("VIP_CHI_DISABLE_CHECK", self.disable_check),
      ("VIP_CHI_WARN_CHECK", self.warn_check),
    ):
      raw = os.environ.get(var, "")
      for name in (n.strip() for n in raw.split(",") if n.strip()):
        if name not in CHECK_IDS:
          raise ValueError(
            f"{var} names an unknown check '{name}'; "
            f"see vip_chi_types_pkg.CHECK_IDS for the {len(CHECK_IDS)} valid names")
        if name in self.check_enable:
          apply(name)

  def disable_check(self, rule: str) -> None:
    """Stop evaluating a rule entirely: no reports, and no pass or fail counts."""
    self.check_enable[rule] = False

  def warn_check(self, rule: str) -> None:
    """Keep evaluating and counting a rule, but report it as a warning."""
    self.check_severity[rule] = CheckSeverity.WARNING

  def off_check(self, rule: str) -> None:
    """Keep evaluating and counting a rule, but do not report it at all."""
    self.check_severity[rule] = CheckSeverity.OFF

  def export_check_csv(self, path: str, run_name: str) -> None:
    """Append this checker's per-rule tallies to a CSV for cross-run aggregation.

    A regression answers "which check does NOTHING anywhere" only by unioning
    every run, and no single run can tell you. Scraping the logs is not an
    option: run.py --all prints a status table, not the per-test output, so the
    summary lines exist only inside individual runs. Hence a machine-readable
    file the runs append to and a script reads.

    Appending rather than rewriting is what makes the union work: each test adds
    its rows and the aggregation is a group-by. Rows carry the run name so a
    rule exercised by exactly one testcase can be traced back to it -- which is
    the question you actually ask when a check turns out to be near-vacuous.
    """
    if not claim_export_tag(run_name, self.log.name):
      self.errors += 1
      self.log.error(
        f"check-tally tag '{self.log.name}' was exported twice in run "
        f"{run_name}: two binds under one name merge into one set of rows, and "
        f"every per-bind question asked of the export afterwards is answered "
        f"about the wrong interface")

    rev = source_revision()

    new = not os.path.exists(path)
    with open(path, "a", encoding="utf-8") as fh:
      if new:
        fh.write("run,bind,check,enabled,severity,passes,fails,rev\n")
      for rule in self._owned_rules():
        fh.write(
          f"{run_name},{self.log.name},{rule},"
          f"{int(self.check_enable.get(rule, True))},"
          f"{self.check_severity.get(rule, CheckSeverity.ERROR).name},"
          f"{self.pass_count.get(rule, 0)},{self.fail_count.get(rule, 0)},"
          f"{rev}\n")

  def export_opcode_csv(self, path: str, run_name: str) -> None:
    """Append the REQ opcodes this bind observed, for the opcode-evidence gate.

    A companion export rather than a column on the tally CSV, and deliberately:
    the tally file is keyed (run, bind, check) and three gates already read it,
    so widening it to (run, bind, check, opcode) would multiply every row by the
    opcode space to carry a fact that has nothing to do with which CHECK ran.
    """
    new = not os.path.exists(path)
    with open(path, "a", encoding="utf-8") as fh:
      if new:
        fh.write("run,bind,opcode,seen\n")
      for opcode in sorted(self._req_opcode_seen):
        fh.write(f"{run_name},{self.log.name},0x{opcode:02x},"
                 f"{self._req_opcode_seen[opcode]}\n")

  def not_exercised(self):
    """This checker's rules that were neither passed nor failed, in registry order.

    A clean regression only means something if the checks actually ran. A rule
    with zero passes AND zero fails did not run, and is indistinguishable from a
    rule that was deleted -- which is the failure mode this exists to surface.
    Disabled rules are excluded: they did not run BY REQUEST, and reporting them
    would train the reader to ignore the list.
    """
    return [r for r in self._owned_rules()
            if self.check_enable.get(r, True)
            and not self.pass_count.get(r, 0)
            and not self.fail_count.get(r, 0)]

  def expect_failure(self, rule: str) -> None:
    """Declare that this run deliberately provokes `rule`, so it must not fail.

    A negative control has to be able to say WHICH rule it is breaking. Waiving
    the whole checker instead would let a second, unintended violation ride along
    unnoticed inside the test whose entire purpose is to prove one rule fires.

    This IS severity OFF, and is spelled as a separate call only because that is
    what a test means. Keeping a parallel expected-failures set alongside the
    severity map was one concept too many: the CSV export recorded such a run as
    a genuine ERROR-severity failure, so the regression aggregation reported the
    negative control as a bug.
    """
    self.check_severity[rule] = CheckSeverity.OFF

  def rule_names(self):
    return sorted(set(self.pass_count) | set(self.fail_count))

  def report(self, log=None) -> None:
    """End-of-test summary, one line per rule that was evaluated."""
    log = log or self.log
    names = self.rule_names()
    if not names:
      log.info("[VIP_CHI_CHECK] no protocol checks were evaluated")
      return
    log.info("VIP_CHI CHECK SUMMARY")
    for rule in names:
      fails = self.fail_count.get(rule, 0)
      sev = self.check_severity.get(rule, CheckSeverity.ERROR)
      tag = "[FAILING]" if fails else "[exercised]"
      if not self.check_enable.get(rule, True):
        tag = "[disabled]"
      elif sev is not CheckSeverity.ERROR:
        tag += f"[{sev.name.lower()}]"
      log.info(f"  {rule:<38s} pass={self.pass_count.get(rule, 0):>7d}  "
               f"fail={fails:>5d}  {tag}")

    # The half of the summary that a clean run cannot show you any other way.
    # Every rule this checker owns that was neither passed nor failed did not
    # run, and a rule that never runs is indistinguishable from one that was
    # deleted. Printed even when empty, and with the count on the same line, so
    # a regression-wide sweep is a grep rather than a parse -- and so an empty
    # list reads as "checked, none" rather than as a section that failed to
    # print.
    missing = self.not_exercised()
    log.info(f"VIP_CHI CHECK VACUITY: not_exercised={len(missing)} "
             f"of={len(self._owned_rules())}")
    for rule in missing:
      why = CHECK_IDS_SV_ONLY.get(rule)
      log.info(f"  NOT EXERCISED  {rule}"
               + (f"  (SV-only: {why})" if why else ""))

    # One line, so a regression-wide sweep for an edge this run never walked is
    # a grep rather than a parse. Kept short for the same reason the check
    # tallies are: the report server wraps long lines, and a wrapped field name
    # is a field nobody can sweep for.
    states = " ".join(f"{st.name}={self._lasm_state_seen[st]}" for st in LasmState)
    edges = " ".join(f"{a.name}->{b.name}={self._lasm_edge_seen[(a, b)]}"
                     for a, b in _LASM_LEGAL_EDGES_C)
    log.info(f"VIP_CHI LASM COVERAGE: {states}")
    log.info(f"VIP_CHI LASM EDGES: {edges}")

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------
  def _reset_state(self) -> None:
    self._reset_tracking_state()

    # An input race cannot survive a reset: both peers drive the sideband low
    # while rst_n is asserted (14.1.3), so whatever was in flight is gone and a
    # flag carried across would demand stable outputs through the bring-up that
    # follows.
    self._input_race_pending = False
    self._input_race_why = ""

    # The L-credit shadow. One pool per channel per direction, each starting at
    # 0 and capturing its initial pool automatically, because that pool arrives
    # as real LCRDV pulses on the wire once the link activates.
    #
    # Cleared on RESET ONLY -- deliberately, and unlike the rest of the tracked
    # state, which _reset_tracking_state also clears whenever the enable gate
    # goes low. Under that gate these counters were zeroed the moment the link
    # left RUN, which made CHI_LCRD_QUIESCENT_IN_STOP unable to fail: the gate
    # emptied the counts on the way into DEACTIVATE, so by the time the link
    # reached STOP the rule was asking whether zero equalled zero. The one rule
    # whose entire job is to catch credits stranded by a tear-down was blind to
    # every tear-down.
    #
    # Surviving the gap is also what makes the counts MEAN anything across it: a
    # credit granted before a link went down is exactly the credit that must not
    # still be banked after it, and a counter that forgets at the boundary cannot
    # say so.
    self._lcrd = {f"{d}{ch}": 0 for d in ("tx", "rx") for ch in _CHANNELS_C}

    self._act_countdown = None
    # The LASM restarts from STOP out of reset, which the reset-idle rule
    # already requires the sideband to be holding.
    # One registered state and dwell per machine. See _tx_lasm_of / _rx_lasm_of:
    # "stuck waiting for an acknowledge" is a claim about ONE direction, and the
    # OR could make it a claim about neither.
    self._tx_lasm = LasmState.STOP
    self._tx_lasm_dwell = 0
    self._rx_lasm = LasmState.STOP
    # Cycles in which the two machines were in DIFFERENT states. This is the
    # non-vacuity evidence for the split itself: while the two were OR-collapsed
    # into one state, a divergence could not be represented at all, so a rule
    # judging them separately is unfalsifiable without a run that actually drove
    # them apart. A control asserts on this rather than assuming the stimulus
    # reached the case.
    self._lasm_divergent_cycles = 0

    # Which REQ opcodes this bind actually saw, and how often.
    #
    # The runtime half of the opcode-evidence axis. The classifiers that gate
    # REQ-derived rules are pure functions of the opcode, so WHAT they answer is
    # already resolvable statically -- scripts/check_classifier_coverage.py does
    # exactly that. What no artifact knew is which opcodes the regression
    # actually DRIVES, and that is the half that makes an unclaimed opcode
    # actionable rather than theoretical: an opcode no classifier claims and
    # nothing drives costs nothing, while the same opcode driven thousands of
    # times means every gated rule stood down for real traffic. That second case
    # is this finding's defect, and it was invisible because the tally CSV has no
    # opcode dimension at all.
    self._req_opcode_seen: dict[int, int] = {}

    # Which transaction currently owns each (requester, DBID) pair, for section
    # 2.5's DBID-uniqueness rule. The value is the in-flight key, so ownership
    # expires with the transaction rather than needing a retire hook of its own:
    # a DBID is in use for exactly as long as its transaction is outstanding,
    # which is the window the rule is written over.
    self._dbid_owner: dict[tuple, tuple] = {}
    # Whether ACTIVATE has been observed since this LASM last left RUN. The
    # legal-step rule judges one step at a time and cannot express "the link
    # went up through ACTIVATE", which is a claim about the whole activation.
    self._tx_activate_seen = False
    self._rx_activate_seen = False
    self._rx_lasm_dwell = 0

  def _reset_tracking_state(self) -> None:
    """Everything the SV always_ff clears on `!checks_enable || !rst_n`.

    Split out from _reset_state because the restart-window countdown must NOT
    be cleared here: it arms at reset release, the one moment the link is
    guaranteed idle and therefore the enable gate is low. Clearing it on the
    disable path would disarm the check on the very cycle it was armed.
    """
    # Keyed by (SrcID, TxnID), not by TxnID alone. Section 2.5 scopes uniqueness
    # to a source -- "The Requester is identified by the SrcID" -- so two
    # requesters holding the same TxnID at once is legal and a TxnID-indexed
    # shadow cannot represent it. It used to be one slot per value with a
    # parallel map of the LAST claimant, which made the second source overwrite
    # the first: A takes 0, B takes 0, A's completion frees the slot, and A
    # reusing 0 with its own request still outstanding passed.
    #
    # The key is read from a different field at each end of a transaction. A
    # request carries the requester in SrcID; every response and data flit that
    # retires one is TARGETED at that requester, so its TgtID is the same node.
    self._req_inflight = {}
    # Which TxnIDs a request has actually put on the wire, tracked SEPARATELY
    # from _req_inflight and deliberately so.
    #
    # _req_inflight is set only for req_has_modeled_completion's opcodes,
    # because what it exists for is pairing a request with the completion that
    # retires it. CHI_RSP_RETRY_ACK_TXN_ID asks a different question -- did any
    # request carry this TxnID -- and gating it on that whitelist would make a
    # RetryAck for a coherent read unjudgeable rather than judged.
    #
    # Cleared on the RetryAck that consumes it and nowhere else. That leaves the
    # rule blind to a stray RetryAck naming a TxnID whose transaction completed
    # normally, and blind is the right direction: the alternative is a clear in
    # every completion path, and a slot cleared one step early would false-fail
    # the legitimate RetryAck that a permissive rule simply misses.
    self._req_txn_id_seen = {}
    # Section 2.5's DBID-equality rule needs two things a completion flit does
    # not carry: what DBID the SEPARATE grant named, and whether the request was
    # an Atomic. Both keyed like the in-flight shadow, on (requester, TxnID) --
    # a grant and the Comp that follows it belong to one transaction at one
    # requester, and on a fan-in link the TxnID alone does not say which.
    #
    # A grant is recorded only for the SEPARATE forms. CompDBIDResp is the
    # combined message and carries the only DBID the transaction ever has, so
    # there is nothing for a later Comp to disagree with, and recording it would
    # arm the rule against a Comp belonging to some other transaction that
    # happened to reuse the TxnID.
    self._write_grant_dbid = {}
    self._req_is_atomic = {}
    # P-Credits this link has seen granted and not yet seen spent, per PCrdType,
    # with the same accumulator split as the SV checker and for the same reason:
    # a grant can land in the cycle a credit is spent, and _post defers absolute
    # values, so two writes in one cycle would lose one of them.
    #
    # Counted rather than flagged because section 2.6.5 is explicit that "there
    # is no fixed relationship between credits and particular transactions" -- a
    # requester holding several grants of one type picks freely which bounced
    # transaction to re-issue against which. A count is the most the wire
    # supports, and a request spending a credit nobody granted is visible in it.
    self._pcrd_held = {}
    self._pcrd_delta = {}
    # Which SrcID owns the TxnID currently occupying each slot.
    #
    # IHI 0050 E section 2.5 scopes the uniqueness rule to a source and says so
    # twice over: "It is required that the TxnID, except for PrefetchTgt, must be
    # unique for a given Requester. The Requester is identified by the SrcID."
    # Two requests carrying the same TxnID from DIFFERENT SrcIDs are therefore
    # legal and ordinary -- and unavoidable on a link where more than one
    # requester's traffic converges, because each allocates from its own pool.
    #
    # Without this the reuse rules read the spec as "unique per link", a stricter
    # rule than the one written. It went unnoticed because no bind sat on a fan-in
    # link until a later change bound the HN-I proxy's SN-facing ports.
    self._req_exp_comp_ack = {}
    self._completion_seen = {}
    self._write_grant_seen_by_dbid = {}
    self._expected_write_beats_by_txn = {}
    self._expected_write_beats_by_dbid = {}
    self._expected_write_valid_by_dbid = {}
    self._expected_completion_beats_by_txn = {}
    self._expected_completion_opcode_by_txn = {}
    self._expected_completion_valid_by_txn = {}
    self._dat_completion_req_valid_by_txn = {}
    self._dat_completion_req_txn_by_txn = {}

    # Read-completion DAT beats seen so far, per direction and per TxnID -- see
    # _retire_dat_transfer for why this is counted per transfer rather than read
    # off the FLITPEND run.
    self._dat_beats_by_txn = {"tx": {}, "rx": {}}

    self._burst = {
      d: {"active": False, "txn_id": 0, "expected_data_id": 0, "count": 0,
          "opcode": int(DatOpcode.COMP_DATA)}
      for d in ("tx", "rx")
    }

    # In-flight temporal attempts, one record per armed SV property thread.
    self._pending_completion = []
    self._pending_atomic = []
    self._pending_ordered = []

    # Snoops this endpoint has sent and not yet seen answered, keyed on the
    # snoop's TxnID, plus the SnpRespData beats seen so far for each. Keyed
    # rather than counted so a SnpDVMOp -- two SNP flits carrying one TxnID and
    # answered by one SnpResp -- opens one window and not two.
    self._snp_inflight = {}
    self._snp_dat_beats = {}
    # The receiving window's shadow, and the extra registered stage that carries
    # its assertion allowance. See _observe_snoop_rx_window.
    self._snp_rx_inflight = {}
    self._snp_rx_dat_beats = {}
    self._snp_rx_landed = None

    # TXSACTIVE over-assertion tracking: consecutive fully-idle cycles with the
    # sideband still up, and a latch so one stuck episode reports once rather
    # than once per cycle.
    self._txsactive_idle_cycles = 0
    self._txsactive_reported = False

    self._nba = []

  # ---------------------------------------------------------------------------
  # Deferred state updates
  # ---------------------------------------------------------------------------
  # The SV checks live in an always_ff, so every state read in a cycle sees the
  # value from the START of that cycle and every write lands at the end of it.
  # Reading the dicts directly and posting writes here reproduces that: without
  # it, a request and the response that consumes its bookkeeping arriving in the
  # same cycle would see each other's updates and the checks would disagree with
  # the SV port on exactly the traffic that is hardest to reason about.
  def _post(self, target: dict, key, value) -> None:
    self._nba.append((target, key, value))

  def _flush(self) -> None:
    for target, key, value in self._nba:
      target[key] = value
    self._nba = []

  # ---------------------------------------------------------------------------
  # Link state predicates, mirroring the SV functions of the same names.
  # ---------------------------------------------------------------------------
  @classmethod
  def _link_is_active(cls, s: dict) -> bool:
    """Anywhere but STOP -- i.e. ACTIVATE, RUN or DEACTIVATE.

    Kept as a sample-level predicate rather than read off the tracked state
    because two callers need the answer for a sample other than the current one.
    """
    return cls._lasm_of(s) is not LasmState.STOP

  @property
  def lasm_divergent_cycles(self) -> int:
    """Cycles in which this endpoint's two link machines differed. See the
    counter's declaration in __init__ for why a control asserts on it."""
    return self._lasm_divergent_cycles

  @staticmethod
  def _tx_lasm_of(s: dict) -> LasmState:
    """This endpoint's TRANSMIT-link state: our own request, their acknowledge.

    E section 14.6.1 / D 13.6.1 defines the two machines by the direction of the
    PAYLOAD -- TXLINK is every channel whose payload is an output of this
    component -- and makes the TXLINK state "controlled by" this component.
    Section 14.5.1 is explicit about the count: "An entire interface uses a
    total of four signals, two signals are used for all the transmit channels
    and two signals are used for all the receive channels."
    """
    return lasm(s["txlinkactivereq"], s["rxlinkactiveack"])

  @staticmethod
  def _rx_lasm_of(s: dict) -> LasmState:
    """This endpoint's RECEIVE-link state: their request, our acknowledge.

    Section 14.6.1: the RXLINK state "is controlled by the component on the
    other side of the interface", which is why the request term is an input here
    and an output in the transmit twin.
    """
    return lasm(s["rxlinkactivereq"], s["txlinkactiveack"])

  @staticmethod
  def _lasm_of(s: dict) -> LasmState:
    """"Anything is up", which is the right gate for the CHANNEL rules.

    NOT the handshake state any more -- see _tx_lasm_of / _rx_lasm_of. A flit may
    cross as soon as its own direction is running, and the credit rules need the
    link out of STOP in either direction, so this stays a reduction. The
    per-direction distinction matters to the handshake rules, not to the question
    "is this interface carrying anything".

    The paragraphs below are kept because they record WHY one machine was
    correct until now, and that reason is exactly what changed: the completer
    never raised a request of its own, so half the signals were identically
    zero and the OR was exact. With both handshakes live it is no longer a
    faithful reduction of either machine -- it hides an aborted activation
    behind the other direction's request.

    ONE state machine per link, not one per direction. The link adapter mirrors
    both sideband signals to both endpoints -- the requester-polarity endpoint
    drives LINKACTIVEREQ and the completer-polarity one drives LINKACTIVEACK,
    and each is copied to the other side -- so a link carries a single
    activation handshake that both endpoints observe, not two independently
    activated directions. Modelling it as two would leave one of them wired to a
    request nobody ever raises, permanently in STOP, and every flit the peer
    sent across it would look like a violation.

    Which of the two request signals is live depends on this endpoint's
    polarity, and polarity is not a function of role alone (an HN-I port takes
    either, depending on which side it faces). The OR is exact rather than a
    heuristic: at any endpoint the signal of each pair that is not the live one
    is identically zero, so `req_either` is the link's request and `ack_either`
    its acknowledge, whichever end this bind sits on.

    This is the same expression the retired link_is_running() and
    link_is_active() predicates were built from, so both map onto the new state
    exactly -- running == (state is RUN), active == (state is not STOP) -- and
    replacing them changes no verdict. What the state adds is the distinction
    those predicates could not draw: ACTIVATE from DEACTIVATE, and therefore
    which transitions are legal.
    """
    return lasm(s["txlinkactivereq"] or s["rxlinkactivereq"],
                s["txlinkactiveack"] or s["rxlinkactiveack"])

  # ---------------------------------------------------------------------------
  def _sample(self) -> dict:
    g = self.bus.get_or
    names = ["txlinkactivereq", "txlinkactiveack", "txsactive",
             "rxlinkactivereq", "rxlinkactiveack", "rxsactive",
             # The snoop valids, for link_quiet alone. Sampled here rather than
             # read from the bus at the check, because every other signal this
             # checker judges comes from one snapshot per edge and a mixed read
             # would compare values from two different points in the cycle.
             # `get_or` yields 0 on a role with no snoop channel.
             "txsnpflitv", "rxsnpflitv"]
    for ch in _CHANNELS_C:
      names += [f"tx{ch}flitv", f"tx{ch}flitpend", f"tx{ch}lcrdv",
                f"rx{ch}flitv", f"rx{ch}flitpend", f"rx{ch}lcrdv"]
    s = {n: g(n) for n in names}
    # The outbound snoop's fields, on the cycle it is presented. Only tx: the
    # snoop window below is the SENDER's obligation, and only an ICN-facing
    # endpoint transmits snoops, so the direction scopes the arm to the vantage
    # that owes the window without needing a role predicate. `get_or` yields 0
    # for txsnpflitv on a role with no snoop channel, so this never fires there.
    s["txsnpflit"] = self._snp_flit_or_none("tx", s["txsnpflitv"])
    # The inbound snoop's fields, for the receiving window below. Same argument
    # in the other direction: only a snoopee receives snoops, so the direction
    # scopes that arm to the vantage that owes the level.
    s["rxsnpflit"] = self._snp_flit_or_none("rx", s["rxsnpflitv"])
    # Flit contents only where a flit is actually being presented. Every check
    # that reads them is already guarded by the same flitv, so a None here is
    # never dereferenced -- and skipping the slice on idle cycles keeps this
    # coroutine off the critical path of every clock edge.
    for ch in _CHANNELS_C:
      for d in ("tx", "rx"):
        s[f"{d}{ch}flit"] = self._flit_fields(d, ch) if s[f"{d}{ch}flitv"] else None
    return s

  def _snp_flit_or_none(self, direction: str, valid) -> dict | None:
    """The snoop on `direction` this cycle, or None -- and a credit return is None.

    SNP opcode 0x00 is SnpLCrdReturn: a link-layer flit that carries no
    transaction and will never be answered. Opening a snoop window for one leaves
    it outstanding forever, which drops TXSACTIVE's obligation on the floor at
    both ends -- CHI_TXSACTIVE_COVERS_OUTSTANDING then reports every cycle after
    the first returned credit.

    The exclusion has existed on REQ, RSP and DAT since the monitor was written
    and nowhere for SNP, because nothing had ever sent a credit return on this
    channel: the coherent link is the only one that carries it and that link could
    not be taken down without a reset.
    """
    if not valid:
      return None
    f = self._flit_fields(direction, "snp")
    return None if int(f["opcode"]) == 0 else f

  def _flit_fields(self, direction: str, channel: str) -> dict:
    raw = self.bus.get_or(f"{direction}{channel}flit")
    return {name: (raw >> shift) & bits
            for name, (shift, bits) in self._slices[channel].items()}

  def _enabled(self, s: dict) -> bool:
    if self._checks_enable is not None:
      return self._checks_enable
    # Mirrors the SV bind expression: this interface's own link activity.
    return bool(s["txlinkactivereq"] or s["rxlinkactivereq"])

  def _dat_reorder_allowed(self) -> bool:
    """DAT beats may legally arrive in any order -- DataID carries the position.

    This VIP's own drivers always emit them in order, so the DataID-ordering
    checks hold that convention by default and catch a driver regression. A
    testcase whose completer deliberately reorders beats raises the knob: the
    ordering checks stand down, and the beat-count, TxnID and credit checks
    keep checking.
    """
    return bool(self.tb_cfg is not None
                and getattr(self.tb_cfg, "dat_reorder_allowed", False))

  def _dat_interleave_allowed(self) -> bool:
    """The DAT channel may carry more than one transfer's beats per FLITPEND run.

    CHI permits it: a DAT flit names its transaction in TxnID and its position in
    DataID, and nothing requires a transfer's beats to be contiguous. What stands
    down is exactly the set of checks that read one run as one transfer -- TxnID
    stability across the run, the run's beat count, and the DataID-ordering pair.
    The per-TxnID bookkeeping that retires a completed transfer stays armed,
    which is what keeps the outstanding / TXSACTIVE checks meaningful here.
    """
    return bool(self.tb_cfg is not None
                and getattr(self.tb_cfg, "dat_interleave_allowed", False))

  # ---------------------------------------------------------------------------
  async def run(self) -> None:
    bus = self.bus
    prev = None
    prev_rst = bus.get_rst() if hasattr(bus, "get_rst") else int(bus.rst_n.value)

    while True:
      await RisingEdge(bus.clk)
      cur = self._sample()
      rst = int(bus.rst_n.value)
      enabled = self._enabled(cur)

      if rst == 0:
        # Held in reset. The SV form is (!rst_n && $past(!rst_n)), i.e. from the
        # second reset cycle onward, so the edge itself is not judged.
        #
        # Gated on _link_ever_active, NOT on the enable gate, and the sideband
        # rule inside shows why in the sharpest form this port has produced:
        # the gate IS (txlinkactivereq or rxlinkactivereq), and the rule
        # REQUIRES txlinkactivereq low in reset. The rule's own requirement was
        # what switched the rule off -- a driver that satisfied it held the
        # sideband idle, which made the gate low, which skipped the check. The
        # only design the gate would ever have let through is one that violated
        # the rule, which is the one case it then had no chance to report.
        if self._link_ever_active and prev_rst == 0:
          self._check_reset_idle(cur)
        self._reset_state()
        prev, prev_rst = cur, rst
        continue

      if self._link_is_active(cur):
        self._link_ever_active = True

      if prev_rst == 0:
        # Reset just released: arm the restart window. Armed outside the enable
        # gate for the reason given on _check_restart_window.
        self._act_countdown = _LINK_ACT_WINDOW_C
      if self._link_ever_active:
        self._check_restart_window(cur)

      # Advanced and judged OUTSIDE the enable gate, deliberately. The gate is
      # this interface's own link activity, so gating the state machine on it
      # would blind exactly the half of the cycle where the link comes down: in
      # DEACTIVATE and STOP the gate is low, and RUN -> DEACTIVATE -> STOP could
      # never be judged. It also has to advance across the gap regardless, or
      # the state would be stale the moment the link came back and the first
      # transition after every deactivation would be measured from the wrong
      # place. An interface whose agent is never built holds both directions in
      # STOP and only ever sees the legal hold, so it still reports nothing.
      self._check_lasm(cur)
      self._check_lasm_timeouts()

      # Outside the enable gate and outside _link_ever_active, matching the SV
      # form's `disable iff (!vif.rst_n)`. An interface whose agent is never
      # built never moves either output, so no edge occurs and nothing is
      # judged -- the gate would buy nothing and would blind the tear-down,
      # where two of the four orderings live. `prev` carries the last reset
      # sample when reset has just released, which is what $rose/$fell compare
      # against in SV, so the first post-release cycle is judged in both ports.
      if prev is not None:
        self._check_output_race(prev, cur)
        self._check_input_race(prev, cur)

      # Judged on _link_ever_active rather than on the enable gate, and the
      # reason is the same for all three: the gate is this interface's ACTIVATION
      # REQUEST, so it is low in both DEACTIVATE and STOP -- exactly the two
      # states in which "no flit may go out", "no credit may still be held" and
      # "the sideband must be idle" have any content. Under the gate they could
      # only ever judge a link that was already up, which is the half of each
      # question that never fails.
      #
      # _link_ever_active carries the intended meaning instead, the same way the
      # restart-window check uses it: an interface whose agent is never built
      # stays unarmed and cannot false-fail on an idle link, while one that has
      # carried traffic is judged for the whole life of the link.
      if self._link_ever_active:
        self._check_link_gating(cur)
        self._check_lcrd(cur)
        if prev is not None and prev_rst == 1:
          self._check_deactivate_idle(prev, cur)

      if enabled:
        self._check_valid_requires_pend(prev, cur)
        self._check_transactions(cur)
      else:
        # The SV always_ff clears its state whenever checks_enable is low, so a
        # link that goes down and comes back does not carry stale bookkeeping
        # across the gap.
        self._reset_tracking_state()

      prev, prev_rst = cur, rst

  # ---------------------------------------------------------------------------
  # Reset: sideband and every channel must be idle while rst_n is low.
  # ---------------------------------------------------------------------------
  def _check_reset_idle(self, s: dict) -> None:
    """The reset-idle set is CLOSED, and this is the list.

    E section 14.1.3 / D section 13.1.3, word for word in both issues:

      "During reset the following interface signals must be deasserted by the
       component:  TX***LCRDV.  TX***FLITV.  TXLINKACTIVEREQ and
       RXLINKACTIVEACK. [...] All other signals can be any value."

    Four items and then a sentence that closes the set, so FLITPEND and
    TXSACTIVE are not merely unmentioned -- they are excluded, and requiring
    them low rejects two behaviors the specification permits outright:

      FLITPEND -- E section 14.4 / D section 13.4: "A transmitter is permitted
      to keep the signal permanently asserted."

      TXSACTIVE -- E section 14.7 / D section 13.7 gives it no reset
      requirement, section 14.7.4 calls SACTIVE signaling "orthogonal to the
      LINKACTIVE states", and section 14.7.2 permits an interconnect interface
      to "use the RXSACTIVE input signal to directly generate the TXSACTIVE
      output signal" -- and RXSACTIVE, being an input, may be any value during
      reset.

    The two LINKACTIVE terms below ARE the spec's two, despite reading as one.
    This VIP names signals by direction (`tx*` is what this component drives);
    the specification names them by channel group. So the component's two
    driven LINKACTIVE outputs -- spec TXLINKACTIVEREQ and spec RXLINKACTIVEACK
    -- are this interface's `txlinkactivereq` and `txlinkactiveack`. The
    signals named `rxlinkactive*` here are the peer's outputs, which this bind
    cannot hold low and must not judge.
    """
    self._chk(
      "CHI_LINK_SIDEBAND_IDLE_IN_RESET",
      not (s["txlinkactivereq"] or s["txlinkactiveack"]),
      "link sideband was not held idle during reset")
    for ch in _CHANNELS_C:
      self._chk(
        f"CHI_{ch.upper()}_IDLE_IN_RESET",
        not (s[f"tx{ch}flitv"] or s[f"tx{ch}lcrdv"]),
        f"{ch.upper()} channel was not held idle during reset")

  # ---------------------------------------------------------------------------
  # Link Activation State Machine, one per link (see _lasm_of).
  # ---------------------------------------------------------------------------
  def _check_lasm(self, s: dict) -> None:
    """Advance the LASM and judge the step against the legal transition set.

    The state is registered rather than recomputed from a pair of samples so it
    survives the enable gate and so the dwell counter has somewhere to live.
    """
    for who, cur, nxt in (
      ("TX", self._tx_lasm, self._tx_lasm_of(s)),
      ("RX", self._rx_lasm, self._rx_lasm_of(s)),
    ):
      self._chk(
        "CHI_LASM_LEGAL_TRANSITION",
        lasm_legal_step(cur, nxt),
        f"{who} link stepped {cur.name} -> {nxt.name}; the LASM may only hold "
        f"or advance STOP -> ACTIVATE -> RUN -> DEACTIVATE -> STOP")

      # A second, different claim about the same edge: the link went up THROUGH
      # ACTIVATE, not merely by a step the transition table permits.
      #
      # Section 14.5.1 makes the receiver acknowledge a request it has OBSERVED,
      # and Table 14-2 states it from the transmitter's side -- it "remains in
      # the ACTIVATE state while it is waiting for the receiver to acknowledge
      # the move to the RUN state". So {req=1, ack=0} has to be visible for at
      # least one cycle on every activation.
      #
      # The step rule alone does not say this. It judges consecutive samples, so
      # it reports STOP -> RUN when the two signals move on the same edge -- but
      # it is silent about an activation whose ACTIVATE cycle exists only
      # between two of its own evaluations, and it can be turned OFF by a
      # negative control that wants a different illegal step, taking this claim
      # with it. Stated separately, it holds independently.
      seen = (self._tx_activate_seen if who == "TX" else self._rx_activate_seen)
      if nxt is LasmState.ACTIVATE:
        seen = True
      if nxt is LasmState.RUN and cur is not LasmState.RUN:
        self._chk(
          "CHI_LASM_ACTIVATE_OBSERVED",
          seen,
          f"{who} link entered RUN without ACTIVATE ever being visible; a "
          f"receiver cannot acknowledge a request in the cycle it first appears")
      if nxt is LasmState.STOP:
        seen = False
      if who == "TX":
        self._tx_activate_seen = seen
      else:
        self._rx_activate_seen = seen

    cur = self._tx_lasm
    nxt = self._tx_lasm_of(s)

    # LASM coverage, kept here rather than in vip_chi_coverage for the same
    # structural reason the SV covergroup sits in vip_chi_sva: that component
    # subscribes to analysis ports and has no bus handle, and link state is a
    # wire property. Only the four LEGAL edges are binned -- an illegal step is
    # the check's business, and giving it a bin would let a regression "cover" a
    # violation.
    self._lasm_state_seen[nxt] += 1
    if nxt is not cur and lasm_legal_step(cur, nxt):
      self._lasm_edge_seen[(cur, nxt)] += 1

    self._tx_lasm_dwell = 0 if nxt is not cur else self._tx_lasm_dwell + 1
    self._tx_lasm = nxt

    rx_nxt = self._rx_lasm_of(s)
    self._rx_lasm_dwell = (
      0 if rx_nxt is not self._rx_lasm else self._rx_lasm_dwell + 1)
    self._rx_lasm = rx_nxt

    # See the counter's declaration: the two machines standing in different
    # states is the case the OR-collapsed model could not represent.
    if nxt is not rx_nxt:
      self._lasm_divergent_cycles += 1

    # Credit quiescence is judged PER POOL, because each pool belongs to one
    # machine: tx* is what we may still send and is stranded when our transmit
    # link stops, rx* is what we have granted and is stranded when our receive
    # link stops.
    self._check_lcrd_quiescent_in_stop(self._tx_lasm_of(s), self._rx_lasm_of(s))

  # ---------------------------------------------------------------------------
  # E section 14.6.3 / D section 13.6.3, Asynchronous race condition.
  # ---------------------------------------------------------------------------
  # Four orderings on ONE component's two outputs. The signal-name mapping is
  # the whole difficulty, so it is written out: the specification names
  # LINKACTIVE by CHANNEL GROUP and this interface names it by DIRECTION, which
  # puts both of a component's driven outputs under tx* here.
  #
  #   spec TXLINKACTIVEREQ == txlinkactivereq   our transmit request
  #   spec RXLINKACTIVEACK == txlinkactiveack   our acknowledge to them
  #   spec RXLINKACTIVEREQ == rxlinkactivereq   their request     (input)
  #   spec TXLINKACTIVEACK == rxlinkactiveack   their acknowledge (input)
  #
  # Each entry is (rising?, the signal that moved, the other output, the value
  # the other output must already hold, the section's own sentence).
  _OUTPUT_RACE_C = (
    (True, "txlinkactiveack", "txlinkactivereq", 1,
     "the assertion of RXACK before the assertion of TXREQ"),
    (False, "txlinkactiveack", "txlinkactivereq", 0,
     "the deassertion of RXACK before the deassertion of TXREQ"),
    (True, "txlinkactivereq", "txlinkactiveack", 0,
     "the assertion of TXREQ before the deassertion of RXACK"),
    (False, "txlinkactivereq", "txlinkactiveack", 1,
     "the deassertion of TXREQ before the assertion of RXACK"),
  )

  def _check_output_race(self, prev: dict, cur: dict) -> None:
    """No banned output race on this component's two LINKACTIVE outputs.

    "Output X must change after or at the same time as output Y, but it is not
    permitted to change before output Y."

    The peer's two outputs -- the rx* pair, inputs here -- are deliberately NOT
    judged. Section 14.6.3 permits an observer to see those arrive out of order:
    "race conditions can result in two signals, that are asserted within the
    same cycle, are observed in different clock cycles", the yellow Async Input
    Race states of Figure 14-5. A rule on them would report conformant traffic.
    Each end is judged by its own bind, where its outputs are outputs.

    "OR AT THE SAME TIME" decides the shape: only changing BEFORE is banned, so
    the other output is read in the SAME sample as the edge. When both move on
    one edge the other output already carries its new value and the case passes,
    which is what the section requires. A strict ordering would false-fail every
    component that changes both together.
    """
    # The edge is matched on two-state values. Here that costs nothing -- this
    # port's signals are ints -- but the SystemVerilog twin writes the same
    # comparison out longhand instead of using $rose/$fell, because $fell is
    # true for X -> 0 and an undriven output coming up at reset release would
    # otherwise be reported as a deassertion.
    for rising, moved, other, need, sentence in self._OUTPUT_RACE_C:
      was, now = int(prev[moved]), int(cur[moved])
      if now != (1 if rising else 0) or was == now:
        continue
      edge = "0->1" if rising else "1->0"
      self._chk(
        "CHI_LASM_OUTPUT_RACE", int(cur[other]) == need,
        f"banned output race: {moved} {edge} with {other}="
        f"{int(cur[other])}; 14.6.3 forbids {sentence}")

  # The same four orderings mirrored onto the INPUT pair -- the peer's two
  # outputs as they arrive here. Observing them out of order is not a peer
  # violation this bind may report: 14.6.3 says an asynchronous race can make
  # two signals driven in one cycle arrive in different ones, and those are the
  # yellow Async Input Race states of Figure 14-5. What the section requires
  # instead is of the OBSERVER, and that is the rule below.
  _INPUT_RACE_C = (
    (True, "rxlinkactiveack", "rxlinkactivereq", 1,
     "their acknowledge rose with their request low"),
    (False, "rxlinkactiveack", "rxlinkactivereq", 0,
     "their acknowledge fell with their request still high"),
    (True, "rxlinkactivereq", "rxlinkactiveack", 0,
     "their request rose with their acknowledge still high"),
    (False, "rxlinkactivereq", "rxlinkactiveack", 1,
     "their request fell with their acknowledge low"),
  )

  @classmethod
  def _input_race_step(cls, prev: dict, cur: dict) -> str | None:
    """Name the forbidden-order input step taken this cycle, or None."""
    for rising, moved, other, need, sentence in cls._INPUT_RACE_C:
      was, now = int(prev[moved]), int(cur[moved])
      if now != (1 if rising else 0) or was == now:
        continue
      if int(cur[other]) != need:
        return sentence
    return None

  def _check_input_race(self, prev: dict, cur: dict) -> None:
    """While an input race is unresolved, neither of our outputs may move.

    Section 14.6.3, and it is a different rule from the four: those constrain a
    driver's own two outputs, this constrains the OBSERVER.

    "For all input race conditions, a component that observes the input race is
    required to wait for both signals before changing any output signals. This
    is represented in Figure 14-5 by the fact that the only permitted output
    transition from a race state is caused by the arrival of the other signal
    associated with the race condition."

    A race state is not a static combination of the two inputs -- the Rx machine
    already uses all four -- so it is identified by the STEP that reached it, and
    has to be tracked. The flag arms on a forbidden-order input step and is
    cleared by the next input change of any kind, because that change IS the
    arrival of the other signal: a peer's two outputs driven in one cycle and
    observed in two produce one race seen as two steps, not two races.

    It is also cleared on a violation. Once the component has moved an output the
    obligation has already been broken, and holding the flag would report every
    remaining cycle of the run -- burying the one report that says what happened.
    """
    armed = self._input_race_pending
    moved = [n for n in ("txlinkactivereq", "txlinkactiveack")
             if int(cur[n]) != int(prev[n])]

    if armed:
      self._chk(
        "CHI_LASM_INPUT_RACE_HOLD", not moved,
        f"{' and '.join(moved)} moved while an input race was unresolved "
        f"({self._input_race_why}); 14.6.3 requires a component that observes "
        f"the race to wait for both signals before changing any output")

    changed = (int(cur["rxlinkactivereq"]) != int(prev["rxlinkactivereq"]) or
               int(cur["rxlinkactiveack"]) != int(prev["rxlinkactiveack"]))

    if changed:
      # RESOLVE TAKES PRECEDENCE OVER ARM, and that ordering is the whole
      # correctness of the flag. An armed race is resolved by this change
      # whatever the change is -- it is the arrival of the other signal -- and
      # the second half of a raced pair is itself out of order almost by
      # definition, so arming on it would turn one race into an unbroken chain
      # and one illegal act by the peer into a report every cycle.
      why = None if armed else self._input_race_step(prev, cur)
      self._input_race_pending = why is not None
      if why is not None:
        self._input_race_why = why
    else:
      # THE OBLIGATION IS ONE CYCLE. A race is two signals driven in one cycle
      # and observed in different ones, so the resynchronisation window is a
      # cycle; if the second has not arrived by then, what was observed was a
      # peer changing one signal at a time and 14.6.3's wait does not apply.
      # Demanding more would require stability from a component with nothing
      # left to wait for -- and it is the bound that lets a one-shot driver wait
      # a race out instead of dropping its request.
      self._input_race_pending = False

  def _check_lcrd_quiescent_in_stop(self, tx_state: LasmState,
                                    rx_state: LasmState) -> None:
    """No L-credit may still be outstanding while its own machine is in STOP.

    A sender must have returned every credit it holds before the link goes down;
    one left behind means the shadow and the link disagree about what the peer
    is entitled to send, and that disagreement is what the NEXT activation would
    start from -- a pool seeded with a stale credit lets the first flit after
    bring-up go out unauthorised, which the underflow check could then never
    catch because the count never reaches zero.

    PER POOL, because each pool belongs to one machine. `tx*` is what this
    component may still SEND -- granted to us by the peer, spent by our flitv --
    so it is stranded when the TRANSMIT link stops. `rx*` is what we have GRANTED
    and the peer may still spend, so it is stranded when the RECEIVE link stops.
    Under the reduction a tx pool could be judged against a receive link that had
    gone down while ours was still up, and the other way round: the rule was
    asking the right question of the wrong machine.

    One check id for both halves -- it is one obligation, and a user standing it
    down wants both quiet. The message names the direction.

    Read before _check_lcrd runs this cycle, so the counts judged are the ones
    carried INTO STOP rather than any same-cycle return.
    """
    for pool, held in self._lcrd.items():
      own = tx_state if pool.startswith("tx") else rx_state
      if own is not LasmState.STOP:
        continue
      which = "TRANSMIT" if pool.startswith("tx") else "RECEIVE"
      self._chk(
        "CHI_LCRD_QUIESCENT_IN_STOP", held == 0,
        f"{pool} still holds {held} L-credit(s) with the {which} link in STOP")

  # ---------------------------------------------------------------------------
  # No flit and no credit before the link is RUN.
  # ---------------------------------------------------------------------------
  def _check_link_gating(self, s: dict) -> None:
    """Flits need RUN; credits need only that the link has left STOP.

    Both are judged against the tracked LASM rather than against a pair of
    hand-written predicates. The verdicts are unchanged -- the retired
    predicates were the same expressions -- but the Python port previously gated
    credits on RUN where the SV port gated them on ACTIVE, and the state makes
    which one is right unambiguous: credits legitimately flow from ACTIVATE
    onward, because that is how the initial pool reaches the peer before the
    link is RUN at all. The SV behaviour was the correct one.
    """
    # PER DIRECTION, and which machine gates which signal follows 14.6.1's
    # definition rather than the signal's name prefix. TXLINK is every channel
    # whose PAYLOAD is an output of this component, RXLINK every channel whose
    # payload is an input -- so for one channel the two halves land on DIFFERENT
    # machines:
    #
    #   tx<ch>flitv   we SEND ch    -> the payload is our output  -> TX
    #   tx<ch>lcrdv   we GRANT ch   -> we RECEIVE ch, so the
    #                                  payload is our input       -> RX
    #
    # An endpoint grants credit for the channels it RECEIVES, so every lcrdv this
    # component drives belongs to the machine the other direction runs. Under the
    # reduction both halves were judged against whichever machine happened to be
    # up, which is the aliasing that matters: a credit granted while only
    # our transmit link was alive read as legal.
    tx_state = self._tx_lasm_of(s)
    rx_state = self._rx_lasm_of(s)
    for ch in _CHANNELS_C:
      if s[f"tx{ch}flitv"]:
        self._chk(
          f"CHI_{ch.upper()}_FLITV_REQUIRES_LINK",
          self._flit_send_allowed(tx_state, s, ch),
          f"tx{ch}flitv asserted with the TRANSMIT link in {tx_state.name}, "
          f"not RUN")
      if s[f"tx{ch}lcrdv"]:
        self._chk(
          f"CHI_{ch.upper()}_LCRDV_REQUIRES_LINK",
          rx_state is not LasmState.STOP,
          f"tx{ch}lcrdv asserted with the RECEIVE link in STOP")

  @staticmethod
  def _flit_send_allowed(state: LasmState, s: dict, channel: str) -> bool:
    """May the flit now on `channel` go out in the current link state?

    RUN is the ordinary answer. DEACTIVATE is the exception, and it exists for
    exactly one kind of flit: a sender asked to bring the link down must first
    hand back every L-credit it holds, and the only way to hand one back is to
    send a flit under it. Refusing all traffic in DEACTIVATE would therefore make
    a clean tear-down impossible -- the credits would be stranded and
    CHI_LCRD_QUIESCENT_IN_STOP would fire on a link that did everything right.

    Anything OTHER than an L-credit return is still a violation there, which is
    what keeps the exception narrow: it admits the one flit the tear-down needs
    and nothing else.
    """
    if state is LasmState.RUN:
      return True
    if state is not LasmState.DEACTIVATE:
      return False
    flit = s.get(f"tx{channel}flit")
    return flit is not None and int(flit.get("opcode", -1)) == 0

  # ---------------------------------------------------------------------------
  # FLITPEND announces a flit one cycle ahead. The obligation runs FROM THE FLIT
  # BACKWARDS: E section 14.4 / D section 13.4 require that the signal is
  # asserted exactly one cycle before a flit is sent, and that a deasserted
  # FLITPEND forbids a flit in the next cycle. Those two are one statement read
  # from either end -- flitv(t) -> flitpend(t-1) is the contrapositive of
  # !flitpend(t-1) -> !flitv(t) -- so there is one check here and not two. A
  # second ID could never fail without the first, which is the kind of rule that
  # reports coverage it does not have.
  #
  # Nothing constrains FLITPEND when no flit follows. The same section PERMITS a
  # transmitter to hold it permanently asserted, to assert it without an
  # L-Credit, and to assert then deassert it without ever sending a flit. The
  # rule this replaced tested `flitpend |-> flitv`, which fails all three.
  # ---------------------------------------------------------------------------
  def _check_valid_requires_pend(self, prev: dict, s: dict) -> None:
    if prev is None:
      return
    for ch in _CHANNELS_C:
      if s[f"tx{ch}flitv"]:
        self._chk(
          f"CHI_{ch.upper()}_VALID_REQUIRES_PEND", bool(prev[f"tx{ch}flitpend"]),
          f"tx{ch}flitv sent without tx{ch}flitpend in the preceding cycle")

  # ---------------------------------------------------------------------------
  # L-credit shadow, mirroring lcrd_next() in the SV checker.
  # ---------------------------------------------------------------------------
  def _check_lcrd(self, s: dict) -> None:
    """Track one send-credit pool per channel per direction.

    The pairing is what makes this sound: a tx<chan>flitv send is credited by
    the INBOUND rx<chan>lcrdv, not by the outbound tx<chan>lcrdv, which credits
    the peer's rx<chan>flitv. Grant is applied before consume so a same-cycle
    grant and consume is safe (0 -> 1 -> 0) rather than racing.

    The driver refuses to send at zero credit, so a fired underflow is always a
    real violation: a flit driven with no credit authorizing it.
    """
    pairs = [
      (f"tx{ch}", s[f"rx{ch}lcrdv"], s[f"tx{ch}flitv"], _CAPS_C[ch])
      for ch in _CHANNELS_C
    ] + [
      (f"rx{ch}", s[f"tx{ch}lcrdv"], s[f"rx{ch}flitv"], _CAPS_C[ch])
      for ch in _CHANNELS_C
    ]

    for pool, grant, consume, cap in pairs:
      count = self._lcrd[pool]

      # IHI 0050 E section 14.2.1, Note: "An L-Credit cannot be used in the
      # cycle it is received." Judged BEFORE the grant is applied, because that
      # is the only moment the two are still distinguishable -- grant-before-
      # consume ordering below deliberately makes a same-cycle pair arithmetic-
      # ally safe (0 -> 1 -> 0), which is right for the counter and is exactly
      # what hides this.
      #
      # Only at zero. Above zero a same-cycle grant and consume is an ordinary
      # pipelined link spending an EARLIER credit while a new one arrives, which
      # the Note does not forbid; at zero there is no earlier credit and the
      # flit can only be spending the one on the wire this cycle.
      #
      # Informative in the specification (it is a Note), so it is a rule rather
      # than a fatal -- but it constrains the normative model, and the VIP's own
      # driver cannot produce it, so a report here is always about the peer.
      #
      if grant and consume and count == 0:
        self._chk(
          "CHI_LCRD_USED_IN_GRANT_CYCLE", False,
          f"{pool} flit sent in the same cycle its only L-credit was granted; "
          f"section 14.2.1 says a credit cannot be used in the cycle it is "
          f"received")
      else:
        self._chk("CHI_LCRD_USED_IN_GRANT_CYCLE", True, "")

      if grant:
        self._chk(
          "CHI_LCRD_OVERFLOW", count != cap,
          f"{pool} L-credit grant overflowed the tracked count")
        if count != cap:
          count += 1
      if consume:
        self._chk(
          "CHI_LCRD_UNDERFLOW", count != 0,
          f"{pool} L-credit consumed with no credit available (underflow)")
        if count != 0:
          count -= 1
      self._lcrd[pool] = count

  # ---------------------------------------------------------------------------
  # TXSACTIVE must drop once the link is no longer active.
  # ---------------------------------------------------------------------------
  def _check_deactivate_idle(self, prev: dict, cur: dict) -> None:
    """TXSACTIVE may only be asserted while the link is RUN.

    This rule was VACUOUS BY CONSTRUCTION until the graceful-deactivation path
    existed, and in two independent ways worth recording, because both are easy
    to reintroduce:

      1. its gate defeated it. The antecedent needed the link DOWN and the enable
         gate IS this interface's activation request, so on nearly every cycle
         the antecedent could have held, the gate had already skipped it.
      2. nothing walked the states it judges. The VIP could only take a link down
         by reset, so DEACTIVATE was never entered at all.

    Both are fixed: the caller gates it on _link_ever_active, and the antecedent
    is widened from STOP alone to the whole tear-down half, DEACTIVATE and STOP,
    which is what the rule's name has always claimed. A node tearing its link
    down must not still be telling the receiver it may have snoopable
    transactions outstanding.

    ACTIVATE is deliberately NOT included, and the distinction is the point.
    TXSACTIVE is an early warning, not a report: a node bringing a link up
    already knows whether it will have snoopable traffic, and raising the
    sideband while it waits for the acknowledge is exactly what the signal is for
    -- it gives the receiver time to stop gating its snoop logic before the first
    flit arrives. Only the tear-down half carries the claim that nothing can be
    outstanding, because the tear-down only begins once everything has retired.

    Judged on the FOLLOWING cycle (SV `|=>`), so the antecedent comes from the
    previous sample.
    """
    state = self._lasm_of(prev)
    if state in (LasmState.DEACTIVATE, LasmState.STOP):
      self._chk(
        "CHI_LINK_DEACTIVATE_WHEN_IDLE", not cur["txsactive"],
        f"txsactive was asserted with the link in {state.name}; nothing can be "
        f"outstanding once a tear-down has begun")

  # ---------------------------------------------------------------------------
  # A link stuck coming up or going down.
  # ---------------------------------------------------------------------------
  def _check_lasm_timeouts(self) -> None:
    """ACTIVATE and DEACTIVATE are states a link must pass THROUGH, not sit in.

    Stuck is the one failure mode no other rule here can see, because every cycle
    of it is legal: holding is always a legal LASM step, no flit goes out to
    violate a channel rule, and the transaction-completion timeout has nothing in
    flight to measure. The run simply hangs, and hangs without naming anything.

    Measured on the dwell counter rather than as a bounded temporal window, so
    the bound is a run-time knob and the report can state how long the link has
    been there. Fired on the CROSSING, not on every cycle beyond it: a stuck link
    would otherwise report once per cycle for the rest of the run, burying the
    first (and only useful) report under thousands of copies.
    """
    for state, knob, rule, what in (
      (LasmState.ACTIVATE, "link_activation_timeout_cycles",
       "CHI_LASM_ACTIVATION_TIMEOUT", "bring-up"),
      (LasmState.DEACTIVATE, "link_deactivation_timeout_cycles",
       "CHI_LASM_DEACTIVATION_TIMEOUT", "tear-down"),
    ):
      limit = int(getattr(self.tb_cfg, knob, 0) or 0) if self.tb_cfg else 0
      if limit <= 0:
        continue
      # Per machine, and that is the whole point of the split: under the OR the
      # other direction's acknowledge could hold the reduced state in RUN while
      # this direction waited forever, so the rule stopped being able to fire.
      for who, cur, dwell in (("our", self._tx_lasm, self._tx_lasm_dwell),
                              ("peer's", self._rx_lasm, self._rx_lasm_dwell)):
        if cur is not state:
          continue
        self._chk(
          rule, dwell != limit,
          f"{'TX' if who == 'our' else 'RX'} link stuck in {state.name} for "
          f"{dwell} cycles ({who} {what} unacknowledged, limit {limit})")

  # ---------------------------------------------------------------------------
  # After reset releases, the link must activate within the window.
  # ---------------------------------------------------------------------------
  def _check_restart_window(self, s: dict) -> None:
    """The link must come back up within the window after reset releases.

    Gated on _link_ever_active rather than on the usual enable, and the
    exception is the point. The usual gate is this interface's CURRENT link
    activity, and the check arms at reset release -- the one moment the link is
    guaranteed idle, because the reset-idle rule requires it. Gating on it made
    the check read as "if the link is up, the link comes up" and it could never
    fire. An interface whose agent is never built stays unarmed and cannot
    report a spurious failure; one that has carried traffic must reactivate.
    """
    if self._act_countdown is None:
      return
    if self._link_is_active(s):
      self._chk("CHI_LINK_RESTARTS_AFTER_RESET", True,
                "link activation did not restart after reset release")
      self._act_countdown = None
      return
    self._act_countdown -= 1
    if self._act_countdown <= 0:
      self._err("CHI_LINK_RESTARTS_AFTER_RESET",
                "link activation did not restart after reset release")
      self._act_countdown = None

  # ===========================================================================
  # Transaction layer
  # ===========================================================================
  # Everything below tracks requests across cycles rather than judging a single
  # sample, and is the part of the checker that can say a link is carrying
  # traffic that is individually well-formed but collectively wrong: a TxnID
  # reused while its first use is still outstanding, write data sent before it
  # was granted a buffer, a burst whose beat count contradicts the size its
  # request asked for, a request that is never completed at all.
  # ===========================================================================

  # Beats of write payload the request itself will be followed by.
  def _req_write_payload_beats(self, opcode: int, size: int) -> int:
    op = int(opcode)
    # AtomicCompare Size is the COMBINED compare+swap size: the write payload
    # spans the whole 2**Size operand region in one contiguous run.
    if req_opcode_is_atomic_compare(op):
      return chi_xfer_dat_beats(size, self._data_bytes)
    # The combined Write + CMO family carries the write half's data burst like
    # any other write. Omitting it returned zero beats, which cleared
    # _expected_write_valid_by_dbid and stood the write-burst length checks down
    # for all six forms -- they passed by never being asked.
    if (req_opcode_is_atomic(op)
        or op in (int(ReqOpcode.WRITE_NO_SNP_PTL), int(ReqOpcode.WRITE_NO_SNP_FULL))
        or req_opcode_is_combined_write_cmo(op)
        or req_opcode_is_coherent_write_data(op)):
      return chi_xfer_dat_beats(size, self._data_bytes)
    return 0

  # Beats of payload the completion will carry back.
  def _req_completion_payload_beats(self, opcode: int, size: int) -> int:
    op = int(opcode)
    # AtomicCompare's CompData returns only the pre-op value of the compared
    # location -- one operand, which is half of the 2**Size operand span.
    if req_opcode_is_atomic_compare(op):
      return chi_xfer_dat_beats(size, self._data_bytes) // 2
    if (op in (int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP))
        or req_opcode_is_coherent_read(op)
        or req_opcode_is_atomic_returning_data(op)):
      return chi_xfer_dat_beats(size, self._data_bytes)
    return 0

  # ---------------------------------------------------------------------------
  def _credit_grants(self, s: dict) -> None:
    """Count PCrdGrants into the pool the requests on this link draw from.

    Whichever direction carries it: at a requester bind the grant arrives on
    rxrsp, at a completer bind it leaves on txrsp, and one link has one pool.
    Run before the spend checks so a grant and the request that spends it in the
    same cycle are not read out of order -- section 2.6.5 permits a grant to
    arrive before the RetryAck that owed it, so there is nothing else to pair it
    with.
    """
    self._pcrd_delta = {}
    for d in ("rx", "tx"):
      if not s[f"{d}rspflitv"]:
        continue
      f = s[f"{d}rspflit"]
      if int(f["opcode"]) != int(RspOpcode.PCRD_GRANT):
        continue
      t = int(f["pcrdtype"])
      self._pcrd_delta[t] = self._pcrd_delta.get(t, 0) + 1

  def _pcrd_available(self, pcrd_type: int) -> int:
    """The pool as of this cycle: settled count plus what has been taken in.

    Reading the settled count alone would make a grant invisible to a spend in
    the same cycle and false-fail it, which for a rule this strict is the one
    direction that must not happen.
    """
    return (self._pcrd_held.get(pcrd_type, 0)
            + self._pcrd_delta.get(pcrd_type, 0))

  def _settle_credits(self) -> None:
    for t, d in self._pcrd_delta.items():
      self._pcrd_held[t] = self._pcrd_held.get(t, 0) + d
    self._pcrd_delta = {}

  def _check_transactions(self, s: dict) -> None:
    self._credit_grants(s)

    if self._is_requester:
      self._observe_request(s, "tx", "CHI_TXNID_REUSE_REQUESTER",
                            "requester reused a TxnID while the earlier "
                            "request was still in flight")
      self._observe_requester_responses(s)
      self._check_write_dat_grant(s)
      self._check_comp_ack(s)
    elif self._is_completer:
      self._observe_request(s, "rx", "CHI_TXNID_REUSE_COMPLETER",
                            "completer observed a reused request TxnID while "
                            "the earlier request was still in flight")
      self._observe_completer_responses(s)

    for d in ("tx", "rx"):
      self._check_dat_burst(s, d)
      self._check_rsp_field_zero(s, d)
      self._check_rsp_comp_resp(s, d)

    self._check_completion_timeout(s)
    self._check_atomic_dat_completion(s)
    self._check_ordered_read_receipt(s)
    self._observe_snoop_window(s)
    self._observe_snoop_rx_window(s)
    self._check_txsactive(s)

    self._settle_credits()
    self._flush()

  # ---------------------------------------------------------------------------
  # The snoop window, at the vantage that sends snoops.
  #
  # E 14.7.2 / D 13.7.2 gives the ICN-to-RN interface TWO conditions, "in both
  # the following conditions", and only the first is the request window the
  # outstanding count already models. The second is a window of its own:
  #
  #   "Before or in the same cycle in which its initiating Snoop or SnpDVMOp
  #    flit is sent. It must keep TXSACTIVE asserted until after the final
  #    completing flit is sent, which will be either SnpResp or SnpRespData."
  #
  # The RN-F side of the same clause says what the two conditions together mean:
  # "the TXSACTIVE output is the logical OR of the requirements for the Request
  # interface and the Snoop interface". An OR, not a sequence -- so a home that
  # holds the sideband up across a snoop only because the request that caused
  # the snoop happens to still be outstanding satisfies the letter by accident,
  # and stops satisfying it the moment the two windows do not nest. Counting the
  # snoop separately is what makes the OR the reason the signal is high.
  #
  # Both edges are posted, not applied, and the two deferrals do different work.
  # The open lands at the end of the send cycle, which grants the sideband the
  # same one-cycle sequential grace the request limb already allows -- a driver
  # cannot present a flit and a level from the same clock edge. The close lands
  # at the end of the answering cycle, so the cycle carrying the final SnpResp
  # or SnpRespData beat is still inside the window: "until AFTER the final
  # completing flit".
  # ---------------------------------------------------------------------------
  def _observe_snoop_window(self, s: dict) -> None:
    f = s["txsnpflit"]
    if f is not None:
      self._post(self._snp_inflight, int(f["txnid"]), True)
      # Cleared with the open, not only with the close: a burst that never
      # reached its last beat would otherwise leave a count behind for the next
      # snoop to inherit, and that snoop would retire early by exactly as many
      # beats as the truncated one left.
      self._post(self._snp_dat_beats, int(f["txnid"]), 0)

    rf = s["rxrspflit"]
    if (rf is not None
        and int(rf["opcode"]) in _SNP_RESP_RSP_OPCODES_C
        and self._snp_inflight.get(int(rf["txnid"]), False)):
      self._post(self._snp_inflight, int(rf["txnid"]), False)

    df = s["rxdatflit"]
    if (df is None
        or int(df["opcode"]) not in _SNP_RESP_DAT_OPCODES_C
        or not self._snp_inflight.get(int(df["txnid"]), False)):
      return

    # A snoop data response is a full cache line however partial its content:
    # SnpRespDataPtl carries the same burst with byte enables. Retiring on the
    # first beat would drop the window mid-burst, which is the exact thing the
    # clause forbids.
    txn = int(df["txnid"])
    beats = self._snp_dat_beats.get(txn, 0) + 1
    if beats < chi_xfer_dat_beats(REQ_SIZE_64B, self._data_bytes):
      self._post(self._snp_dat_beats, txn, beats)
      return
    self._post(self._snp_dat_beats, txn, 0)
    self._post(self._snp_inflight, txn, False)

  # ---------------------------------------------------------------------------
  # The snoop window, at the vantage that RECEIVES snoops.
  #
  # The other half of the same clause, and the sentence is the snoopee's own:
  # "An RN-F or RN-D component must also assert TXSACTIVE while a Snoop
  # transaction is in progress".
  #
  # It needs something the sending window does not: an ASSERTION ALLOWANCE. A
  # snoopee cannot raise a level before it has been given a reason to, so the
  # window can only be required from later than the cycle the SNP flit lands in.
  # The open therefore reads the PREVIOUS cycle's landing, which with the posted
  # write this class already uses puts the count non-zero two cycles after the
  # landing edge.
  #
  # Two is measured, not chosen. Across every coherent testcase in both ports the
  # interval from the accepted SNP beat to the sideband rising is exactly 2, in
  # 72 pyUVM and 127 SystemVerilog occurrences with no spread: the responder
  # steps off the accepted beat before it opens its window, and the credit loop
  # is the only writer of the level. An allowance assumed to be one cycle would
  # false-fail every coherent run.
  #
  # `opened` exists for the case where a snoop is answered in the very cycle its
  # window opens. The posted write means the flag is still False when the close
  # sites test it, so without this they would decline to retire and the entry
  # would stay open for good.
  # ---------------------------------------------------------------------------
  def _observe_snoop_rx_window(self, s: dict) -> None:
    landed = self._snp_rx_landed
    rx = s["rxsnpflit"]
    self._snp_rx_landed = int(rx["txnid"]) if rx is not None else None

    opened = None
    if landed is not None and not self._snp_rx_inflight.get(landed, False):
      self._post(self._snp_rx_inflight, landed, True)
      self._post(self._snp_rx_dat_beats, landed, 0)
      opened = landed

    rf = s["txrspflit"]
    if (rf is not None
        and int(rf["opcode"]) in _SNP_RESP_RSP_OPCODES_C
        and (self._snp_rx_inflight.get(int(rf["txnid"]), False)
             or int(rf["txnid"]) == opened)):
      self._post(self._snp_rx_inflight, int(rf["txnid"]), False)

    df = s["txdatflit"]
    if df is None or int(df["opcode"]) not in _SNP_RESP_DAT_OPCODES_C:
      return
    txn = int(df["txnid"])
    if not self._snp_rx_inflight.get(txn, False) and txn != opened:
      return

    beats = self._snp_rx_dat_beats.get(txn, 0) + 1
    if beats < chi_xfer_dat_beats(REQ_SIZE_64B, self._data_bytes):
      self._post(self._snp_rx_dat_beats, txn, beats)
      return
    self._post(self._snp_rx_dat_beats, txn, 0)
    self._post(self._snp_rx_inflight, txn, False)

  # ---------------------------------------------------------------------------
  # TXSACTIVE against the outstanding window.
  #
  # TXSACTIVE tells the receiver this node may have snoopable transactions
  # outstanding. The receiver's use for it is to decide when it can stop
  # watching for snoop traffic, so the failure that matters is UNDER-assertion:
  # the sideband low while transactions are still in flight tells the receiver
  # it may stand down when it may not.
  #
  # Over-assertion is legal -- "may have" is permissive -- so the second check
  # is not its mirror. It bounds how long the signal may stay up once the link
  # has gone completely quiet, which catches a sender that raises TXSACTIVE and
  # then never lowers it: still legal by the letter, but it makes the sideband
  # carry no information at all.
  # ---------------------------------------------------------------------------
  def _check_txsactive(self, s: dict) -> None:
    outstanding = sum(1 for v in self._req_inflight.values() if v)
    snoops = sum(1 for v in self._snp_inflight.values() if v)
    snoops_rx = sum(1 for v in self._snp_rx_inflight.values() if v)

    # BOTH vantages. This was requester-only, on the ground that "a completer
    # has none of its own outstanding transactions". That does not survive
    # section 14.7.2, which states the obligation separately for each role and
    # gives the completer one of its own: on receiving a transaction initiating
    # flit it must assert TXSACTIVE before or in the cycle of its first Response
    # flit, and "keep TXSACTIVE asserted until after the final completing flit
    # is sent or received".
    #
    # So a completer's window is the requests it has RECEIVED and not yet
    # completed -- exactly what _req_inflight holds at a completer, because it
    # is filled from the direction the role receives on.
    # Two limbs, one rule, and the message says which one is unmet: a snoop
    # window broken while the causing request is still outstanding is invisible
    # in a count that adds them together, and it is the failure 14.7.2's second
    # condition exists to name. See _observe_snoop_window.
    if outstanding or snoops or snoops_rx:
      self._chk(
        "CHI_TXSACTIVE_COVERS_OUTSTANDING", bool(s["txsactive"]),
        f"TXSACTIVE was low with {outstanding} transaction(s), {snoops} "
        f"snoop(s) sent and {snoops_rx} snoop(s) received still outstanding: "
        f"the window it reports must cover every one of them, not just the "
        f"cycles carrying flits")

    # An episode ends the moment anything happens on the link. That is what
    # keeps the bound clear of a sender's own retire tail: the completion, and
    # any CompAck chasing it, are flits, so the count only runs once the link
    # is genuinely idle AND this checker sees nothing outstanding.
    # Every channel, INCLUDING SNP. The snoop valids were omitted, so a link
    # busy with nothing but snoop traffic read as quiet and this rule reported a
    # stuck sideband on an RN-F that was legitimately holding TXSACTIVE up for
    # the snoop window section 14.7.2 requires it to keep -- flagging LEGAL
    # behaviour, on the coherent binds, on every run.
    #
    # Not added to _CHANNELS_C: that list is REQ/RSP/DAT by design, because the
    # snoop channel has its own bind, its own credit pool and its own rules, and
    # adding it there would arm all of them twice. What is needed here is only
    # "is anything moving". ChiBus.get_or returns 0 for a signal a role does not
    # have, so this costs nothing on the roles with no snoop channel.
    link_quiet = not outstanding and not snoops and not snoops_rx and not any(
      s[f"{d}{ch}flitv"] for d in ("tx", "rx")
      for ch in (*_CHANNELS_C, "snp"))

    limit = _TXSACTIVE_SETTLE_CYCLES_C + self._txsactive_extend_max_cycles

    if not (link_quiet and s["txsactive"]):
      # The episode ended. Score it as a pass -- whether it ended because the
      # sideband dropped or because traffic resumed, it did not stay up
      # indefinitely, which is what this rule asserts. Scoring the ENDING (and
      # not merely staying silent) is what keeps the rule out of the summary's
      # blind spot: a check that only ever reports failures is indistinguishable
      # from one that never runs.
      if self._txsactive_idle_cycles and not self._txsactive_reported:
        self._chk("CHI_TXSACTIVE_DEASSERT_BOUNDED", True, "")
      self._txsactive_idle_cycles = 0
      self._txsactive_reported = False
      return

    self._txsactive_idle_cycles += 1
    if self._txsactive_idle_cycles <= limit or self._txsactive_reported:
      return

    self._txsactive_reported = True
    self._chk(
      "CHI_TXSACTIVE_DEASSERT_BOUNDED", False,
      f"TXSACTIVE stayed asserted for {self._txsactive_idle_cycles} cycles "
      f"with nothing outstanding and no flit on any channel (bound is "
      f"{limit}): a sideband that never drops reports nothing")

  @property
  def _txsactive_extend_max_cycles(self) -> int:
    # Read live rather than latched, like the reorder knob, so a testcase can
    # raise it before its traffic starts.
    return max(0, int(getattr(self.tb_cfg, "txsactive_extend_max_cycles", 0)
                      if self.tb_cfg is not None else 0))

  # ---------------------------------------------------------------------------
  # A request goes out (requester) or arrives (completer).
  # ---------------------------------------------------------------------------
  def _observe_request(self, s: dict, d: str, reuse_rule: str,
                       reuse_msg: str) -> None:
    if not s[f"{d}reqflitv"]:
      return
    f = s[f"{d}reqflit"]
    opcode = f["opcode"]
    txn = f["txnid"]

    # See the counter's declaration. Recorded for EVERY request, including the
    # credit and prefetch forms a transaction rule would skip: the question this
    # answers is "was it driven", and a form excluded here could not be
    # distinguished afterwards from one nothing sends.
    self._req_opcode_seen[opcode] = self._req_opcode_seen.get(opcode, 0) + 1

    # Not gated on req_has_modeled_completion: see the shadow's comment.
    # ReqLCrdReturn and PCrdReturn are excluded because both are required to
    # drive TxnID zero, so marking slot 0 for them would leave the one slot a
    # real request can also use permanently unjudgeable.
    if opcode not in (int(ReqOpcode.PCRD_RETURN), int(ReqOpcode.LCRD_RETURN)):
      self._post(self._req_txn_id_seen, txn, True)

    # Section 2.9.4's first-attempt rule, read through the credit pool. A request
    # with AllowRetry deasserted is claiming to spend a pre-allocated P-Credit,
    # so this link must have seen a PCrdGrant of that PCrdType still unspent.
    #
    # PrefetchTgt is exempt because section 2.9.4 REQUIRES its AllowRetry
    # deasserted and it needs no credit; ReqLCrdReturn carries no transaction at
    # all; PCrdReturn spends without being judged, because section 2.6.6 makes it
    # a NOP that "uses the credit that is not required" while a return of a
    # credit this bind never saw granted is a requester bookkeeping error that
    # the driver's own check_phase already reports.
    pcrd = int(f["pcrdtype"])
    if (not int(f["allowretry"]) and opcode not in (
          int(ReqOpcode.PREFETCH_TGT), int(ReqOpcode.LCRD_RETURN),
          int(ReqOpcode.PCRD_RETURN))):
      held = self._pcrd_available(pcrd)
      self._chk("CHI_REQ_RETRY_SPENDS_GRANTED_CREDIT",
                held != 0,
                f"opcode 0x{int(opcode):x} carried AllowRetry deasserted with "
                f"PCrdType 0x{pcrd:x}, and this link has seen no unspent "
                f"PCrdGrant of that type; section 2.9.4 requires AllowRetry "
                f"asserted on a first attempt")
      if held != 0:
        self._pcrd_delta[pcrd] = self._pcrd_delta.get(pcrd, 0) - 1
    elif opcode == int(ReqOpcode.PCRD_RETURN):
      if self._pcrd_available(pcrd) != 0:
        self._pcrd_delta[pcrd] = self._pcrd_delta.get(pcrd, 0) - 1

    # Section 2.5 scopes the rule to "all requests except PrefetchTgt", and the
    # arm here is `req_has_modeled_completion` instead. MEASURED, not assumed:
    # the two coincide over every opcode this VIP can drive. Of the four REQ
    # opcodes outside the classifier,
    #
    #   PrefetchTgt      is the specification's own named exception,
    #   ReqLCrdReturn    is a link-layer credit return and carries no
    #                    transaction at all,
    #   PCrdReturn       is a NOP that names a credit; both it and the credit
    #                    return are REQUIRED to drive TxnID zero, so treating
    #                    either as a transaction would leave slot 0 permanently
    #                    claimed and unjudgeable for the requests that can use
    #                    it,
    #   CleanShared      is unimplemented -- no constraint, sequence or driver
    #                    in either port.
    #
    # So the arm is not narrower than the rule today. It WOULD become narrower
    # the day CleanShared is implemented, which is why that claim is verified
    # rather than trusted: check_classifier_coverage.py fails if the opcode is
    # referenced anywhere outside the type packages.
    #
    # Widening the arm on its own would not be an improvement. The shadow is
    # retired by completions this checker models, so an opcode outside the
    # classifier would claim a slot nothing frees, and the next legitimate use
    # of that TxnID would be reported as a reuse -- a false failure in place of
    # a rule that currently has nothing to judge.
    if req_has_modeled_completion(opcode):
      # A TxnID identifies an outstanding transaction. Reusing one before its
      # first use retires makes the two indistinguishable to every downstream
      # tracker, including this checker.
      # Same SrcID reusing a live slot is the violation. A DIFFERENT SrcID
      # landing on the same TxnID is a pass, not a decline: section 2.5's rule
      # is satisfied outright, because the two requests are distinguishable by
      # the field the spec names -- and now the shadow can hold both at once,
      # so it is a pass that leaves the first source's claim standing.
      key = self._inflight_key(f["srcid"], txn)
      self._chk(reuse_rule, not self._req_inflight.get(key, False),
                f"{reuse_msg}: SrcID 0x{key[0]:x} reused TxnID 0x{key[1]:x}")
      self._post(self._req_inflight, key, True)
      # For section 2.5's DBID-equality exemption. Recorded per transaction
      # rather than looked up when the Comp arrives, because the completion
      # flit does not carry the request opcode.
      self._post(self._req_is_atomic, key, req_opcode_is_atomic(int(opcode)))
      self._post(self._write_grant_dbid, key, None)
      self._arm_completion(s, f)

    self._post(self._expected_write_beats_by_txn, txn,
               self._req_write_payload_beats(opcode, f["size"]))

    beats = self._req_completion_payload_beats(opcode, f["size"])
    if beats:
      completion_txn = _completion_txn_for_req(opcode, txn, f["returntxnid"])
      self._post(self._expected_completion_beats_by_txn, completion_txn, beats)
      self._post(self._expected_completion_opcode_by_txn, completion_txn,
                 _expected_completion_dat_opcode(opcode))
      self._post(self._expected_completion_valid_by_txn, completion_txn, True)
      self._post(self._dat_completion_req_valid_by_txn, completion_txn, True)
      self._post(self._dat_completion_req_txn_by_txn, completion_txn, txn)

    # Every request, not only writes. The write-only gate was correct for
    # exactly as long as ExpCompAck was unreachable on a read: the moment
    # Table 2-9 was implemented and the four coherent reads started setting the
    # bit, a read's CompAck would have arrived against a tracker that had
    # recorded nothing -- and COMPACK_WITHOUT_EXPCOMPACK would have fired on
    # every conformant coherent read in the regression.
    self._post(self._req_exp_comp_ack, txn, bool(f["expcompack"]))
    self._post(self._completion_seen, txn, False)

    # IHI 0050 E Table 2-9 / D Table 2-8, the "Yes" column. The role argument is
    # a constant one: every opcode the table marks required is an opcode only an
    # RN-F may issue at all, so no role test is needed here -- a non-RN-F sending
    # one of them is a different violation, of the opcode legality rule rather
    # than of this one. Judged from whichever vantage this bind sits at, for the
    # same reason CHI_RSP_FIELD_ZERO is: a link may carry a bind at only one end.
    self._chk("CHI_EXPCOMPACK_REQUIRED_BUT_ZERO",
              not (exp_comp_ack_required(opcode, True)
                   and not int(f["expcompack"])),
              "a request whose opcode requires CompAck was issued with "
              "ExpCompAck = 0")

    # Atomic operand Size against IHI 0050 E Table 2-17 / D Table 2-17.
    #
    # The classifier passes anything that is not an atomic, so this needs no
    # opcode-family gate: the rule reads "if this is an atomic, its Size is one
    # the table lists", and every other opcode records a pass trivially. That is
    # the same shape as the ExpCompAck rule above and it is deliberate -- a rule
    # that only evaluates for the family it judges cannot distinguish "no atomic
    # went by" from "the classifier forgot this opcode", which is how the combined
    # Write + CMO family went six opcodes unclaimed.
    #
    # The wide-operand stress profile that vip_chi_atomic_seq records as a
    # deliberate decision violates this rule on purpose. Those testcases turn it
    # down to CheckSeverity.OFF rather than being exempted here, for the reason
    # the LASM illegal-transition test gives: OFF still evaluates and still
    # tallies, so the rule stays visible as exercised-and-failing on exactly the
    # links where the violation is intended, instead of publishing enabled = 0 and
    # reading as a rule nothing ever reached.
    self._chk("CHI_ATOMIC_SIZE_LEGAL",
              atomic_size_legal(opcode, f["size"]),
              f"atomic opcode 0x{int(opcode):x} carried Size {int(f['size'])}, "
              f"which Table 2-17 does not permit for it")

    # Order legality: Table 13-25 reserves Order = 0b01 outside a read, and Table
    # 2-12's footnote a permits Order = 0b10 on ReadOnce*, WriteUnique, ReadNoSnp,
    # WriteNoSnp and Atomic only. Total classifier again, same reason as above.
    self._chk("CHI_REQ_ORDER_LEGAL",
              req_order_legal(opcode, f["order"]),
              f"opcode 0x{int(opcode):x} carried Order 0b{int(f['order']):02b}, "
              f"which the specification does not permit for it")

    # Table 2-12 as a whitelist: the table closes each of its two blocks with
    # "All other values -- Not valid", so a tuple outside the nine rows is a
    # protocol error and every request has a tuple to judge.
    #
    # The SnpAttr the tuple is judged with is the DECODED one, for the same
    # reason the Table 2-14 rule below decodes it: on the opcodes where REQ bit
    # 17 is DoDWT there is no SnpAttr claim on the wire to judge, and Table 2-14
    # lists every one of them as Non-snoopable only, so zero is the value the
    # tuple must be read with. Reading the raw bit instead reported every
    # conformant DoDWT = 1 write as a Snoopable Non-cacheable request -- a row
    # the table indeed does not list, against a request that never made the
    # claim. Found by tc_chi_e_dwt_dbid_return_nid, which is the first testcase
    # able to put a one on that bit at all.
    ma = int(f["memattr"])
    snp_attr_claim = (0 if req_bit17_is_dodwt(self._issue, opcode)
                      else int(f["snpattr"]))
    self._chk("CHI_REQ_ATTR_COMBINATION_LEGAL",
              req_attr_combination_legal(ma, snp_attr_claim, f["likelyshared"],
                                         f["order"]),
              f"request carried MemAttr 0x{ma:x} (Allocate {(ma >> 3) & 1} "
              f"Cacheable {(ma >> 2) & 1} Device {(ma >> 1) & 1} EWA {ma & 1}), "
              f"SnpAttr {snp_attr_claim}, LikelyShared {int(f['likelyshared'])} "
              f"and Order 0b{int(f['order']):02b}, a combination Table 2-12 does "
              f"not list")

    # Table 2-14's per-opcode requirement, which the tuple rule above cannot
    # express: Table 2-12 says which combinations are legal, Table 2-14 says which
    # of them this opcode may use. A coherent request marked Non-snoopable
    # satisfies the tuple rule and is still wrong.
    # Judged only where the bit IS SnpAttr. Under Issue E the same bit is DoDWT on
    # WriteNoSnpFull, WriteNoSnpPtl and Combined Write, and a conformant
    # DoDWT = 1 there puts a one on the wire that is not an SnpAttr claim at all.
    # The specification separates the two by role -- DoDWT is applicable only from
    # Home to Slave -- which a bind cannot establish, so on those opcodes the rule
    # has nothing to falsify and says so by passing rather than by not evaluating.
    snp_req = (SnpAttrReq.ANY
               if req_bit17_is_dodwt(self._issue, opcode)
               else snp_attr_requirement(opcode))
    snp = int(f["snpattr"])
    self._chk("CHI_REQ_SNP_ATTR_LEGAL",
              not ((snp_req is SnpAttrReq.ONE and snp != 1)
                   or (snp_req is SnpAttrReq.ZERO and snp != 0)),
              f"opcode 0x{int(opcode):x} carried SnpAttr {snp}, and Table 2-14 "
              f"lists it as "
              f"{'Snoopable' if snp_req is SnpAttrReq.ONE else 'Non-snoopable'} "
              f"only")

    # Table A-3's Allocate column, which no other rule reaches: Table 2-12's
    # Snoopable rows leave the bit free, so an Evict carrying it is a legal tuple
    # with an inapplicable field set.
    self._chk("CHI_REQ_ALLOCATE_LEGAL",
              not (((ma >> 3) & 1) and not req_allocate_permitted(opcode)),
              f"opcode 0x{int(opcode):x} carried Allocate asserted, and "
              f"Table A-3 marks the field inapplicable for it")

    # Section 2.9.5's LikelyShared whitelist. Narrower than the tuple rule above,
    # which only knows the table's "LikelyShared implies Snoopable": this also
    # faults the six Snoopable-only opcodes the section excludes.
    self._chk("CHI_REQ_LIKELY_SHARED_LEGAL",
              not (int(f["likelyshared"])
                   and not req_likely_shared_permitted(opcode)),
              f"opcode 0x{int(opcode):x} carried LikelyShared asserted, which "
              f"section 2.9.5 does not permit for it")

    # Table A-3 fixes Size at 64 bytes for every coherent read, dataless and
    # CopyBack opcode, and for the full writes. Size = 0b110 is 64 bytes
    # (Table 2-15), independent of the data bus width.
    self._chk("CHI_REQ_SIZE_LEGAL",
              not (req_size_fixed_64b(opcode)
                   and int(f["size"]) != REQ_SIZE_64B),
              f"opcode 0x{int(opcode):x} carried Size 0b{int(f['size']):03b}, and "
              f"Table A-3 fixes its Size at 64 bytes (0b110)")

    # Section 6.3's closed list of transactions that support an Exclusive access.
    # Excl on anything else is not a weaker guarantee, it is a bit the receiver
    # has no defined behavior for.
    self._chk("CHI_REQ_EXCL_LEGAL",
              not (int(f["excl"]) and not req_excl_permitted(opcode)),
              f"opcode 0x{int(opcode):x} carried Excl asserted, and section 6.3 "
              f"does not list it as supporting Exclusive accesses")

    # ReturnNID and ReturnTxnID are inapplicable and must be zero outside the
    # request sets E 13.10.4 / 13.10.15 name, and the two sets differ:
    # CleanSharedPersistSep may carry a ReturnNID and must not carry a
    # ReturnTxnID, because a separated persist gets an RSP rather than data.
    # Folded into ONE check id because it is one obligation -- the return path is
    # not in use, so neither half of it may be set.
    if (int(f["returnnid"]) and not req_return_nid_applicable(opcode)):
      self._chk("CHI_REQ_RETURN_PATH_LEGAL", False,
                f"opcode 0x{int(opcode):x} carried ReturnNID "
                f"0x{int(f['returnnid']):x}, and section 13.10.4 makes the "
                "field inapplicable and zero for it")
    else:
      self._chk("CHI_REQ_RETURN_PATH_LEGAL",
                not (int(f["returntxnid"])
                     and not req_return_txn_id_applicable(opcode)),
                f"opcode 0x{int(opcode):x} carried ReturnTxnID "
                f"0x{int(f['returntxnid']):x}, and section 13.10.15 makes the "
                "field inapplicable and zero for it")

    # Table A-3's Endian column: applicable on the Atomics only. Endian selects an
    # Atomic operand's byte order and has nothing to say about a plain read or
    # write, which the table states as must-be-zero rather than as free.
    self._chk("CHI_REQ_ENDIAN_LEGAL",
              not (int(f["endian"]) and not req_endian_applicable(opcode)),
              f"opcode 0x{int(opcode):x} carried Endian asserted, and Table A-3 "
              f"makes the field inapplicable outside an Atomic")

    # IHI 0050 E Table 12-2's per-opcode TagOp permission, as a mask indexed by
    # the encoding. The table has five columns for a two-bit field -- Match and
    # Fetch are both 0b11 -- so the mask is what the encoding forces. Total, and
    # the opcodes Table 12-2 has no row for (CleanUnique) or calls a Don't Care
    # (ReqLCrdReturn) are unjudged rather than guessed.
    #
    # Guarded on the field's PRESENCE, which is this port's equivalent of the SV
    # checker's generate-if. Memory tagging is an Issue E feature, so a CHI-D REQ
    # layout has no tagop at all: _flit_slices simply does not produce a slice for
    # it, and reading f["tagop"] on a CHI-D link raises KeyError at run time
    # rather than standing the rule down. Same asymmetry as SV's, where the field
    # is not a struct member and the rule fails to elaborate instead.
    if "tagop" in f:
      self._chk("CHI_REQ_TAGOP_LEGAL",
                bool(req_tagop_permitted_mask(self._issue, opcode)
                     & (1 << int(f["tagop"]))),
                f"opcode 0x{int(opcode):x} carried TagOp "
                f"0x{int(f['tagop']):x}, which Table 12-2 does not permit "
                "for it")

    # Section 2.9.4: "If the AllowRetry field is asserted, the PCrdType field
    # must be set to 0b0000." A request that still allows a Retry response
    # cannot also be spending a credit. The converse -- AllowRetry deasserted
    # carries the RetryAck's PCrdType -- needs the credit tracker and is not
    # this rule.
    self._chk("CHI_REQ_ALLOW_RETRY_PCRD_ZERO",
              not (int(f["allowretry"]) and int(f["pcrdtype"])),
              f"opcode 0x{int(opcode):x} carried AllowRetry set with PCrdType "
              f"0x{int(f['pcrdtype']):x}, and section 2.9.4 requires PCrdType "
              "zero while a Retry response is still allowed")

    # Every column Table A-2 and Table A-3 mark inapplicable-and-zero for
    # PCrdReturn. Issue D's tables agree: D drops only the TagOp column, and
    # D's part-2 row is uniformly "0a", so column identity does not even have
    # to be resolved there.
    #
    # What is NOT here matters as much as what is. QoS, TgtID, SrcID and Opcode
    # are the transaction's identity; PCrdType is applicable and section 2.6.6
    # requires it to match the grant being returned, so a zero there would be
    # the bug; TraceTag reads "Y" in Table A-2, so a conformant PCrdReturn may
    # carry one and asserting zero would false-fail it; and DoDWT reads "-",
    # sharing SnpAttr's bit, which is the name checked below.
    #
    # The tagop, groupidext and mpam terms are guarded on field PRESENCE, the
    # same way CHI_REQ_TAGOP_LEGAL is: memory tagging and the separate
    # GroupIDExt member are Issue E only, and mpam_field_width is zero on a
    # link with no MPAM bus, so _flit_slices produces no slice and reading the
    # key would raise KeyError rather than stand the term down.
    if opcode == int(ReqOpcode.PCRD_RETURN):
      offenders = [n for n in ("txnid", "returnnid", "returntxnid", "endian",
                               "size", "addr", "ns", "likelyshared",
                               "allowretry", "order", "memattr", "snpattr",
                               "lpid", "excl", "expcompack",
                               "tagop", "groupidext", "mpam")
                   if n in f and int(f[n])]
      self._chk("CHI_REQ_PCRD_RETURN_FIELDS_ZERO",
                not offenders,
                "PCrdReturn carried a Table A-2/A-3 zero-marked field "
                "non-zero: "
                + ", ".join(f"{n}=0x{int(f[n]):x}" for n in offenders))

    # The other half of Table 2-9, which nothing checked: the table marks
    # ExpCompAck prohibited on a whole class of requests, and until now only the
    # required-but-zero direction was reported. Table A-3's ExpCompAck column
    # agrees, giving "0" on every opcode the requirement function classifies as
    # prohibited.
    #
    # The role argument is the constant True for the same reason the required
    # direction above uses it, read the other way round: passing RN-F shrinks the
    # prohibited set, because the opcodes an RN-F may acknowledge are exactly the
    # ones lifted out of it. That is the under-reporting direction, which is what a
    # rule running on every request should prefer.
    self._chk("CHI_EXPCOMPACK_PROHIBITED_BUT_SET",
              not (int(f["expcompack"]) and exp_comp_ack_prohibited(opcode, True)),
              f"opcode 0x{int(opcode):x} carried ExpCompAck asserted, and "
              f"Table 2-9 prohibits the bit for it")

  def _arm_completion(self, s: dict, f: dict) -> None:
    """Start the temporal attempts a request opens."""
    opcode = f["opcode"]
    txn = f["txnid"]
    completion_txn = _completion_txn_for_req(opcode, txn, f["returntxnid"])
    rec = {"opcode": opcode, "req_txn": txn, "completion_txn": completion_txn}

    if self._enable_completion_timeout:
      self._pending_completion.append(dict(rec, remaining=self._timeout_cycles))

    # The atomic and ordered-read rules are vantage-specific in the SV port
    # (an RN-I and an SN-F property each), so they are gated on the exact role
    # rather than on the requester/completer split.
    if self._is_rni or self._is_snf:
      if req_opcode_is_atomic_returning_data(opcode):
        self._pending_atomic.append(dict(rec))
      if (int(opcode) in _ORDERED_READ_OPCODES_C
          and int(f["order"]) != int(ReqOrder.NONE)):
        self._pending_ordered.append(dict(rec))

  # ---------------------------------------------------------------------------
  # Responses seen at a requester: grants and completions arriving inbound.
  # ---------------------------------------------------------------------------
  def _observe_requester_responses(self, s: dict) -> None:
    if not s["rxrspflitv"]:
      return
    f = s["rxrspflit"]
    opcode = int(f["opcode"])
    txn = f["txnid"]

    if opcode in _DBID_GRANT_OPCODES_C:
      self._record_write_grant(f, mark_grant_seen=True)
    self._check_comp_dbid(f, opcode)
    if opcode in PLAIN_COMPLETION_RSP_OPCODES_C:
      self._post(self._completion_seen, txn, True)
      self._post(self._req_inflight, self._inflight_key(f["tgtid"], txn),
                 False)
    elif opcode == int(RspOpcode.COMP_PERSIST):
      self._post(self._req_inflight, self._inflight_key(f["tgtid"], txn),
                 False)
    elif opcode == int(RspOpcode.RETRY_ACK):
      # A RetryAck retires the bounced request: the completer did not accept
      # it, so its TxnID is released and the requester re-issues after the
      # matching PCrdGrant. Clearing the marker keeps that legitimate re-issue
      # from reading as a TxnID reuse.
      self._post(self._req_inflight, self._inflight_key(f["tgtid"], txn),
                 False)
      # And section 2.6.5 requires the flit to carry the bounced request's
      # TxnID, so a RetryAck landing on a slot no request has used bounced
      # nothing -- and the credit that follows it would have no transaction to
      # re-issue.
      self._chk("CHI_RSP_RETRY_ACK_TXN_ID",
                self._req_txn_id_seen.get(txn, False),
                f"RetryAck arrived with TxnID 0x{int(txn):x}, which no request "
                f"on this link has used; section 2.6.5 requires the bounced "
                f"request's TxnID")
      self._post(self._req_txn_id_seen, txn, False)

  # ---------------------------------------------------------------------------
  # Responses driven by a completer: the grants it issues, outbound.
  # ---------------------------------------------------------------------------
  def _observe_completer_responses(self, s: dict) -> None:
    if not s["txrspflitv"]:
      return
    f = s["txrspflit"]
    opcode = int(f["opcode"])

    if opcode in _DBID_GRANT_OPCODES_C:
      # A completer knows what it granted, but not whether the requester will
      # honour it, so it records the expected burst size without the
      # grant-seen marker the requester side uses to police its own DAT.
      self._record_write_grant(f, mark_grant_seen=False)
    self._check_comp_dbid(f, opcode)

    # A completer retires a request when it SENDS the completion, exactly as a
    # requester retires one when it receives it. Without this the completer-side
    # shadow only ever grew: filled by every received request and cleared by
    # nothing but a RetryAck.
    #
    # It went unnoticed because the one rule that reads the count was gated to
    # the requester. The stated reason was that a completer has no window of its
    # own -- which is not what section 14.7.2 says -- but the gate was load
    # bearing for a different reason, and dropping it without this made the
    # count run away on every completer bind.
    if opcode in PLAIN_COMPLETION_RSP_OPCODES_C or opcode == int(
        RspOpcode.COMP_PERSIST):
      self._post(self._req_inflight,
                 self._inflight_key(f["tgtid"], f["txnid"]), False)

    if opcode == int(RspOpcode.RETRY_ACK):
      # Mirror of the requester side: a RetryAck this node drove retires the
      # bounced request's TxnID, for the requester it is aimed at.
      self._post(self._req_inflight,
                 self._inflight_key(f["tgtid"], f["txnid"]), False)
      # Section 2.6.5 read at the sending vantage: a completer must bounce a
      # request it received, and the TxnID is the only thing naming which one.
      self._chk("CHI_RSP_RETRY_ACK_TXN_ID",
                self._req_txn_id_seen.get(f["txnid"], False),
                f"RetryAck was sent with TxnID 0x{int(f['txnid']):x}, which no "
                f"request received on this link has used; section 2.6.5 "
                f"requires the bounced request's TxnID")
      self._post(self._req_txn_id_seen, f["txnid"], False)

  def _record_write_grant(self, f: dict, mark_grant_seen: bool) -> None:
    """Carry a request's expected write size across to its granted DBID.

    The write data that follows is tagged with the DBID, not with the request's
    TxnID, so the beat-count expectation has to be re-keyed here or the burst
    check would have nothing to compare against.

    Also where section 2.5's DBID-uniqueness rule is judged, because this is the
    one place both vantages see a grant: the completer as it drives one, the
    requester as it receives one.
    """
    dbid = f["dbid"]
    self._check_dbid_unique(f, dbid)
    beats = self._expected_write_beats_by_txn.get(f["txnid"], 0)
    if mark_grant_seen:
      self._post(self._write_grant_seen_by_dbid, dbid, True)
    self._post(self._expected_write_beats_by_dbid, dbid, beats)
    self._post(self._expected_write_valid_by_dbid, dbid, beats != 0)

  # ---------------------------------------------------------------------------
  # Section 2.5: a DBID a Completer hands out must be unique for a given
  # Requester.
  #
  # The Requester tags its write data with the DBID and with nothing else, so two
  # of its transactions holding one DBID at the same time make their data
  # indistinguishable -- to the Completer first, and to every shadow built on top
  # of it. This is the TxnID-uniqueness rule with the roles swapped, and it was
  # the one identifier rule in the section that nothing checked.
  #
  # Scoped PER REQUESTER, as the section writes it: two different Requesters
  # holding the same DBID at one Completer is explicitly permitted, and reporting
  # it would be the checker inventing a requirement. The response's TgtID is the
  # requester -- a grant aimed at A and a grant aimed at B are two conversations.
  #
  # Ownership expires with the transaction rather than through a retire hook of
  # its own: a re-grant is compared against whether the PREVIOUS owner is still
  # in flight, which is exactly the window the rule is written over and costs no
  # new bookkeeping at the several places a transaction can retire.
  # ---------------------------------------------------------------------------
  def _check_dbid_unique(self, f: dict, dbid: int) -> None:
    requester = int(f["tgtid"])
    key = self._inflight_key(requester, f["txnid"])
    slot = (requester, int(dbid))

    prev = self._dbid_owner.get(slot)
    # A re-grant for the SAME transaction is not a reuse: a completer is
    # permitted to send more than one DBID-bearing response, and they carry the
    # DBID the transaction already holds.
    collision = (prev is not None and prev != key
                 and self._req_inflight.get(prev, False))

    self._chk("CHI_COMPLETER_DBID_UNIQUE", not collision,
              f"completer granted DBID 0x{int(dbid):x} to requester "
              f"0x{requester:x} for TxnID 0x{int(f['txnid']):x} while its "
              f"TxnID 0x{prev[1]:x} still holds that DBID"
              if collision else "")
    self._post(self._dbid_owner, slot, key)

  # ---------------------------------------------------------------------------
  # Section 2.5: a Comp sent SEPARATE from its DBIDResp must carry the same DBID.
  # ---------------------------------------------------------------------------
  # Section 2.5: a Comp sent SEPARATE from its DBIDResp must carry the same DBID.
  #
  # Judged at both vantages under one ID, the RSP_FIELD_ZERO shape: the requester
  # reads the responses it receives, the completer the ones it drives, and a link
  # may carry a bind at only one end.
  #
  # `who` is the node the pair belongs to -- the response's TgtID, which is the
  # requester. A grant aimed at A and a Comp aimed at B are two transactions,
  # even on one TxnID.
  # ---------------------------------------------------------------------------
  def _check_comp_dbid(self, f: dict, opcode: int) -> None:
    key = self._inflight_key(f["tgtid"], f["txnid"])

    # The SEPARATE grant forms only. See the state's comment for why
    # CompDBIDResp is not one of them.
    if opcode in (int(RspOpcode.DBID_RESP), int(RspOpcode.DBID_RESP_ORD)):
      self._post(self._write_grant_dbid, key, int(f["dbid"]))
      return

    if opcode != int(RspOpcode.COMP):
      return

    granted = self._write_grant_dbid.get(key)
    if granted is None:
      # No separate grant on record, so the rule does not apply: this is a Comp
      # for a transaction that never split its response, or one whose grant this
      # bind did not see. Deliberately not counted as a pass -- a pass here
      # would be recorded on every dataless completion on the link and the
      # tally would say the rule is exercised on traffic it never governed.
      return

    # Two lines after the rule, section 2.5 makes the equality "permitted, but
    # is not required" for Atomic transactions. Exempt rather than judged: a
    # completer that renumbers is conformant, and reporting it would be the
    # checker inventing a requirement.
    if self._req_is_atomic.get(key, False):
      return

    self._chk("CHI_COMP_DBID_MATCHES_GRANT", int(f["dbid"]) == granted,
              f"Comp for TxnID 0x{int(f['txnid']):x} at SrcID 0x{key[0]:x} "
              f"carried DBID 0x{int(f['dbid']):x} where the separate DBIDResp "
              f"granted 0x{granted:x}")
    self._post(self._write_grant_dbid, key, None)

  # ---------------------------------------------------------------------------
  # Write data must be authorized by a grant, and must carry that grant's DBID.
  # ---------------------------------------------------------------------------
  def _check_write_dat_grant(self, s: dict) -> None:
    if not s["txdatflitv"]:
      return
    f = s["txdatflit"]
    if int(f["opcode"]) not in _WRITE_DAT_OPCODES_C:
      return

    dbid = f["dbid"]
    self._chk("CHI_WRITE_DAT_BEFORE_DBID",
              self._write_grant_seen_by_dbid.get(dbid, False),
              "write DAT was sent before a DBID-bearing grant response")
    self._chk("CHI_WRITE_DAT_TXNID_MATCHES_DBID", f["txnid"] == dbid,
              "write DAT txnid did not match DBID on the wire")

    if not s["txdatflitpend"]:
      # Last beat: the grant is spent.
      self._post(self._write_grant_seen_by_dbid, dbid, False)

  # ---------------------------------------------------------------------------
  # CompAck acknowledges a completion, and only where one was asked for.
  # ---------------------------------------------------------------------------
  def _check_comp_ack(self, s: dict) -> None:
    if not s["txrspflitv"]:
      return
    f = s["txrspflit"]
    if int(f["opcode"]) != int(RspOpcode.COMP_ACK):
      return

    txn = f["txnid"]
    self._chk("CHI_COMPACK_BEFORE_COMPLETION",
              self._completion_seen.get(txn, False),
              "CompAck was sent before the completion it acknowledges")
    self._chk("CHI_COMPACK_WITHOUT_EXPCOMPACK",
              self._req_exp_comp_ack.get(txn, False),
              "CompAck was sent for a request without ExpCompAck")

    self._post(self._req_exp_comp_ack, txn, False)
    self._post(self._completion_seen, txn, False)

  # ---------------------------------------------------------------------------
  # Table A-4 zero-field legality, checked from both vantages of the link.
  #
  # One rule, two directions, one check ID. It is not decoration: which vantage
  # sees a given opcode depends on which end of the link this bind sits on. A
  # PCrdGrant is txrsp at the completer and rxrsp at the requester, and a link
  # may carry a bind at only one end, so a single-direction check would be
  # silently one-sided -- the shape of defect this rule was written after.
  #
  # Unlike its SystemVerilog twin this needs no X guard: Verilator is 2-state,
  # so a field cannot hold X here. That asymmetry is the reason the SV side
  # carries a guard the Python side does not, and it is not a parity defect.
  # ---------------------------------------------------------------------------
  def _check_rsp_field_zero(self, s: dict, d: str) -> None:
    if not s[f"{d}rspflitv"]:
      return
    f = s[f"{d}rspflit"]
    opcode = int(f["opcode"])
    if opcode not in _A4_ZERO_FIELD_RSP_OPCODES_C:
      return

    bad = ((opcode in _A4_TXNID_ZERO_RSP_OPCODES_C and int(f["txnid"]) != 0)
           or (opcode in _A4_RESPERR_ZERO_RSP_OPCODES_C
               and int(f["resperr"]) != 0)
           or (opcode in _A4_RESP_ZERO_RSP_OPCODES_C and int(f["resp"]) != 0)
           or (opcode in _A4_DBID_ZERO_RSP_OPCODES_C and int(f["dbid"]) != 0))

    self._chk("CHI_RSP_FIELD_ZERO", not bad,
              f"{d}rsp opcode 0x{opcode:x} drove a Table A-4 zero-marked field "
              f"non-zero (TxnID=0x{int(f['txnid']):x} "
              f"RespErr=0x{int(f['resperr']):x} Resp=0x{int(f['resp']):x} "
              f"DBID=0x{int(f['dbid']):x})")

  # ---------------------------------------------------------------------------
  # The Resp encodings a Comp may carry -- E Table 4-7 / D Table 4-5.
  #
  # Judged from both vantages under one ID, for the reason the zero-field rule
  # above gives: which end of a link sees a given completion depends on where the
  # bind sits, and a single-direction check would be silently one-sided.
  #
  # The rule is unconditional on the opcode and needs no correlation with the
  # request, which is the whole reason it belongs here rather than in the
  # coherency checker. The two tables are written for DATALESS completions, but
  # both issues also require a Write, AtomicStore or DVM completion to carry
  # Resp = 0 -- and zero is Comp_I, already in the table. The union over every use
  # of the opcode is therefore the table itself.
  #
  # ERRORS ARE EXEMPT, and the exemption is built in rather than retrofitted:
  # both issues state that in a response with an error indication "the cache
  # state is permitted to be any value, INCLUDING RESERVED VALUES". A rule
  # without it would report every DECERR completion in this regression, which is
  # the false-failure this bench has the stimulus to produce today.
  # ---------------------------------------------------------------------------
  def _check_rsp_comp_resp(self, s: dict, d: str) -> None:
    if not s[f"{d}rspflitv"]:
      return
    f = s[f"{d}rspflit"]
    if int(f["opcode"]) != int(RspOpcode.COMP):
      return
    # DERR and NDERR carry the exemption; OK and EXOKAY do not. EXOKAY is not an
    # error -- an exclusive CleanUnique completes with it and a real cache state.
    if int(f["resperr"]) in (int(RespErr.DERR), int(RespErr.NDERR)):
      return

    self._chk("CHI_RSP_COMP_RESP_LEGAL",
              comp_resp_legal(self._issue, int(f["resp"])),
              f"{d}rsp Comp carried Resp 0b{int(f['resp']):03b}, which "
              f"{'E Table 4-7' if int(self._issue) == int(Issue.E) else 'D Table 4-5'} "
              f"does not list for a Comp response")

  # ---------------------------------------------------------------------------
  # DAT bursts: beat placement, TxnID stability, and the closing beat count.
  # ---------------------------------------------------------------------------
  def _check_dat_burst(self, s: dict, d: str) -> None:
    if not s[f"{d}datflitv"]:
      return
    f = s[f"{d}datflit"]
    st = self._burst[d]
    up = d.upper()
    more = bool(s[f"{d}datflitpend"])
    interleaved = self._dat_interleave_allowed()
    reorder = self._dat_reorder_allowed() or interleaved

    # HomeNID is applicable in CompData and DataSepResp and inapplicable and zero
    # in every other Data message (IHI 0050 E 13.10.3). Checked on whichever
    # direction carries the beat, so one rule covers both vantages without a role
    # test: the requester sends write data and receives completions, the completer
    # the reverse.
    self._chk("CHI_DAT_HOME_NID_LEGAL",
              not (int(f["homenid"])
                   and not dat_home_nid_applicable(f["opcode"])),
              f"{d} DAT opcode 0x{int(f['opcode']):x} carried HomeNID "
              f"0x{int(f['homenid']):x}, and section 13.10.3 makes the field "
              "inapplicable and zero outside CompData and DataSepResp")

    # Table A-5 gives CBusy "0" on the write-data opcodes: a requester sending
    # write data has no completer-busy level to report.
    self._chk("CHI_DAT_CBUSY_LEGAL",
              not (int(f["cbusy"]) and not dat_cbusy_applicable(f["opcode"])),
              f"{d} DAT opcode 0x{int(f['opcode']):x} carried CBusy "
              f"0x{int(f['cbusy']):x}, and Table A-5 makes the field "
              "inapplicable and zero on write data")

    # Retire the transfer this beat belongs to, counted by TxnID, before the
    # run-shaped tracking below. See _retire_dat_transfer.
    self._retire_dat_transfer(d, f)

    if not st["active"]:
      self._post(st, "count", 1)
      self._post(st, "opcode", int(f["opcode"]))
      if not reorder:
        self._chk(f"CHI_{up}_DAT_FIRST_BEAT_DATAID_ZERO", f["dataid"] == 0,
                  f"first {up} DAT beat did not start at dataid 0")
      if more:
        self._post(st, "active", True)
        self._post(st, "txn_id", f["txnid"])
        self._post(st, "expected_data_id", (f["dataid"] + 1) & self._data_id_mask)
      else:
        self._close_burst(s, d, int(f["opcode"]), f, 1)
      return

    self._chk(f"CHI_{up}_DAT_TXNID_STABLE",
              interleaved or f["txnid"] == st["txn_id"],
              f"{up} DAT burst changed txnid before {d}datflitpend dropped")
    if not reorder:
      self._chk(f"CHI_{up}_DAT_DATAID_SEQUENTIAL",
                f["dataid"] == st["expected_data_id"],
                f"{up} DAT burst dataid was not sequential")

    self._post(st, "count", st["count"] + 1)
    if more:
      self._post(st, "expected_data_id",
                 (st["expected_data_id"] + 1) & self._data_id_mask)
      return

    self._close_burst(s, d, st["opcode"], f, st["count"] + 1)
    self._post(st, "active", False)
    self._post(st, "txn_id", 0)
    self._post(st, "expected_data_id", 0)
    self._post(st, "count", 0)
    self._post(st, "opcode", int(DatOpcode.COMP_DATA))

  # Retire the read completion this beat belongs to, counted by TxnID.
  #
  # Deliberately separate from the FLITPEND-run tracker: the run tells you when
  # the CHANNEL went quiet, which is only the same thing as "this transfer
  # finished" while no two transfers share the channel. Retiring on the run
  # would leave every interleaved transfer but the last outstanding forever,
  # which surfaces at the end of the test as a TXSACTIVE failure with nothing to
  # point at the data. On contiguous traffic the count is reached on exactly the
  # beat the run ends at, so this is the same moment as before.
  def _retire_dat_transfer(self, d: str, f: dict) -> None:
    completion_side = self._is_completer if d == "tx" else self._is_requester
    if not completion_side or int(f["opcode"]) not in _READ_COMPLETION_DAT_OPCODES_C:
      return
    up = d.upper()
    txn = f["txnid"]
    seen = self._dat_beats_by_txn[d]

    if not self._expected_completion_valid_by_txn.get(txn, False):
      # No request on record for this TxnID. The orphan itself is the
      # scoreboard's to report; here it just must not accumulate a count a later,
      # legitimate transfer would inherit.
      self._post(seen, txn, 0)
      return

    beats = seen.get(txn, 0) + 1
    if beats < self._expected_completion_beats_by_txn.get(txn, 0):
      self._post(seen, txn, beats)
      return

    self._chk(f"CHI_{up}_READ_COMPLETION_DAT_OPCODE",
              self._expected_completion_opcode_by_txn.get(txn) == int(f["opcode"]),
              f"{up} read completion DAT opcode did not match the request "
              f"type")
    self._post(seen, txn, 0)
    self._post(self._expected_completion_valid_by_txn, txn, False)
    # The read half of section 2.8.3 rule 1. Keyed by the REQUEST's TxnID, not
    # the completion's: a separated read returns its data under ReturnTxnID, but
    # the CompAck that closes it still carries the TxnID the request was issued
    # with.
    self._post(self._completion_seen,
               self._dat_completion_req_txn_by_txn.get(txn, txn)
               if self._dat_completion_req_valid_by_txn.get(txn, False) else txn,
               True)
    if self._dat_completion_req_valid_by_txn.get(txn, False):
      self._post(self._req_inflight,
                 self._inflight_key(
                   f["tgtid"],
                   self._dat_completion_req_txn_by_txn.get(txn, 0)), False)
      self._post(self._dat_completion_req_valid_by_txn, txn, False)

  def _close_burst(self, s: dict, d: str, opcode: int, f: dict,
                   beats: int) -> None:
    """Last beat of a burst: does its length match what the request asked for?

    Which side of the link a burst is judged from depends on the role. Write
    data flows requester -> completer, so it is outbound at a requester and
    inbound at a completer; read completions flow the other way.

    The opcode check and the retirement moved to _retire_dat_transfer, which is
    per transfer rather than per run; what is left here is the run's own length,
    and that only means anything when the run IS one transfer.
    """
    up = d.upper()
    outbound = (d == "tx")
    write_side = self._is_requester if outbound else self._is_completer
    completion_side = self._is_completer if outbound else self._is_requester

    if write_side and opcode in _WRITE_DAT_OPCODES_C:
      dbid = f["dbid"]
      if self._expected_write_valid_by_dbid.get(dbid, False):
        self._chk(f"CHI_{up}_WRITE_DAT_BEAT_COUNT",
                  self._expected_write_beats_by_dbid.get(dbid, 0) == beats,
                  f"{up} write DAT burst beat count did not match the granted "
                  f"request size")
      self._post(self._expected_write_valid_by_dbid, dbid, False)
      return

    if completion_side and opcode in _READ_COMPLETION_DAT_OPCODES_C:
      txn = f["txnid"]
      if not self._expected_completion_valid_by_txn.get(txn, False):
        return
      self._chk(f"CHI_{up}_READ_COMPLETION_DAT_BEAT_COUNT",
                self._dat_interleave_allowed()
                or self._expected_completion_beats_by_txn.get(txn, 0) == beats,
                f"{up} read completion DAT burst beat count did not match the "
                f"request size")

  # ---------------------------------------------------------------------------
  # Temporal attempts
  # ---------------------------------------------------------------------------
  def _dat_transfer_last_beat(self, s: dict, d: str, completion_txn: int) -> bool:
    """Is the DAT beat on the wire this cycle the last one of its OWN transfer?

    The FLITPEND deassert used to answer this on its own, and on contiguous
    traffic it still does -- the transfer's last beat is the run's last beat. It
    stops answering it the moment a completer interleaves transfers, because
    FLITPEND then says the CHANNEL has more to send, not that THIS transfer
    does. Counting the transfer's own beats holds either way; the FLITPEND
    fallback covers a transfer with no request on record, where there is no
    expected count to compare against.
    """
    if not self._expected_completion_valid_by_txn.get(completion_txn, False):
      return not s[f"{d}datflitpend"]
    seen = self._dat_beats_by_txn[d].get(completion_txn, 0)
    return (seen + 1) >= self._expected_completion_beats_by_txn.get(completion_txn, 0)

  def _final_completion_observed(self, s: dict, opcode: int, req_txn: int,
                                 completion_txn: int) -> bool:
    """Is the completion that retires this request on the wire right now?"""
    cd = self._completion_dir
    if req_completion_uses_dat(opcode):
      if not s[f"{cd}datflitv"]:
        return False
      f = s[f"{cd}datflit"]
      return (f["txnid"] == completion_txn
              and self._dat_transfer_last_beat(s, cd, completion_txn)
              and int(f["opcode"]) == _expected_completion_dat_opcode(opcode))
    if not s[f"{cd}rspflitv"]:
      return False
    f = s[f"{cd}rspflit"]
    return (f["txnid"] == req_txn
            and is_final_rsp_completion(opcode, f["opcode"]))

  def _check_completion_timeout(self, s: dict) -> None:
    """Every request this checker models must eventually be completed.

    A link that stops making progress otherwise fails as a test timeout with no
    indication of which transaction stalled; this names it.
    """
    if not self._pending_completion:
      return
    still = []
    for rec in self._pending_completion:
      if self._final_completion_observed(s, rec["opcode"], rec["req_txn"],
                                         rec["completion_txn"]):
        self._chk("CHI_COMPLETION_FOLLOWS_REQ", True,
                  "request was not completed within the timeout window")
        continue
      if rec["remaining"] <= 0:
        self._err("CHI_COMPLETION_FOLLOWS_REQ",
                  f"request txnid={rec['req_txn']} opcode=0x{rec['opcode']:x} "
                  f"was not completed within {self._timeout_cycles} cycles")
        continue
      rec["remaining"] -= 1
      still.append(rec)
    self._pending_completion = still

  def _check_atomic_dat_completion(self, s: dict) -> None:
    """A data-returning atomic completes on DAT, never on a bare Comp.

    The returned pre-op value is the whole point of the transaction, so a
    completer that answers with Comp has silently dropped it.
    """
    if not self._pending_atomic:
      return
    cd = self._completion_dir
    still = []
    for rec in self._pending_atomic:
      if s[f"{cd}rspflitv"]:
        f = s[f"{cd}rspflit"]
        if (f["txnid"] == rec["req_txn"]
            and int(f["opcode"]) in PLAIN_COMPLETION_RSP_OPCODES_C):
          self._err("CHI_ATOMIC_RETURN_USES_DAT_COMPLETION",
                    f"data-returning atomic txnid={rec['req_txn']} was "
                    f"completed by an RSP instead of returning data on DAT")
          continue
      if (s[f"{cd}datflitv"] and not s[f"{cd}datflitpend"]
          and s[f"{cd}datflit"]["txnid"] == rec["completion_txn"]
          and int(s[f"{cd}datflit"]["opcode"]) == int(DatOpcode.COMP_DATA)):
        self._chk("CHI_ATOMIC_RETURN_USES_DAT_COMPLETION", True,
                  "data-returning atomic returned its data on DAT")
        continue
      still.append(rec)
    self._pending_atomic = still

  def _check_ordered_read_receipt(self, s: dict) -> None:
    """An ordered read is receipted before its data, not after.

    ReadReceipt is what releases the requester's ordering hazard. Data arriving
    first means the requester was told the read completed before it was told
    the read was ordered, which defeats the ordering it asked for.
    """
    if not self._pending_ordered:
      return
    cd = self._completion_dir
    still = []
    for rec in self._pending_ordered:
      if self._final_completion_observed(s, rec["opcode"], rec["req_txn"],
                                         rec["completion_txn"]):
        self._err("CHI_ORDERED_READ_RECEIPT_BEFORE_DAT",
                  f"ordered read txnid={rec['req_txn']} was completed before "
                  f"its ReadReceipt")
        continue
      if (s[f"{cd}rspflitv"]
          and s[f"{cd}rspflit"]["txnid"] == rec["req_txn"]
          and int(s[f"{cd}rspflit"]["opcode"]) == int(RspOpcode.READ_RECEIPT)):
        self._chk("CHI_ORDERED_READ_RECEIPT_BEFORE_DAT", True,
                  "ordered read was receipted before its completion")
        continue
      still.append(rec)
    self._pending_ordered = still
