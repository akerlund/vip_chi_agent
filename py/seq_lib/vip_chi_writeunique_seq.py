################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_writeunique_seq.sv -- a non-allocating coherent write to
# a line the requester does NOT hold. set_partial() selects WriteUniquePtl vs
# WriteUniqueFull.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, Dir
from vip_chi_coherent_base_seq import vip_chi_coherent_base_seq


class vip_chi_writeunique_seq(vip_chi_coherent_base_seq):

  def __init__(self, name="vip_chi_writeunique_seq", cfg=None):
    super().__init__(name, cfg=cfg)
    self.partial_enabled = False

  def reset(self):
    super().reset()
    self.partial_enabled = False

  def set_partial(self, enabled=True):
    self.partial_enabled = bool(enabled)

  async def body(self):
    self.set_direction(Dir.WRITE)
    self.set_coherent_opcode(
        ReqOpcode.WRITE_UNIQUE_PTL if self.partial_enabled
        else ReqOpcode.WRITE_UNIQUE_FULL)
    await super().body()
