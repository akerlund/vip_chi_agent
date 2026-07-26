################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_writeback_seq.sv -- Coherent WriteBackFull: give a held (dirty) line back to the home.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, Dir
from vip_chi_coherent_base_seq import vip_chi_coherent_base_seq


class vip_chi_writeback_seq(vip_chi_coherent_base_seq):

  def __init__(self, name="vip_chi_writeback_seq", cfg=None):
    super().__init__(name, cfg=cfg)

  async def body(self):
    self.set_direction(Dir.WRITE)
    self.set_coherent_opcode(ReqOpcode.WRITE_BACK_FULL)
    await super().body()
