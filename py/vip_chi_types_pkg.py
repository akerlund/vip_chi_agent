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
  "CHI_LCRD_QUIESCENT_IN_STOP",
  "CHI_LCRD_OVERFLOW",
  "CHI_LCRD_UNDERFLOW",
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
  # ExpCompAck legality, appended for the same append-only reason. The converse
  # -- a CompAck arriving for a request that never asked for one -- has been
  # checked since the first cut as COMPACK_WITHOUT_EXPCOMPACK; this is the
  # direction nobody was watching, because the item constraint made it
  # unreachable.
  "CHI_EXPCOMPACK_REQUIRED_BUT_ZERO",
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
QOS_WIDTH = 4
PCRD_TYPE_WIDTH = 4
MPAM_WIDTH = 11
TAGOP_WIDTH = 2
GROUP_ID_EXT_WIDTH = 3
SIZE_WIDTH = 3
RESP_WIDTH = 3
RESP_ERR_WIDTH = 2
ORDER_WIDTH = 2
MEMATTR_WIDTH = 4
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
    return 8 if self.is_e else 5

  # -- data-geometry-derived widths --
  @property
  def be_width(self) -> int:
    return self.data_bytes if self.data_bytes > 0 else 1

  @property
  def num_dat_beats(self) -> int:
    return (CACHE_LINE_BYTES // self.data_bytes) if self.data_bytes > 0 else 0

  @property
  def data_id_width(self) -> int:
    beats = self.num_dat_beats
    return 1 if beats <= 1 else clog2(beats)

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

# Snoops that forbid the snoopee from RETAINING Unique. A shared snoop exists to
# create a sharer, so Table 4-9's responses to SnpShared and SnpSharedFwd carry
# Invalid or SharedClean and never a Unique state.
#
# SnpClean, SnpCleanShared and the remaining fwd forms are deliberately absent:
# this VIP's home never originates them, so listing them would assert a reading
# of Table 4-9 that no traffic here can confirm or refute. Add them with the
# stimulus that exercises them.
SNP_NO_RETAIN_UNIQUE_OPCODES = frozenset({
  int(SnpOpcode.SHARED), int(SnpOpcode.SHARED_FWD),
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


_COMBINED_WRITE_CMO_OPCODES = frozenset({
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH),
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_INV),
  int(ReqOpcode.WRITE_NO_SNP_FULL_CLEAN_SH_PER_SEP),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_INV),
  int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP),
})


def req_opcode_is_combined_write_cmo(opcode: int) -> bool:
  """A single request carrying both a write and a cache maintenance operation.

  The twin of vip_chi_req_opcode_is_combined_write_cmo in the SystemVerilog
  types package. It lives here rather than beside its callers because the six
  are writes first and anything classifying writes has to say so.
  """
  return int(opcode) in _COMBINED_WRITE_CMO_OPCODES


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
_COMPACK_OPTIONAL_OPCODES = frozenset({
  int(ReqOpcode.READ_NO_SNP),
  int(ReqOpcode.READ_NO_SNP_SEP),
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
      ("lpid", cfg.lpid_width), ("dodwt", 1), ("memattr", MEMATTR_WIDTH),
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
      ("tracetag", 1), ("donotdatapull", 1), ("rettosrc", 1),
      ("opcode", cfg.snp_opcode_width), ("addr", a), ("ns", 1),
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
