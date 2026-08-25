################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_item.sv.
#
# The shared CHI transaction item: request/response/snoop fields plus the
# sequence-facing randomization knobs and the raw-override flit views. Flit
# PACKING lives in the drivers (via the vip_chi_types_pkg codec); this object is
# the field container the sequencer carries and the monitor publishes.
#
# Port notes:
#   * @vsc.randobj + uvm_sequence_item, exactly as vip_axi4_item.py. pyvsc solves
#     the genuinely-constrained scalar fields (opcode/addr/size/role/...).
#   * SV `constraint` blocks -> @vsc.constraint methods. Compile-time CFG_P
#     branches (issue / feature enables / data geometry) are baked as plain
#     Python `if` at trace time; runtime knobs (min/max addr+size, alignment,
#     raw_override) are mirrored into vsc STATE fields in pre_randomize.
#   * The SV `addr & ((1<<size)-1) == 0` alignment constraint ports verbatim --
#     pyvsc solves the variable shift (verified).
#   * post_randomize sizes the per-beat payload arrays from opcode+size and fills
#     them per data_type, then picks the DAT opcode -- 1:1 with the SV.
#
################################################################################

from __future__ import annotations

import random

import vsc
from pyuvm import uvm_sequence_item

from vip_chi_types_pkg import (
  ChiCfg, VIP_CHI_DEFAULT_CFG, Dir, Role, DataType, ReqOpcode, DatOpcode,
  RspOpcode, Resp, RespErr, Issue, RawChannel, mask, clog2, chi_xfer_dat_beats,
  req_opcode_is_atomic, req_opcode_is_atomic_compare,
  exp_comp_ack_required, exp_comp_ack_prohibited,
  SnpAttr, req_dodwt_applicable, SnpAttrReq, snp_attr_requirement,
  req_return_txn_id_applicable,
  req_return_nid_applicable,
  req_tagop_permitted_mask,
  TAGOP_UPDATE,
)

_RO = ReqOpcode  # brevity in the opcode-set tables below

# Non-coherent legal REQ opcode sets (con_opcode_legal), by direction and issue.
_READ_OPCODES_D = [_RO.READ_NO_SNP, _RO.PREFETCH_TGT]
_READ_OPCODES_E = _READ_OPCODES_D + [_RO.READ_NO_SNP_SEP]
_WRITE_OPCODES_D = [_RO.WRITE_NO_SNP_PTL, _RO.WRITE_NO_SNP_FULL,
                    _RO.CLEAN_SHARED_PERSIST] + list(range(0x28, 0x3A))
_WRITE_OPCODES_E = _WRITE_OPCODES_D + [_RO.WRITE_NO_SNP_ZERO,
                                       _RO.CLEAN_SHARED_PERSIST_SEP]

# Combined Write + CMO (Issue E). Legal to BUILD, but deliberately NOT in the
# randomization pool above: they are opt-in through cfg.combined_write_cmo_enable
# so an existing random write test cannot start emitting them and change every
# waveform. Every one sits in the Opcode[6] = 1 half of Table 13-14 and does not
# fit CHI-D's 6-bit REQ opcode field at all.
_COMBINED_WRITE_CMO_OPCODES = [
  _RO.WRITE_NO_SNP_FULL_CLEAN_SH, _RO.WRITE_NO_SNP_FULL_CLEAN_INV,
  _RO.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP, _RO.WRITE_NO_SNP_PTL_CLEAN_SH,
  _RO.WRITE_NO_SNP_PTL_CLEAN_INV, _RO.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP,
]

# Coherent RN-F legal REQ opcode sets (con_opcode_legal_rnf). MakeReadUnique is
# 0x41, which needs the 7-bit CHI-E REQ opcode field -- randomizing it under
# CHI-D would emit a flit that truncates to 0x01 (ReadShared) on the wire, so it
# joins the read set only for issue E.
_RNF_READ_OPCODES_D = [_RO.READ_SHARED, _RO.READ_CLEAN, _RO.READ_UNIQUE,
                       _RO.READ_ONCE]
_RNF_READ_OPCODES_E = _RNF_READ_OPCODES_D + [_RO.MAKE_READ_UNIQUE]
_RNF_WRITE_OPCODES = [_RO.WRITE_BACK_FULL, _RO.WRITE_CLEAN_FULL, _RO.EVICT,
                      _RO.CLEAN_UNIQUE, _RO.MAKE_UNIQUE, _RO.CLEAN_INVALID,
                      _RO.MAKE_INVALID, _RO.WRITE_UNIQUE_FULL, _RO.WRITE_UNIQUE_PTL]

# Two isolated CHI-E coherent opcodes. Legal to BUILD, but deliberately NOT in
# the pool above: each is opt-in through its own item knob, for the same reason
# the combined Write + CMO forms are -- both look like ordinary coherent writes
# to the solver, so an unconditional pool entry would put them into every random
# coherent write test. Both sit in the Opcode[6] = 1 half of Table 13-14 and do
# not fit CHI-D's 6-bit REQ opcode field at all.
_WRITE_UNIQUE_ZERO_OPCODES = [_RO.WRITE_UNIQUE_ZERO]
_WRITE_EVICT_OR_EVICT_OPCODES = [_RO.WRITE_EVICT_OR_EVICT]

# Opcodes that carry write/atomic DAT payload (get_payload_beat_count). The
# combined forms carry the same payload as the write they contain -- the CMO half
# adds responses, not data.
_WRITE_PAYLOAD_OPCODES = {
  int(_RO.WRITE_NO_SNP_FULL), int(_RO.WRITE_NO_SNP_PTL), int(_RO.WRITE_BACK_FULL),
  int(_RO.WRITE_CLEAN_FULL), int(_RO.WRITE_UNIQUE_FULL), int(_RO.WRITE_UNIQUE_PTL),
  int(_RO.WRITE_EVICT_OR_EVICT),
} | {int(o) for o in _COMBINED_WRITE_CMO_OPCODES}

_PARTIAL_WRITE_OPCODES = {
  int(_RO.WRITE_NO_SNP_PTL), int(_RO.WRITE_UNIQUE_PTL),
  int(_RO.WRITE_NO_SNP_PTL_CLEAN_SH), int(_RO.WRITE_NO_SNP_PTL_CLEAN_INV),
  int(_RO.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP),
}

# ExpCompAck legality per IHI 0050 E Table 2-9 / D Table 2-8, enumerated from
# the types-package classifier so the table is written once. Two sets per
# requester column: the opcodes REQUIRED to carry the bit, and the opcodes
# ALLOWED to (required plus optional). Anything outside ALLOWED is prohibited,
# including an encoding no ReqOpcode member names -- which is the same answer
# the SystemVerilog function's default gives.
_COMPACK_REQUIRED_RNF = tuple(sorted(
  int(o) for o in _RO if exp_comp_ack_required(int(o), True)))
_COMPACK_ALLOWED_RNF = tuple(sorted(
  int(o) for o in _RO if not exp_comp_ack_prohibited(int(o), True)))
_COMPACK_ALLOWED_NON_RNF = tuple(sorted(
  int(o) for o in _RO if not exp_comp_ack_prohibited(int(o), False)))
# The opcodes in which DoDWT is a field at all (E section 13.10.25). Derived from
# the classifier rather than listed, so the two can never drift.
_DODWT_APPLICABLE = tuple(sorted(
  int(o) for o in _RO if req_dodwt_applicable(int(o))))
# Table 2-14's two constrained columns, derived from the classifier rather than
# listed so the two can never drift.
_SNP_ATTR_MUST_BE_ONE = tuple(sorted(
  int(o) for o in _RO if snp_attr_requirement(int(o)) is SnpAttrReq.ONE))
_SNP_ATTR_MUST_BE_ZERO = tuple(sorted(
  int(o) for o in _RO if snp_attr_requirement(int(o)) is SnpAttrReq.ZERO))


# The REQ opcodes IHI 0050 E 13.10.4 marks ReturnNID INAPPLICABLE for, derived
# from the classifier rather than restated, so the constraint and the checker
# cannot disagree. The solver needs a closed list; req_return_nid_applicable is
# the single source of truth for both.
_RETURN_NID_INAPPLICABLE_C = tuple(sorted(
  int(o) for o in ReqOpcode if not req_return_nid_applicable(int(o))))

# The same for ReturnTxnID, from its own classifier. The two lists are NOT the
# same -- CleanSharedPersistSep carries a ReturnNID and no ReturnTxnID -- which
# is exactly why each is derived separately.
_RETURN_TXN_ID_INAPPLICABLE_C = tuple(sorted(
  int(o) for o in ReqOpcode if not req_return_txn_id_applicable(int(o))))


# Table 12-2's permitted-TagOp mask, inverted into the opcode groups a
# constraint can name. Derived from req_tagop_permitted_mask rather than
# transcribed beside it, so the generator and CHI_REQ_TAGOP_LEGAL cannot
# disagree about the same table: one of them would then be wrong, and a
# generator that produces what the checker rejects is the worse of the two.
#
# 0b1111 -- every encoding permitted -- is dropped rather than emitted as a
# no-op constraint. It covers Issue D (no memory tagging, and the issue gate
# already holds TagOp at zero), CleanUnique (no row in Table 12-2) and
# ReqLCrdReturn (a Don't Care by the note under it), all of which the classifier
# returns unjudged on purpose.
# CleanShared is excluded, and the exclusion is load-bearing rather than tidy:
# check_classifier_coverage.py records it as unimplemented -- "no
# con_opcode_legal, sequence or driver" -- and enforces that by failing on any
# reference to it outside the type packages. Naming it in a constraint would
# make that claim false while changing nothing, because con_opcode_legal still
# refuses to generate it. The CHECKER still judges it: an inbound CleanShared
# carrying a bad TagOp is reported by CHI_REQ_TAGOP_LEGAL, which is the only
# vantage from which this VIP can see one at all.
_TAGOP_UNGENERATABLE_C = (int(ReqOpcode.CLEAN_SHARED),)  # unimplemented-ok


def _tagop_groups():
  groups = {}
  for op in ReqOpcode:
    if int(op) in _TAGOP_UNGENERATABLE_C:
      continue
    m = req_tagop_permitted_mask(int(Issue.E), int(op))
    if m == 0b1111:
      continue
    groups.setdefault(m, []).append(int(op))
  return tuple(
    (tuple(sorted(ops)), tuple(v for v in range(4) if (m >> v) & 1))
    for m, ops in sorted(groups.items()))


_TAGOP_GROUPS_C = _tagop_groups()


@vsc.randobj
class vip_chi_item(uvm_sequence_item):

  def __init__(self, name: str = "vip_chi_item", cfg: ChiCfg = None):
    super().__init__(name)
    self.name = name
    if cfg is None:
      # Mirror SV: an unconfigured item defaults to the tiny placeholder
      # (VIP_CHI_DEFAULT_CFG_C) so a missing cfg is obviously degenerate rather
      # than silently taking a plausible-but-arbitrary geometry.
      cfg = VIP_CHI_DEFAULT_CFG
    self.cfg = cfg

    # ---- CFG-derived constants (fixed at construction) --------------------
    self._issue_e = cfg.is_e
    self._db = cfg.data_bytes
    self._data_w = 8 * cfg.data_bytes
    self._be_w = cfg.be_width
    self._addr_w = cfg.addr_width
    self._node_w = cfg.node_id_width
    self._txn_w = cfg.txn_id_width
    self._data_id_w = cfg.data_id_width
    self._clog2_db_p1 = clog2(cfg.data_bytes) + 1
    self._read_set = _READ_OPCODES_E if self._issue_e else _READ_OPCODES_D
    self._write_set = _WRITE_OPCODES_E if self._issue_e else _WRITE_OPCODES_D
    self._rnf_read_set = _RNF_READ_OPCODES_E if self._issue_e \
                         else _RNF_READ_OPCODES_D

    # ---- rand scalar fields (REQ) -----------------------------------------
    self.direction = vsc.rand_bit_t(1)
    self.role = vsc.rand_bit_t(3)
    self.opcode = vsc.rand_bit_t(7)
    self.addr = vsc.rand_bit_t(max(self._addr_w, 1))
    self.size = vsc.rand_bit_t(3)
    self.src_id = vsc.rand_bit_t(max(self._node_w, 1))
    self.tgt_id = vsc.rand_bit_t(max(self._node_w, 1))
    self.txn_id = vsc.rand_bit_t(max(self._txn_w, 1))
    self.return_nid = vsc.rand_bit_t(max(self._node_w, 1))
    self.return_txn_id = vsc.rand_bit_t(max(self._txn_w, 1))
    self.lp_id = vsc.rand_bit_t(max(cfg.lpid_width, 1))
    self.qos = vsc.rand_bit_t(4)
    self.ns = vsc.rand_bit_t(1)
    self.order = vsc.rand_bit_t(2)
    self.mem_attr = vsc.rand_bit_t(4)
    self.pcrd_type = vsc.rand_bit_t(4)
    self.allow_retry = vsc.rand_bit_t(1)
    self.excl = vsc.rand_bit_t(1)
    self.exp_comp_ack = vsc.rand_bit_t(1)
    self.tracetag = vsc.rand_bit_t(1)
    # REQ bit 17 carries SnpAttr in both issues and, under Issue E only, DoDWT.
    # Two members for one wire bit because the two are different fields with
    # different rules; req_dodwt_applicable(opcode) says which one this request
    # is actually carrying, and con_dodwt_overload keeps the pair from ever
    # disagreeing about it.
    self.snp_attr = vsc.rand_bit_t(1)
    self.dodwt = vsc.rand_bit_t(1)
    self.likelyshared = vsc.rand_bit_t(1)
    self.endian = vsc.rand_bit_t(1)
    self.group_id_ext = vsc.rand_bit_t(3)
    self.tagop = vsc.rand_bit_t(2)
    self.mpam = vsc.rand_bit_t(max(cfg.mpam_field_width, 1))
    self.datacheck = vsc.rand_bit_t(max(cfg.datacheck_width, 1))
    self.poison = vsc.rand_bit_t(max(cfg.poison_width, 1))

    # ---- vsc STATE fields (synced from knobs in pre_randomize) -------------
    self.s_raw_override = vsc.uint8_t(0)
    self.s_enforce_align = vsc.uint8_t(1)
    self.s_atomic_oversized = vsc.uint8_t(0)
    self.s_combined_cmo = vsc.uint8_t(0)
    self.s_write_unique_zero = vsc.uint8_t(0)
    self.s_write_evict_or_evict = vsc.uint8_t(0)
    self.s_min_size = vsc.uint8_t(0)
    self.s_max_size = vsc.uint8_t(6)
    self.s_min_addr = vsc.uint64_t(0)
    self.s_max_addr = vsc.uint64_t(mask(self._addr_w))

    # ---- non-rand response / snoop / raw scalars --------------------------
    self.dat_opcode = int(DatOpcode.COMP_DATA)
    self.dat_tagop = 0
    # TagOp as carried by EACH beat of the transfer. dat_tagop above is a single
    # field every beat overwrites, so the last beat silently wins and a burst
    # whose beats disagree is indistinguishable from one that does not. CHI
    # requires one TagOp for a whole transfer, so the disagreement is the thing
    # worth catching -- and it cannot be caught after reassembly unless the
    # per-beat values survive it.
    self.dat_tagop_beats = []
    self.rsp_opcode = int(RspOpcode.COMP)
    self.rsp_resp = int(Resp.I)
    self.rsp_resp_err = int(RespErr.OKAY)
    self.dbid = 0
    self.fwd_state = 0
    self.is_snoop = False
    self.snp_opcode = 0
    self.snp_addr = 0
    self.snp_resp = int(Resp.I)
    self.fwd_nid = 0
    self.fwd_txn_id = 0
    self.ret_to_src = False
    self.do_not_go_to_sd = False
    self.raw_override = False
    self.raw_flitpend = False
    self.raw_channel = int(RawChannel.NONE)
    self.raw_req = 0
    self.raw_rsp = 0
    self.raw_dat = 0
    self.raw_snp = 0

    # ---- transaction timestamps (stamped by the monitor) ------------------
    # Cycle counts on the observing agent's reset-gated free-running counter,
    # NOT $time: that keeps every latency a timescale-independent integer, so a
    # bound written in one bench means the same thing in another. 0 means the
    # milestone was never reached, which is why cycle 0 is never handed out
    # (the counter's first observable value is 1).
    self.t_req_issued = 0
    self.t_retry_ack = 0
    self.t_pcrd_grant = 0
    self.t_req_reissued = 0
    self.t_dbid = 0
    self.t_first_dat = 0
    self.t_last_dat = 0
    self.t_comp = 0
    self.t_compack = 0
    # Retries this ONE transaction suffered. The perf counters keep a global
    # tally; that cannot say whether ten retries were one pathological
    # transaction or ten unlucky ones.
    self.retry_count = 0
    # Per-beat arrival cycles, only when cfg.collect_beat_timestamps is set.
    self.t_dat_beats = []

    # ---- payload arrays (built in post_randomize / by sequences) ----------
    self.data = []
    self.be = []
    self.tag = []
    self.tu = []
    self.data_id = []
    self.cc_id = []
    self.dat_resp = []
    self.dat_resp_err = []

    # ---- randomization knobs ----------------------------------------------
    self.min_addr = 0
    self.max_addr = mask(self._addr_w)
    self.min_size = 0
    self.max_size = 6
    self.enforce_addr_alignment = True
    # Ask for atomic operand Sizes that IHI 0050 E Table 2-17 / D Table 2-17 does
    # NOT list -- a deliberate deviation, not extra rigour.
    #
    # The default is the specification. This used to be the other way round: the
    # table was modelled but gated behind a knob that defaulted OFF, so every
    # atomic a plain randomize() produced was unconstrained and the VIP's default
    # stimulus was out of spec. A verification component whose default traffic
    # violates the protocol it checks is the wrong way for the switch to point --
    # see F-CORR-008.
    #
    # The deviation is kept because it is load-bearing: the atomic testcases drive
    # a full bus-beat operand to exercise the operand DAT / RMW / return datapath
    # at the widest beat, which is above the ordinary limit on every geometry
    # here. They now ask for it by name, and CHI_ATOMIC_SIZE_LEGAL reports what
    # they drive -- each of those testcases arms the rule at OFF and then requires
    # that it fired, so the deviation stays visible rather than silent.
    self.atomic_oversized_operands = False
    # Combined Write + CMO opt-in. Default OFF, and the default is the point:
    # these six are legal writes, so leaving them in the randomization pool
    # unconditionally would have every existing random write test start emitting
    # them and change every waveform in the regression.
    self.combined_write_cmo_enable = False
    self.write_unique_zero_enable = False
    self.write_evict_or_evict_enable = False
    self.data_type = DataType.RANDOM
    self.counter_value = 0
    self.counter_increment = 1
    self.custom_data = []
    self.custom_be = []
    self.custom_tag = []
    self.custom_tu = []
    self.deferred_custom_payload = False

  # ==========================================================================
  # Setters (mirror the SV set_* API).
  # ==========================================================================
  def set_config(self, cfg: ChiCfg) -> None:
    if cfg != self.cfg:
      raise ValueError(f"[{self.name}] set_config cfg does not match item cfg")

  def set_size(self, value: int) -> None:
    self.set_size_range(int(value), int(value))

  def set_size_range(self, lo: int, hi: int) -> None:
    if lo < 0 or hi > 6 or lo > hi:
      raise ValueError(f"[{self.name}] Illegal size range [{lo}:{hi}]")
    self.min_size = lo
    self.max_size = hi

  def set_data_type(self, value) -> None:
    self.data_type = value

  def set_enforce_addr_alignment(self, value: bool) -> None:
    self.enforce_addr_alignment = bool(value)

  def set_atomic_oversized_operands(self, value: bool) -> None:
    self.atomic_oversized_operands = bool(value)

  def set_combined_write_cmo_enable(self, value: bool) -> None:
    self.combined_write_cmo_enable = bool(value)

  def set_write_unique_zero_enable(self, value: bool) -> None:
    self.write_unique_zero_enable = bool(value)

  def set_write_evict_or_evict_enable(self, value: bool) -> None:
    self.write_evict_or_evict_enable = bool(value)

  def set_counter_value(self, start: int) -> None:
    self.counter_value = int(start) & mask(self._data_w)

  def set_counter_increment(self, inc: int) -> None:
    self.counter_increment = int(inc) & mask(self._data_w)

  def set_addr_range(self, lo: int, hi: int) -> None:
    self.min_addr = int(lo)
    self.max_addr = int(hi)

  def set_data(self, values) -> None:
    self.custom_data = [int(v) & mask(self._data_w) for v in values]
    self.data_type = DataType.CUSTOM

  def set_be(self, values) -> None:
    self.custom_be = [int(v) & mask(self._be_w) for v in values]

  def set_src_id(self, value: int) -> None:
    self.src_id = int(value) & mask(max(self._node_w, 1))

  def set_tgt_id(self, value: int) -> None:
    self.tgt_id = int(value) & mask(max(self._node_w, 1))

  def set_lp_id(self, value: int) -> None:
    self.lp_id = int(value)

  def set_return_nid(self, value: int) -> None:
    self.return_nid = int(value) & mask(max(self._node_w, 1))

  def set_return_txn_id(self, value: int) -> None:
    self.return_txn_id = int(value)

  def set_qos(self, value: int) -> None:
    self.qos = int(value)

  def set_tracetag(self, value) -> None:
    self.tracetag = int(value) & 1

  def set_snp_attr(self, value) -> None:
    self.snp_attr = int(value) & 1

  def set_dodwt(self, value) -> None:
    self.dodwt = int(value) & 1

  def set_likelyshared(self, value) -> None:
    self.likelyshared = int(value) & 1

  def set_endian(self, value) -> None:
    self.endian = int(value) & 1

  def set_group_id_ext(self, value: int) -> None:
    self.group_id_ext = int(value)

  def set_tagop(self, value: int) -> None:
    self.tagop = int(value)

  def set_dat_tagop(self, value: int) -> None:
    self.dat_tagop = int(value)

  def apply_dat_tagop(self, value: int) -> None:
    """Set the WriteData TagOp and re-derive the TU bits it implies.

    Section 12.5.2 is a list of per-opcode bullets, but every bullet says the
    same thing about TU: inapplicable and zero under Transfer and under Match,
    all bits asserted under Update. The one relaxation is WriteNoSnpPtl /
    WriteUniquePtl / WriteUniquePtlStash, where "any combination of TU and BE
    bits, including none or all, can be asserted" -- all-asserted is inside
    that, so one rule covers the chapter without weakening it anywhere.

    Under Invalid the section is stronger than TU alone -- "the Memory Tagging
    fields must be set to zero and ignored by the Completer" -- and the zero
    branch here is that.

    Nothing related TagOp to TU before this: TU was whatever set_tu() left, and
    zero otherwise, on every opcode and every TagOp alike. A write asking the
    completer to Update tags while telling it, bit by bit, that none of them
    should be updated is not a value a conformant Requester can send. See
    F-CORR-009.

    A test that pinned TU through set_tu() keeps its pin -- custom_tu is what
    post_randomize honours, and this leaves it alone.
    """
    self.dat_tagop = int(value)
    if self.custom_tu:
      return
    tu_all = mask(self.cfg.tu_width) if self._issue_e else 0
    fill = tu_all if int(value) == TAGOP_UPDATE else 0
    self.tu = [fill] * len(self.tu)

  def set_tag(self, values) -> None:
    self.custom_tag = [int(v) for v in values]
    self.tag = [int(v) for v in values]

  def set_tu(self, values) -> None:
    self.custom_tu = [int(v) for v in values]
    self.tu = [int(v) for v in values]

  def set_deferred_custom_payload(self, enable: bool) -> None:
    self.deferred_custom_payload = bool(enable)

  def get_counter(self) -> int:
    return self.counter_value

  def clear_raw_override(self) -> None:
    self.raw_override = False
    self.raw_channel = int(RawChannel.NONE)
    self.raw_flitpend = False
    self.raw_req = 0
    self.raw_rsp = 0
    self.raw_dat = 0
    self.raw_snp = 0

  def _set_raw(self, attr, value, flitpend, channel):
    self.clear_raw_override()
    setattr(self, attr, int(value))
    self.raw_override = True
    self.raw_flitpend = bool(flitpend)
    self.raw_channel = int(channel)

  def set_raw_req(self, value, flitpend=False):
    self._set_raw("raw_req", value, flitpend, RawChannel.REQ)

  def set_raw_rsp(self, value, flitpend=False):
    self._set_raw("raw_rsp", value, flitpend, RawChannel.RSP)

  def set_raw_dat(self, value, flitpend=False):
    self._set_raw("raw_dat", value, flitpend, RawChannel.DAT)

  def set_raw_snp(self, value, flitpend=False):
    self._set_raw("raw_snp", value, flitpend, RawChannel.SNP)

  # ==========================================================================
  # Legality / payload helpers.
  # ==========================================================================
  def req_opcode_is_legal(self, value: int, direction: int) -> bool:
    v = int(value)
    if int(direction) == int(Dir.READ):
      legal = {int(_RO.READ_NO_SNP), int(_RO.PREFETCH_TGT), int(_RO.PCRD_RETURN),
               int(_RO.READ_SHARED), int(_RO.READ_CLEAN), int(_RO.READ_UNIQUE),
               int(_RO.READ_ONCE)}
      # MakeReadUnique is 0x41 and so needs the 7-bit CHI-E REQ opcode field; in
      # CHI-D it does not fit and would be truncated to 0x01 (ReadShared) on the
      # wire. ReadNoSnpSep is issue-gated for protocol rather than width reasons.
      if v in (int(_RO.READ_NO_SNP_SEP), int(_RO.MAKE_READ_UNIQUE)):
        return self._issue_e
      return v in legal
    if int(direction) == int(Dir.WRITE):
      legal = {int(o) for o in (
        _RO.WRITE_NO_SNP_PTL, _RO.WRITE_NO_SNP_FULL, _RO.CLEAN_SHARED_PERSIST,
        _RO.PCRD_RETURN, _RO.WRITE_BACK_FULL, _RO.WRITE_CLEAN_FULL, _RO.EVICT,
        _RO.CLEAN_UNIQUE, _RO.MAKE_UNIQUE, _RO.CLEAN_INVALID, _RO.MAKE_INVALID,
        _RO.WRITE_UNIQUE_FULL, _RO.WRITE_UNIQUE_PTL)}
      legal |= set(range(0x28, 0x3A))  # atomics
      if v in (int(_RO.WRITE_NO_SNP_ZERO), int(_RO.CLEAN_SHARED_PERSIST_SEP)):
        return self._issue_e
      if v in {int(o) for o in _COMBINED_WRITE_CMO_OPCODES}:
        return self._issue_e
      # Both sit in the Opcode[6] = 1 half of the REQ table, so neither fits
      # CHI-D's 6-bit opcode field at all.
      if v in {int(o) for o in
               _WRITE_UNIQUE_ZERO_OPCODES + _WRITE_EVICT_OR_EVICT_OPCODES}:
        return self._issue_e
      return v in legal
    return False

  def get_payload_beat_count(self) -> int:
    op = int(self.opcode)
    if req_opcode_is_atomic(op):
      return chi_xfer_dat_beats(int(self.size), self._db)
    if op in _WRITE_PAYLOAD_OPCODES:
      return chi_xfer_dat_beats(int(self.size), self._db)
    return 0

  def _make_random_data(self) -> int:
    return random.getrandbits(self._data_w) if self._data_w > 0 else 0

  def _make_random_be(self) -> int:
    v = random.getrandbits(self._be_w)
    return v if v else 1

  # ==========================================================================
  # pre_randomize -- sync knobs into vsc state fields; validate.
  # ==========================================================================
  def pre_randomize(self):
    self.s_raw_override = 1 if self.raw_override else 0
    self.s_enforce_align = 1 if self.enforce_addr_alignment else 0
    self.s_atomic_oversized = 1 if self.atomic_oversized_operands else 0
    self.s_combined_cmo = 1 if self.combined_write_cmo_enable else 0
    self.s_write_unique_zero = 1 if self.write_unique_zero_enable else 0
    self.s_write_evict_or_evict = 1 if self.write_evict_or_evict_enable else 0
    self.s_min_size = int(self.min_size)
    self.s_max_size = int(self.max_size)
    self.s_min_addr = int(self.min_addr)
    self.s_max_addr = int(self.max_addr)
    if self.min_addr > self.max_addr:
      raise ValueError(f"[{self.name}] min_addr is larger than max_addr")
    if self.data_type == DataType.CUSTOM:
      if not self.custom_data and not self.deferred_custom_payload:
        raise ValueError(f"[{self.name}] CUSTOM data_type requires set_data() first")
      if self.custom_data and self.custom_be and \
         len(self.custom_be) != len(self.custom_data):
        raise ValueError(f"[{self.name}] custom_be length must match custom_data")

  # ==========================================================================
  # Constraints (SV con_* blocks; runtime-gated by s_raw_override).
  # ==========================================================================
  @vsc.constraint
  def con_role_legal(self):
    with vsc.if_then(self.s_raw_override == 0):
      self.role.inside(vsc.rangelist(int(Role.SNF), int(Role.RNI), int(Role.RNF)))

  @vsc.constraint
  def con_addr_range(self):
    with vsc.if_then(self.s_raw_override == 0):
      self.addr >= self.s_min_addr
      self.addr <= self.s_max_addr

  @vsc.constraint
  def con_size_range(self):
    with vsc.if_then(self.s_raw_override == 0):
      self.size >= self.s_min_size
      self.size <= self.s_max_size

  @vsc.constraint
  def con_addr_alignment(self):
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.s_enforce_align == 1):
        (self.addr & ((1 << self.size) - 1)) == 0

  @vsc.constraint
  def con_atomic_compare_beat_align(self):
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.opcode == int(_RO.ATOMIC_COMPARE)):
        self.size >= self._clog2_db_p1

  @vsc.constraint
  def con_atomic_compare_supported(self):
    if self._clog2_db_p1 > 6:
      with vsc.if_then(self.s_raw_override == 0):
        self.opcode != int(_RO.ATOMIC_COMPARE)

  @vsc.constraint
  def con_atomic_table_2_17_size(self):
    """The permitted Sizes are the ones IHI 0050 E Table 2-17 lists, and no others:

      AtomicStore / AtomicLoad / AtomicSwap   1, 2, 4 or 8 byte   -> Size 0..3
      AtomicCompare                           2, 4, 8, 16 or 32   -> Size 1..5

    D Table 2-17 is the same table with the same number, so this holds for both
    issues. The bounds are written out here rather than calling atomic_size_legal()
    because `size` is the random variable being solved: the classifier is the
    single source of truth for the CHECKER, which reads a Size off the wire, and
    this is the same table stated where the solver can use it.

    Two things about AtomicCompare, both following from its Size being the COMBINED
    compare+swap size. It has a FLOOR, which no other atomic has -- Size 0 would be
    half a byte per operand -- and its ceiling is one step HIGHER, 32 bytes being
    two 16-byte operands. Deriving the ceiling from the ordinary 8-byte limit
    instead of from the table gives Size <= 4, which excludes the legal 32-byte
    compare, and on the 16-byte cut that is worse than conservative:
    con_atomic_compare_beat_align requires Size >= clog2(data_bytes)+1 = 5 there, so a
    <= 4 ceiling and a >= 5 floor left the strict mode with NO satisfiable Size and
    an AtomicCompare draw would have failed randomization outright. Reading the
    ceiling off Table 2-17 leaves exactly Size 5, which is the one value that is
    both legal and representable at beat granularity on that cut.
    """
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.s_atomic_oversized == 0):
        with vsc.if_then(self.opcode.inside(vsc.rangelist((0x28, 0x39)))):
          with vsc.if_then(self.opcode == int(_RO.ATOMIC_COMPARE)):
            self.size.inside(vsc.rangelist((1, 5)))
          with vsc.if_then(self.opcode != int(_RO.ATOMIC_COMPARE)):
            self.size <= 3

  @vsc.constraint
  def con_opcode_legal(self):
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.role != int(Role.RNF)):
        with vsc.if_then(self.direction == int(Dir.READ)):
          self.opcode.inside(vsc.rangelist(*[int(o) for o in self._read_set]))
        with vsc.if_then(self.direction == int(Dir.WRITE)):
          # The combined Write + CMO forms join the legal set only when asked
          # for. They are ordinary writes as far as the solver is concerned, so
          # an unconditional pool entry would put them into every random write
          # test in the regression.
          with vsc.if_then(self.s_combined_cmo == 0):
            self.opcode.inside(vsc.rangelist(*[int(o) for o in self._write_set]))
          with vsc.else_then:
            self.opcode.inside(vsc.rangelist(
              *[int(o) for o in self._write_set + _COMBINED_WRITE_CMO_OPCODES]))

  @vsc.constraint
  def con_opcode_legal_rnf(self):
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.role == int(Role.RNF)):
        with vsc.if_then(self.direction == int(Dir.READ)):
          self.opcode.inside(vsc.rangelist(*[int(o) for o in self._rnf_read_set]))
        with vsc.if_then(self.direction == int(Dir.WRITE)):
          # Each of the two isolated CHI-E opcodes joins the coherent write pool
          # only when asked for, for the same reason the combined Write + CMO
          # forms do on the non-coherent side: both look like ordinary coherent
          # writes to the solver. Spelled as the four combinations because the
          # two knobs are independent of each other.
          _base = [int(o) for o in _RNF_WRITE_OPCODES]
          _zero = [int(o) for o in _WRITE_UNIQUE_ZERO_OPCODES]
          _evict = [int(o) for o in _WRITE_EVICT_OR_EVICT_OPCODES]
          with vsc.if_then(self.s_write_unique_zero == 0):
            with vsc.if_then(self.s_write_evict_or_evict == 0):
              self.opcode.inside(vsc.rangelist(*_base))
            with vsc.else_then:
              self.opcode.inside(vsc.rangelist(*(_base + _evict)))
          with vsc.else_then:
            with vsc.if_then(self.s_write_evict_or_evict == 0):
              self.opcode.inside(vsc.rangelist(*(_base + _zero)))
            with vsc.else_then:
              self.opcode.inside(vsc.rangelist(*(_base + _zero + _evict)))

  @vsc.constraint
  def con_return_path_fields(self):
    # ReturnNID is zeroed only where IHI 0050 E 13.10.4 makes it INAPPLICABLE,
    # which is a smaller set than "everything except ReadNoSnpSep".
    #
    # It used to be that larger set, and the difference is not academic. 13.10.4
    # makes the field applicable "in ReadNoSnp, ReadNoSnpSep,
    # CleanSharedPersistSep, WriteNoSnp, Combined Write, and Atomic requests",
    # and it is the field that names the node a CompData, DataSepResp or PERSIST
    # is sent to. Forcing it to zero on a Combined Write therefore made the one
    # response 2.8 routes by ReturnNID -- the Persist answering a PCMO --
    # impossible to address correctly: no test could set the field, so no test
    # could show the driver targeting it at SrcID instead. See F-CORR-012, whose
    # own tasks assume a stimulus this constraint did not permit.
    #
    # Zeroing is the only thing dropped. The VALUE still comes from the sequence,
    # which pins `return_nid == return_nid_val` on every request it builds, and
    # that value still defaults to 0 -- so a request nobody has asked to route
    # is unchanged, and a test that wants a real return node can now say so.
    #
    # ReturnTxnID gets the same treatment from its own classifier, and it took
    # two goes to get right. It was "zero on everything but ReadNoSnpSep", on
    # the reasoning that 13.10.5 names it "the TxnID of a CompData or
    # DataSepResp only, and a separated persist gets an RSP rather than data".
    # That reasoning is wrong, and section 2.5 says so outright: "when DoDWT = 1,
    # ReturnTxnID value is expected to be the original Requester TxnID [...]
    # Used as the TxnID in the DBIDResp response". A DBIDResp is an RSP, so the
    # premise that the field only ever addresses data was false -- and the
    # constraint built on it made a conformant DWT write unrandomizable.
    #
    # The two lists still differ and are still derived separately:
    # CleanSharedPersistSep carries a ReturnNID and no ReturnTxnID.
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.opcode == int(_RO.READ_NO_SNP_SEP)):
        self.return_nid == self.src_id
      with vsc.if_then(self.opcode != int(_RO.READ_NO_SNP_SEP)):
        with vsc.if_then(
            self.opcode.inside(vsc.rangelist(*_RETURN_TXN_ID_INAPPLICABLE_C))):
          self.return_txn_id == 0
        with vsc.if_then(
            self.opcode.inside(vsc.rangelist(*_RETURN_NID_INAPPLICABLE_C))):
          self.return_nid == 0

  @vsc.constraint
  def con_exp_comp_ack_legal(self):
    # IHI 0050 E Table 2-9 / D Table 2-8, "Requester CompAck requirement".
    #
    # The table has three answers per opcode -- Yes, Optional, No -- and this
    # constraint has three cases to match. It used to have one: every read was
    # forced to zero, which is the opposite of what the table says for the four
    # coherent reads an RN-F can issue, and CleanUnique/MakeUnique escaped
    # through the write side of the same rule.
    #
    # Both edges are hard, and only the middle is soft. Required and prohibited
    # are protocol; the zero on an OPTIONAL opcode is this VIP's policy, and a
    # sequence that wants Ordered Write Observation on a WriteNoSnp -- or an
    # RN-F that wants to acknowledge a ReadOnce -- overrides it by asking, which
    # is what soft is for.
    #
    # Where SV calls vip_chi_exp_comp_ack_{required,prohibited} from inside the
    # constraint, this side cannot: pyvsc would hand the function a solver
    # expression rather than an opcode. The sets are enumerated from the same
    # types-package function at import time instead, so the table is still
    # written once and the two ports cannot classify an opcode differently.
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.role == int(Role.RNF)):
        with vsc.if_then(self.opcode.inside(
            vsc.rangelist(*_COMPACK_REQUIRED_RNF))):
          self.exp_comp_ack == 1
        with vsc.if_then(~self.opcode.inside(
            vsc.rangelist(*_COMPACK_ALLOWED_RNF))):
          self.exp_comp_ack == 0
      with vsc.else_then:
        with vsc.if_then(~self.opcode.inside(
            vsc.rangelist(*_COMPACK_ALLOWED_NON_RNF))):
          self.exp_comp_ack == 0
      # The soft has to be guarded away from the REQUIRED opcodes, or it stops
      # being about ExpCompAck at all: the solver is free to choose the opcode
      # too, so an unguarded "prefer zero" is satisfiable by never drawing a
      # request that requires a one. Left unguarded, an RN-F read randomizes to
      # ReadOnce every single time -- the only read in the pool whose bit may be
      # zero -- and ReadShared/ReadClean/ReadUnique/MakeReadUnique disappear from
      # the stimulus. A policy default that silently deletes four opcodes is a
      # worse defect than the one this constraint was rewritten to fix.
      with vsc.if_then(~self.opcode.inside(
          vsc.rangelist(*_COMPACK_REQUIRED_RNF))):
        vsc.soft(self.exp_comp_ack == 0)

  @vsc.constraint
  def con_snp_attr_legal(self):
    """SnpAttr must be the value Table 2-14 permits for this opcode.

    The same shape as con_exp_comp_ack_legal, and for the same reason: the table
    marks a value required on some opcodes, forbidden on others and free on the
    rest, so an explicit setter asking for the wrong one should be refused here
    rather than reaching the wire. raw_override is the way to drive an illegal
    value on purpose.
    """
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.opcode.inside(vsc.rangelist(*_SNP_ATTR_MUST_BE_ONE))):
        self.snp_attr == 1
      with vsc.else_if(self.opcode.inside(
          vsc.rangelist(*_SNP_ATTR_MUST_BE_ZERO))):
        self.snp_attr == 0

  @vsc.constraint
  def con_dodwt_overload(self):
    """DoDWT and SnpAttr share REQ bit 17, so only one can be set at a time.

    IHI 0050 E section 13.10.25 restricts DoDWT to WriteNoSnpFull, WriteNoSnpPtl
    and Combined Write, and makes it "inapplicable and must be set to zero in all
    other requests". Holding the inapplicable bit at zero is what lets the packer
    treat the wire bit as SnpAttr everywhere else without silently discarding a
    value a sequence asked for: a sequence that sets DoDWT on, say, a read now
    fails randomization here rather than having its request go out with SnpAttr
    asserted instead.
    """
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(~self.opcode.inside(vsc.rangelist(*_DODWT_APPLICABLE))):
        self.dodwt == 0

  @vsc.constraint
  def con_issue_gated_fields(self):
    """Issue-gated optional fields are forced to zero when absent.

    SnpAttr is deliberately NOT in this list. Issue D defines the field (D Table
    12-6 names that bit SnpAttr and nothing else) -- it is DoDWT alone that Issue
    E introduced, so gating the pair together is what made Non-snoopable
    structural on every coherent request in CHI-D.
    """
    with vsc.if_then(self.s_raw_override == 0):
      if not self._issue_e:
        self.tracetag == 0
        self.dodwt == 0
        self.likelyshared == 0
        self.endian == 0
        self.group_id_ext == 0
        self.tagop == 0
      if not self.cfg.mpam_en:
        self.mpam == 0
      if not self.cfg.datacheck_en:
        self.datacheck == 0
      if not self.cfg.poison_en:
        self.poison == 0

  # ==========================================================================
  @vsc.constraint
  def con_tagop_legal(self):
    """Table 12-2: which TagOp encodings each request opcode may carry.

    Until this existed TagOp was a plain rand field with one constraint on it --
    the issue gate holding it at zero under CHI-D -- so under CHI-E every opcode
    could carry every value. That is not a hole in coverage, it is a generator
    that produces requests a conformant completer has no defined behaviour for,
    and the VIP's own SN-F would store the tag and the scoreboard would predict
    it, so the regression confirmed the wrong model. See F-CORR-009.

    Written as opcode groups rather than as a call to the classifier, because a
    function call in a constraint makes both arguments solve-ordered and turns a
    declarative constraint into a post-hoc check that can simply fail. The
    groups are DERIVED from the classifier at import (_TAGOP_GROUPS_C), so the
    two cannot drift apart.

    Only the randomized value is constrained. A sequence that pins TagOp through
    set_tagop() pins it through an inline constraint, so an illegal pin now
    fails randomization loudly instead of reaching the wire quietly -- which is
    the point, and is how the ReadNoSnpSep-with-Update in tc_chi_base_seq_smoke
    surfaced.
    """
    with vsc.if_then(self.s_raw_override == 0):
      if self._issue_e:
        for ops, permitted in _TAGOP_GROUPS_C:
          with vsc.if_then(self.opcode.inside(vsc.rangelist(*ops))):
            self.tagop.inside(vsc.rangelist(*permitted))

  # ==========================================================================
  # post_randomize -- size + fill the per-beat payload arrays, pick DAT opcode.
  # ==========================================================================
  def post_randomize(self):
    beats = self.get_payload_beat_count()
    op = int(self.opcode)

    self.data = [0] * beats
    self.be = [0] * beats
    self.tag = [0] * beats
    self.tu = [0] * beats
    self.data_id = [0] * beats
    self.cc_id = [0] * beats
    self.dat_resp = [0] * beats
    self.dat_resp_err = [0] * beats

    next_counter = self.counter_value
    for beat in range(beats):
      if self.data_type == DataType.COUNTER:
        self.data[beat] = next_counter & mask(self._data_w)
        next_counter = (next_counter + self.counter_increment) & mask(self._data_w)
      elif self.data_type == DataType.ZEROS:
        self.data[beat] = 0
      elif self.data_type == DataType.ONES:
        self.data[beat] = mask(self._data_w)
      elif self.data_type == DataType.CUSTOM:
        self.data[beat] = self.custom_data[beat] if self.custom_data else 0
      else:
        self.data[beat] = self._make_random_data()

      if self.custom_be:
        self.be[beat] = self.custom_be[beat]
      elif op in _PARTIAL_WRITE_OPCODES:
        self.be[beat] = self._make_random_be()
      else:
        self.be[beat] = mask(self._be_w)

      self.tag[beat] = self.custom_tag[beat] if self.custom_tag else 0
      self.tu[beat] = self.custom_tu[beat] if self.custom_tu else 0
      self.data_id[beat] = beat & mask(self._data_id_w)
      self.cc_id[beat] = beat & mask(self._data_id_w)
      self.dat_resp[beat] = int(Resp.I)
      self.dat_resp_err[beat] = int(RespErr.OKAY)

    if self.data_type == DataType.COUNTER:
      self.counter_value = next_counter

    if not self.cfg.datacheck_en or beats == 0:
      self.datacheck = 0
    if not self.cfg.poison_en or beats == 0:
      self.poison = 0
    if not self._issue_e or beats == 0:
      self.dat_tagop = 0
      self.tag = [0] * len(self.tag)
      self.tu = [0] * len(self.tu)

    if op in _WRITE_PAYLOAD_OPCODES or req_opcode_is_atomic(op):
      # WriteUnique/atomic data travels as NonCopyBackWrData (+CompAck variant).
      if op in (int(_RO.WRITE_BACK_FULL), int(_RO.WRITE_CLEAN_FULL),
                # WriteEvictOrEvict is a CopyBack too, and its CopyBackWrData is
                # treated as an IMPLICIT CompAck -- which is why it keeps the
                # plain opcode here even though ExpCompAck is always set.
                int(_RO.WRITE_EVICT_OR_EVICT)):
        self.dat_opcode = int(DatOpcode.COPY_BACK_WR_DATA)
      elif int(self.exp_comp_ack):
        self.dat_opcode = int(DatOpcode.NCB_WR_DATA_COMP_ACK)
      else:
        self.dat_opcode = int(DatOpcode.NON_COPY_BACK_WR_DATA)
    elif op == int(_RO.READ_NO_SNP_SEP):
      self.dat_opcode = int(DatOpcode.DATA_SEP_RESP)
    else:
      self.dat_opcode = int(DatOpcode.COMP_DATA)

    self.deferred_custom_payload = False

  # ==========================================================================
  # copy / compare / print (pyuvm hooks).
  # ==========================================================================
  _SCALARS = (
    "direction", "role", "src_id", "tgt_id", "txn_id", "lp_id", "return_nid",
    "return_txn_id", "qos", "opcode", "addr", "size", "ns", "order", "mem_attr",
    "pcrd_type", "allow_retry", "excl", "exp_comp_ack", "tracetag", "snp_attr",
    "dodwt",
    "likelyshared", "endian", "group_id_ext", "tagop", "mpam", "datacheck",
    "poison", "dat_opcode", "dat_tagop", "rsp_opcode", "rsp_resp", "rsp_resp_err",
    "dbid", "fwd_state", "snp_opcode", "snp_addr", "snp_resp",
  )
  _ARRAYS = ("data", "be", "tag", "tu", "data_id", "cc_id", "dat_resp",
             "dat_resp_err")

  # Copied with the item but deliberately NOT compared: two observations of the
  # same transaction on two links are the same transaction even though they were
  # seen at different cycles, and a scoreboard comparing a predicted item to an
  # observed one must not fail on when it happened.
  _TIMESTAMPS = ("t_req_issued", "t_retry_ack", "t_pcrd_grant", "t_req_reissued",
                 "t_dbid", "t_first_dat", "t_last_dat", "t_comp", "t_compack",
                 "retry_count")

  def do_copy(self, rhs: "vip_chi_item") -> None:
    for f in self._SCALARS:
      setattr(self, f, int(getattr(rhs, f)))
    for f in self._TIMESTAMPS:
      setattr(self, f, int(getattr(rhs, f)))
    self.t_dat_beats = list(rhs.t_dat_beats)
    for f in ("is_snoop", "ret_to_src", "do_not_go_to_sd", "raw_override",
              "raw_flitpend"):
      setattr(self, f, bool(getattr(rhs, f)))
    for f in ("raw_req", "raw_rsp", "raw_dat", "raw_snp", "raw_channel"):
      setattr(self, f, int(getattr(rhs, f)))
    for f in self._ARRAYS:
      setattr(self, f, list(getattr(rhs, f)))
    self.data_type = rhs.data_type

  def do_compare(self, rhs: "vip_chi_item", *_) -> bool:
    for f in self._SCALARS:
      if int(getattr(self, f)) != int(getattr(rhs, f)):
        return False
    for f in self._ARRAYS:
      if list(getattr(self, f)) != list(getattr(rhs, f)):
        return False
    return True

  # ==========================================================================
  # Timestamp accessors. Each returns 0 when the interval it measures was never
  # observed, which is the same convention the fields themselves use: a caller
  # asking for the latency of a transaction that never completed gets 0, not a
  # number computed against a milestone that never happened.
  # ==========================================================================
  def latency(self) -> int:
    """Cycles from the request going out to its completion.

    Measured from the RE-ISSUE when the transaction was retried: the completer
    was entitled to refuse the first attempt, so timing from the original REQ
    charges it for a delay the protocol allows.
    """
    start = self.t_req_reissued or self.t_req_issued
    end = self.t_comp or self.t_last_dat
    if not start or not end or end < start:
      return 0
    return end - start

  def dbid_latency(self) -> int:
    """Cycles from the request to its DBID grant (a write's buffer allocation)."""
    start = self.t_req_reissued or self.t_req_issued
    if not start or not self.t_dbid or self.t_dbid < start:
      return 0
    return self.t_dbid - start

  def data_burst_time(self) -> int:
    """Cycles spanned by the data burst itself, first beat to last.

    Zero for a single-beat transfer -- one beat spans no interval -- which is
    the honest answer rather than an off-by-one 1.
    """
    if not self.t_first_dat or not self.t_last_dat:
      return 0
    return self.t_last_dat - self.t_first_dat

  def convert2string(self) -> str:
    return (f"{self.name} dir={int(self.direction)} role={int(self.role)} "
            f"src=0x{int(self.src_id):x} tgt=0x{int(self.tgt_id):x} "
            f"txn=0x{int(self.txn_id):x} opcode=0x{int(self.opcode):x} "
            f"addr=0x{int(self.addr):x} size={int(self.size)} "
            f"beats={len(self.data)} dat_opcode=0x{int(self.dat_opcode):x} "
            f"raw={int(self.raw_override)}")


# ==============================================================================
# Field-model deferral
#
# @vsc.randobj's interposer builds a field model at the end of every
# construction, which is ~0.52 ms of the ~0.62 ms it costs to build an item.
# The monitor mints one item per observed flit and the raw sequence one per
# hand-packed request; both set `raw_override` and fill every field directly,
# so the constraint model they build is never used.
#
# Deferring is safe rather than merely cheap: pyvsc's get_model() rebuilds the
# model on demand, so an item that unexpectedly does get randomized simply pays
# the cost then and solves identically. The deferral suppresses the
# construction-time build and nothing else.
#
# This has to be a scoped swap rather than a subclass override: pyvsc installs
# build_field_model onto the decorated class itself, so a method defined in the
# class body would be replaced by the decorator.
# ==============================================================================

_vsc_build_field_model = vip_chi_item.build_field_model
_defer_depth = 0


def _deferred_build_field_model(self, name=None):
  if _defer_depth > 0:
    return None
  return _vsc_build_field_model(self, name)


class defer_field_model:
  """Context manager: construct vip_chi_items without building their pyvsc
  constraint model. Use it only where the item is a data carrier that is never
  randomized.

  Safe under cocotb because item construction is synchronous - no await can
  interleave between __enter__ and __exit__ - and the depth counter keeps
  nested uses correct.
  """

  def __enter__(self):
    global _defer_depth
    if _defer_depth == 0:
      vip_chi_item.build_field_model = _deferred_build_field_model
    _defer_depth += 1
    return self

  def __exit__(self, exc_type, exc, tb):
    global _defer_depth
    _defer_depth -= 1
    if _defer_depth == 0:
      vip_chi_item.build_field_model = _vsc_build_field_model
    return False
