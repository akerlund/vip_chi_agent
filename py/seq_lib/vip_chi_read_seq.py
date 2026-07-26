################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_read_seq.sv -- pins READ direction, then runs the base
# generation loop.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ChiCfg, Dir
from vip_chi_base_seq import vip_chi_base_seq


class vip_chi_read_seq(vip_chi_base_seq):

  def __init__(self, name: str = "vip_chi_read_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)

  def preview_next_request(self):
    self.set_direction(Dir.READ)
    return super().preview_next_request()

  async def body(self):
    self.set_direction(Dir.READ)
    await super().body()
