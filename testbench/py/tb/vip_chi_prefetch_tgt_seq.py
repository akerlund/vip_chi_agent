################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tb/vip_chi_prefetch_tgt_seq.sv -- forces READ direction and a
# PrefetchTgt opcode, then runs the shared base generation flow. PrefetchTgt is a
# no-completion hint: the RN-I driver drives only the REQ and retires the item
# locally (no RSP / DAT expected).
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ChiCfg, Dir, ReqOpcode
from vip_chi_base_seq import vip_chi_base_seq


class vip_chi_prefetch_tgt_seq(vip_chi_base_seq):

  def __init__(self, name: str = "vip_chi_prefetch_tgt_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)

  def _choose_opcode(self):
    return ReqOpcode.PREFETCH_TGT

  def access_name(self):
    return "PrefetchTgt"

  def preview_next_request(self):
    self.set_direction(Dir.READ)
    return super().preview_next_request()

  async def body(self):
    self.set_direction(Dir.READ)
    await super().body()
