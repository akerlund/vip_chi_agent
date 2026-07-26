################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_atomic_seq.sv -- issues one atomic request (AtomicStore /
# Load / Swap / Compare), carrying the operand as the write payload.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ChiCfg, Dir, AtomicOp, atomic_op_to_req_opcode
from vip_chi_base_seq import vip_chi_base_seq


class vip_chi_atomic_seq(vip_chi_base_seq):

  def __init__(self, name: str = "vip_chi_atomic_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)
    self.atomic_op = AtomicOp.STORE_0

  def reset(self):
    super().reset()
    self.atomic_op = AtomicOp.STORE_0

  def set_atomic_op(self, op):
    self.atomic_op = op

  def _choose_opcode(self):
    return atomic_op_to_req_opcode(int(self.atomic_op))

  def preview_next_request(self):
    self.set_direction(Dir.WRITE)
    return super().preview_next_request()

  async def body(self):
    self.set_direction(Dir.WRITE)
    await super().body()


# The variant subclasses mirror the SV file's atomic_store/load/swap/compare
# sequences: they pin a family (STORE / LOAD / SWAP / COMPARE) and expose
# set_variant() to select the arithmetic index within the STORE/LOAD [0:7] set.
class vip_chi_atomic_store_seq(vip_chi_atomic_seq):

  _VARIANTS = [
    AtomicOp.STORE_0, AtomicOp.STORE_1, AtomicOp.STORE_2, AtomicOp.STORE_3,
    AtomicOp.STORE_4, AtomicOp.STORE_5, AtomicOp.STORE_6, AtomicOp.STORE_7,
  ]

  def __init__(self, name: str = "vip_chi_atomic_store_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)
    self.variant = 0
    self.set_atomic_op(self._variant_to_op(0))

  def reset(self):
    super().reset()
    self.variant = 0
    self.set_atomic_op(self._variant_to_op(0))

  def set_variant(self, value):
    self.variant = int(value)
    self.set_atomic_op(self._variant_to_op(self.variant))

  def get_variant(self):
    return self.variant

  def _variant_to_op(self, value):
    if not 0 <= int(value) <= 7:
      raise ValueError(
        f"[{self.get_name()}] AtomicStore variant {value} is outside [0:7]")
    return self._VARIANTS[int(value)]

  def preview_next_request(self):
    self.set_atomic_op(self._variant_to_op(self.variant))
    return super().preview_next_request()

  async def body(self):
    self.set_atomic_op(self._variant_to_op(self.variant))
    await super().body()


class vip_chi_atomic_load_seq(vip_chi_atomic_seq):

  _VARIANTS = [
    AtomicOp.LOAD_0, AtomicOp.LOAD_1, AtomicOp.LOAD_2, AtomicOp.LOAD_3,
    AtomicOp.LOAD_4, AtomicOp.LOAD_5, AtomicOp.LOAD_6, AtomicOp.LOAD_7,
  ]

  def __init__(self, name: str = "vip_chi_atomic_load_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)
    self.variant = 0
    self.set_atomic_op(self._variant_to_op(0))

  def reset(self):
    super().reset()
    self.variant = 0
    self.set_atomic_op(self._variant_to_op(0))

  def set_variant(self, value):
    self.variant = int(value)
    self.set_atomic_op(self._variant_to_op(self.variant))

  def get_variant(self):
    return self.variant

  def _variant_to_op(self, value):
    if not 0 <= int(value) <= 7:
      raise ValueError(
        f"[{self.get_name()}] AtomicLoad variant {value} is outside [0:7]")
    return self._VARIANTS[int(value)]

  def preview_next_request(self):
    self.set_atomic_op(self._variant_to_op(self.variant))
    return super().preview_next_request()

  async def body(self):
    self.set_atomic_op(self._variant_to_op(self.variant))
    await super().body()


class vip_chi_atomic_swap_seq(vip_chi_atomic_seq):

  def __init__(self, name: str = "vip_chi_atomic_swap_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)
    self.set_atomic_op(AtomicOp.SWAP)

  def reset(self):
    super().reset()
    self.set_atomic_op(AtomicOp.SWAP)

  def preview_next_request(self):
    self.set_atomic_op(AtomicOp.SWAP)
    return super().preview_next_request()

  async def body(self):
    self.set_atomic_op(AtomicOp.SWAP)
    await super().body()


class vip_chi_atomic_compare_seq(vip_chi_atomic_seq):

  def __init__(self, name: str = "vip_chi_atomic_compare_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)
    self.set_atomic_op(AtomicOp.COMPARE)

  def reset(self):
    super().reset()
    self.set_atomic_op(AtomicOp.COMPARE)

  def preview_next_request(self):
    self.set_atomic_op(AtomicOp.COMPARE)
    return super().preview_next_request()

  async def body(self):
    self.set_atomic_op(AtomicOp.COMPARE)
    await super().body()
