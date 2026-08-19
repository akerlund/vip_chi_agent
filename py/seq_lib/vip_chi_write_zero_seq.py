################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_write_zero_seq.sv -- WriteNoSnpZero (CHI-E only): a
# data-less write that zeroes the Size-selected byte range at the completer.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ChiCfg, Dir, DataType, ReqOpcode
from vip_chi_reject import reject
from vip_chi_base_seq import vip_chi_base_seq


class vip_chi_write_zero_seq(vip_chi_base_seq):

  def __init__(self, name: str = "vip_chi_write_zero_seq", cfg: ChiCfg = None):
    super().__init__(name, cfg)

  def _choose_opcode(self):
    # reject() rather than raise: with no expectation armed it raises exactly as
    # before, and inside an expect_rejection scope it records and returns so a
    # negative control can prove the refusal happened -- the behaviour of the
    # demoted `uvm_fatal the SV twin catches with chi_write_zero_fatal_catcher.
    # Falling through to return the opcode mirrors SV, whose task also continues
    # once the fatal is demoted.
    if not self.CFG.is_e:
      reject("WRITE_ZERO_ISSUE",
             f"[{self.get_name()}] WriteNoSnpZero is only legal under CHI-E")
    return ReqOpcode.WRITE_NO_SNP_ZERO

  def preview_next_request(self):
    self.set_direction(Dir.WRITE)
    self.set_data_type(DataType.ZEROS)
    return super().preview_next_request()

  async def body(self):
    self.set_direction(Dir.WRITE)
    if not self.CFG.is_e:
      reject("WRITE_ZERO_ISSUE",
             f"[{self.get_name()}] WriteNoSnpZero is only legal under CHI-E")
    self.set_data_type(DataType.ZEROS)
    await super().body()
