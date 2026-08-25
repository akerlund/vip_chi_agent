################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_combined_write_obligation_negctl.sv.
#
# The negative control for the combined-write obligation set (F-INTOP-008).
#
# Replacing a fixed completion sequence with an obligation set buys tolerance of
# ORDER. It must not buy tolerance of anything at all, and the difference is not
# self-evident from reading the loop: the same code that accepts CompCMO before
# Comp would accept a second CompCMO, or a ReadReceipt, if the final else were
# ever softened.
#
# cfg.snf_combined_cmo_duplicate_negctl makes the completer send CompCMO twice.
# The duplicate is chosen deliberately over an obviously wrong opcode: it is a
# response this transaction really is entitled to, arriving at a moment when it
# satisfies nothing outstanding. An implementation that keyed on "is this a
# legal opcode for this request" rather than on "is this obligation still owed"
# would pass a control built from a ReadReceipt and fail this one.
#
# What is asserted:
#   * the requester refuses the duplicate through reject(), so the refusal is
#     recorded as a tested outcome rather than killing the run.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_write_cmo_seq import vip_chi_write_cmo_seq, CMO_CLEAN_SH_PER_SEP
from chi_e_base_test import chi_e_base_test

from vip_chi_reject import expect_rejection

ADDR_C = 0x4D20_0000
SIZE_C = 6
SETTLE_C = 20


class tc_chi_e_combined_write_obligation_negctl(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    snf_cfg.snf_combined_cmo_duplicate_negctl = True

  async def run_phase(self):
    self.raise_objection()

    self.drain_observation_fifos()

    seq = vip_chi_write_cmo_seq("write_cmo_obligation_negctl", cfg=self.chi_cfg)
    seq.set_partial(False)
    seq.set_cmo(CMO_CLEAN_SH_PER_SEP)
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(ADDR_C)
    seq.set_size(SIZE_C)
    seq.set_get_response(True)
    seq.set_verbose(False)

    with expect_rejection("COMBINED_WRITE_COMPLETION"):
      await seq.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    self.logger.info(
      "Test (tc_chi_e_combined_write_obligation_negctl) PASS: a second CompCMO "
      "satisfying no outstanding obligation was refused")

    self.drop_objection()
