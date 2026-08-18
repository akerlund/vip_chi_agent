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

from cocotb.triggers import RisingEdge

from vip_chi_types_pkg import (
  CHECK_IDS,
  CHECK_IDS_MAIN,
  CHECK_IDS_SV_ONLY,
  CheckSeverity,
  DatOpcode,
  LasmState,
  ReqOpcode,
  ReqOrder,
  Role,
  RspOpcode,
  chi_xfer_dat_beats,
  flit_layout,
  lasm,
  lasm_legal_step,
  req_opcode_is_atomic,
  req_opcode_is_atomic_compare,
  req_opcode_is_atomic_returning_data,
  req_opcode_is_combined_write_cmo,
)

# L-credit tracking caps, mirroring REQ/RSP/DAT_SEND_CAP_C in the SV checker.
# These bound the shadow counter, not the protocol: a grant past the cap means
# the peer is granting more credit than any sane pool holds.
_REQ_SEND_CAP_C = 64
_RSP_SEND_CAP_C = 64
_DAT_SEND_CAP_C = 64

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

_REQUESTER_ROLES_C = (Role.RNI, Role.RNF)
_COMPLETER_ROLES_C = (Role.SNF, Role.HNF)

# Flit fields this checker reads, per channel. Only these are sliced out of the
# raw flit: unpacking the whole DAT flit every beat would drag the multi-hundred
# bit `data` field through a big-int shift for a checker that never looks at it.
_FLIT_FIELDS_C = {
  "req": ("opcode", "txnid", "returntxnid", "size", "expcompack", "order"),
  "rsp": ("opcode", "txnid", "dbid", "resperr", "resp"),
  "dat": ("opcode", "txnid", "dbid", "dataid"),
}

# Opcode classes, mirroring the SV req_opcode_is_* / is_write_* functions.
_COHERENT_READ_OPCODES_C = frozenset({
  int(ReqOpcode.READ_SHARED), int(ReqOpcode.READ_CLEAN),
  int(ReqOpcode.READ_UNIQUE), int(ReqOpcode.MAKE_READ_UNIQUE),
  int(ReqOpcode.READ_ONCE),
})
_COHERENT_WRITE_DATA_OPCODES_C = frozenset({
  int(ReqOpcode.WRITE_BACK_FULL), int(ReqOpcode.WRITE_CLEAN_FULL),
  int(ReqOpcode.WRITE_UNIQUE_FULL), int(ReqOpcode.WRITE_UNIQUE_PTL),
  # WriteEvictOrEvict is a CopyBack whose data is CONDITIONAL: the home asks for it with CompDBIDResp or declines with a bare Comp.
  # Listing it here is still right, and the conditionality takes care of itself -- the burst-length check arms only when a DBID is granted, which is exactly the leg that carries data.
  int(ReqOpcode.WRITE_EVICT_OR_EVICT),
})
# MakeUnique completes on an RSP-only Comp (no data), like CleanUnique.
_COHERENT_RSP_ONLY_OPCODES_C = frozenset({
  int(ReqOpcode.EVICT), int(ReqOpcode.CLEAN_INVALID),
  int(ReqOpcode.MAKE_INVALID), int(ReqOpcode.CLEAN_UNIQUE),
  int(ReqOpcode.MAKE_UNIQUE),
})
# Non-coherent opcodes whose completion this checker models.
_MODELED_COMPLETION_OPCODES_C = frozenset({
  int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP),
  int(ReqOpcode.WRITE_NO_SNP_PTL), int(ReqOpcode.WRITE_NO_SNP_FULL),
  int(ReqOpcode.WRITE_NO_SNP_ZERO), int(ReqOpcode.CLEAN_SHARED_PERSIST),
  int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP),
  # WriteUniqueZero is the snoopable twin of WriteNoSnpZero and completes the
  # same way, with a bare Comp. Naming only one of the pair left every rule
  # gated on this set standing down for the other -- TxnID reuse and the
  # completion timeout, in both ports -- for an opcode that ships with its own
  # sequence, testcase and completer service routine.
  int(ReqOpcode.WRITE_UNIQUE_ZERO),
})
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
_PLAIN_COMPLETION_RSP_OPCODES_C = frozenset({
  int(RspOpcode.COMP), int(RspOpcode.COMP_DBID_RESP),
})

# --------------------------------------------------------------------------- #
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


def _req_opcode_is_coherent_read(opcode: int) -> bool:
  return int(opcode) in _COHERENT_READ_OPCODES_C


def _req_has_modeled_completion(opcode: int) -> bool:
  op = int(opcode)
  return (op in _MODELED_COMPLETION_OPCODES_C
          or op in _COHERENT_READ_OPCODES_C
          or op in _COHERENT_WRITE_DATA_OPCODES_C
          or op in _COHERENT_RSP_ONLY_OPCODES_C
          or req_opcode_is_atomic(op))


def _req_completion_uses_dat(opcode: int) -> bool:
  op = int(opcode)
  return (op in (int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP))
          or op in _COHERENT_READ_OPCODES_C
          or req_opcode_is_atomic_returning_data(op))


def _is_write_req_opcode(opcode: int) -> bool:
  """A combined Write + CMO is a write request here, exactly as its plain form
  is. Leaving the family out made this function quietly answer "not a write" for
  six legal write opcodes, which switched off the ExpCompAck bookkeeping: a
  combined write that set ExpCompAck was then reported as sending a CompAck it
  had never asked for.
  """
  op = int(opcode)
  # WriteUniqueZero is listed on its own rather than folded into
  # _NON_COHERENT_WRITE_OPCODES_C, because it is snoopable and that name would
  # then be wrong. Both Zero opcodes belong here for a reason that is not about
  # data: neither carries a write burst, but this function decides whether
  # ExpCompAck is RECORDED for the TxnID, and a slot that is never written keeps
  # the previous transaction's value. _req_write_payload_beats answers the data
  # question separately, and correctly returns 0 for both.
  return (op in _NON_COHERENT_WRITE_OPCODES_C
          or op == int(ReqOpcode.WRITE_UNIQUE_ZERO)
          or op in _COHERENT_WRITE_DATA_OPCODES_C
          or req_opcode_is_combined_write_cmo(op)
          or req_opcode_is_atomic(op))


def _is_final_rsp_completion(opcode: int, rsp_opcode: int) -> bool:
  """Does this RSP retire the request, or is it an intermediate response?"""
  if _req_completion_uses_dat(opcode):
    # The completion arrives on DAT; no RSP retires such a request.
    return False
  if int(opcode) == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP):
    return int(rsp_opcode) == int(RspOpcode.COMP_PERSIST)
  return int(rsp_opcode) in _PLAIN_COMPLETION_RSP_OPCODES_C


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

    # LASM coverage accumulates over the whole run and is deliberately NOT
    # cleared by _reset_state: a link that was torn down and brought back up
    # covered those edges, and forgetting them at the reset would understate
    # what the run exercised. Seeded by init_check_control below.

    self._reset_state()

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------
  def _chk(self, rule: str, ok: bool, msg: str, where: str) -> None:
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
      self._err(rule, msg, where)

  def _err(self, rule: str, msg: str, where: str) -> None:
    self.fail_count[rule] = self.fail_count.get(rule, 0) + 1
    severity = self.check_severity.get(rule, CheckSeverity.ERROR)
    if severity is CheckSeverity.OFF:
      # Counted, not reported, and not a run failure. This is what a negative
      # control uses to prove its rule fires: the tally still moves, so the test
      # can assert on it, but the deliberate violation does not read as a bug.
      # Logged at info so the run still SHOWS what happened -- silence here would
      # make a provoked failure and a suppressed real one look identical.
      self.log.info(f"EXPECTED {rule}: {msg}. IHI 0050 {where}.")
      return
    if severity is CheckSeverity.WARNING:
      # Demoted by the USER, so it must not fail the run -- but it is still a
      # violation and still visible, unlike OFF.
      self.log.warning(f"{rule}: {msg}. IHI 0050 {where}.")
      return
    self.errors += 1
    self.log.error(f"{rule}: {msg}. IHI 0050 {where}.")

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

    new = not os.path.exists(path)
    with open(path, "a", encoding="utf-8") as fh:
      if new:
        fh.write("run,bind,check,enabled,severity,passes,fails\n")
      for rule in self._owned_rules():
        fh.write(
          f"{run_name},{self.log.name},{rule},"
          f"{int(self.check_enable.get(rule, True))},"
          f"{self.check_severity.get(rule, CheckSeverity.ERROR).name},"
          f"{self.pass_count.get(rule, 0)},{self.fail_count.get(rule, 0)}\n")

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
    self._lasm = LasmState.STOP
    self._lasm_dwell = 0

  def _reset_tracking_state(self) -> None:
    """Everything the SV always_ff clears on `!checks_enable || !rst_n`.

    Split out from _reset_state because the restart-window countdown must NOT
    be cleared here: it arms at reset release, the one moment the link is
    guaranteed idle and therefore the enable gate is low. Clearing it on the
    disable path would disarm the check on the very cycle it was armed.
    """
    # Per-TxnID bookkeeping. The SV declares these as arrays sized by the TxnID
    # space and clears them on reset; a dict with a zero default is the same
    # thing without allocating the whole space up front.
    self._req_inflight = {}
    self._req_exp_comp_ack = {}
    self._write_completion_seen = {}
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

  @staticmethod
  def _lasm_of(s: dict) -> LasmState:
    """The LASM state of this link, as seen from this endpoint.

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
             "rxlinkactivereq", "rxlinkactiveack", "rxsactive"]
    for ch in _CHANNELS_C:
      names += [f"tx{ch}flitv", f"tx{ch}flitpend", f"tx{ch}lcrdv",
                f"rx{ch}flitv", f"rx{ch}flitpend", f"rx{ch}lcrdv"]
    s = {n: g(n) for n in names}
    # Flit contents only where a flit is actually being presented. Every check
    # that reads them is already guarded by the same flitv, so a None here is
    # never dereferenced -- and skipping the slice on idle cycles keeps this
    # coroutine off the critical path of every clock edge.
    for ch in _CHANNELS_C:
      for d in ("tx", "rx"):
        s[f"{d}{ch}flit"] = self._flit_fields(d, ch) if s[f"{d}{ch}flitv"] else None
    return s

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
        self._check_pend_requires_valid(cur)
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
    self._chk(
      "CHI_LINK_SIDEBAND_IDLE_IN_RESET",
      not (s["txlinkactivereq"] or s["txlinkactiveack"] or s["txsactive"]),
      "link sideband was not held idle during reset",
      "section 13.4",
    )
    for ch in _CHANNELS_C:
      self._chk(
        f"CHI_{ch.upper()}_IDLE_IN_RESET",
        not (s[f"tx{ch}flitv"] or s[f"tx{ch}flitpend"] or s[f"tx{ch}lcrdv"]),
        f"{ch.upper()} channel was not held idle during reset",
        "section 13.4",
      )

  # ---------------------------------------------------------------------------
  # Link Activation State Machine, one per link (see _lasm_of).
  # ---------------------------------------------------------------------------
  def _check_lasm(self, s: dict) -> None:
    """Advance the LASM and judge the step against the legal transition set.

    The state is registered rather than recomputed from a pair of samples so it
    survives the enable gate and so the dwell counter has somewhere to live.
    """
    cur = self._lasm
    nxt = self._lasm_of(s)

    self._chk(
      "CHI_LASM_LEGAL_TRANSITION",
      lasm_legal_step(cur, nxt),
      f"link stepped {cur.name} -> {nxt.name}; the LASM may only hold or "
      f"advance STOP -> ACTIVATE -> RUN -> DEACTIVATE -> STOP",
      "section 13.4",
    )

    # LASM coverage, kept here rather than in vip_chi_coverage for the same
    # structural reason the SV covergroup sits in vip_chi_sva: that component
    # subscribes to analysis ports and has no bus handle, and link state is a
    # wire property. Only the four LEGAL edges are binned -- an illegal step is
    # the check's business, and giving it a bin would let a regression "cover" a
    # violation.
    self._lasm_state_seen[nxt] += 1
    if nxt is not cur and lasm_legal_step(cur, nxt):
      self._lasm_edge_seen[(cur, nxt)] += 1

    self._lasm_dwell = 0 if nxt is not cur else self._lasm_dwell + 1
    self._lasm = nxt

    self._check_lcrd_quiescent_in_stop(nxt)

  def _check_lcrd_quiescent_in_stop(self, state: LasmState) -> None:
    """No L-credit may still be outstanding while the link is in STOP.

    A sender must have returned every credit it holds before the link goes down;
    one left behind means the shadow and the link disagree about what the peer
    is entitled to send, and that disagreement is what the NEXT activation would
    start from -- a pool seeded with a stale credit lets the first flit after
    bring-up go out unauthorised, which the underflow check could then never
    catch because the count never reaches zero.

    Read before _check_lcrd runs this cycle, so the counts judged are the ones
    carried INTO STOP rather than any same-cycle return.
    """
    if state is not LasmState.STOP:
      return
    for pool, held in self._lcrd.items():
      self._chk(
        "CHI_LCRD_QUIESCENT_IN_STOP", held == 0,
        f"{pool} still holds {held} L-credit(s) with the link in STOP",
        "section 13.6",
      )

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
    state = self._lasm
    for ch in _CHANNELS_C:
      if s[f"tx{ch}flitv"]:
        self._chk(
          f"CHI_{ch.upper()}_FLITV_REQUIRES_LINK",
          self._flit_send_allowed(state, s, ch),
          f"tx{ch}flitv asserted with the link in {state.name}, not RUN",
          "section 13.7",
        )
      if s[f"tx{ch}lcrdv"]:
        self._chk(
          f"CHI_{ch.upper()}_LCRDV_REQUIRES_LINK", state is not LasmState.STOP,
          f"tx{ch}lcrdv asserted with the link in STOP",
          "section 13.7",
        )

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
  # FLITPEND is a look-ahead for a flit that must actually arrive.
  # ---------------------------------------------------------------------------
  def _check_pend_requires_valid(self, s: dict) -> None:
    for ch in _CHANNELS_C:
      if s[f"tx{ch}flitpend"]:
        self._chk(
          f"CHI_{ch.upper()}_PEND_REQUIRES_VALID", bool(s[f"tx{ch}flitv"]),
          f"tx{ch}flitpend asserted without tx{ch}flitv",
          "section 13.3",
        )

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
      if grant:
        self._chk(
          "CHI_LCRD_OVERFLOW", count != cap,
          f"{pool} L-credit grant overflowed the tracked count",
          "section 13.6",
        )
        if count != cap:
          count += 1
      if consume:
        self._chk(
          "CHI_LCRD_UNDERFLOW", count != 0,
          f"{pool} L-credit consumed with no credit available (underflow)",
          "section 13.6",
        )
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
        f"outstanding once a tear-down has begun",
        "section 13.4",
      )

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
      if limit <= 0 or self._lasm is not state:
        continue
      self._chk(
        rule, self._lasm_dwell != limit,
        f"link stuck in {state.name} for {self._lasm_dwell} cycles "
        f"(tx {what} unacknowledged, limit {limit})",
        "section 13.4",
      )

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
                "link activation did not restart after reset release",
                "section 13.4")
      self._act_countdown = None
      return
    self._act_countdown -= 1
    if self._act_countdown <= 0:
      self._err("CHI_LINK_RESTARTS_AFTER_RESET",
                "link activation did not restart after reset release",
                "section 13.4")
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
        or op in _COHERENT_WRITE_DATA_OPCODES_C):
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
        or op in _COHERENT_READ_OPCODES_C
        or req_opcode_is_atomic_returning_data(op)):
      return chi_xfer_dat_beats(size, self._data_bytes)
    return 0

  # ---------------------------------------------------------------------------
  def _check_transactions(self, s: dict) -> None:
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

    self._check_completion_timeout(s)
    self._check_atomic_dat_completion(s)
    self._check_ordered_read_receipt(s)
    self._check_txsactive(s)

    self._flush()

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

    # Requester vantage only. TXSACTIVE reports the TRANSMITTING node's own
    # outstanding transactions, and a completer has none: the requests it is
    # servicing belong to the requester at the other end of the link, which is
    # the node whose sideband covers them. This checker's _req_inflight tracks
    # received requests at a completer, so it would otherwise read that peer's
    # window off the wrong wire.
    if outstanding and self._is_requester:
      self._chk(
        "CHI_TXSACTIVE_COVERS_OUTSTANDING", bool(s["txsactive"]),
        f"TXSACTIVE was low with {outstanding} transaction(s) still "
        f"outstanding: the window it reports must cover every one of them, "
        f"not just the cycles carrying flits",
        "section 13.4")

    # An episode ends the moment anything happens on the link. That is what
    # keeps the bound clear of a sender's own retire tail: the completion, and
    # any CompAck chasing it, are flits, so the count only runs once the link
    # is genuinely idle AND this checker sees nothing outstanding.
    link_quiet = not outstanding and not any(
      s[f"{d}{ch}flitv"] for d in ("tx", "rx") for ch in _CHANNELS_C)

    limit = _TXSACTIVE_SETTLE_CYCLES_C + self._txsactive_extend_max_cycles

    if not (link_quiet and s["txsactive"]):
      # The episode ended. Score it as a pass -- whether it ended because the
      # sideband dropped or because traffic resumed, it did not stay up
      # indefinitely, which is what this rule asserts. Scoring the ENDING (and
      # not merely staying silent) is what keeps the rule out of the summary's
      # blind spot: a check that only ever reports failures is indistinguishable
      # from one that never runs.
      if self._txsactive_idle_cycles and not self._txsactive_reported:
        self._chk("CHI_TXSACTIVE_DEASSERT_BOUNDED", True, "", "section 13.4")
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
      f"{limit}): a sideband that never drops reports nothing",
      "section 13.4")

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

    if _req_has_modeled_completion(opcode):
      # A TxnID identifies an outstanding transaction. Reusing one before its
      # first use retires makes the two indistinguishable to every downstream
      # tracker, including this checker.
      self._chk(reuse_rule, not self._req_inflight.get(txn, False),
                reuse_msg, "section 2.3")
      self._post(self._req_inflight, txn, True)
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

    if _is_write_req_opcode(opcode):
      self._post(self._req_exp_comp_ack, txn, bool(f["expcompack"]))
      self._post(self._write_completion_seen, txn, False)

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
    if opcode in _PLAIN_COMPLETION_RSP_OPCODES_C:
      self._post(self._write_completion_seen, txn, True)
      self._post(self._req_inflight, txn, False)
    elif opcode == int(RspOpcode.COMP_PERSIST):
      self._post(self._req_inflight, txn, False)
    elif opcode == int(RspOpcode.RETRY_ACK):
      # A RetryAck retires the bounced request: the completer did not accept
      # it, so its TxnID is released and the requester re-issues after the
      # matching PCrdGrant. Clearing the marker keeps that legitimate re-issue
      # from reading as a TxnID reuse.
      self._post(self._req_inflight, txn, False)

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
    if opcode == int(RspOpcode.RETRY_ACK):
      # Mirror of the requester side: a RetryAck this node drove retires the
      # bounced request's TxnID.
      self._post(self._req_inflight, f["txnid"], False)

  def _record_write_grant(self, f: dict, mark_grant_seen: bool) -> None:
    """Carry a request's expected write size across to its granted DBID.

    The write data that follows is tagged with the DBID, not with the request's
    TxnID, so the beat-count expectation has to be re-keyed here or the burst
    check would have nothing to compare against.
    """
    dbid = f["dbid"]
    beats = self._expected_write_beats_by_txn.get(f["txnid"], 0)
    if mark_grant_seen:
      self._post(self._write_grant_seen_by_dbid, dbid, True)
    self._post(self._expected_write_beats_by_dbid, dbid, beats)
    self._post(self._expected_write_valid_by_dbid, dbid, beats != 0)

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
              "write DAT was sent before a DBID-bearing grant response",
              "section 2.6")
    self._chk("CHI_WRITE_DAT_TXNID_MATCHES_DBID", f["txnid"] == dbid,
              "write DAT txnid did not match DBID on the wire",
              "section 2.6")

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
              self._write_completion_seen.get(txn, False),
              "CompAck was sent before a write completion response",
              "section 2.6")
    self._chk("CHI_COMPACK_WITHOUT_EXPCOMPACK",
              self._req_exp_comp_ack.get(txn, False),
              "CompAck was sent for a request without ExpCompAck",
              "section 2.6")

    self._post(self._req_exp_comp_ack, txn, False)
    self._post(self._write_completion_seen, txn, False)

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
              f"DBID=0x{int(f['dbid']):x})",
              "Table A-4")

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

    # Retire the transfer this beat belongs to, counted by TxnID, before the
    # run-shaped tracking below. See _retire_dat_transfer.
    self._retire_dat_transfer(d, f)

    if not st["active"]:
      self._post(st, "count", 1)
      self._post(st, "opcode", int(f["opcode"]))
      if not reorder:
        self._chk(f"CHI_{up}_DAT_FIRST_BEAT_DATAID_ZERO", f["dataid"] == 0,
                  f"first {up} DAT beat did not start at dataid 0",
                  "section 2.9")
      if more:
        self._post(st, "active", True)
        self._post(st, "txn_id", f["txnid"])
        self._post(st, "expected_data_id", (f["dataid"] + 1) & self._data_id_mask)
      else:
        self._close_burst(s, d, int(f["opcode"]), f, 1)
      return

    self._chk(f"CHI_{up}_DAT_TXNID_STABLE",
              interleaved or f["txnid"] == st["txn_id"],
              f"{up} DAT burst changed txnid before {d}datflitpend dropped",
              "section 2.9")
    if not reorder:
      self._chk(f"CHI_{up}_DAT_DATAID_SEQUENTIAL",
                f["dataid"] == st["expected_data_id"],
                f"{up} DAT burst dataid was not sequential", "section 2.9")

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
              f"type", "section 2.9")
    self._post(seen, txn, 0)
    self._post(self._expected_completion_valid_by_txn, txn, False)
    if self._dat_completion_req_valid_by_txn.get(txn, False):
      self._post(self._req_inflight,
                 self._dat_completion_req_txn_by_txn.get(txn, 0), False)
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
                  f"request size", "section 2.9")
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
                f"request size", "section 2.9")

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
    if _req_completion_uses_dat(opcode):
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
            and _is_final_rsp_completion(opcode, f["opcode"]))

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
                  "request was not completed within the timeout window",
                  "section 2.3")
        continue
      if rec["remaining"] <= 0:
        self._err("CHI_COMPLETION_FOLLOWS_REQ",
                  f"request txnid={rec['req_txn']} opcode=0x{rec['opcode']:x} "
                  f"was not completed within {self._timeout_cycles} cycles",
                  "section 2.3")
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
            and int(f["opcode"]) in _PLAIN_COMPLETION_RSP_OPCODES_C):
          self._err("CHI_ATOMIC_RETURN_USES_DAT_COMPLETION",
                    f"data-returning atomic txnid={rec['req_txn']} was "
                    f"completed by an RSP instead of returning data on DAT",
                    "section 2.12")
          continue
      if (s[f"{cd}datflitv"] and not s[f"{cd}datflitpend"]
          and s[f"{cd}datflit"]["txnid"] == rec["completion_txn"]
          and int(s[f"{cd}datflit"]["opcode"]) == int(DatOpcode.COMP_DATA)):
        self._chk("CHI_ATOMIC_RETURN_USES_DAT_COMPLETION", True,
                  "data-returning atomic returned its data on DAT",
                  "section 2.12")
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
                  f"its ReadReceipt", "section 2.7")
        continue
      if (s[f"{cd}rspflitv"]
          and s[f"{cd}rspflit"]["txnid"] == rec["req_txn"]
          and int(s[f"{cd}rspflit"]["opcode"]) == int(RspOpcode.READ_RECEIPT)):
        self._chk("CHI_ORDERED_READ_RECEIPT_BEFORE_DAT", True,
                  "ordered read was receipted before its completion",
                  "section 2.7")
        continue
      still.append(rec)
    self._pending_ordered = still
