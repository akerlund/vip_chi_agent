################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_types_pkg.sv.
#
# This module is the KEYSTONE of the whole port: CHI carries a whole packed
# struct per channel on one wide wire (txreqflit / txrspflit / txdatflit /
# txsnpflit), so every driver packs a flit dict -> int before driving and every
# monitor unpacks int -> dict after sampling. Getting the field order and widths
# right here is what makes the entire port correct.
#
# SystemVerilog packed structs list the MSB field first and the LSB field last,
# so the layouts below are MSB-first and `qos` is always the least-significant
# field. Widths derive from the runtime ChiCfg exactly as the SV helper
# functions derive them from vip_chi_cfg_t (no parameterized classes; widths are
# plain ints).
#
# The SV has three type classes: vip_chi_types (superset), vip_chi_types_d
# (CHI-D wire shape) and vip_chi_types_e (CHI-E wire shape). The interface uses
# _d / _e, so those are the layouts encoded here -- CHI-D omits the E-only
# tagop / groupidext / tag / tu fields entirely (not width-1 placeholders).
#
################################################################################

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum

# ---------------------------------------------------------------------------
# Unbounded-int helpers (Python ints have no wrap; SV packed vectors do).
# ---------------------------------------------------------------------------


def mask(width: int) -> int:
  return (1 << width) - 1


def trunc(value: int, width: int) -> int:
  return int(value) & mask(width)


def clog2(n: int) -> int:
  return 0 if n <= 1 else (n - 1).bit_length()


# ---------------------------------------------------------------------------
# Enums (mirror the SV typedef enums).
# ---------------------------------------------------------------------------


class Issue(IntEnum):
  D = 0
  E = 1


class Role(IntEnum):
  MONITOR = 0
  SNF = 1
  RNI = 2
  HNI = 3
  RNF = 4
  HNF = 5


class Dir(IntEnum):
  READ = 0
  WRITE = 1


class DataType(IntEnum):
  RANDOM = 0
  COUNTER = 1
  ZEROS = 2
  ONES = 3
  CUSTOM = 4


class AtomicOp(IntEnum):
  STORE_0 = 0
  STORE_1 = 1
  STORE_2 = 2
  STORE_3 = 3
  STORE_4 = 4
  STORE_5 = 5
  STORE_6 = 6
  STORE_7 = 7
  LOAD_0 = 8
  LOAD_1 = 9
  LOAD_2 = 10
  LOAD_3 = 11
  LOAD_4 = 12
  LOAD_5 = 13
  LOAD_6 = 14
  LOAD_7 = 15
  SWAP = 16
  COMPARE = 17


class RawChannel(IntEnum):
  NONE = 0
  REQ = 1
  RSP = 2
  DAT = 3
  SNP = 4


class ReqNs(IntEnum):
  SECURE = 0
  NON_SECURE = 1


class Exclusive(IntEnum):
  NORMAL = 0
  EXCLUSIVE = 1


class SnpAttr(IntEnum):
  """IHI 0050 E Table 2-13 / D Table 2-13: SnpAttr field encodings.

  The field says whether a transaction requires snooping, and Table 2-14 fixes
  the permitted value per transaction type -- it is not a free attribute.

  Under Issue E this one bit is also DoDWT (E section 13.10.25, "The bit shares
  the same field as SnpAttr"). The two never collide: DoDWT is only applicable
  in requests from Home to Slave, and E section 2.9.3 requires SnpAttr to be zero
  in every such request. Issue D defines no DoDWT at all.
  """
  NON_SNOOPABLE = 0
  SNOOPABLE = 1


class ReqOrder(IntEnum):
  NONE = 0
  REQ_ACCEPTED = 1
  REQ_ORDER = 2
  ENDPOINT = 3


class LasmState(IntEnum):
  """Link Activation State Machine.

  The state is a {LINKACTIVEREQ, LINKACTIVEACK} pair, so it is derived from the
  wires rather than from which node happens to originate activation -- which is
  what makes it usable on a VIP that activates asymmetrically. One instance per
  LINK here, not one per direction: this VIP's link adapter mirrors both sideband
  signals to both endpoints, so a link carries a single handshake that both ends
  observe. See bind_chi._lasm_of for why modelling it per direction is wrong.

  The encoding is the pair itself ({req, ack}), so lasm() is a cast rather than
  a lookup and the state prints as the signals a waveform shows. Note that the
  legal cycle STOP -> ACTIVATE -> RUN -> DEACTIVATE -> STOP is therefore NOT
  numerically ordered: DEACTIVATE (req low, ack still high) is 0b01 and ACTIVATE
  (req high, ack not yet) is 0b10.
  """
  STOP = 0b00
  DEACTIVATE = 0b01
  ACTIVATE = 0b10
  RUN = 0b11


class DatInterleavePolicy(IntEnum):
  """Which in-flight transfer a completer takes the next DAT beat from.

  CHI relates every data packet to its transaction by TxnID and to its position
  by DataID, so a completer is free to interleave the beats of several transfers
  on one DAT channel; nothing in the protocol requires the beats of a transfer to
  be contiguous. See vip_chi_cfg_agent.dat_interleave_depth for the gate.

  ROUND_ROBIN : one beat per eligible stream, in turn. Deterministic, so a test
                can state the exact beat order it expects.
  RANDOM      : a uniform draw among the eligible streams each beat. Reaches
                orders round-robin never produces, including runs of beats from
                one stream.
  """
  ROUND_ROBIN = 0
  RANDOM = 1


def lasm(req, ack) -> LasmState:
  """Map one direction's request/acknowledge pair onto its LASM state."""
  return LasmState(((1 if req else 0) << 1) | (1 if ack else 0))


# The single legal successor of each state. The LASM advances around one cycle
# and may additionally hold in any state; every other pair is a violation.
_LASM_NEXT_C = {
  LasmState.STOP: LasmState.ACTIVATE,
  LasmState.ACTIVATE: LasmState.RUN,
  LasmState.RUN: LasmState.DEACTIVATE,
  LasmState.DEACTIVATE: LasmState.STOP,
}


def lasm_legal_step(cur: LasmState, nxt: LasmState) -> bool:
  """True when `nxt` may legally follow `cur`."""
  return nxt == cur or _LASM_NEXT_C.get(cur) == nxt


class CheckSeverity(IntEnum):
  """Per-check severity.

  OFF still EVALUATES the rule and still counts its passes and failures -- it
  only suppresses the report. A check turned off during bring-up must still show
  up in the end-of-test table as failing, or "off" becomes indistinguishable
  from "fixed".
  """
  ERROR = 0
  WARNING = 1
  OFF = 2


# Every protocol rule both checkers know about, in the same order as
# vip_chi_check_id_t in the SV types package.
#
# This is the CANONICAL list, not a list of rules that happened to fire. That
# distinction is the whole point: a summary built only from rules that were
# evaluated cannot report the ones that never were, and a rule that never
# evaluates is indistinguishable from a rule that does not exist.
#
# One entry per RULE, not per check site: where SV asserts a rule twice because
# the requester and completer sides need different antecedents, both sites carry
# the same name. New entries go at the END -- the names appear in plusargs and
# in regression exports, so reordering would silently repoint a
# `--vip-chi-disable-check` written against an older build.
CHECK_IDS = (
  # Channel structural rules, one per REQ/RSP/DAT channel.
  "CHI_REQ_FLITV_REQUIRES_LINK",
  "CHI_RSP_FLITV_REQUIRES_LINK",
  "CHI_DAT_FLITV_REQUIRES_LINK",
  "CHI_REQ_LCRDV_REQUIRES_LINK",
  "CHI_RSP_LCRDV_REQUIRES_LINK",
  "CHI_DAT_LCRDV_REQUIRES_LINK",
  "CHI_REQ_VALID_REQUIRES_PEND",
  "CHI_RSP_VALID_REQUIRES_PEND",
  "CHI_DAT_VALID_REQUIRES_PEND",
  "CHI_REQ_IDLE_IN_RESET",
  "CHI_RSP_IDLE_IN_RESET",
  "CHI_DAT_IDLE_IN_RESET",
  # X/Z rules. SV-only by design: Verilator is 2-state, so a net cannot hold X
  # and a mirror here could never fire. Listed so the two registries line up and
  # so the summary can say WHY they are absent rather than leaving a hole.
  "CHI_REQ_KNOWN_WHEN_VALID",
  "CHI_RSP_KNOWN_WHEN_VALID",
  "CHI_DAT_KNOWN_WHEN_VALID",
  # Link layer.
  "CHI_LINK_SIDEBAND_IDLE_IN_RESET",
  "CHI_LINK_RESTARTS_AFTER_RESET",
  "CHI_LINK_DEACTIVATE_WHEN_IDLE",
  "CHI_LASM_LEGAL_TRANSITION",
  "CHI_LASM_ACTIVATE_OBSERVED",
  "CHI_LCRD_QUIESCENT_IN_STOP",
  "CHI_LCRD_OVERFLOW",
  "CHI_LCRD_UNDERFLOW",
  "CHI_LCRD_USED_IN_GRANT_CYCLE",
  "CHI_TXSACTIVE_COVERS_OUTSTANDING",
  "CHI_TXSACTIVE_DEASSERT_BOUNDED",
  # Transaction layer.
  "CHI_COMPLETION_FOLLOWS_REQ",
  "CHI_ATOMIC_RETURN_USES_DAT_COMPLETION",
  "CHI_ORDERED_READ_RECEIPT_BEFORE_DAT",
  "CHI_TXNID_REUSE_REQUESTER",
  "CHI_TXNID_REUSE_COMPLETER",
  "CHI_WRITE_DAT_BEFORE_DBID",
  "CHI_WRITE_DAT_TXNID_MATCHES_DBID",
  "CHI_COMPACK_BEFORE_COMPLETION",
  "CHI_COMPACK_WITHOUT_EXPCOMPACK",
  # DAT burst shape, tracked separately per direction.
  "CHI_TX_DAT_FIRST_BEAT_DATAID_ZERO",
  "CHI_RX_DAT_FIRST_BEAT_DATAID_ZERO",
  "CHI_TX_DAT_DATAID_SEQUENTIAL",
  "CHI_RX_DAT_DATAID_SEQUENTIAL",
  "CHI_TX_DAT_TXNID_STABLE",
  "CHI_RX_DAT_TXNID_STABLE",
  "CHI_TX_WRITE_DAT_BEAT_COUNT",
  "CHI_RX_WRITE_DAT_BEAT_COUNT",
  "CHI_TX_READ_COMPLETION_DAT_OPCODE",
  "CHI_RX_READ_COMPLETION_DAT_OPCODE",
  "CHI_TX_READ_COMPLETION_DAT_BEAT_COUNT",
  "CHI_RX_READ_COMPLETION_DAT_BEAT_COUNT",
  # SNP channel (bind_chi_snp).
  "CHI_SNP_FLITV_REQUIRES_LINK",
  "CHI_SNP_LCRDV_REQUIRES_LINK",
  "CHI_SNP_VALID_REQUIRES_PEND",
  "CHI_SNP_KNOWN_WHEN_VALID",
  "CHI_SNP_IDLE_IN_RESET",
  "CHI_SNP_LCRD_OVERFLOW",
  "CHI_SNP_LCRD_UNDERFLOW",
  # Per-opcode SNP field applicability. Named CHI_SNP_* so CHECK_IDS_SNP -- a
  # name-prefix filter here, a range test in SV -- puts them in the SNP bind's
  # set, and placed inside the SNP block so the SV range test agrees.
  "CHI_SNP_FWD_FIELDS_ZERO",
  "CHI_SNP_RET_TO_SRC_LEGAL",
  "CHI_SNP_DO_NOT_GO_TO_SD_LEGAL",
  # Link layer, appended. These belong with the link rules above and are down
  # here only because the order is append-only; putting them where they read best
  # would renumber the SNP block. They sit AFTER it deliberately, so the SNP
  # range test still answers false for them and bind_chi keeps ownership.
  "CHI_LASM_ACTIVATION_TIMEOUT",
  "CHI_LASM_DEACTIVATION_TIMEOUT",
  # RSP field legality, appended for the same append-only reason. One ID for one
  # rule: Appendix A Table A-4 marks certain RSP fields `0` or `0 a` for certain
  # opcodes, and both markings mean the field must be driven zero. TxnID, RespErr
  # and Resp are checked together because they are three columns of one table,
  # not three rules.
  "CHI_RSP_FIELD_ZERO",
  # rule: the Resp encodings a Comp response may carry -- E Table 4-7 / D Table
  # 4-5. Issue-parameterized, because E adds Comp_UD_PD and D gives that encoding
  # no meaning on a Comp at all. Separate from RSP_FIELD_ZERO because that one
  # says a field must be ZERO for certain opcodes; this one bounds a field to a
  # SET for one opcode, and the two would stand down together if fused.
  "CHI_RSP_COMP_RESP_LEGAL",
  # ExpCompAck legality, appended for the same append-only reason. The converse
  # -- a CompAck arriving for a request that never asked for one -- has been
  # checked since the first cut as COMPACK_WITHOUT_EXPCOMPACK; this is the
  # direction nobody was watching, because the item constraint made it
  # unreachable.
  "CHI_EXPCOMPACK_REQUIRED_BUT_ZERO",
  # Atomic operand Size against IHI 0050 E Table 2-17 / D Table 2-17. The VIP
  # has had an opinion about this since the first cut (con_atomic_table_2_17_size)
  # and no rule reading it, so the constraint was unverified in both ports.
  # Stands down on a link whose testcase drives the recorded wide-operand
  # stress profile; see atomic_size_stress_allowed.
  "CHI_ATOMIC_SIZE_LEGAL",
  "CHI_REQ_ORDER_LEGAL",
  "CHI_REQ_ATTR_COMBINATION_LEGAL",
  "CHI_REQ_SNP_ATTR_LEGAL",
  "CHI_REQ_LIKELY_SHARED_LEGAL",
  "CHI_REQ_SIZE_LEGAL",
  "CHI_REQ_EXCL_LEGAL",
  "CHI_REQ_ENDIAN_LEGAL",
  "CHI_REQ_TAGOP_LEGAL",
  "CHI_REQ_RETURN_PATH_LEGAL",
  "CHI_DAT_HOME_NID_LEGAL",
  "CHI_DAT_CBUSY_LEGAL",
  "CHI_EXPCOMPACK_PROHIBITED_BUT_SET",
  # Retry field legality, IHI 0050 E section 2.9.4 / D section 2.9.4. Both pass
  # on this VIP today: they guard the retry machinery, which has been built
  # since the first cut with nothing judging the fields it drives.
  #
  # The grant half of the same flow needs nothing here: section 2.6.5 pins
  # PCrdGrant's TxnID and DBID at zero, and CHI_RSP_FIELD_ZERO already asserts
  # both.
  "CHI_REQ_ALLOW_RETRY_PCRD_ZERO",
  "CHI_REQ_PCRD_RETURN_FIELDS_ZERO",
  # Section 2.6.5 step 2: "The TxnID is set to the same value as the TxnID of
  # the request." A RetryAck naming a TxnID no request is holding bounces
  # nothing, and the requester has no transaction to re-issue against the credit
  # that follows.
  "CHI_RSP_RETRY_ACK_TXN_ID",
  # Section 2.9.4: "The AllowRetry field must be asserted the first time a
  # transaction is sent." Checked as a credit pool rather than as a
  # first-attempt pairing, because section 2.6.5 step 4 permits the re-issue's
  # TxnID to differ from the bounced request's -- so the credit it spends is the
  # only thing on the wire tying the two together.
  "CHI_REQ_RETRY_SPENDS_GRANTED_CREDIT",
  # IHI 0050 E section 14.6.3 / D section 13.6.3, the Banned Output Race. A
  # component's two LINKACTIVE outputs have a defined relationship -- "Output X
  # must change after or at the same time as output Y, but it is not permitted
  # to change before output Y" -- instantiated as four orderings on TXREQ and
  # RXACK. One id for all four: they are one statement about one pair of
  # signals, and the report names which ordering broke.
  "CHI_LASM_OUTPUT_RACE",
  # The companion to the four, and a different rule: they constrain a driver's
  # own two outputs, this constrains the OBSERVER. "For all input race
  # conditions, a component that observes the input race is required to wait for
  # both signals before changing any output signals."
  "CHI_LASM_INPUT_RACE_HOLD",
  # Section 2.5: "A Comp response message sent separate from a DBIDResp or
  # DBIDRespOrd message for a Write transaction must include the same DBID field
  # value." The SEPARATE form is the only one where two messages carry a DBID
  # that could disagree, so this became checkable when cfg.split_write_rsp
  # landed and nothing has read it since.
  #
  # Atomic transactions are EXEMPT, two lines later in the same section, where
  # the equality is "permitted, but is not required". Built in rather than
  # retrofitted: a rule written for writes and applied to atomics would
  # false-fail a conformant completer.
  "CHI_COMP_DBID_MATCHES_GRANT",

  # Section 2.5 again, on the other identifier the pair uses: a DBID a Completer
  # hands out must be unique for a given Requester while the transaction it
  # belongs to is outstanding. The Requester tags its write data with the DBID
  # and nothing else, so two live transactions sharing one make their data
  # indistinguishable -- to the Completer first, and to every shadow after it.
  #
  # The mirror of the TxnID-uniqueness rule with the roles swapped, and it was
  # the one identifier rule in the section that nothing checked.
  "CHI_COMPLETER_DBID_UNIQUE",

  # Allocate where Table A-3 marks it inapplicable, appended for the same
  # append-only reason.
  #
  # Its own id, and the reason is what makes the rest of Table A-3's MemAttr
  # columns absent rather than forgotten. Cacheable, Device and EWA are fixed by
  # the table on the fourteen Snoopable-only opcodes -- and on those opcodes
  # SnpAttr must be 1, which CHI_REQ_SNP_ATTR_LEGAL requires, while Table 2-12
  # admits no Snoopable row without Cacheable and EWA and none with Device, which
  # CHI_REQ_ATTR_COMBINATION_LEGAL requires. A rule for those three columns could
  # not fail without one of those two failing first.
  #
  # Allocate is the one column neither reaches: Table 2-12's Snoopable rows leave
  # it free, so an Evict carrying it passes every existing rule while section
  # 2.9.3 puts Evict on its inapplicable-and-must-be-zero list.
  "CHI_REQ_ALLOCATE_LEGAL",
)

# Rules the Python port deliberately does not implement, with the reason. Kept
# beside the registry so the vacuity report can distinguish "never exercised"
# (a gap worth chasing) from "cannot exist here" (a recorded decision).
CHECK_IDS_SV_ONLY = {
  "CHI_REQ_KNOWN_WHEN_VALID": "Verilator is 2-state; a net cannot hold X/Z",
  "CHI_RSP_KNOWN_WHEN_VALID": "Verilator is 2-state; a net cannot hold X/Z",
  "CHI_DAT_KNOWN_WHEN_VALID": "Verilator is 2-state; a net cannot hold X/Z",
  "CHI_SNP_KNOWN_WHEN_VALID": "Verilator is 2-state; a net cannot hold X/Z",
}

# Rules owned by the SNP checker rather than the main one, so each report can
# say which of its own rules went unexercised without listing the other's.
CHECK_IDS_SNP = tuple(n for n in CHECK_IDS if n.startswith("CHI_SNP_"))
CHECK_IDS_MAIN = tuple(n for n in CHECK_IDS if not n.startswith("CHI_SNP_"))


# Every SCOREBOARD rule, in the same order as vip_chi_sb_check_id_t in the SV
# types package.
#
# The registry above covers the SVA binds only, and every scoreboard check ever
# written here has been outside it: named nowhere, counted only when it FAILED,
# and therefore invisible to the vacuity aggregation. A scoreboard rule that
# never once evaluated reads, in every log and in the regression summary, exactly
# like a rule that holds -- which is the state the whole per-check mechanism
# exists to make impossible.
#
# A SECOND registry rather than more entries in the first, for a structural
# reason: the SVA IDs size four fixed arrays inside EVERY vip_chi_if instance,
# and a scoreboard rule is judged once per component, not per interface. The two
# share the CSV schema instead, which is what actually matters -- the aggregation
# reads both through one code path and gates on both alike.
#
# Append-only, like the other registry: the names appear in regression exports.
CHECK_IDS_SB = (
  # Checker A -- lifecycle. Orphans are split by CHANNEL because they are
  # reached by different paths: an RSP arrives for a transaction the table never
  # opened, a DAT for one whose return leg was never registered.
  "CHI_SB_TXN_COMPLETES",
  "CHI_SB_RSP_HAS_OPEN_TXN",
  "CHI_SB_RSP_TGTID_CORRECT",
  "CHI_SB_PERSIST_PGROUP_MATCHES",
  "CHI_SB_TAG_MATCH_OWED",
  "CHI_SB_DAT_HAS_OPEN_TXN",
  "CHI_SB_TXNID_NOT_REUSED",
  "CHI_SB_COMPLETION_OPCODE_MODELLED",
  # Checker B -- cross-agent request fidelity.
  "CHI_SB_REQ_RELAYED",
  "CHI_SB_REQ_ROUTED",
  # Checker C -- data and MTE tag integrity. The read and atomic-return compares
  # shared one counter before this registry existed, so a regression could not
  # tell which of the two had actually run.
  "CHI_SB_READ_DATA_MATCHES",
  "CHI_SB_ATOMIC_RETURN_MATCHES",
  "CHI_SB_READ_TAG_MATCHES",
  "CHI_SB_READ_TAGOP_REPLAYED",
  "CHI_SB_TAGOP_STABLE_ACROSS_BEATS",
  # Checker E -- ordered-stream acknowledgement order.
  "CHI_SB_ORDERED_ACK_IN_ORDER",
  # Checker F -- Appendix B originator legality.
  "CHI_SB_ORIGINATOR_LEGAL",
)


class Resp(IntEnum):
  """Cache-state Resp field (RSP/DAT). Reserved encodings kept for fidelity."""
  I = 0b000
  SC = 0b001
  UC = 0b010
  RESERVED_0 = 0b011
  RESERVED_1 = 0b100
  RESERVED_2 = 0b101
  UD_PD = 0b110   # UniqueDirty / partial-dirty
  SD_PD = 0b111   # SharedDirty / partial-dirty


class RespErr(IntEnum):
  OKAY = 0b00
  EXOKAY = 0b01
  DERR = 0b10
  NDERR = 0b11


class ReqOpcode(IntEnum):
  # Hands one L-credit back to the receiver that granted it. Opcode 0 on
  # every channel; carries no transaction. See VIP_CHI_*_LCRD_RETURN_C.
  LCRD_RETURN = 0x00
  READ_NO_SNP = 0x04
  PCRD_RETURN = 0x05
  READ_NO_SNP_SEP = 0x11
  CLEAN_SHARED_PERSIST_SEP = 0x13
  WRITE_NO_SNP_PTL = 0x1C
  WRITE_NO_SNP_FULL = 0x1D
  CLEAN_SHARED_PERSIST = 0x27
  ATOMIC_STORE_0 = 0x28
  ATOMIC_STORE_1 = 0x29
  ATOMIC_STORE_2 = 0x2A
  ATOMIC_STORE_3 = 0x2B
  ATOMIC_STORE_4 = 0x2C
  ATOMIC_STORE_5 = 0x2D
  ATOMIC_STORE_6 = 0x2E
  ATOMIC_STORE_7 = 0x2F
  ATOMIC_LOAD_0 = 0x30
  ATOMIC_LOAD_1 = 0x31
  ATOMIC_LOAD_2 = 0x32
  ATOMIC_LOAD_3 = 0x33
  ATOMIC_LOAD_4 = 0x34
  ATOMIC_LOAD_5 = 0x35
  ATOMIC_LOAD_6 = 0x36
  ATOMIC_LOAD_7 = 0x37
  ATOMIC_SWAP = 0x38
  ATOMIC_COMPARE = 0x39
  PREFETCH_TGT = 0x3A
  MAKE_READ_UNIQUE = 0x41
  WRITE_NO_SNP_ZERO = 0x44
  WRITE_EVICT_OR_EVICT = 0x42
  WRITE_UNIQUE_ZERO = 0x43
  # Coherent (Tier C) -- all <= 0x1B so they fit the CHI-D 6-bit field too.
  READ_SHARED = 0x01
  READ_CLEAN = 0x02
  READ_ONCE = 0x03
  READ_UNIQUE = 0x07
  CLEAN_SHARED = 0x08
  CLEAN_INVALID = 0x09
  MAKE_INVALID = 0x0A
  CLEAN_UNIQUE = 0x0B
  MAKE_UNIQUE = 0x0C
  EVICT = 0x0D
  WRITE_CLEAN_FULL = 0x17
  WRITE_UNIQUE_PTL = 0x18
  WRITE_UNIQUE_FULL = 0x19
  WRITE_BACK_FULL = 0x1B
  # Combined Write + CMO (Issue E only). One request carrying both a write and a
  # cache-maintenance operation to the same address, which the completer must
  # apply IN THAT ORDER -- the CMO acts on the state the write leaves behind, so
  # a completer that applied them the other way round would be silently wrong on
  # exactly the case the combined form exists to make efficient.
  #
  # Table 13-14 is two-dimensional: rows are Opcode[5:0] and these all sit in the
  # Opcode[6] = 1 column, which is why they are 0x40 above the row value and why
  # they cannot fit CHI-D's 6-bit REQ opcode field at all.
  WRITE_NO_SNP_FULL_CLEAN_SH = 0x50
  WRITE_NO_SNP_FULL_CLEAN_INV = 0x51
  WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP = 0x52
  WRITE_NO_SNP_PTL_CLEAN_SH = 0x60
  WRITE_NO_SNP_PTL_CLEAN_INV = 0x61
  WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP = 0x62


class RspOpcode(IntEnum):
  # Hands one L-credit back to the receiver that granted it. Opcode 0 on
  # every channel; carries no transaction. See VIP_CHI_*_LCRD_RETURN_C.
  LCRD_RETURN = 0x00
  COMP_ACK = 0x02
  RETRY_ACK = 0x03
  COMP = 0x04
  COMP_DBID_RESP = 0x05
  DBID_RESP = 0x06
  PCRD_GRANT = 0x07
  READ_RECEIPT = 0x08
  RESP_SEP_DATA = 0x0B
  PERSIST = 0x0C
  COMP_PERSIST = 0x0D
  DBID_RESP_ORD = 0x0E
  # The CMO half of a Combined Write's completion (Issue E only). The write half
  # completes with Comp / CompDBIDResp as any write does; the CMO half is a
  # SEPARATE response, and a completer that answered a combined request with the
  # write completion alone would leave the CMO permanently outstanding.
  COMP_CMO = 0x14

  # The Completer's answer to a write whose tags had to be CHECKED.
  #
  # IHI 0050 E section 12: TagOp = 0b11 on a write means Match -- "the Physical
  # Tags in the write must be checked against the Allocation Tag values obtained
  # from memory" -- and section 2.3.1 makes the response an obligation: "If the
  # WriteData message indicates that a Tag Match is required, then the Slave
  # sends a TagMatch response after completing the required Tag Match
  # operation."
  #
  # Reachable from a sequence for as long as this VIP has had a TagOp field:
  # TagOp is a bare 2-bit value with no enum and no constraint, so any test
  # could ask for Match and get silence back. Modelling it needs no new flit
  # field -- Table 13-7 shares the response's DBID bits with TagGroupID, exactly
  # as it does with PGroupID.
  TAG_MATCH = 0x0A

  SNP_RESP = 0x01
  SNP_RESP_FWDED = 0x09


class DatOpcode(IntEnum):
  # Hands one L-credit back to the receiver that granted it. Opcode 0 on
  # every channel; carries no transaction. See VIP_CHI_*_LCRD_RETURN_C.
  LCRD_RETURN = 0x00
  SNP_RESP_DATA = 0x1
  COPY_BACK_WR_DATA = 0x2
  NON_COPY_BACK_WR_DATA = 0x3
  COMP_DATA = 0x4
  SNP_RESP_DATA_PTL = 0x5
  SNP_RESP_DATA_FWDED = 0x6
  DATA_SEP_RESP = 0xB
  NCB_WR_DATA_COMP_ACK = 0xC


class SnpOpcode(IntEnum):
  # Link-layer credit return, opcode 0 on every channel; carries no transaction.
  # See VIP_CHI_*_LCRD_RETURN_C. The other three channel enums have always had
  # this and the snoop one did not, which is a naming gap rather than a
  # behavioural one -- the monitor tests opcode 0 directly -- but it left the SV
  # and Python ports disagreeing about which opcodes exist, and a divergence
  # report that always contains one entry is a report nobody reads.
  LCRD_RETURN = 0x00
  SHARED = 0x01
  CLEAN = 0x02
  ONCE = 0x03
  UNIQUE = 0x07
  CLEAN_SHARED = 0x08
  CLEAN_INVALID = 0x09
  MAKE_INVALID = 0x0A
  SHARED_FWD = 0x11
  CLEAN_FWD = 0x12
  ONCE_FWD = 0x13
  NOT_SHARED_DIRTY_FWD = 0x14
  UNIQUE_FWD = 0x17


# Fixed spec-derived field widths (issue-independent).
# ============================================================================
# Appendix B -- which node class may ORIGINATE a packet.
# ============================================================================
# Appendix B is a table of From->To pairs, one block per packet type, and until
# now neither port modelled it. The absence hid a whole class of defect: a flow
# can be built out of legal opcodes carrying legal fields in a legal order and
# still be illegal, because the node emitting it is not one the specification
# lets emit it. Nothing else in the VIP asks that question -- the completer is
# the only party judging the flow, and it answers whatever it is asked.
#
# The VIP's own separated read was exactly that shape: ReadNoSnpSep from an RN-I
# and RespSepData from an SN-F, neither of which appears anywhere in Appendix B,
# and every test of it passed in both ports.
#
# Only the FROM column is encoded. The To column is a routing question the TgtID
# checks already answer, and encoding it here would give one fact two owners.
# That also means the per-opcode entry is the UNION of that opcode's From cells:
# it says "a node of this class may originate this packet", not "may originate
# it towards you".
#
# Node classes the VIP has no role for -- RN-D, SN-I and ICN(MN) -- are dropped
# rather than approximated. The table is therefore a subset of Appendix B and
# never a superset: a role it permits is a role Appendix B permits, so a
# violation it reports is a real one.
#
# Reading these blocks needs the PDF, not the markdown conversion. The
# conversion renders a merged left-hand cell as if each opcode had its own
# From row, which turns a block's three From rows into one per opcode and
# silently invents originators. It is the same failure mode as the flit tables
# in , and it is why ReadNoSnpSep looks RN-originated in the md.

_ORIG_RNF_C = frozenset({Role.RNF})
_ORIG_RN_C = frozenset({Role.RNF, Role.RNI})
_ORIG_HOME_C = frozenset({Role.HNF, Role.HNI})
_ORIG_RN_HOME_C = _ORIG_RN_C | _ORIG_HOME_C
_ORIG_HOME_SNF_C = _ORIG_HOME_C | frozenset({Role.SNF})


# Table B-1. The three-row blocks are RN-*->ICN, ICN(HN-F)->SN-F and
# ICN(HN-I)->SN-I, so their union is every class but the Slave.
ORIGINATOR_REQ_C = {
  ReqOpcode.READ_NO_SNP: _ORIG_RN_HOME_C,
  ReqOpcode.WRITE_NO_SNP_FULL: _ORIG_RN_HOME_C,
  ReqOpcode.WRITE_NO_SNP_PTL: _ORIG_RN_HOME_C,
  ReqOpcode.WRITE_NO_SNP_ZERO: _ORIG_RN_HOME_C,

  # Two rows, both from a Home: ICN(HN-F)->SN-F and ICN(HN-I)->SN-I. There is
  # no row in which a Request Node sends ReadNoSnpSep, and section 2.3.1 says
  # the same thing in prose -- "must only be sent by the Home to the Slave".
  ReqOpcode.READ_NO_SNP_SEP: _ORIG_HOME_C,

  ReqOpcode.CLEAN_SHARED: _ORIG_RN_HOME_C,
  ReqOpcode.CLEAN_SHARED_PERSIST: _ORIG_RN_HOME_C,
  ReqOpcode.CLEAN_SHARED_PERSIST_SEP: _ORIG_RN_HOME_C,
  ReqOpcode.CLEAN_INVALID: _ORIG_RN_HOME_C,
  ReqOpcode.MAKE_INVALID: _ORIG_RN_HOME_C,

  ReqOpcode.PCRD_RETURN: _ORIG_RN_HOME_C,

  # PrefetchTgt is the one request a Request Node addresses straight at a
  # Slave: RN-F, RN-D, RN-I -> SN-F, with no Home row at all.
  ReqOpcode.PREFETCH_TGT: _ORIG_RN_C,

  # Coherent requests are RN-F only -- an RN-I has no cache to act on.
  ReqOpcode.READ_CLEAN: _ORIG_RNF_C,
  ReqOpcode.READ_SHARED: _ORIG_RNF_C,
  ReqOpcode.READ_UNIQUE: _ORIG_RNF_C,
  ReqOpcode.MAKE_READ_UNIQUE: _ORIG_RNF_C,
  ReqOpcode.CLEAN_UNIQUE: _ORIG_RNF_C,
  ReqOpcode.MAKE_UNIQUE: _ORIG_RNF_C,
  ReqOpcode.EVICT: _ORIG_RNF_C,
  ReqOpcode.WRITE_BACK_FULL: _ORIG_RNF_C,
  ReqOpcode.WRITE_EVICT_OR_EVICT: _ORIG_RNF_C,
  ReqOpcode.WRITE_CLEAN_FULL: _ORIG_RNF_C,

  # The ReadOnce / WriteUnique block: any Request Node, no Home row.
  ReqOpcode.READ_ONCE: _ORIG_RN_C,
  ReqOpcode.WRITE_UNIQUE_FULL: _ORIG_RN_C,
  ReqOpcode.WRITE_UNIQUE_PTL: _ORIG_RN_C,
  ReqOpcode.WRITE_UNIQUE_ZERO: _ORIG_RN_C,
}

# Atomics share one block: RN-*->ICN, ICN(HN-F)->SN-F, ICN(HN-I)->SN-I.
# The contiguous 0x28..0x39 range; ATOMIC_REQ_OPCODES below says the same thing
# but is declared after this table.
for _op in range(0x28, 0x3A):
  ORIGINATOR_REQ_C[ReqOpcode(_op)] = _ORIG_RN_HOME_C

# Table B-1's preamble: "unless explicitly stated otherwise, a reference to a
# Write transaction includes both the individual Write transaction and the
# corresponding Combined Write transaction." So each Combined Write inherits the
# row of the write it is built on -- these are all WriteNoSnp*.
for _op in (ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH,
            ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_INV,
            ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP,
            ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH,
            ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_INV,
            ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP):
  ORIGINATOR_REQ_C[_op] = _ORIG_RN_HOME_C


# Table B-2 is deliberately absent. It has two rows: every snoop but SnpDVMOp is
# ICN(HN-F) -> RN-F, and SnpDVMOp is ICN(MN) -> RN-F/RN-D, a node class this VIP
# has no role for. The one modellable row cannot be falsified here -- the RN-F
# agent's only peer IS the HN-F, so the monitor attributes every snoop it can
# see to HN-F by construction and the rule would pass without ever having been
# able to fail. A vacuous rule is worse than a missing one: it reports evidence
# it does not have. It becomes worth encoding when a second snoop source exists.


# Table B-3.
ORIGINATOR_RSP_C = {
  RspOpcode.RETRY_ACK: _ORIG_HOME_SNF_C,
  RspOpcode.PCRD_GRANT: _ORIG_HOME_SNF_C,
  RspOpcode.COMP: _ORIG_HOME_SNF_C,
  RspOpcode.COMP_DBID_RESP: _ORIG_HOME_SNF_C,
  RspOpcode.COMP_CMO: _ORIG_HOME_SNF_C,
  RspOpcode.READ_RECEIPT: _ORIG_HOME_SNF_C,
  RspOpcode.DBID_RESP: _ORIG_HOME_SNF_C,
  RspOpcode.PERSIST: _ORIG_HOME_SNF_C,
  RspOpcode.COMP_PERSIST: _ORIG_HOME_SNF_C,

  # One row, and it is the whole finding: RespSepData is ICN(HN-F, HN-I) ->
  # RN-*, with no Slave row. Section 2.3.1 says it outright -- "RespSepData is
  # permitted from the Home only."
  RspOpcode.RESP_SEP_DATA: _ORIG_HOME_C,

  # DBIDRespOrd has a Home row and no Slave row, unlike plain DBIDResp.
  RspOpcode.DBID_RESP_ORD: _ORIG_HOME_C,

  # TagMatch: ICN(HN-F) and SN-F. No HN-I row -- an HN-I has no tags.
  RspOpcode.TAG_MATCH: frozenset({Role.HNF, Role.SNF}),

  # Downstream responses.
  RspOpcode.COMP_ACK: _ORIG_RN_C,
  RspOpcode.SNP_RESP: _ORIG_RNF_C,
  RspOpcode.SNP_RESP_FWDED: _ORIG_RNF_C,
}


# Table B-4.
ORIGINATOR_DAT_C = {
  # CompData has an upstream block (Home, SN-F, SN-I) and a peer-to-peer row,
  # RN-F -> RN-*, which is why RN-F appears here and not on DataSepResp.
  DatOpcode.COMP_DATA: _ORIG_HOME_SNF_C | frozenset({Role.RNF}),
  DatOpcode.DATA_SEP_RESP: _ORIG_HOME_SNF_C,

  DatOpcode.COPY_BACK_WR_DATA: _ORIG_RNF_C,
  DatOpcode.NON_COPY_BACK_WR_DATA: _ORIG_RN_HOME_C,
  DatOpcode.NCB_WR_DATA_COMP_ACK: _ORIG_RN_C,
  DatOpcode.SNP_RESP_DATA: _ORIG_RNF_C,
  DatOpcode.SNP_RESP_DATA_PTL: _ORIG_RNF_C,
  DatOpcode.SNP_RESP_DATA_FWDED: _ORIG_RNF_C,
}


# The one place this VIP knowingly departs from Appendix B, named rather than
# left implicit.
#
# The agent topology is point-to-point RN-I <-> SN-F: there is no Home component
# between them. The separated read needs one -- Appendix B puts the ReadNoSnpSep
# on a Home->Slave link -- so the RN-I agent plays the Home's REQ leg, and the
# item constraint that sets ReturnNID == SrcID is what makes the data come back
# to it. Everything else on the link is then conformant: the Slave's ReadReceipt
# goes to the Home stand-in (Table B-3 SN-F -> ICN(HN-F)) and its DataSepResp to
# the requester (Table B-4 SN-F -> RN-I, an EXPECTED target, not merely a
# permitted one).
#
# cfg.rni_home_standin is on by default, which grants an RN-I the originator
# rights of a Home for these opcodes and nothing else. Turning it off makes the
# checker judge the link as literal Appendix B, which is what the negative
# control does: the departure is then visible as a reported violation rather
# than as an exemption nobody can see.
HOME_STANDIN_REQ_C = frozenset({
  ReqOpcode.READ_NO_SNP_SEP,
})

# The same departure seen from the completer's end, and found by the checker
# above on its first sweep rather than by reading: the SN-F answers an ordered
# write with DBIDRespOrd, and Table B-3 gives that response ONE From row --
# ICN(HN-F, HN-I, MN). Plain DBIDResp has three, including
# "SN-F -> ICN(HN-F), RN-F, RN-D, RN-I", so a Slave answering a Requester
# directly is contemplated by the table; extending that to DBIDRespOrd is not.
#
# The reason it is not is section 2.6: "The Completer is a PoS. A PoS sending
# DBIDResp or DBIDRespOrd means [...]" -- DBIDRespOrd carries a Point of
# Serialization guarantee, ordering "all subsequent [...] requests to the same
# address from the same source against this request". A Slave in a real system
# is not the PoS for other Requesters and cannot make that promise.
#
# On this link it can, and that is the whole justification: the RN-I <-> SN-F
# pair has no other ordering point in it, so the completer IS the PoS the
# requester is talking to. Same shape as the separated read -- a node playing
# the Home's part because the link has no Home on it -- and named the same way,
# so it is auditable rather than assumed. Switching the stand-in off makes
# CHI_SB_ORIGINATOR_LEGAL report it, which is what the negative control asserts.
HOME_STANDIN_RSP_C = frozenset({
  RspOpcode.DBID_RESP_ORD,
})

QOS_WIDTH = 4
PCRD_TYPE_WIDTH = 4
MPAM_WIDTH = 11
TAGOP_WIDTH = 2

# Table 13-34 "TagOp value encodings": 0b11 is "Match Fetch" -- Match on a write
# (check the physical tags against memory), Fetch on a read. The twin of
# VIP_CHI_TAGOP_MATCH_C in the SystemVerilog port.
TAGOP_MATCH = 0b11
# The other three encodings from the same table, named because section 12.5.2's
# TU rules turn on them: Invalid zeroes every Memory Tagging field, Transfer and
# Match make TU inapplicable, Update requires every TU bit asserted.
TAGOP_INVALID = 0b00
TAGOP_TRANSFER = 0b01
TAGOP_UPDATE = 0b10
GROUP_ID_EXT_WIDTH = 3
SIZE_WIDTH = 3
RESP_WIDTH = 3
RESP_ERR_WIDTH = 2
ORDER_WIDTH = 2
MEMATTR_WIDTH = 4
# DataID and CCID, both fixed at 2 bits by Table 13-9 / 12-9 regardless of the
# data-bus width. See ChiCfg.data_id_width.
DATA_ID_WIDTH = 2
CBUSY_WIDTH = 3
FWDSTATE_WIDTH = 3
DATASOURCE_WIDTH = 4
CACHE_LINE_BYTES = 64


# ---------------------------------------------------------------------------
# Runtime configuration (replaces vip_chi_cfg_t; plain ints, no parameters).
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ChiCfg:
  issue: Issue = Issue.D
  node_id_width: int = 7
  addr_width: int = 44
  data_bytes: int = 32
  datacheck_en: bool = False
  poison_en: bool = False
  mpam_en: bool = False
  parity_en: bool = False

  # -- issue-derived scalar widths (mirror the SV chi_*_width helpers) --
  @property
  def is_e(self) -> bool:
    return self.issue == Issue.E

  @property
  def txn_id_width(self) -> int:
    return 12 if self.is_e else 10

  @property
  def req_opcode_width(self) -> int:
    return 7 if self.is_e else 6

  @property
  def rsp_opcode_width(self) -> int:
    return 5 if self.is_e else 4

  @property
  def dat_opcode_width(self) -> int:
    return 4

  @property
  def snp_opcode_width(self) -> int:
    return 5

  @property
  def lpid_width(self) -> int:
    """LPID is 5 bits in BOTH issues. Issue E does not widen it.

    It used to return 8 for E, on the reasonable-looking reading that Issue E
    "extends the group ID to 8 bits". It does -- but by prefixing GroupIDExt,
    not by widening LPID. IHI 0050 E 13.10.8 states the extension as a
    concatenation: "used to extend the persistent group ID size to 8 bits;
    PGroupID[7:0] = {GroupIDExt[2:0], LPID[4:0]}". Carrying an 8-bit LPID AND a
    3-bit GroupIDExt counted the extension twice and made the Issue E REQ flit
    three bits wider than Table 13-6's.

    The arithmetic is what settled it, and it did not need the table read at
    all. Table 13-6 gives R = (87 + RAW + M + Y) to (99 + RAW + M + Y), a span
    of 12 that is exactly the node-ID variation across this flit's three node-ID
    fields -- so at the narrowest NodeID_Width the total must equal the minimum
    exactly, and at the widest the maximum exactly. This VIP was +3 at all four
    corners. Issue D, whose Table 12-6 total is R = (121 to 141) + M + X, lands
    on both corners exactly, which is what validates the method rather than the
    conclusion.
    """
    return 5

  # -- data-geometry-derived widths --
  @property
  def be_width(self) -> int:
    return self.data_bytes if self.data_bytes > 0 else 1

  @property
  def num_dat_beats(self) -> int:
    return (CACHE_LINE_BYTES // self.data_bytes) if self.data_bytes > 0 else 0

  @property
  def data_id_width(self) -> int:
    """DataID and CCID are 2 bits, at every data-bus width.

    IHI 0050 E Table 13-9 and D Table 12-9 both give a flat "2" for each, in the
    column that carries a formula wherever one is meant -- BE is "DW/8 = 16, 32,
    64", Tag is "DW/32 = 4, 8, 16", Data is "DW = 128, 256, 512". These two are
    not parameterized and the tables say so by not parameterizing them.

    This used to be clog2(beats), which is the width DataID *needs* rather than
    the width it *has*: at DW = 128 it happens to give 2 and is right by
    accident; at 256 and 512 it gives 1, and the flit came out two bits narrow.

    That went unseen because a second deviation cancelled it. The VIP gives
    DataCheck and Poison a 1-bit placeholder when their buses are absent (as
    mpam_field_width does), where the specification's totals take DC = P = 0 --
    so the DAT flit ran +2 from the placeholders and -2 from these, landing
    exactly on Table 13-9's total at DW = 256 and 512. Two errors summing to
    zero at the two configurations anyone would check. The finding on it notes width gate is what separated them.
    """
    return DATA_ID_WIDTH

  @property
  def datacheck_width(self) -> int:
    return (self.data_bytes if self.data_bytes > 0 else 1) if self.datacheck_en else 1

  @property
  def poison_width(self) -> int:
    return (((self.data_bytes + 7) // 8) if self.data_bytes > 0 else 1) if self.poison_en else 1

  @property
  def mpam_field_width(self) -> int:
    return MPAM_WIDTH if self.mpam_en else 1

  @property
  def tag_width(self) -> int:
    w = (8 * self.data_bytes) // 32
    return w if w > 0 else 1

  @property
  def tu_width(self) -> int:
    w = (8 * self.data_bytes) // 128
    return w if w > 0 else 1


VIP_CHI_DEFAULT_CFG = ChiCfg(issue=Issue.D, node_id_width=1, addr_width=1, data_bytes=1)


# ---------------------------------------------------------------------------
# Transfer helpers (mirror the SV chi_size_bytes / chi_xfer_dat_beats).
# ---------------------------------------------------------------------------


def chi_size_bytes(size: int) -> int:
  return 1 << size


def chi_xfer_dat_beats(size: int, data_bytes: int) -> int:
  """DAT beats one transfer of 2**size bytes needs on a data_bytes-wide bus."""
  if data_bytes <= 0:
    return 0
  size_bytes = chi_size_bytes(size)
  if size_bytes <= data_bytes:
    return 1
  return (size_bytes + data_bytes - 1) // data_bytes


# Snoops whose response must NOT carry data. The snoopee invalidates the line and
# DISCARDS any Dirty copy instead of passing it to the Home: IHI 0050 Chapter 4
# lists no SnpRespData form among the responses permitted to SnpMakeInvalid, only
# the data-less SnpResp_I (Tables 4-9 and 4-11).
#
# The rule is not a formality. SnpMakeInvalid is what a Home sends once the
# requester has committed to overwriting the WHOLE line -- MakeUnique, a full
# WriteUnique -- so the cached copy is about to be superseded and the Home wants
# it gone, not returned. A SnpRespData_I_PD there hands back beats the Home then
# owns as Dirty data it must write out, which can land the stale line in memory
# after the new one. A Home is also entitled to have allocated no buffer and no
# DBID for the beats, leaving the DAT flit unmatched.
#
# SnpCleanInvalid is the opcode that DOES want the Dirty copy back, and the two
# are otherwise identical in their effect on the snoopee. That is why deciding
# the response form from the held state alone looks correct everywhere else:
# only the opcode separates "invalidate and write back" from "invalidate and
# drop". SnpMakeInvalidStash and the stash/query snoops belong in this set when
# they are modeled.
SNP_NO_DATA_OPCODES = frozenset({int(SnpOpcode.MAKE_INVALID)})

# Snoops that leave the snoopee INVALID. IHI 0050 Chapter 4, Tables 4-9 and 4-11:
# every response permitted to these carries the Invalid state, with or without
# data. A snoopee that answers one still holding the line has not given up
# ownership, so the requester about to take it Unique is not the only owner --
# the single-writer invariant, broken without any flit looking wrong.
SNP_INVALIDATING_OPCODES = frozenset({
  int(SnpOpcode.UNIQUE), int(SnpOpcode.CLEAN_INVALID),
  int(SnpOpcode.MAKE_INVALID), int(SnpOpcode.UNIQUE_FWD),
})

# Snoops that forbid the snoopee from RETAINING Unique. The set is IHI 0050 E
# 4.3's, not a reading of the response tables: it names "Must not leave the cache
# line in Unique state" under SnpClean/SnpCleanFwd,
# SnpNotSharedDirty/SnpNotSharedDirtyFwd and SnpShared/SnpSharedFwd. D 4.3 is
# identical.
#
# SnpClean and SnpCleanFwd are listed because this home DOES originate them,
# which is a correction: they were left out on the stated grounds that "this VIP's
# home never originates them", and snoop_for_req maps ReadClean to SnpClean on the
# ordinary path and to SnpCleanFwd on the direct-cache-transfer path, both of
# which several coherent testcases drive. The omission was a rule that could have
# been evaluated and was not.
#
# SnpNotSharedDirty and SnpNotSharedDirtyFwd stay out, and now for a reason that
# holds: snoop_for_req has no ReadNotSharedDirty case, so no request in this model
# produces either. SnpCleanShared stays out for the same kind of reason -- there
# is no CleanShared sequence in seq_lib, so nothing can issue the request that
# would produce it. Both are unreachable rather than unexamined.
SNP_NO_RETAIN_UNIQUE_OPCODES = frozenset({
  int(SnpOpcode.SHARED), int(SnpOpcode.SHARED_FWD),
  int(SnpOpcode.CLEAN), int(SnpOpcode.CLEAN_FWD),
})


def snp_opcode_invalidates(opcode: int) -> bool:
  return int(opcode) in SNP_INVALIDATING_OPCODES


def snp_opcode_forbids_retaining_unique(opcode: int) -> bool:
  return int(opcode) in SNP_NO_RETAIN_UNIQUE_OPCODES


def snp_opcode_returns_no_data(opcode: int) -> bool:
  return int(opcode) in SNP_NO_DATA_OPCODES


# The three permissions a cache state carries, named separately because the seven
# CHI states are not a total order: SharedDirty holds the dirty data without the
# right to write it, so it is neither above nor below UniqueClean. A rule written
# as "state must not increase" cannot be expressed on a rank; it has to be
# expressed on the permissions themselves.
READABLE_STATES = frozenset({
  int(Resp.SC), int(Resp.UC), int(Resp.UD_PD), int(Resp.SD_PD),
})
WRITABLE_STATES = frozenset({int(Resp.UC), int(Resp.UD_PD)})
DIRTY_HOLDING_STATES = frozenset({int(Resp.UD_PD), int(Resp.SD_PD)})


def state_is_readable(state: int) -> bool:
  return int(state) in READABLE_STATES


def state_is_writable(state: int) -> bool:
  return int(state) in WRITABLE_STATES


def state_holds_dirty(state: int) -> bool:
  return int(state) in DIRTY_HOLDING_STATES


def snp_resp_state_gains_permission(from_state: int, reported_state: int) -> bool:
  """True when a snoop response reports a state holding a permission the snoopee
  did not have when the snoop arrived.

  IHI 0050 Chapter 4: a snoop is a request to give up permissions, never a grant
  of them. Whatever the opcode, a snoopee may keep what it held, drop to
  something weaker, or invalidate -- it may not come back readable if it was
  Invalid, writable if it was Shared, or Dirty if it was Clean. The only path
  that raises a cache state is a response to that node's OWN request, which
  arrives on RSP/DAT against a transaction the snoop knows nothing about.

  This is the gate that makes it safe to take the snoopee's next state FROM the
  response rather than deriving it: the reported state writes the shadow
  directory, so an implementation that reports nonsense would otherwise steer
  every later coherency check through it. The opcode ceiling
  (snp_opcode_invalidates / snp_opcode_forbids_retaining_unique above) is the
  other half and is independent -- it bounds the response by what was ASKED, this
  bounds it by what was HELD, and neither implies the other.

  Read and write permission are unconditional: I -> SC needs a read, SC -> UC
  needs a CleanUnique or MakeUnique, and both are requests the checker sees.
  Gaining either without one is a genuine impossibility.

  BECOMING DIRTY IS CONDITIONAL, and the condition is the whole subtlety. A
  holder turns Clean into Dirty by writing to its own cache line -- a purely local
  act with no CHI transaction behind it, so a node granted UC can be UD an instant
  later and nothing on the wire says so. Flagging that would report the observer's
  blind spot as the peer's fault, which is the failure mode this rule exists to
  avoid. But the local act needs WRITE PERMISSION: a SharedClean holder cannot
  write, so it cannot manufacture dirty data, and an SC -> SD response is
  impossible rather than merely unobserved. So dirty is allowed to appear only
  where the snoopee could have written it.

  Stated as a permission comparison and not a state table on purpose: it holds
  for all seven CHI states including the three this VIP does not model, so it
  does not have to be revisited when one of them is added.
  """
  return ((state_is_readable(reported_state) and not state_is_readable(from_state)) or
          (state_is_writable(reported_state) and not state_is_writable(from_state)) or
          (state_holds_dirty(reported_state) and not state_holds_dirty(from_state)
           and not state_is_writable(from_state)))


# The join is a lookup rather than a chain of ifs because the five states this
# VIP models are exactly the five permission triples satisfying "writable implies
# readable" and "dirty implies readable" -- (R, W, D) -> state is total over them.
_JOIN_BY_PERMISSION = {
  (False, False, False): int(Resp.I),
  (True,  False, False): int(Resp.SC),
  (True,  True,  False): int(Resp.UC),
  (True,  False, True):  int(Resp.SD_PD),
  (True,  True,  True):  int(Resp.UD_PD),
}


def state_join(a: int, b: int) -> int:
  """The least cache state carrying every permission either operand carries.

  OR-ing two permission triples yields another one, so the join is total and
  closed over the modeled set. It is NOT a maximum over a rank: SD and UC are
  incomparable (SD holds the dirty data without the right to write it, UC holds
  the right without the data), and their join is UD -- a state neither operand
  is. That row is Table 4-14's ReadUnique-from-SD case, and it is the one a
  rank-based implementation gets wrong.
  """
  return _JOIN_BY_PERMISSION[(
    state_is_readable(a) or state_is_readable(b),
    state_is_writable(a) or state_is_writable(b),
    state_holds_dirty(a) or state_holds_dirty(b),
  )]


_FINAL_STATE_JOIN_OPS = frozenset({
  int(ReqOpcode.READ_SHARED),
  int(ReqOpcode.READ_CLEAN),
  int(ReqOpcode.READ_UNIQUE),
  int(ReqOpcode.MAKE_READ_UNIQUE),
  int(ReqOpcode.CLEAN_UNIQUE),
})


def req_final_state(opcode: int, held: int, granted: int) -> int:
  """The Requester's cache state after its own request completes: a function of
  the state it HELD and the state the completion GRANTED.

  IHI 0050 E Table 4-14 (4.7.1, reads), Tables 4-17 and 4-18 (MakeReadUnique) and
  Table 4-19 (4.7.2, dataless); D Tables 4-12 and 4-13. Those four tables are a
  single rule: a completion GRANTS coherence rights, it does not revoke rights
  the Requester already holds. Every row is the permission join of the two
  states, with one exception noted below -- checked row by row, including the
  three that make the point:

    ReadClean  UD + CompData_SC -> UD    (the grant is weaker; the holder keeps
                                          its dirty line and its write right)
    ReadClean  SD + CompData_UC -> UD    (join of two incomparable states)
    ReadUnique SD + CompData_UC -> UD    (same, and present in D as well as E)

  Taking the granted Resp verbatim -- which is what "final = Resp" does --
  silently drops the writeback obligation for a line the Requester is still
  responsible for, and the dirty beats along with it.

  The held state must be read at COMPLETION time, not at the time the request was
  issued. Tables 4-17 and 4-18 make this explicit with a separate "state at time
  of response" column: a snoop landing while the request is outstanding can take
  the line away, and then SC-at-issue/I-at-response + CompData_UC is UC, not the
  UD that joining against the issue-time state would give. Both callers read a
  live shadow, so they get this for free -- but only because they read it late.

  MakeUnique is the exception and the reason this takes an opcode at all. Its
  completion is Comp_UC (Table 4-19 / D Table 4-13) yet its final state is UD
  from every permitted initial state: the Requester has undertaken to overwrite
  the whole line, so it becomes Dirty by its own act rather than by inheriting
  anyone's dirty data. No join produces that, because the grant does not carry
  it.

  Opcodes that do not appear in these tables return the held state unchanged. The
  non-allocating reads belong to that group on purpose: 4.7.1 requires the
  Requester to IGNORE the cache state in the CompData response to ReadNoSnp,
  ReadOnce, ReadOnceCleanInvalid and ReadOnceMakeInvalid, so joining against it
  would be wrong and not merely unnecessary. Callers decide separately whether an
  opcode invalidates the line -- that is not a state this function can return,
  since "no change" and "goes to I" are different answers.
  """
  op = int(opcode)
  if op == int(ReqOpcode.MAKE_UNIQUE):
    return int(Resp.UD_PD)
  if op in _FINAL_STATE_JOIN_OPS:
    return state_join(held, granted)
  return int(held)


def req_keeps_local_data(held: int) -> bool:
  """True when the Requester must DISCARD the data a read returned because the
  line it already holds is the newer copy.

  IHI 0050 E Table 4-14 footnote c: "Data received from memory must be dropped if
  the cache state is UD or SD, or merged if the cache state is UDP." The
  reachable half of that is the drop: this VIP has no byte-granular dirty
  tracking, so UDP is not modeled and the merge case cannot arise. Overwriting a
  dirty line with the fetched copy loses the locally-modified bytes outright --
  the state stays right and the data goes wrong, which is worse than either alone
  because every later data-integrity check then agrees with the loss.
  """
  return state_holds_dirty(held)


# ---------------------------------------------------------------------------
# IHI 0050 E Table 4-5 / D Table 4-3, "Request types and the corresponding snoop
# requests": WHICH snoop a Home is permitted to send for a given request. The
# table is only half the rule -- the bullet list that follows it in both issues
# widens several rows, and the widening is normative, not commentary. The
# permitted set for a request is therefore
#
#   {Snoop Expected} u {Alternative snoop} u {the bullets below}
#
# and the bullets that matter to the requests this VIP models are:
#
#   B1  SnpNotSharedDirty, SnpShared or SnpClean may be used for
#       ReadNotSharedDirty, ReadShared AND ReadClean.
#   B2  SnpNotSharedDirtyFwd, SnpSharedFwd or SnpCleanFwd may be used for
#       ReadShared.
#   B3  SnpNotSharedDirtyFwd or SnpCleanFwd may be used for ReadNotSharedDirty
#       and ReadClean.  *** SnpSharedFwd is absent here ***
#   B4  Any invalidating snoop may be replaced by SnpUnique or SnpCleanInvalid.
#   B5  Any Forwarding snoop may be replaced by its non-Forwarding form.
#   B6  ReadOnce may use any non-Forwarding, non-invalidating snoop, or
#       SnpOnceFwd.
#
# B1 against B3 is the whole point of this table, and it is the opposite of what
# a reading of the table alone suggests. SnpShared for a ReadClean is PERMITTED
# (B1). SnpSharedFwd for a ReadClean is NOT (B3 omits it, and no other bullet
# reaches it).
#
# The asymmetry is not editorial. A forwarding snoop hands the cache line
# straight to the requester in a state the SNOOPEE picks, and Table 4-34
# (SnpSharedFwd) permits a UD or SD snoopee to forward CompData_SD_PD -- the
# requester ends Shared Dirty. Table 4-14's ReadClean rows permit final SC or UC
# and nothing else; there is no SD row and no CompData_SD_PD column for that
# request. So SnpSharedFwd for a ReadClean lets one legal snoopee response put
# the requester in a state its own request forbids, with no flit anywhere in the
# transaction being individually illegal. The non-forwarding SnpShared cannot do
# this: the snoopee answers the HOME, the home sources the completion, and the
# home is bound by Table 4-14 when it picks the Resp.
#
# Both issues carry B1-B5 in identical words. D additionally permits
# SnpUniqueFwd for ReadShared when only one sharer is present; E drops that
# bullet, so it is not encoded here -- this VIP never picks it, and encoding a
# D-only permission would make the checker accept on E what E does not allow.
# ---------------------------------------------------------------------------
_SNOOPS_PERMITTED_FOR_REQ = {
    # SnpSharedFwd expected, SnpShared alternative; B1 adds SnpClean, B2 the
    # other two Fwd forms.
    int(ReqOpcode.READ_SHARED): frozenset({
        int(SnpOpcode.SHARED), int(SnpOpcode.CLEAN),
        int(SnpOpcode.SHARED_FWD), int(SnpOpcode.CLEAN_FWD),
        int(SnpOpcode.NOT_SHARED_DIRTY_FWD),
    }),
    # SnpCleanFwd expected, SnpClean alternative; B1 adds SnpShared, B3 adds
    # SnpNotSharedDirtyFwd ONLY.
    int(ReqOpcode.READ_CLEAN): frozenset({
        int(SnpOpcode.CLEAN), int(SnpOpcode.SHARED),
        int(SnpOpcode.CLEAN_FWD), int(SnpOpcode.NOT_SHARED_DIRTY_FWD),
    }),
    # SnpUniqueFwd expected, SnpUnique alternative; B4 adds SnpCleanInvalid.
    int(ReqOpcode.READ_UNIQUE): frozenset({
        int(SnpOpcode.UNIQUE), int(SnpOpcode.UNIQUE_FWD),
        int(SnpOpcode.CLEAN_INVALID),
    }),
    # SnpCleanInvalid expected; SnpUnique, SnpUniqueFwd and SnpMakeInvalid are
    # listed alternatives. E-only opcode, so no D column to reconcile.
    int(ReqOpcode.MAKE_READ_UNIQUE): frozenset({
        int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.UNIQUE),
        int(SnpOpcode.UNIQUE_FWD), int(SnpOpcode.MAKE_INVALID),
    }),
    # SnpOnceFwd expected, SnpOnce alternative, plus B6's "any non-Forwarding,
    # non-invalidating snoop".
    int(ReqOpcode.READ_ONCE): frozenset({
        int(SnpOpcode.ONCE), int(SnpOpcode.ONCE_FWD), int(SnpOpcode.SHARED),
        int(SnpOpcode.CLEAN), int(SnpOpcode.CLEAN_SHARED),
    }),
    # SnpCleanInvalid expected, no alternative column; B4 adds SnpUnique.
    int(ReqOpcode.CLEAN_UNIQUE): frozenset({
        int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.UNIQUE),
    }),
    int(ReqOpcode.CLEAN_INVALID): frozenset({
        int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.UNIQUE),
    }),
    # SnpCleanShared expected, no alternative and no bullet reaching it:
    # CleanShared is the one request in this set whose snoop is forced. The
    # pairing is encoded now, ahead of the request itself -- CleanShared is not
    # yet in the RN-F's opcode set, and adding it without this row would have put
    # the home on the SnpCleanInvalid default, invalidating a line the request
    # only asked to have cleaned.
    int(ReqOpcode.CLEAN_SHARED): frozenset({int(SnpOpcode.CLEAN_SHARED)}),
    # SnpMakeInvalid expected; E lists SnpCleanInvalid as the alternative and B4
    # reaches SnpUnique in both issues.
    int(ReqOpcode.MAKE_UNIQUE): frozenset({
        int(SnpOpcode.MAKE_INVALID), int(SnpOpcode.CLEAN_INVALID),
        int(SnpOpcode.UNIQUE),
    }),
    int(ReqOpcode.MAKE_INVALID): frozenset({
        int(SnpOpcode.MAKE_INVALID), int(SnpOpcode.CLEAN_INVALID),
        int(SnpOpcode.UNIQUE),
    }),
    int(ReqOpcode.WRITE_UNIQUE_FULL): frozenset({
        int(SnpOpcode.MAKE_INVALID), int(SnpOpcode.CLEAN_INVALID),
        int(SnpOpcode.UNIQUE),
    }),
    int(ReqOpcode.WRITE_UNIQUE_ZERO): frozenset({
        int(SnpOpcode.MAKE_INVALID), int(SnpOpcode.CLEAN_INVALID),
        int(SnpOpcode.UNIQUE),
    }),
    # The one row the table states as a choice rather than an expectation:
    # "SnpCleanInvalid or SnpUnique".
    int(ReqOpcode.WRITE_UNIQUE_PTL): frozenset({
        int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.UNIQUE),
    }),
}


def snoop_permitted_for_req(req_op: int, snp_op: int) -> bool:
  """True when Table 4-5 (plus its bullets) permits `snp_op` for `req_op`.

  Requests whose Table 4-5 row is n/a in every snoop column -- the NoSnp family,
  the CopyBacks, Evict, PCrdReturn -- return False for every snoop. A snoop
  attributed to one of those is judged by req_generates_snoop() instead, so
  returning False here would double-report the same event.
  """
  return int(snp_op) in _SNOOPS_PERMITTED_FOR_REQ.get(int(req_op), frozenset())


def req_generates_snoop(req_op: int) -> bool:
  """True when Table 4-5 gives the request a snoop at all.

  Split from snoop_permitted_for_req() so a snoop correlated to a ReadNoSnp
  reports "this request is snoopless" rather than "this snoop is the wrong
  opcode", which are different defects with different causes.
  """
  return int(req_op) in _SNOOPS_PERMITTED_FOR_REQ


# The Home's CHOICE from the permitted set above, with `fwd` selecting the Direct
# Cache Transfer column. Deliberately separate from the predicate, and not
# derived from it: the driver picks and the checker judges, and a checker that
# asked the driver's function what to expect would agree with the driver by
# construction. They are cross-checked only at the point where it counts -- the
# checker applies the predicate to the opcode that actually appeared on the wire.
#
# Where the choice is free the Expected column is taken, except that
# CleanUnique/CleanInvalid/MakeReadUnique keep the SnpUnique this home has always
# sent (B4 permits it) so the change is confined to the row the spec forbids.
_SNOOP_FOR_REQ = {
    int(ReqOpcode.READ_SHARED): (int(SnpOpcode.SHARED), int(SnpOpcode.SHARED_FWD)),
    # The row this box exists for. SnpCleanFwd is the Expected forwarding snoop;
    # SnpSharedFwd -- what this home used to send for every read that was not a
    # unique read -- is permitted for ReadShared and for nothing else.
    int(ReqOpcode.READ_CLEAN): (int(SnpOpcode.CLEAN), int(SnpOpcode.CLEAN_FWD)),
    int(ReqOpcode.READ_UNIQUE): (int(SnpOpcode.UNIQUE), int(SnpOpcode.UNIQUE_FWD)),
    int(ReqOpcode.MAKE_READ_UNIQUE): (int(SnpOpcode.UNIQUE), int(SnpOpcode.UNIQUE_FWD)),
    int(ReqOpcode.READ_ONCE): (int(SnpOpcode.ONCE), int(SnpOpcode.ONCE_FWD)),
    int(ReqOpcode.CLEAN_UNIQUE): (int(SnpOpcode.UNIQUE), int(SnpOpcode.UNIQUE)),
    int(ReqOpcode.CLEAN_INVALID): (int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.CLEAN_INVALID)),
    int(ReqOpcode.CLEAN_SHARED): (int(SnpOpcode.CLEAN_SHARED), int(SnpOpcode.CLEAN_SHARED)),
    int(ReqOpcode.MAKE_UNIQUE): (int(SnpOpcode.MAKE_INVALID), int(SnpOpcode.MAKE_INVALID)),
    int(ReqOpcode.MAKE_INVALID): (int(SnpOpcode.MAKE_INVALID), int(SnpOpcode.MAKE_INVALID)),
    int(ReqOpcode.WRITE_UNIQUE_FULL): (int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.CLEAN_INVALID)),
    int(ReqOpcode.WRITE_UNIQUE_PTL): (int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.CLEAN_INVALID)),
    int(ReqOpcode.WRITE_UNIQUE_ZERO): (int(SnpOpcode.CLEAN_INVALID), int(SnpOpcode.CLEAN_INVALID)),
}


def snoop_for_req(req_op: int, fwd: bool = False) -> int:
  """The snoop this VIP's HN-F originates for `req_op`; `fwd` picks the DCT form.

  Snoopless requests per Table 4-5 return SnpOnce rather than raising: callers
  gate on req_generates_snoop(), and a caller that does not is wrong in a way a
  simulation reports instead of propagating.
  """
  pair = _SNOOP_FOR_REQ.get(int(req_op))
  if pair is None:
    return int(SnpOpcode.ONCE)
  return pair[1] if fwd else pair[0]


# Atomic REQ opcodes occupy the contiguous 0x28..0x39 range.
ATOMIC_REQ_OPCODES = tuple(range(0x28, 0x3A))


def req_opcode_is_atomic(opcode: int) -> bool:
  return 0x28 <= int(opcode) <= 0x39


def req_opcode_is_atomic_compare(opcode: int) -> bool:
  return int(opcode) == int(ReqOpcode.ATOMIC_COMPARE)


def req_opcode_is_atomic_store(opcode: int) -> bool:
  return int(ReqOpcode.ATOMIC_STORE_0) <= int(opcode) <= int(ReqOpcode.ATOMIC_STORE_7)


def req_opcode_is_atomic_returning_data(opcode: int) -> bool:
  op = int(opcode)
  return (int(ReqOpcode.ATOMIC_LOAD_0) <= op <= int(ReqOpcode.ATOMIC_LOAD_7)
          or op in (int(ReqOpcode.ATOMIC_SWAP), int(ReqOpcode.ATOMIC_COMPARE)))


def atomic_size_legal(opcode: int, size: int) -> bool:
  """TRUE when Size is one the specification permits for this atomic.

  IHI 0050 E Table 2-17 (Atomic transaction outbound and inbound data sizes, in
  section 2.10.5 -- 2.10.4 is Data packetization) is a closed list, and it is not the same list for every atomic:

    AtomicStore / AtomicLoad / AtomicSwap   1, 2, 4 or 8 byte   -> Size 0..3
    AtomicCompare                           2, 4, 8, 16 or 32   -> Size 1..5

  D Table 2-17 is the same table, with the same number, so one function serves
  both issues.

  AtomicCompare is the exception at BOTH ends and for the same reason: its Size is
  the COMBINED compare+swap size, so a 2-byte transaction carries two 1-byte
  operands. That gives it a floor no other atomic has -- Size 0 would be half a
  byte each -- and a ceiling one step higher, because 32 bytes is two 16-byte
  operands. Deriving this from the ordinary <= 8-byte limit gets the ceiling wrong
  in the direction that rejects legal traffic.

  Returns TRUE for anything that is not an atomic, so a caller can apply it
  unconditionally to a REQ opcode without first asking what kind it is.
  """
  if not req_opcode_is_atomic(opcode):
    return True
  if req_opcode_is_atomic_compare(opcode):
    return 1 <= int(size) <= 5
  return int(size) <= 3


# Order = 0b01 is applicable only in a READ request (Table 13-25). The modeled
# read opcodes, named rather than derived, so an opcode added later has to be
# classified here instead of silently inheriting the permissive answer.
_ORDER_ACCEPTED_READ_OPCODES = frozenset({
  int(ReqOpcode.READ_NO_SNP),
  int(ReqOpcode.READ_NO_SNP_SEP),
  int(ReqOpcode.READ_SHARED),
  int(ReqOpcode.READ_CLEAN),
  int(ReqOpcode.READ_UNIQUE),
  int(ReqOpcode.READ_ONCE),
})

# Table 2-12 footnote a: Order = 0b10 is permitted in ReadOnce*, WriteUnique,
# ReadNoSnp, WriteNoSnp and Atomic transactions only. Atomics and the Combined
# Write family are added by predicate below.
_ORDER_REQ_ORDER_OPCODES = frozenset({
  int(ReqOpcode.READ_ONCE),
  int(ReqOpcode.READ_NO_SNP),
  int(ReqOpcode.READ_NO_SNP_SEP),
  int(ReqOpcode.WRITE_UNIQUE_FULL),
  int(ReqOpcode.WRITE_UNIQUE_PTL),
  int(ReqOpcode.WRITE_UNIQUE_ZERO),
  int(ReqOpcode.WRITE_NO_SNP_FULL),
  int(ReqOpcode.WRITE_NO_SNP_PTL),
  int(ReqOpcode.WRITE_NO_SNP_ZERO),
})


def req_order_legal(opcode: int, order: int) -> bool:
  """TRUE when this REQ's Order value is one the spec permits for this opcode.

  TOTAL: every opcode/Order pair it does not object to is TRUE, so the rule that
  calls it evaluates on every request rather than only on the ones it can fault.
  A classifier that answers only for the cases it judges cannot tell "no such
  request went by" from "the classifier forgot this opcode".

  Two normative restrictions, both opcode-only, so neither needs the node-class
  model this VIP does not have:

    Order = 0b01 "Request accepted" (IHI 0050 E Table 13-25) is applicable only in
    a READ request from HN-F to SN-F, or HN-I to SN-I, and is "Reserved in all
    other cases". Whether a given link is Home-to-Slave is not decidable here.
    "The opcode is a read" is a necessary condition either way, so a WRITE
    carrying 0b01 is Reserved on any link, and that much is checked.

    Order = 0b10 "Request Order" (IHI 0050 E Table 2-12, footnote a) "is permitted
    in ReadOnce*, WriteUnique, ReadNoSnp, WriteNoSnp and Atomic transactions
    only". The footnote is a superscript and does not survive a text extraction of
    the table, which is why the restriction reads as absent from the table body.

  Deliberately permissive where the footnote's naming is: the families are read to
  include their variants, and the Combined Write opcodes are counted as WriteNoSnp
  because that is what their write half is. A whitelist read generously
  under-reports; read narrowly it would fail conformant traffic, which is the
  worse error for a rule that runs on every request in the sweep.

  The one POSITIVE requirement on this field is ReadNoSnpSep's. Chapter 4 gives it
  "The Order field of the request must be set to b01", and its communicating node
  pairs are exactly ICN(HN-F) to SN-F and ICN(HN-I) to SN-I -- the two cases Table
  13-25 names as applicable for that value. So on that opcode every other Order
  value is wrong, which incidentally closes the gap described above: the
  Home-to-Slave condition undecidable at a bind is implied by the opcode in the one
  place the value is mandatory.

  Order = 0b00 is legal everywhere EXCEPT ReadNoSnpSep. Order = 0b11 is NOT judged
  here: Table 2-12 admits it only on the two Device rows, so it is a constraint on
  {MemAttr, Order} together and belongs to the attribute-combination rule.
  """
  # Checked BEFORE the per-value cases: this is a requirement on the OPCODE, so it
  # has to reject every value except 0b01 rather than only the ones a per-value
  # branch happens to reach. 0b10 would otherwise slip through the Request-Order
  # whitelist, which lists ReadNoSnpSep because that value is permitted on it in
  # general -- but Chapter 4 makes 0b01 mandatory, which is stricter.
  if int(opcode) == int(ReqOpcode.READ_NO_SNP_SEP):
    return int(order) == int(ReqOrder.REQ_ACCEPTED)

  order = int(order)
  opcode = int(opcode)
  if order == int(ReqOrder.REQ_ACCEPTED):
    return opcode in _ORDER_ACCEPTED_READ_OPCODES
  if order == int(ReqOrder.REQ_ORDER):
    return (opcode in _ORDER_REQ_ORDER_OPCODES
            or req_opcode_is_atomic(opcode)
            or req_opcode_is_combined_write_cmo(opcode))
  return True


_COMBINED_WRITE_CMO_OPCODES = frozenset({
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH),
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_INV),
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_INV),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP),
})


# ---------------------------------------------------------------------------
# Completion classifiers.
#
# These live HERE rather than in the checker that first needed them, and the
# move is the point rather than tidying. "Does this REQ opcode have a completion
# this tree models" is asked by the checker, to decide whether to hold the
# request outstanding, AND by the raw-injection path in the requester driver, to
# decide how long to hold TXSACTIVE. Two copies of that answer drift the moment
# an opcode is classified, as happened once: the raw
# path's comment asserted a property of the opcode set that stopped being true
# when WriteUniqueZero joined this classifier, and nothing connected the two.
# One definition, in the layer both sides already import from.
# ---------------------------------------------------------------------------
_COHERENT_READ_OPCODES_C = frozenset({
  int(ReqOpcode.READ_SHARED), int(ReqOpcode.READ_CLEAN),
  int(ReqOpcode.READ_UNIQUE), int(ReqOpcode.MAKE_READ_UNIQUE),
  int(ReqOpcode.READ_ONCE),
})
_COHERENT_WRITE_DATA_OPCODES_C = frozenset({
  int(ReqOpcode.WRITE_BACK_FULL), int(ReqOpcode.WRITE_CLEAN_FULL),
  int(ReqOpcode.WRITE_UNIQUE_FULL), int(ReqOpcode.WRITE_UNIQUE_PTL),
  # WriteEvictOrEvict is a CopyBack whose data is CONDITIONAL: the home asks for
  # it with CompDBIDResp or declines with a bare Comp. Listing it here is still
  # right, and the conditionality takes care of itself -- the burst-length check
  # arms only when a DBID is granted, which is exactly the leg that carries data.
  int(ReqOpcode.WRITE_EVICT_OR_EVICT),
})
# MakeUnique completes on an RSP-only Comp (no data), like CleanUnique.
_COHERENT_RSP_ONLY_OPCODES_C = frozenset({
  int(ReqOpcode.EVICT), int(ReqOpcode.CLEAN_INVALID),
  int(ReqOpcode.MAKE_INVALID), int(ReqOpcode.CLEAN_UNIQUE),
  int(ReqOpcode.MAKE_UNIQUE),
})
# Non-coherent opcodes whose completion this tree models.
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


# The RSP opcodes that retire a request outright, as opposed to granting a
# buffer or acknowledging a retry.
PLAIN_COMPLETION_RSP_OPCODES_C = frozenset({
  int(RspOpcode.COMP), int(RspOpcode.COMP_DBID_RESP),
})


def req_opcode_is_coherent_read(opcode: int) -> bool:
  return int(opcode) in _COHERENT_READ_OPCODES_C


def req_opcode_is_coherent_write_data(opcode: int) -> bool:
  return int(opcode) in _COHERENT_WRITE_DATA_OPCODES_C


def req_opcode_is_coherent_rsp_only(opcode: int) -> bool:
  return int(opcode) in _COHERENT_RSP_ONLY_OPCODES_C


def req_has_modeled_completion(opcode: int) -> bool:
  op = int(opcode)
  # The combined Write + CMO family completes exactly as its plain write half
  # does, and it ships with sequences, a testcase and a completer service
  # routine -- so leaving it out stood the TxnID-reuse rules and the completion
  # timeout down for six opcodes the regression drives. The same omission the
  # WriteUniqueZero comment above records, for a family rather than for one
  # opcode. It stayed invisible because check_classifier_coverage saw the six
  # claimed by _is_write_req_opcode, a classifier that answered a question about
  # ExpCompAck and nothing about completions.
  return (op in _MODELED_COMPLETION_OPCODES_C
          or req_opcode_is_coherent_read(op)
          or req_opcode_is_coherent_write_data(op)
          or req_opcode_is_coherent_rsp_only(op)
          or req_opcode_is_combined_write_cmo(op)
          or req_opcode_is_atomic(op))


def req_completion_uses_dat(opcode: int) -> bool:
  op = int(opcode)
  return (op in (int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP))
          or req_opcode_is_coherent_read(op)
          or req_opcode_is_atomic_returning_data(op))


def is_final_rsp_completion(opcode: int, rsp_opcode: int) -> bool:
  """Does this RSP retire the request, or is it an intermediate response?"""
  if req_completion_uses_dat(opcode):
    # The completion arrives on DAT; no RSP retires such a request.
    return False
  if int(opcode) == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP):
    return int(rsp_opcode) == int(RspOpcode.COMP_PERSIST)
  return int(rsp_opcode) in PLAIN_COMPLETION_RSP_OPCODES_C



def req_opcode_combined_cmo_is_persist(opcode: int) -> bool:
  """TRUE when a combined Write + CMO carries a PERSISTENT CMO.

  The twin of vip_chi_req_opcode_combined_cmo_is_persist in the SystemVerilog
  package. It lives here rather than in the driver that first needed it because
  three places ask the question -- the completer, deciding whether to send a
  Persist at all; the sequence, defaulting ReturnNID because 2.8 routes that
  Persist by it; and the scoreboard, expecting the response -- and three copies
  of a two-opcode set is how one of them ends up disagreeing.
  """
  op = int(opcode)
  return op in (int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP),
                int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP))


def req_opcode_is_combined_write_cmo(opcode: int) -> bool:
  """A single request carrying both a write and a cache maintenance operation.

  The twin of vip_chi_req_opcode_is_combined_write_cmo in the SystemVerilog
  types package. It lives here rather than beside its callers because the six
  are writes first and anything classifying writes has to say so.
  """
  return int(opcode) in _COMBINED_WRITE_CMO_OPCODES


# The opcode half of IHI 0050 E section 13.10.25. The Combined Write family is
# added by predicate below rather than listed here, so a form added later cannot
# miss this set.
_DODWT_APPLICABLE_OPCODES = frozenset({
  int(ReqOpcode.WRITE_NO_SNP_FULL),
  int(ReqOpcode.WRITE_NO_SNP_PTL),
})


def req_dodwt_applicable(opcode: int) -> bool:
  """TRUE for the request opcodes in which DoDWT is a field at all.

  IHI 0050 E section 13.10.25: DoDWT is "Only applicable in WriteNoSnpFull,
  WriteNoSnpPtl and Combined Write requests from Home to Slave", is
  "inapplicable and must be set to zero in all other requests", and "The bit
  shares the same field as SnpAttr". This answers the opcode half of that rule;
  the Home-to-Slave half is a property of the link, so a caller that knows its
  role adds it.

  The overload is safe precisely because the two lists cannot overlap. Every
  opcode here is a WriteNoSnp form, which Table 2-14 lists as Non-snoopable only,
  and section 2.9.3 independently requires SnpAttr to be zero in any request from
  HN to SN. Where DoDWT can be one, SnpAttr must be zero.

  The twin of vip_chi_req_dodwt_applicable in the SystemVerilog types package.
  """
  return (int(opcode) in _DODWT_APPLICABLE_OPCODES or
          req_opcode_is_combined_write_cmo(opcode))


class SnpAttrReq(IntEnum):
  """Three-valued because Table 2-14 is.

  Its two columns give "Y -", "- Y" and "Y Y", and collapsing those to a boolean
  loses the difference between "must be zero" and "may be either".
  """

  ANY = 0
  ZERO = 1
  ONE = 2


# Table 2-14's "- Y" rows: Snoopable only. Every one is a coherent transaction,
# which is why modeling REQ bit 17 as DoDWT alone put the whole coherent traffic
# class on the wire marked Non-snoopable.
_SNP_ATTR_ONE_OPCODES = frozenset({
  int(ReqOpcode.READ_ONCE),
  int(ReqOpcode.READ_CLEAN),
  int(ReqOpcode.READ_SHARED),
  int(ReqOpcode.READ_UNIQUE),
  int(ReqOpcode.MAKE_READ_UNIQUE),
  int(ReqOpcode.CLEAN_UNIQUE),
  int(ReqOpcode.MAKE_UNIQUE),
  int(ReqOpcode.EVICT),
  int(ReqOpcode.WRITE_BACK_FULL),
  int(ReqOpcode.WRITE_CLEAN_FULL),
  int(ReqOpcode.WRITE_EVICT_OR_EVICT),
  int(ReqOpcode.WRITE_UNIQUE_FULL),
  int(ReqOpcode.WRITE_UNIQUE_PTL),
  int(ReqOpcode.WRITE_UNIQUE_ZERO),
})

# Table 2-14's "Y -" rows: Non-snoopable only. The Combined Write family is added
# by predicate below -- every form this VIP models is a WriteNoSnp, so it inherits
# the write half's requirement.
_SNP_ATTR_ZERO_OPCODES = frozenset({
  int(ReqOpcode.READ_NO_SNP),
  int(ReqOpcode.READ_NO_SNP_SEP),
  int(ReqOpcode.WRITE_NO_SNP_FULL),
  int(ReqOpcode.WRITE_NO_SNP_PTL),
  int(ReqOpcode.WRITE_NO_SNP_ZERO),
})


# The four stash snoops of D 12.9.33. Empty because none is modelled: the set is
# named rather than implied so that adding SnpStashUnique means adding it here
# and nowhere else.
_SNP_STASH_OPCODES_C: tuple = ()


def snp_opcode_is_forwarding(opcode: int) -> bool:
  """Whether the snoop is a Forward type, the only kind carrying Fwd* fields.

  E 13.10.5: FwdNID is "Applicable in Forward type snoops", "Inapplicable and
  must be zero in all other Snoop requests". E 13.10.16 says the same of
  FwdTxnID and adds that the same bits carry StashLPID in stash snoops and
  VMIDExt in SnpDVMOp -- neither modelled, so among the opcodes here the field
  is FwdTxnID or it is zero.

  Encoding-derived rather than listed: Chapter 12/13 give every Forward snoop
  its non-forward opcode with bit[4] set, so a Forward opcode added later is
  classified without touching this function.
  """
  return bool(int(opcode) & 0x10)


def snp_ret_to_src_must_be_zero(opcode: int) -> bool:
  """Whether RetToSrc must be zero for an opcode.

  IHI 0050 E 4.9 / D 4.9, identical text in both issues: "RetToSrc is applicable
  and must be set to zero in: Stash snoops. SnpCleanShared, SnpCleanInvalid, and
  SnpMakeInvalid, SnpOnceFwd and SnpUniqueFwd", any value in all other snoops
  except SnpDVMOp, and zero in SnpDVMOp.

  Note what that list is NOT. It is not "the invalidating snoops": SnpUnique
  invalidates and may carry ANY RetToSrc value, while SnpCleanShared and
  SnpOnceFwd do not invalidate and must carry zero. A rule written from the
  shape of the opcode rather than from 4.9 would both miss two opcodes and
  false-fail conformant SnpUnique traffic.

  4.9 carries one further rule deliberately not modelled here: "Home must only
  set RetToSrc on the Snoop request to a single Request Node." That is a
  constraint across the several snoops of one transaction, and no single
  interface sees them all.
  """
  return int(opcode) in (
    int(SnpOpcode.CLEAN_SHARED), int(SnpOpcode.CLEAN_INVALID),
    int(SnpOpcode.MAKE_INVALID), int(SnpOpcode.ONCE_FWD),
    int(SnpOpcode.UNIQUE_FWD),
  )


def snp_bit_is_do_not_data_pull(issue: int, opcode: int) -> bool:
  """Whether one SNP packet bit is DoNotDataPull rather than DoNotGoToSD.

  IHI 0050 E Table 13-8 / D Table 12-8: the two field names share a single
  one-bit row -- the same shape as REQ bit 17's SnpAttr/DoDWT overload. D
  12.9.32 and 12.9.33 state the partition from both sides: DoNotGoToSD is
  applicable in every snoop except SnpUniqueStash, SnpMakeInvalidStash,
  SnpStashShared, SnpStashUnique and SnpDVMOp, and "for Stash snoop requests the
  same bits in the packet are used for DoNotDataPull"; DoNotDataPull is
  applicable in exactly those four stash snoops and is "not present in Non-stash
  snoops". Issue E removed DoNotDataPull entirely.

  No stash snoop is modelled here -- none has an encoding in SnpOpcode -- so on
  every opcode this VIP can send or receive the bit is DoNotGoToSD, in both
  issues. Kept as a function rather than folded away so that adding a stash
  snoop cannot silently reinterpret the bit, and so the two flows say the same
  thing.
  """
  if int(issue) != int(Issue.D):
    return False
  return int(opcode) in _SNP_STASH_OPCODES_C


def comp_resp_legal(issue: int, resp: int) -> bool:
  """The Resp encodings a Comp response is permitted to carry.

  IHI 0050 E Table 4-7 / D Table 4-5, "Permitted Dataless transaction completion
  and Resp field encodings". E adds Comp_UD_PD (0b110) to the three D lists; D
  gives that encoding no meaning on a Comp at all, which is why the issue has to
  be a parameter rather than the union being checked everywhere.

  The tables are written for DATALESS completions, but the union over every use
  of the Comp opcode is the same set, so this needs no correlation with the
  request. Both issues state that "the Resp field of a Comp or CompDBIDResp
  response must be set to zero for a Write transaction completion", and that a
  DVM completion is "a Comp response, with the Resp field set to zero" -- and
  zero is Comp_I, already in the table. So a Comp whose Resp is outside the table
  is wrong whatever transaction it completes.

  The caller is responsible for the error exemption: both issues state that "in a
  response with an error indication, the cache state is permitted to be any
  value, INCLUDING RESERVED VALUES", so a Comp carrying DERR or NDERR is outside
  this rule entirely.
  """
  r = int(resp)
  if r in (int(Resp.I), int(Resp.SC), int(Resp.UC)):
    return True
  if r == int(Resp.UD_PD):
    return int(issue) == int(Issue.E)
  return False


def snp_do_not_go_to_sd_required(issue: int, opcode: int) -> bool:
  """Whether DoNotGoToSD must be set to 1 for an opcode.

  E 13.10.35 gives three lists rather than two: any value in the
  non-invalidating snoops, MUST BE ONE in the invalidating and stash forms plus
  SnpQuery, and zero in SnpDVMOp. D 12.9.32 has no must-be-one list at all --
  there the field is applicable and takes any value outside the stash and DVM
  opcodes -- so this is a place where the two issues genuinely differ rather
  than one being a clarification of the other.

  A boolean answers it because the third case is unreachable here: the
  must-be-zero opcode is SnpDVMOp, and DVM is a recorded non-goal
  (docs/FUTURE_WORK.md). Modelling DVM means giving this a three-valued answer.
  Restricted to modelled opcodes for the same reason: SnpQuery,
  SnpPreferUnique*, SnpNotSharedDirty and the stash forms have no encoding here,
  so naming them would assert a reading no traffic in this tree can confirm.
  """
  if snp_bit_is_do_not_data_pull(issue, opcode):
    return False
  if int(issue) != int(Issue.E):
    return False
  return int(opcode) in (
    int(SnpOpcode.UNIQUE), int(SnpOpcode.UNIQUE_FWD),
    int(SnpOpcode.CLEAN_SHARED), int(SnpOpcode.CLEAN_INVALID),
    int(SnpOpcode.MAKE_INVALID),
  )


def snp_attr_requirement(opcode: int) -> SnpAttrReq:
  """What SnpAttr value this opcode is permitted to carry.

  IHI 0050 E Table 2-14 / D Table 2-14, "Snoop attributes for the different
  transaction types".

  TOTAL: an opcode the table does not constrain returns ANY, so a caller may
  apply this to every request without first asking what kind it is.

  Two normative tightenings are deliberately NOT applied here. Section 2.9.6
  requires SnpAttr = 0 in a CMO, an Atomic, and ReadNoSnp/ReadNoSnpSep "from Home
  to Slave", and section 2.9.3 requires it in ANY request from HN to SN. Both are
  properties of the link rather than of the opcode, and whether a given link is
  Home-to-Slave is not decidable from a role parameter here -- the same limitation
  req_order_legal records for Order = 0b01. A rule that runs on every request must
  under-report rather than fail conformant traffic, so the opcode half is what
  this answers.

  The twin of vip_chi_snp_attr_requirement in the SystemVerilog types package.
  """
  opcode = int(opcode)
  if opcode in _SNP_ATTR_ONE_OPCODES:
    return SnpAttrReq.ONE
  if opcode in _SNP_ATTR_ZERO_OPCODES or req_opcode_is_combined_write_cmo(opcode):
    return SnpAttrReq.ZERO
  # The "Y Y" rows -- the four CMOs and the Atomics -- plus PrefetchTgt, which the
  # table marks not applicable and free to take any value, plus the credit returns
  # the table does not list at all.
  return SnpAttrReq.ANY


def req_allocate_permitted(opcode: int) -> bool:
  """FALSE where Table A-3 marks Allocate inapplicable for this opcode.

  IHI 0050 E section 2.9.3 / D section 2.9.3, under Allocate: the field "is
  inapplicable and must be set to zero in DVMOp, PCrdReturn and Evict
  transactions". Table A-3 says the same in its Allocate column -- a literal zero
  on Evict and a footnoted zero on PCrdReturn -- so two authorities agree before
  this is enforced, which is the standard the Size column was held to.

  DVMOp is not modeled by this VIP. PCrdReturn's whole MemAttr is already
  required to be zero by the PCrdReturn field rule, so the opcode that makes this
  rule non-vacuous is Evict, and on Evict nothing else can catch it: Table 2-12's
  Snoopable rows leave Allocate free, so an Evict with Allocate asserted is a
  legal tuple carrying an inapplicable field.

  Section 2.9.3's other Allocate statement -- "Must not be asserted for Normal
  Non-cacheable memory transactions" -- is NOT here. That is a property of the
  MemAttr tuple rather than of the opcode, and Table 2-12's Non-cacheable rows
  already carry it, so req_attr_combination_legal owns it.

  The twin of vip_chi_req_allocate_permitted in the SystemVerilog types package.
  """
  return int(opcode) not in (int(ReqOpcode.EVICT), int(ReqOpcode.PCRD_RETURN))


def req_mem_attr_default(opcode: int) -> int:
  """The MemAttr value this opcode must carry, where the specification fixes it.

  IHI 0050 E section 2.9.3, the assertion-requirement lists under EWA, Cacheable
  and Allocate:

    EWA       "Must be asserted in any Read or Dataless transaction that is not a
              ReadNoSnp, ReadNoSnpSep, or CMO transaction" and "in any Write
              transaction that is not a WriteNoSnp transaction".
    Cacheable "Must be asserted for any Read transaction except for ReadNoSnp and
              ReadNoSnpSep", "any Dataless transaction except for CleanShared,
              CleanSharedPersist*, CleanInvalid, MakeInvalid", and "any Write
              transaction except WriteNoSnpFull and WriteNoSnpPtl".
    Allocate  "Must be asserted for the WriteEvictFull transaction", "Is
              inapplicable and must be set to zero in DVMOp, PCrdReturn and Evict
              transactions", and otherwise only "Can be asserted".

  Where the specification leaves a field free the answer here is zero, which is
  Non-cacheable Non-bufferable -- a legal Table 2-12 row and what this VIP has
  always driven. So this changes the wire image for exactly the opcodes that were
  non-conformant: the fourteen Snoopable-only ones, and WriteNoSnpZero, whose
  Cacheable the Write rule above does not except.

  Cacheable implies EWA here rather than merely permitting it, because Table 2-12
  lists no row with Cacheable = 1 and EWA = 0.

  Returns {Allocate, Cacheable, Device, EWA} in Table 13-21 bit order. Device is
  zero throughout: this VIP models no Device-memory stimulus, and a Device request
  is a different Table 2-12 block entirely.

  The twin of vip_chi_req_mem_attr_default in the SystemVerilog types package.
  """
  opcode = int(opcode)
  cacheable = opcode in _SNP_ATTR_ONE_OPCODES or opcode == int(ReqOpcode.WRITE_NO_SNP_ZERO)
  ewa = cacheable
  # "Must be asserted for the WriteEvictFull transaction" -- one whose Allocate is
  # deasserted is convertible to an Evict, a different transaction. Evict itself is
  # on the inapplicable-and-zero list.
  allocate = opcode == int(ReqOpcode.WRITE_EVICT_OR_EVICT)
  return (int(allocate) << 3) | (int(cacheable) << 2) | int(ewa)


# Section 2.9.5's named whitelist, plus PrefetchTgt, which the section marks
# inapplicable but free to take any value.
_LIKELY_SHARED_PERMITTED = frozenset({
  int(ReqOpcode.READ_CLEAN),
  int(ReqOpcode.READ_SHARED),
  int(ReqOpcode.WRITE_UNIQUE_PTL),
  int(ReqOpcode.WRITE_UNIQUE_FULL),
  int(ReqOpcode.WRITE_UNIQUE_ZERO),
  int(ReqOpcode.WRITE_BACK_FULL),
  int(ReqOpcode.WRITE_CLEAN_FULL),
  # Named in the list in its own right, alongside WriteEvictFull.
  int(ReqOpcode.WRITE_EVICT_OR_EVICT),
  int(ReqOpcode.PREFETCH_TGT),
})


# Section 6.3's closed list of transactions that support an Exclusive access.
# "WriteNoSnp" in that list means the Full and Ptl forms only, NOT
# WriteNoSnpZero. Section 6.3 does not qualify the name, and a permissive reading
# was the first thing tried here -- but Table A-3 does qualify it: the Excl column
# gives WriteNoSnpFull and WriteNoSnpPtl "Y" and WriteNoSnpZero "0",
# applicable-and-must-be-zero. The table is the finer authority on a per-opcode
# question, and it makes sense: an Exclusive store has to write the data it was
# granted exclusivity for, and WriteNoSnpZero carries none.
_EXCL_PERMITTED_OPCODES = frozenset({
  int(ReqOpcode.READ_CLEAN), int(ReqOpcode.READ_SHARED),
  int(ReqOpcode.CLEAN_UNIQUE), int(ReqOpcode.MAKE_READ_UNIQUE),
  int(ReqOpcode.READ_NO_SNP),
  int(ReqOpcode.WRITE_NO_SNP_FULL), int(ReqOpcode.WRITE_NO_SNP_PTL),
})


def dat_cbusy_applicable(opcode: int) -> bool:
  """Whether CBusy is applicable to a DAT opcode.

  From Table A-5 "Data message field mappings", parsed out of the PDF with the
  bbox method in docs/review_claude/TABLE_A3_PARSE.md and checked in as
  docs/review_claude/table_a5_parsed.json. The table gives CBusy "0" on
  CopyBackWrData, NonCopyBackWrData, NCBWrDataCompAck and WriteDataCancel, and
  "Y" on CompData, DataSepResp and the SnpRespData forms.

  The table was necessary here in a way it was not for HomeNID: 13.10.47 defines
  CBusy as a completer activity indicator with IMPLEMENTATION DEFINED encodings
  and states no per-opcode rule at all. It makes sense in hindsight -- write data
  flows requester to completer, and a requester has no completer-busy level to
  report -- but that is an argument, and the table is an authority.

  WriteDataCancel has no encoding here, so among modelled opcodes the set is the
  three write-data forms.
  """
  return int(opcode) not in (int(DatOpcode.COPY_BACK_WR_DATA),
                             int(DatOpcode.NON_COPY_BACK_WR_DATA),
                             int(DatOpcode.NCB_WR_DATA_COMP_ACK))


def dat_home_nid_applicable(opcode: int) -> bool:
  """Whether HomeNID is applicable to a DAT opcode.

  IHI 0050 E 13.10.3: "Applicable in CompData and DataSepResp from the Slave and
  Home. Inapplicable and must be zero in all other Data messages."

  Read from the field definition rather than from Table A-5, deliberately: that
  table's headers are rotated, and a plain text dump lists them in an order that
  is NOT the column order, so mapping a cell to HomeNID needs the bbox parse. The
  prose says the same thing without that risk.

  "From the Slave and Home" is the sender, not a further condition on the opcode:
  only a completer sends either message. The rule is opcode-keyed and does not
  attempt to establish the peer's node class.
  """
  return int(opcode) in (int(DatOpcode.COMP_DATA), int(DatOpcode.DATA_SEP_RESP))


def req_return_txn_id_applicable(opcode: int) -> bool:
  """Whether ReturnTxnID is applicable to a request opcode.

  IHI 0050 E 13.10.15: "Applicable only in ReadNoSnp, ReadNoSnpSep, WriteNoSnp,
  Combined Write, and Atomic requests from Home to Slave. Inapplicable and must
  be set to zero for all other requests."

  See req_return_nid_applicable for why the two sets differ, why the
  Home-to-Slave half is not modelled, and why WriteNoSnpZero is treated as
  applicable.
  """
  op = int(opcode)
  if op in (int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.READ_NO_SNP_SEP),
            int(ReqOpcode.WRITE_NO_SNP_FULL), int(ReqOpcode.WRITE_NO_SNP_PTL),
            int(ReqOpcode.WRITE_NO_SNP_ZERO),
            int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_INV),
            int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH),
            int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP),
            int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_INV),
            int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH),
            int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP)):
    return True
  return req_opcode_is_atomic(op)


def req_return_nid_applicable(opcode: int) -> bool:
  """Whether ReturnNID is applicable to a request opcode.

  IHI 0050 E 13.10.4: "Applicable from Home to Slave in ReadNoSnp,
  ReadNoSnpSep, CleanSharedPersistSep, WriteNoSnp, Combined Write, and Atomic
  requests. Inapplicable and must be zero for all other requests."

  The two sets are NOT the same, and collapsing them is what would make this
  rule false-fail: CleanSharedPersistSep is here and not in ReturnTxnID's list.
  That follows from what each field is for -- ReturnNID names the node a
  CompData, DataSepResp or PERSIST is sent to, ReturnTxnID names the TxnID of a
  CompData or DataSepResp only, and a separated persist gets an RSP.

  Table A-3 cannot settle this: it has no ReturnNID column. These bits appear
  there as StashNID, marked "-" on every non-stash opcode -- assigned to another
  field that shares the same bits -- so the must-be-zero obligation is in the
  prose and the table alone understates it.

  The "from Home to Slave" half is deliberately not modelled: no bind can
  establish that its peer is a Home, and this VIP drives ReadNoSnp from an RN-I, so enforcing the node pair would fire for a
  reason belonging to a different fix.

  WriteNoSnpZero is treated as APPLICABLE, which is a judgement rather than a
  reading: "WriteNoSnp" is generic in both definitions, and a Zero write's
  completion is an RSP rather than CompData, so a strict reading might exclude
  it. Where the wording is genuinely ambiguous this errs toward applicable,
  because a permissive rule cannot false-fail conformant traffic and a strict
  one can -- which has already happened twice in this checker.
  """
  if int(opcode) == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP):
    return True
  return req_return_txn_id_applicable(opcode)


def req_pgroup_id_applicable(opcode: int) -> bool:
  """Whether REQ's 8-bit group field carries PGroupID for this opcode.

  IHI 0050 E 13.10.7: "Applicable in the CleanSharedPersistSep request and the
  Persist and CompPersist responses. Inapplicable and must be set to zero in all
  other requests and responses."

  Section 2.5 says more, and this follows section 2.5: "Use of this 8-bit field
  is applicable in CleanSharedPersistSep and Combined Write with PCMO
  transactions", and again as an obligation -- "PGroupID must be sent in the
  CleanSharedPersistSep request and a Combined Write request that includes a
  PCMO." 13.10.7's field summary omits the Combined Write; 2.5 states it twice,
  once as a requirement. The two are read together and the wider set wins, which
  is also the direction this VIP errs in on every other ambiguous applicability
  question: a permissive rule cannot false-fail conformant traffic.

  The twin of vip_chi_req_pgroup_id_applicable in the SystemVerilog types
  package.
  """
  op = int(opcode)
  if op == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP):
    return True
  return req_opcode_combined_cmo_is_persist(op)


def rsp_pgroup_id_applicable(rsp_opcode: int) -> bool:
  """Whether RSP's DBID field carries PGroupID for this response opcode.

  IHI 0050 E Table 13-7 gives that 12-bit position three meanings --
  "DBID[11:0] / {4'b0, PGroupID[7:0]} / {4'b0, StashGroupID[7:0]}" -- and
  13.10.7 names the two responses where the middle one applies.

  The twin of vip_chi_rsp_pgroup_id_applicable in the SystemVerilog types
  package.
  """
  return int(rsp_opcode) in (int(RspOpcode.PERSIST), int(RspOpcode.COMP_PERSIST))


def pgroup_id_from_req(group_id_ext: int, lp_id: int) -> int:
  """PGroupID as the request carries it: 13.10.8's equation, literally.

  IHI 0050 E 13.10.8, on Persistent CMO transactions: "used to extend the
  persistent group ID size to 8 bits; PGroupID[7:0] = {GroupIDExt[2:0],
  LPID[4:0]}."

  So PGroupID is not a field of its own anywhere. On REQ it is a VIEW of the
  8-bit position Table 13-6 shares between {GroupIDExt, LPID}, PGroupID,
  StashGroupID and TagGroupID; on RSP it is a view of DBID. Adding a physical
  PGroupID to either layout would make this VIP's flits wider than the
  specification's -- and because both ports would have been widened together,
  no parity check could have seen it. That was once proposed, on
  App A's field lists; Table 13-6 and Table 13-7 say otherwise.

  LPID's low five bits, not all of it: the equation names LPID[4:0] and this VIP
  models LPID as 8 bits wide under Issue E. Taking the masked slice is right on
  either reading of that width, which is why it is written as the spec writes it
  rather than as whatever the local field happens to be.

  The twin of vip_chi_pgroup_id_from_req in the SystemVerilog types package.
  """
  return ((int(group_id_ext) & 0x7) << 5) | (int(lp_id) & 0x1F)


def rsp_opcode_is_write_grant(opcode: int) -> bool:
  """The three responses that carry a write's DBID grant.

  CompDBIDResp is included because it IS a DBIDResp with the Comp folded into
  it: IHI 0050 E Table 2-8's footnote permits the combination only "if both are
  targeting the Home", which is a statement about when the two responses may
  share a flit, not about the grant ceasing to be a grant when they do. Any
  rule about where a grant is addressed applies to all three encodings.

  DBIDRespOrd is the ordered variant and differs only in the ordering guarantee
  it adds, so it grants exactly as DBIDResp does.

  The twin of vip_chi_rsp_opcode_is_write_grant in the SystemVerilog types
  package.
  """
  return int(opcode) in (int(RspOpcode.DBID_RESP), int(RspOpcode.DBID_RESP_ORD),
                         int(RspOpcode.COMP_DBID_RESP))


def req_dwt_grant_uses_return_path(issue: int, opcode: int, bit17: int) -> bool:
  """Whether a write's DBIDResp is routed by ReturnNID/ReturnTxnID, not SrcID.

  IHI 0050 E Table 2-8, "Message field mapping in WriteNoSnpCMO from Home to
  Slave and its responses", is the whole rule in three rows:

      DoDWT  CMO type                    DBIDResp          Persist
        1    All                         HN.Req.ReturnNID  HN.Req.ReturnNID
        0    CleanShared / CleanInvalid  HN.Req.SrcID      -
        0    Persistent                  HN.Req.SrcID      HN.Req.ReturnNID

  So DoDWT alone selects the DBIDResp's target, and it selects nothing else:
  the Persist column does not depend on it, which is why that limb is
  req_opcode_combined_cmo_is_persist's job and not this one. Section 4.2.4 says
  the same in prose -- "The Persist response [...] always uses the ReturnNID
  value of the Request [...] irrespective of the DoDWT field value."

  The TxnID travels with the target. Section 2.5: "When DoDWT = 1, ReturnTxnID
  value is expected to be the original Requester TxnID [...] Used as the TxnID
  in the DBIDResp response." A DBIDResp is the one response in this VIP that
  changes BOTH of its addressing fields on a single request bit, which is why
  the requester cannot keep matching it on TxnID alone.

  Keyed on the bit, not only on the opcode, because DoDWT is a per-request
  choice: the same WriteNoSnpFull is answered at SrcID or at ReturnNID
  depending on it. The opcode still appears here because con_dodwt_overload
  pins DoDWT to zero wherever 13.10.25 makes it inapplicable, so the two agree
  by construction -- and asserting that agreement here would be circular, so
  this reads the bit and lets the constraint own the applicability.

  Takes the RAW bit 17 and the issue rather than a "dodwt" argument, because
  there is no dodwt field to pass: REQ bit 17 is carried as "snpattr" in the
  flit map and is DoDWT only where req_bit17_is_dodwt says so.
  A caller handed a decoded bit would have to do that decode itself, and a
  caller that read a "dodwt" key off a sampled flit would get a KeyError at
  best and a silent zero at worst -- which is the whole shape of the defect
  this VIP already carries once.

  Table 2-8 is headed with the Combined Write, but section 2.5 states the same
  DBIDResp rule for a plain "WriteNoSnp with TagOp not Match", and 13.10.25
  makes DoDWT applicable in WriteNoSnpFull and WriteNoSnpPtl as well as in the
  Combined forms. The rule is DWT's, not the CMO's.

  The twin of vip_chi_req_dwt_grant_uses_return_path in the SystemVerilog types
  package.
  """
  return bool(int(bit17)) and req_bit17_is_dodwt(int(issue), int(opcode))


def req_tagop_permitted_mask(issue: int, opcode: int) -> int:
  """Which TagOp encodings an opcode may carry, as a 4-bit mask.

  Bit 0 = Invalid (0b00), bit 1 = Transfer (0b01), bit 2 = Update (0b10),
  bit 3 = 0b11.

  From IHI 0050 E Table 12-2, "Permitted TagOp values for each request type",
  read out of the PDF -- the markdown conversion drops the table entirely,
  leaving five separate cross-references to a table that is not there.

  The table has FIVE columns for a TWO-bit field: Invalid, Transfer, Update,
  Match and Fetch. Match and Fetch are one encoding (Table 13-34 gives 0b11 as
  "Match Fetch"), so bit 3 is permitted when EITHER column says Yes -- and the
  two are not interchangeable in the table: ReadUnique has Fetch Yes and Match
  No, WriteNoSnpFull has Match Yes and Fetch No. Collapsing them onto one bit is
  what the field encoding forces, and it is why this returns a mask.

  CleanUnique has NO ROW in Table 12-2 and ReqLCrdReturn's TagOp is a Don't Care
  by the note under it, so both are returned unjudged rather than guessed. Under
  Issue D there is no memory tagging and the item's issue-gated constraint
  already holds the field at zero, so the rule stands down.
  """
  if int(issue) != int(Issue.E):
    return 0b1111
  op = int(opcode)
  if op in (int(ReqOpcode.READ_ONCE), int(ReqOpcode.READ_CLEAN),
            int(ReqOpcode.READ_SHARED), int(ReqOpcode.MAKE_READ_UNIQUE),
            int(ReqOpcode.WRITE_EVICT_OR_EVICT), int(ReqOpcode.PREFETCH_TGT)):
    return 0b0011
  if op in (int(ReqOpcode.READ_UNIQUE), int(ReqOpcode.READ_NO_SNP),
            int(ReqOpcode.READ_NO_SNP_SEP)):
    return 0b1011
  if op in (int(ReqOpcode.CLEAN_SHARED), int(ReqOpcode.CLEAN_SHARED_PERSIST),
            int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP),
            int(ReqOpcode.CLEAN_INVALID), int(ReqOpcode.MAKE_INVALID),
            int(ReqOpcode.EVICT), int(ReqOpcode.WRITE_NO_SNP_ZERO),
            int(ReqOpcode.WRITE_UNIQUE_ZERO), int(ReqOpcode.PCRD_RETURN)):
    return 0b0001
  if op in (int(ReqOpcode.MAKE_UNIQUE),
            int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_INV),
            int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH),
            int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP)):
    return 0b0101
  if op == int(ReqOpcode.WRITE_NO_SNP_FULL):
    return 0b1111
  if op in (int(ReqOpcode.WRITE_UNIQUE_FULL), int(ReqOpcode.WRITE_NO_SNP_PTL),
            int(ReqOpcode.WRITE_UNIQUE_PTL)):
    return 0b1101
  if op in (int(ReqOpcode.WRITE_BACK_FULL), int(ReqOpcode.WRITE_CLEAN_FULL),
            int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_INV),
            int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH),
            int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP)):
    return 0b0111
  # Atomics: Invalid, Match. Section 12.4.1 says the same in prose.
  if req_opcode_is_atomic(op):
    return 0b1001
  return 0b1111


def req_endian_applicable(opcode: int) -> bool:
  """TRUE when Endian is a field this opcode carries at all.

  IHI 0050 E Table A-3, Endian column: "Y" on the four Atomic opcodes, "X" --
  inapplicable, any value -- on PrefetchTgt, and "0" on every other request this
  VIP models. Endian selects the byte order of an Atomic's operand, so it has
  nothing to say about a plain read or write, and the table says so by requiring
  zero rather than by leaving it free.

  PrefetchTgt is permitted here rather than faulted, for the reason the
  LikelyShared rule gives: "X" means any value, so asserting it is not a
  violation.

  TOTAL: returns True for everything it does not object to.

  The twin of vip_chi_req_endian_applicable in the SystemVerilog types package.
  """
  return req_opcode_is_atomic(opcode) or int(opcode) == int(ReqOpcode.PREFETCH_TGT)


def req_excl_permitted(opcode: int) -> bool:
  """TRUE when this opcode supports an Exclusive access, so may assert Excl.

  IHI 0050 E section 6.3 "Exclusive transactions" opens with "The following
  transaction types support Exclusive accesses through an Excl bit" and then names
  them, which makes it a closed list: ReadClean, ReadNotSharedDirty, ReadShared,
  ReadPreferUnique (Snoopable load); CleanUnique, MakeReadUnique (Snoopable
  store); ReadNoSnp (Non-snoopable load); WriteNoSnp (Non-snoopable store).

  A consolidated list is why this is a rule at all: Chapter 4 states the same
  permission per opcode across forty request descriptions as "Can have exclusive
  attribute asserted", and a whitelist assembled from those would be a
  transcription exercise with no way to tell a missed bullet from an opcode that
  genuinely forbids it.

  TOTAL: returns True for everything it does not object to.

  The twin of vip_chi_req_excl_permitted in the SystemVerilog types package.
  """
  return int(opcode) in _EXCL_PERMITTED_OPCODES


# Table 2-15: Size 0b110 is 64 bytes, a cache line.
REQ_SIZE_64B = 0b110

# Table A-3's Size column, the opcodes it gives a literal "64B". The Combined
# Write family SPLITS: Full forms are fixed, Ptl forms are free.
_SIZE_FIXED_64B_OPCODES = frozenset({
  int(ReqOpcode.READ_SHARED), int(ReqOpcode.READ_CLEAN),
  int(ReqOpcode.READ_ONCE), int(ReqOpcode.READ_UNIQUE),
  int(ReqOpcode.MAKE_READ_UNIQUE),
  int(ReqOpcode.CLEAN_SHARED), int(ReqOpcode.CLEAN_SHARED_PERSIST),
  int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP), int(ReqOpcode.CLEAN_INVALID),
  int(ReqOpcode.MAKE_INVALID), int(ReqOpcode.CLEAN_UNIQUE),
  int(ReqOpcode.MAKE_UNIQUE), int(ReqOpcode.EVICT),
  int(ReqOpcode.WRITE_BACK_FULL), int(ReqOpcode.WRITE_CLEAN_FULL),
  int(ReqOpcode.WRITE_EVICT_OR_EVICT), int(ReqOpcode.WRITE_UNIQUE_FULL),
  int(ReqOpcode.WRITE_UNIQUE_ZERO), int(ReqOpcode.WRITE_NO_SNP_FULL),
  int(ReqOpcode.WRITE_NO_SNP_ZERO),
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH),
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_INV),
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP),
})


def req_size_fixed_64b(opcode: int) -> bool:
  """TRUE when Table A-3 fixes this opcode's Size at 64 bytes.

  IHI 0050 E Table A-3 "Request message field mappings part 2" (read from the
  PDF, physical page 468) gives a literal "64B" in the Size column for these
  opcodes and a plain "Y" -- any legal value -- for the rest. Chapter 4 says the
  same thing per opcode in prose: "Data size is a cache line length" for the
  fixed ones against "Data size is up to a cache line length" for the others.

  The Combined Write family SPLITS here and must not be treated as one class:
  Table A-3 gives WriteNoSnpFull(CMO) 64B and WriteNoSnpPtl(CMO) any. That
  follows the write half, the same rule Table 2-14 and the CompAck table use for
  this family.

  Size = 0b110 is 64 bytes (Table 2-15), independent of the data bus width: a
  64-byte transfer is four beats on a 16-byte bus.

  The twin of vip_chi_req_size_fixed_64b in the SystemVerilog types package.
  """
  return int(opcode) in _SIZE_FIXED_64B_OPCODES


def req_likely_shared_permitted(opcode: int) -> bool:
  """TRUE when this opcode is permitted to assert LikelyShared.

  IHI 0050 E section 2.9.5. The section gives a named whitelist and then closes
  it twice over: "Must not be asserted in any other Read, Write or Combined Write
  transaction" and "Must not be asserted in any Dataless or Atomic transaction".
  DVMOp and PCrdReturn are inapplicable-and-must-be-zero; PrefetchTgt is
  inapplicable but may carry any value, so it is permitted here rather than
  faulted.

  This is STRICTLY NARROWER than what Table 2-12 implies, which is why it earns
  its own rule. The table shows LikelyShared as 0/1 only on its two Snoopable
  rows, so req_attr_combination_legal faults it on any Non-snoopable request --
  but section 2.9.5 also forbids it on ReadOnce, ReadUnique, MakeReadUnique,
  CleanUnique, MakeUnique and Evict, every one of which is Snoopable only and
  therefore passes the tuple rule. A hint meaning "this line is likely shared" is
  only meaningful where the transaction leaves a shareable copy behind, and those
  six do not.

  TOTAL: returns True for everything it does not object to.

  The twin of vip_chi_req_likely_shared_permitted in the SystemVerilog types
  package.
  """
  return int(opcode) in _LIKELY_SHARED_PERMITTED


def req_attr_combination_legal(mem_attr: int, snp_attr: int,
                               likely_shared: int, order: int) -> bool:
  """TRUE when this request's {MemAttr, SnpAttr, LikelyShared, Order} tuple is one
  of the nine Table 2-12 permits.

  IHI 0050 E Table 2-12 / D Table 2-12, "Legal combinations of MemAttr, SnpAttr,
  and Order field values". The table lists nine rows and closes each of its two
  blocks with "All other values -- Not valid", so it is a whitelist and every
  tuple outside it is a protocol error, not merely unusual.

  MemAttr bit positions are Table 13-21's: [3] Allocate, [2] Cacheable,
  [1] Device (0 Normal, 1 Device), [0] EWA.

  This judges the tuple only. The per-opcode restrictions that also bear on these
  fields live elsewhere on purpose: Order's opcode whitelist is req_order_legal,
  and section 2.9.5 additionally restricts LikelyShared to a named list of
  opcodes, which is narrower than the "must be Snoopable" this table implies.
  Splitting them keeps each rule's report naming one reason rather than several.

  The twin of vip_chi_req_attr_combination_legal in the SystemVerilog types
  package.
  """
  mem_attr = int(mem_attr)
  allocate = bool(mem_attr & 0x8)
  cacheable = bool(mem_attr & 0x4)
  device = bool(mem_attr & 0x2)
  ewa = bool(mem_attr & 0x1)
  snoopable = int(snp_attr) == int(SnpAttr.SNOOPABLE)
  order = int(order)

  # Every row but the two Endpoint-Order Device ones carries Order[0] = 0, which
  # leaves 0b00 and 0b10.
  #
  # 0b01 appears in no row, and footnote b says why: "Order = 0b01 is not used for
  # transactions' ordering". It is a Request-accepted signal rather than an
  # ordering requirement, so this table has nothing to say about it and such a
  # request is judged on its MemAttr alone. Faulting it here would fail conformant
  # traffic: ReadNoSnpSep is REQUIRED to carry 0b01 (Chapter 4, "The Order field of
  # the request must be set to b01"), and whether a given opcode may carry it is
  # req_order_legal's business, not this rule's.
  unordered_or_req_order = order in (int(ReqOrder.NONE), int(ReqOrder.REQ_ORDER),
                                     int(ReqOrder.REQ_ACCEPTED))

  if device:
    # The three Device rows are Allocate = 0, Cacheable = 0, SnpAttr = 0 and
    # LikelyShared = 0 without exception.
    if allocate or cacheable or snoopable or int(likely_shared):
      return False
    # Device nRnE is the only row with EWA = 0, and it is Endpoint Order.
    # 0b01 stands down here too, for the footnote-b reason above.
    if not ewa:
      return order in (int(ReqOrder.ENDPOINT), int(ReqOrder.REQ_ACCEPTED))
    # EWA = 1 covers both Device nRE (Endpoint Order) and Device RE.
    return order == int(ReqOrder.ENDPOINT) or unordered_or_req_order

  # Normal memory. No row here takes Endpoint Order.
  if not unordered_or_req_order:
    return False
  # LikelyShared is 0/1 only on the two Snoopable rows.
  if int(likely_shared) and not snoopable:
    return False
  if snoopable:
    # Snoopable WriteBack, No-allocate or Allocate: both require Cacheable and
    # EWA. This is the pairing that makes SnpAttr = 1 over a zero MemAttr illegal
    # rather than merely odd.
    return cacheable and ewa
  if not cacheable:
    # Non-cacheable Non-bufferable and Non-cacheable Bufferable, differing only
    # in EWA. Neither allocates -- section 2.9.3, "Must not be asserted for
    # Normal Non-cacheable memory transactions".
    return not allocate
  # Non-snoopable WriteBack, No-allocate or Allocate: Cacheable implies EWA.
  return ewa


def req_bit17_is_dodwt(issue: int, opcode: int) -> bool:
  """TRUE when REQ bit 17 carries DoDWT rather than SnpAttr on this link.

  The opcode test alone is not sufficient: DoDWT was introduced in Issue E and
  appears nowhere in Issue D, whose Table 12-6 names that bit SnpAttr and nothing
  else. So under CHI-D the bit is SnpAttr for EVERY opcode, including the
  WriteNoSnp forms. A packer or monitor that consults the opcode alone
  reintroduces, for those opcodes, exactly the field-identity error this pair of
  functions exists to remove.

  The twin of vip_chi_req_bit17_is_dodwt in the SystemVerilog types package.
  """
  return int(issue) == int(Issue.E) and req_dodwt_applicable(opcode)


class CompAckReq(IntEnum):
  """Three-valued because Table 2-9 is.

  "Yes", "Optional" and "No" are three different obligations, and collapsing
  them to a boolean is what produced a legality constraint that forced the bit
  to zero on the rows marked "Yes".
  """

  PROHIBITED = 0
  OPTIONAL = 1
  REQUIRED = 2


# Optional for BOTH columns of the table: the two read forms an RN-F may decline
# to acknowledge, and the two writes that use CompAck only when they want
# Ordered Write Observation.
# ReadNoSnpSep is deliberately NOT here. Chapter 4 gives it "Must not assert
# ExpCompAck in the Request" and Table A-3's ExpCompAck column agrees with a "0".
# Classifying it Optional -- as this set did -- permitted the bit on an opcode the
# specification forbids it on, and left CHI_EXPCOMPACK_PROHIBITED_BUT_SET blind to
# the violation, because the classifier did not call it one.
_COMPACK_OPTIONAL_OPCODES = frozenset({
  int(ReqOpcode.READ_NO_SNP),
  int(ReqOpcode.READ_ONCE),
  int(ReqOpcode.WRITE_UNIQUE_FULL),
  int(ReqOpcode.WRITE_UNIQUE_PTL),
  int(ReqOpcode.WRITE_NO_SNP_FULL),
  int(ReqOpcode.WRITE_NO_SNP_PTL),
}) | _COMBINED_WRITE_CMO_OPCODES

# The "Yes" rows. All of them are RN-F only.
_COMPACK_REQUIRED_RNF_OPCODES = frozenset({
  int(ReqOpcode.READ_CLEAN),
  int(ReqOpcode.READ_SHARED),
  int(ReqOpcode.READ_UNIQUE),
  int(ReqOpcode.MAKE_READ_UNIQUE),
  int(ReqOpcode.CLEAN_UNIQUE),
  int(ReqOpcode.MAKE_UNIQUE),
  int(ReqOpcode.WRITE_EVICT_OR_EVICT),
})


def exp_comp_ack_requirement(req_op: int, requester_is_rnf: bool) -> int:
  """Whether `req_op` must, may, or must not carry ExpCompAck.

  IHI 0050 E Table 2-9 / D Table 2-8, "Requester CompAck requirement", and the
  prose beside it. The table has two columns, RN-F and RN-D/RN-I, and they do
  not agree: every coherent read is "Yes" for an RN-F and "-" for an RN-I
  (which cannot issue one at all), while ReadNoSnp is "Optional" for both. That
  is why the requester role is an argument here rather than being read off the
  opcode -- the opcode alone does not determine the answer.

  Note which way the asymmetry runs. CleanUnique and MakeUnique are Dataless
  requests, and Dataless is exactly the class an RN-I "must not" acknowledge --
  yet both are "Yes" in the RN-F column. They are not CMOs (CleanShared,
  CleanInvalid, MakeInvalid and the Persist forms are), so the RN-F "must not"
  bullet does not reach them either. An implementation that classified by
  request CLASS rather than by opcode would get both of them wrong, in opposite
  directions depending on which bullet it reached for.

  The twin of vip_chi_exp_comp_ack_requirement in the SystemVerilog types
  package. PROHIBITED is the default for the same reason it is there: it is the
  only answer that cannot put an illegal flit on the wire for an opcode nobody
  has classified yet. ReadNotSharedDirty and ReadPreferUnique are "Yes" rows
  this VIP does not yet model, and each would be silently wrong under it.
  """
  op = int(req_op)
  if op in _COMPACK_OPTIONAL_OPCODES:
    return int(CompAckReq.OPTIONAL)
  if requester_is_rnf and op in _COMPACK_REQUIRED_RNF_OPCODES:
    return int(CompAckReq.REQUIRED)
  return int(CompAckReq.PROHIBITED)


def exp_comp_ack_required(req_op: int, requester_is_rnf: bool) -> bool:
  return exp_comp_ack_requirement(req_op, requester_is_rnf) == int(CompAckReq.REQUIRED)


def exp_comp_ack_prohibited(req_op: int, requester_is_rnf: bool) -> bool:
  return exp_comp_ack_requirement(req_op, requester_is_rnf) == int(CompAckReq.PROHIBITED)


def req_opcode_atomic_variant(opcode: int) -> int:
  """The arithmetic variant [0:7] encoded by AtomicStore/Load; -1 otherwise."""
  op = int(opcode)
  if int(ReqOpcode.ATOMIC_STORE_0) <= op <= int(ReqOpcode.ATOMIC_STORE_7):
    return op - int(ReqOpcode.ATOMIC_STORE_0)
  if int(ReqOpcode.ATOMIC_LOAD_0) <= op <= int(ReqOpcode.ATOMIC_LOAD_7):
    return op - int(ReqOpcode.ATOMIC_LOAD_0)
  return -1


# AtomicOp (sequence-facing) -> ReqOpcode.
_ATOMIC_OP_TO_REQ = {
  **{int(AtomicOp.STORE_0) + i: int(ReqOpcode.ATOMIC_STORE_0) + i for i in range(8)},
  **{int(AtomicOp.LOAD_0) + i: int(ReqOpcode.ATOMIC_LOAD_0) + i for i in range(8)},
  int(AtomicOp.SWAP): int(ReqOpcode.ATOMIC_SWAP),
  int(AtomicOp.COMPARE): int(ReqOpcode.ATOMIC_COMPARE),
}


def atomic_op_to_req_opcode(op: int) -> int:
  return _ATOMIC_OP_TO_REQ[int(op)]


# ---------------------------------------------------------------------------
# Flit codec: MSB-first (field, width) layouts + pack / unpack.
# ---------------------------------------------------------------------------

_CHANNELS = ("req", "rsp", "dat", "snp")


def flit_layout(cfg: ChiCfg, channel: str):
  """Return the ordered [(field_name, width)] list, MSB first, for one channel.

  Mirrors vip_chi_types_d / vip_chi_types_e exactly (CHI-D omits the E-only
  tagop / groupidext / tag / tu fields)."""
  e = cfg.is_e
  n = cfg.node_id_width
  a = cfg.addr_width
  db = cfg.data_bytes
  txn = cfg.txn_id_width

  if channel == "req":
    lay = [("mpam", cfg.mpam_field_width), ("tracetag", 1)]
    if e:
      lay.append(("tagop", TAGOP_WIDTH))
    lay += [("expcompack", 1), ("excl", 1)]
    if e:
      lay.append(("groupidext", GROUP_ID_EXT_WIDTH))
    lay += [
      # Table 13-6 / 12-6 stack SnpAttr over DoDWT on this bit, and SnpAttr is
      # the name both issues have. See SnpAttr.
      ("lpid", cfg.lpid_width), ("snpattr", 1), ("memattr", MEMATTR_WIDTH),
      ("pcrdtype", PCRD_TYPE_WIDTH), ("order", ORDER_WIDTH), ("allowretry", 1),
      ("likelyshared", 1), ("ns", 1), ("addr", a), ("size", SIZE_WIDTH),
      ("opcode", cfg.req_opcode_width), ("returntxnid", txn), ("endian", 1),
      ("returnnid", n), ("txnid", txn), ("srcid", n), ("tgtid", n),
      ("qos", QOS_WIDTH),
    ]
    return lay

  if channel == "rsp":
    lay = [("tracetag", 1)]
    if e:
      lay.append(("tagop", TAGOP_WIDTH))
    lay += [
      ("pcrdtype", PCRD_TYPE_WIDTH), ("dbid", txn), ("cbusy", CBUSY_WIDTH),
      ("fwdstate", FWDSTATE_WIDTH), ("resp", RESP_WIDTH), ("resperr", RESP_ERR_WIDTH),
      ("opcode", cfg.rsp_opcode_width), ("txnid", txn), ("srcid", n), ("tgtid", n),
      ("qos", QOS_WIDTH),
    ]
    return lay

  if channel == "dat":
    lay = [
      ("poison", cfg.poison_width), ("datacheck", cfg.datacheck_width),
      ("data", 8 * db), ("be", cfg.be_width), ("tracetag", 1),
    ]
    if e:
      lay += [("tu", cfg.tu_width), ("tag", cfg.tag_width), ("tagop", TAGOP_WIDTH)]
    lay += [
      ("dataid", cfg.data_id_width), ("ccid", cfg.data_id_width), ("dbid", txn),
      ("cbusy", CBUSY_WIDTH), ("datasource", DATASOURCE_WIDTH), ("resp", RESP_WIDTH),
      ("resperr", RESP_ERR_WIDTH), ("opcode", cfg.dat_opcode_width), ("homenid", n),
      ("txnid", txn), ("srcid", n), ("tgtid", n), ("qos", QOS_WIDTH),
    ]
    return lay

  if channel == "snp":
    return [
      ("mpam", cfg.mpam_field_width),
      ("tracetag", 1), ("rettosrc", 1), ("donotgotosd", 1),
      ("ns", 1), ("addr", a), ("opcode", cfg.snp_opcode_width),
      ("fwdtxnid", txn), ("fwdnid", n), ("txnid", txn), ("srcid", n),
      ("qos", QOS_WIDTH),
    ]

  raise ValueError(f"unknown channel {channel!r} (want one of {_CHANNELS})")


def flit_width(cfg: ChiCfg, channel: str) -> int:
  return sum(w for _, w in flit_layout(cfg, channel))


def pack(cfg: ChiCfg, channel: str, fields: dict) -> int:
  """Pack a {field: value} dict into the flit integer (MSB-first). Missing
  fields default to 0; each value is truncated to its field width."""
  val = 0
  for name, w in flit_layout(cfg, channel):
    val = (val << w) | (int(fields.get(name, 0)) & mask(w))
  return val


def unpack(cfg: ChiCfg, channel: str, value: int) -> dict:
  """Inverse of pack(): slice the flit integer back into a {field: value} dict."""
  layout = flit_layout(cfg, channel)
  pos = sum(w for _, w in layout)
  out = {}
  for name, w in layout:
    pos -= w
    out[name] = (int(value) >> pos) & mask(w)
  return out


# ---------------------------------------------------------------------------
# Self-test (run this module directly: python3 vip_chi_types_pkg.py).
# ---------------------------------------------------------------------------


def _selftest() -> None:
  import random

  rng = random.Random(1)
  cfgs = [
    ChiCfg(Issue.D, node_id_width=7, addr_width=44, data_bytes=32),
    ChiCfg(Issue.E, node_id_width=11, addr_width=48, data_bytes=64),
    ChiCfg(Issue.D, node_id_width=3, addr_width=32, data_bytes=16),
    ChiCfg(Issue.E, node_id_width=7, addr_width=52, data_bytes=32,
           mpam_en=True, poison_en=True, datacheck_en=True),
    VIP_CHI_DEFAULT_CFG,
  ]
  checks = 0
  for cfg in cfgs:
    for ch in _CHANNELS:
      layout = flit_layout(cfg, ch)
      width = flit_width(cfg, ch)
      assert width == sum(w for _, w in layout) and width > 0
      assert len({n for n, _ in layout}) == len(layout), f"dup field in {ch}"
      # qos must be the least-significant field.
      assert layout[-1][0] == "qos", f"{ch} LSB is not qos"

      # 1) pack(all-zero) == 0 ; pack(all-ones) round-trips.
      for gen in (lambda w: 0, lambda w: mask(w), lambda w: rng.getrandbits(w)):
        fields = {n: gen(w) for n, w in layout}
        packed = pack(cfg, ch, fields)
        assert 0 <= packed < (1 << width)
        got = unpack(cfg, ch, packed)
        for n, w in layout:
          assert got[n] == (fields[n] & mask(w)), \
            f"{cfg.issue.name} {ch}.{n}: {got[n]:#x} != {fields[n] & mask(w):#x}"
        checks += 1

      # 2) LSB ordering: a distinctive qos lands in the low QOS_WIDTH bits.
      packed = pack(cfg, ch, {"qos": 0xA})
      assert (packed & mask(QOS_WIDTH)) == 0xA, f"{ch} qos not at LSB"

  print(f"OK: flit codec self-test passed ({checks} round-trips over "
        f"{len(cfgs)} cfgs x {len(_CHANNELS)} channels)")
  for cfg in cfgs[:2]:
    print(f"  {cfg.issue.name} N{cfg.node_id_width} A{cfg.addr_width} "
          f"DB{cfg.data_bytes}: " +
          ", ".join(f"{ch}={flit_width(cfg, ch)}b" for ch in _CHANNELS))


if __name__ == "__main__":
  _selftest()
