################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_cfg_item.sv.
#
# Per-item randomization-control knobs -- sequence-facing controls rather than
# protocol flit payload. In SV this extends uvm_object with uvm_field_* macros
# for printing; here it is a plain settable object the vip_chi_item reads as
# constants while pyvsc solves the rand fields.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Dir, DataType


class VipChiCfgItem:
  """Randomization-control config for a vip_chi_item. Defaults mirror the SV
  class exactly; reset() restores them but PRESERVES the direction pinned by the
  owning concrete sequence."""

  def __init__(self, name: str = "vip_chi_cfg_item"):
    self.name = name
    self.direction = Dir.READ
    self.reset()

  def reset(self) -> None:
    saved_direction = self.direction        # pinned by the concrete sequence
    self.direction = saved_direction
    self.data_type = DataType.RANDOM
    self.min_size = 0
    self.max_size = 6
    self.enforce_addr_alignment = True
    self.atomic_strict_size = False
    self.combined_write_cmo_enable = False
    self.get_response = False

  def __repr__(self):
    return (f"VipChiCfgItem(direction={Dir(self.direction).name}, "
            f"data_type={DataType(self.data_type).name}, "
            f"size=[{self.min_size},{self.max_size}], "
            f"enforce_addr_alignment={self.enforce_addr_alignment}, "
            f"atomic_strict_size={self.atomic_strict_size}, "
            f"get_response={self.get_response})")
