################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_write_unique_zero_seq.sv.
#
# WriteUniqueZero: a snoopable full-line store of ZERO that puts NO data on the
# wire. The snoopable twin of WriteNoSnpZero -- the home invalidates every other
# holder, zeroes the line itself, and completes with DBIDResp* + Comp or a
# combined CompDBIDResp. Never carries CompAck.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, Dir, Issue
from vip_chi_coherent_base_seq import vip_chi_coherent_base_seq


class vip_chi_write_unique_zero_seq(vip_chi_coherent_base_seq):

  def __init__(self, name="vip_chi_write_unique_zero_seq", cfg=None):
    super().__init__(name, cfg=cfg)

  async def body(self):
    if self.CFG.issue != Issue.E:
      raise AssertionError(
        f"[{self.get_name()}] this opcode sits in the Opcode[6] = 1 half of the "
        f"REQ table and does not fit CHI-D's 6-bit field")

    self.set_direction(Dir.WRITE)

    # The opcode is opt-in in the item's coherent legal pool, and this sequence
    # is the thing opting in: without it the constraint solver rejects the very
    # opcode this sequence exists to drive.
    self.set_write_unique_zero_enable(True)
    self.set_coherent_opcode(ReqOpcode.WRITE_UNIQUE_ZERO)
    await super().body()
