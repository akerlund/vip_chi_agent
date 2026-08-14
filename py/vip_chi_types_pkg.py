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
  """Link Activation State Machine, one instance per link DIRECTION.

  The state is the {LINKACTIVEREQ, LINKACTIVEACK} pair of that direction, so it
  is derived from the wires rather than from which node happens to originate
  activation -- which is what makes it usable on a VIP that activates
  asymmetrically.

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
  "CHI_REQ_PEND_REQUIRES_VALID",
  "CHI_RSP_PEND_REQUIRES_VALID",
  "CHI_DAT_PEND_REQUIRES_VALID",
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
  "CHI_SNP_PEND_REQUIRES_VALID",
  "CHI_SNP_KNOWN_WHEN_VALID",
  "CHI_SNP_IDLE_IN_RESET",
  "CHI_SNP_LCRD_OVERFLOW",
  "CHI_SNP_LCRD_UNDERFLOW",
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


class RspOpcode(IntEnum):
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
  SNP_RESP = 0x01
  SNP_RESP_FWDED = 0x09


class DatOpcode(IntEnum):
  SNP_RESP_DATA = 0x1
  COPY_BACK_WR_DATA = 0x2
  NON_COPY_BACK_WR_DATA = 0x3
  COMP_DATA = 0x4
  SNP_RESP_DATA_PTL = 0x5
  SNP_RESP_DATA_FWDED = 0x6
  DATA_SEP_RESP = 0xB
  NCB_WR_DATA_COMP_ACK = 0xC


class SnpOpcode(IntEnum):
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
