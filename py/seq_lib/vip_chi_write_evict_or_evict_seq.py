################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_write_evict_or_evict_seq.sv.
#
# WriteEvictOrEvict: the RN-F offers a CLEAN line back and the HOME decides
# whether it wants the data. CompDBIDResp means yes (answered with
# CopyBackWrData, which is an implicit CompAck); Comp means no (answered with an
# explicit CompAck, degenerating into an Evict). ExpCompAck is always set --
# the item constrains it -- because the no-data leg completes only on the ack.
# Which leg the home takes is cfg.hnf_write_evict_request_data.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, Dir, Issue
from vip_chi_coherent_base_seq import vip_chi_coherent_base_seq


class vip_chi_write_evict_or_evict_seq(vip_chi_coherent_base_seq):

  def __init__(self, name="vip_chi_write_evict_or_evict_seq", cfg=None):
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
    self.set_write_evict_or_evict_enable(True)

    # ExpCompAck is not optional here, so the sequence must ask for it: the base
    # sequence pins the bit to its own default, and the item independently
    # constrains this opcode to 1. Left unset the two contradict and the solver
    # fails -- which is the constraint doing its job, not a bug to work around.
    self.set_exp_comp_ack(1)
    self.set_coherent_opcode(ReqOpcode.WRITE_EVICT_OR_EVICT)
    await super().body()
