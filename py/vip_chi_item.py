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
)

_RO = ReqOpcode  # brevity in the opcode-set tables below

# Non-coherent legal REQ opcode sets (con_opcode_legal), by direction and issue.
_READ_OPCODES_D = [_RO.READ_NO_SNP, _RO.PREFETCH_TGT]
_READ_OPCODES_E = _READ_OPCODES_D + [_RO.READ_NO_SNP_SEP]
_WRITE_OPCODES_D = [_RO.WRITE_NO_SNP_PTL, _RO.WRITE_NO_SNP_FULL,
                    _RO.CLEAN_SHARED_PERSIST] + list(range(0x28, 0x3A))
_WRITE_OPCODES_E = _WRITE_OPCODES_D + [_RO.WRITE_NO_SNP_ZERO,
                                       _RO.CLEAN_SHARED_PERSIST_SEP]

# Coherent RN-F legal REQ opcode sets (con_opcode_legal_rnf).
_RNF_READ_OPCODES = [_RO.READ_SHARED, _RO.READ_CLEAN, _RO.READ_UNIQUE,
                     _RO.MAKE_READ_UNIQUE, _RO.READ_ONCE]
_RNF_WRITE_OPCODES = [_RO.WRITE_BACK_FULL, _RO.WRITE_CLEAN_FULL, _RO.EVICT,
                      _RO.CLEAN_UNIQUE, _RO.MAKE_UNIQUE, _RO.CLEAN_INVALID,
                      _RO.MAKE_INVALID, _RO.WRITE_UNIQUE_FULL, _RO.WRITE_UNIQUE_PTL]

# Opcodes that carry write/atomic DAT payload (get_payload_beat_count).
_WRITE_PAYLOAD_OPCODES = {
  int(_RO.WRITE_NO_SNP_FULL), int(_RO.WRITE_NO_SNP_PTL), int(_RO.WRITE_BACK_FULL),
  int(_RO.WRITE_CLEAN_FULL), int(_RO.WRITE_UNIQUE_FULL), int(_RO.WRITE_UNIQUE_PTL),
}
_PARTIAL_WRITE_OPCODES = {int(_RO.WRITE_NO_SNP_PTL), int(_RO.WRITE_UNIQUE_PTL)}

# Opcodes that must never carry ExpCompAck (con_exp_comp_ack_legal).
_NO_EXP_COMP_ACK_OPCODES = [
  _RO.PREFETCH_TGT, _RO.PCRD_RETURN, _RO.CLEAN_SHARED_PERSIST,
  _RO.CLEAN_SHARED_PERSIST_SEP, _RO.WRITE_NO_SNP_ZERO, _RO.MAKE_UNIQUE,
] + list(range(0x28, 0x3A))


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
    self.s_atomic_strict = vsc.uint8_t(0)
    self.s_min_size = vsc.uint8_t(0)
    self.s_max_size = vsc.uint8_t(6)
    self.s_min_addr = vsc.uint64_t(0)
    self.s_max_addr = vsc.uint64_t(mask(self._addr_w))

    # ---- non-rand response / snoop / raw scalars --------------------------
    self.dat_opcode = int(DatOpcode.COMP_DATA)
    self.dat_tagop = 0
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
    self.do_not_data_pull = False
    self.raw_override = False
    self.raw_flitpend = False
    self.raw_channel = int(RawChannel.NONE)
    self.raw_req = 0
    self.raw_rsp = 0
    self.raw_dat = 0
    self.raw_snp = 0

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
    self.atomic_strict_size = False
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

  def set_atomic_strict_size(self, value: bool) -> None:
    self.atomic_strict_size = bool(value)

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
               int(_RO.MAKE_READ_UNIQUE), int(_RO.READ_ONCE)}
      if v == int(_RO.READ_NO_SNP_SEP):
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
    self.s_atomic_strict = 1 if self.atomic_strict_size else 0
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
  def con_atomic_compare_size(self):
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.opcode == int(_RO.ATOMIC_COMPARE)):
        self.size >= self._clog2_db_p1

  @vsc.constraint
  def con_atomic_compare_supported(self):
    if self._clog2_db_p1 > 6:
      with vsc.if_then(self.s_raw_override == 0):
        self.opcode != int(_RO.ATOMIC_COMPARE)

  @vsc.constraint
  def con_atomic_strict_size(self):
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.s_atomic_strict == 1):
        with vsc.if_then(self.opcode.inside(vsc.rangelist((0x28, 0x39)))):
          with vsc.if_then(self.opcode == int(_RO.ATOMIC_COMPARE)):
            self.size <= 4
          with vsc.if_then(self.opcode != int(_RO.ATOMIC_COMPARE)):
            self.size <= 3

  @vsc.constraint
  def con_opcode_legal(self):
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.role != int(Role.RNF)):
        with vsc.if_then(self.direction == int(Dir.READ)):
          self.opcode.inside(vsc.rangelist(*[int(o) for o in self._read_set]))
        with vsc.if_then(self.direction == int(Dir.WRITE)):
          self.opcode.inside(vsc.rangelist(*[int(o) for o in self._write_set]))

  @vsc.constraint
  def con_opcode_legal_rnf(self):
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.role == int(Role.RNF)):
        with vsc.if_then(self.direction == int(Dir.READ)):
          self.opcode.inside(vsc.rangelist(*[int(o) for o in _RNF_READ_OPCODES]))
        with vsc.if_then(self.direction == int(Dir.WRITE)):
          self.opcode.inside(vsc.rangelist(*[int(o) for o in _RNF_WRITE_OPCODES]))

  @vsc.constraint
  def con_return_path_fields(self):
    # Separated-read return routing is only meaningful for ReadNoSnpSep; all
    # other requests clear the return path fields (mirrors SV con_return_path_fields).
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.opcode == int(_RO.READ_NO_SNP_SEP)):
        self.return_nid == self.src_id
      with vsc.if_then(self.opcode != int(_RO.READ_NO_SNP_SEP)):
        self.return_nid == 0
        self.return_txn_id == 0

  @vsc.constraint
  def con_exp_comp_ack_legal(self):
    with vsc.if_then(self.s_raw_override == 0):
      with vsc.if_then(self.direction == int(Dir.READ)):
        self.exp_comp_ack == 0
      with vsc.if_then(self.opcode.inside(
          vsc.rangelist(*[int(o) for o in _NO_EXP_COMP_ACK_OPCODES]))):
        self.exp_comp_ack == 0

  @vsc.constraint
  def con_issue_gated_fields(self):
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
      if op in (int(_RO.WRITE_BACK_FULL), int(_RO.WRITE_CLEAN_FULL)):
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
    "pcrd_type", "allow_retry", "excl", "exp_comp_ack", "tracetag", "dodwt",
    "likelyshared", "endian", "group_id_ext", "tagop", "mpam", "datacheck",
    "poison", "dat_opcode", "dat_tagop", "rsp_opcode", "rsp_resp", "rsp_resp_err",
    "dbid", "fwd_state", "snp_opcode", "snp_addr", "snp_resp",
  )
  _ARRAYS = ("data", "be", "tag", "tu", "data_id", "cc_id", "dat_resp",
             "dat_resp_err")

  def do_copy(self, rhs: "vip_chi_item") -> None:
    for f in self._SCALARS:
      setattr(self, f, int(getattr(rhs, f)))
    for f in ("is_snoop", "ret_to_src", "do_not_data_pull", "raw_override",
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

  def convert2string(self) -> str:
    return (f"{self.name} dir={int(self.direction)} role={int(self.role)} "
            f"src=0x{int(self.src_id):x} tgt=0x{int(self.tgt_id):x} "
            f"txn=0x{int(self.txn_id):x} opcode=0x{int(self.opcode):x} "
            f"addr=0x{int(self.addr):x} size={int(self.size)} "
            f"beats={len(self.data)} dat_opcode=0x{int(self.dat_opcode):x} "
            f"raw={int(self.raw_override)}")
