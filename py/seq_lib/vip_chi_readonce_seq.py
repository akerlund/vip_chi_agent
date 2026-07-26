################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_readonce_seq.sv -- Coherent ReadOnce: a non-allocating snapshot read (ends Invalid).
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, Dir
from vip_chi_coherent_base_seq import vip_chi_coherent_base_seq


class vip_chi_readonce_seq(vip_chi_coherent_base_seq):

  def __init__(self, name="vip_chi_readonce_seq", cfg=None):
    super().__init__(name, cfg=cfg)

  async def body(self):
    self.set_direction(Dir.READ)
    self.set_coherent_opcode(ReqOpcode.READ_ONCE)
    await super().body()
