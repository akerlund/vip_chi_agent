################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_combined_write_cmo_first.sv.
#
# CompCMO driven before the write's Comp (F-INTOP-008).
#
# IHI 0050 E section 2.8 places exactly one ordering rule on CompCMO -- it "must
# only be sent after the associated request is received" -- and none at all
# relative to the write's own completion. Both orders are conformant.
#
# The requester used to encode one of them as the only one: it consumed the
# write completion first and only then looked for CompCMO, so a completer that
# led with the CMO half had that flit collected by the write-completion path and
# died on "was not Comp". The fix is not to accept the other order as a second
# script but to stop scripting: the remaining completions are collected as an
# obligation SET, and each flit retires whichever obligation it satisfies.
#
# cfg.snf_cmo_before_write_comp is not a negative control. It selects a legal
# alternative, which is why it does not appear in the config's has_negctl chain
# -- nothing here is expected to be reported by anything.
#
# What is asserted:
#   * the transaction completes, which under the old fixed sequence it could
#     not have;
#   * the scoreboard reports no violation, so accepting the order is not
#     achieved by the checker having stopped looking.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_write_cmo_seq import vip_chi_write_cmo_seq, CMO_CLEAN_SH_PER_SEP
from vip_chi_types_pkg import RspOpcode
from chi_e_base_test import chi_e_base_test

ADDR_C = 0x4D10_0000
SIZE_C = 6
SETTLE_C = 20


class tc_chi_e_combined_write_cmo_first(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    snf_cfg.snf_cmo_before_write_comp = True
    # The write's Comp must be a separate flit for there to be an order to put
    # the CMO in front of: a combined CompDBIDResp carries the completion with
    # the grant, before the write data has even been sent.
    snf_cfg.split_write_rsp = True

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard
    self.drain_observation_fifos()

    seq = vip_chi_write_cmo_seq("write_cmo_first", cfg=self.chi_cfg)
    seq.set_partial(False)
    seq.set_cmo(CMO_CLEAN_SH_PER_SEP)
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(ADDR_C)
    seq.set_size(SIZE_C)
    seq.set_get_response(True)
    seq.set_verbose(False)
    await seq.start(self.v_sqr.rni_sequencer)

    responses = seq.get_responses()
    assert len(responses) == 1, (
      f"the combined Write + PCMO returned {len(responses)} responses, "
      f"expected 1")

    await self.wait_clocks(SETTLE_C)

    # The CMO half really did arrive first. Without this the test passes against
    # a knob that does nothing, because the write-first order completes too.
    log = self.tb_env.rni_agent.rni_driver.combined_completion_log
    assert log and log[0] == int(RspOpcode.COMP_CMO), (
      f"the combined Write + PCMO retired its obligations in the order "
      f"{[hex(o) for o in log]}; CompCMO was expected first, so the completer "
      f"did not take the order this testcase exists to exercise")

    assert sb.total_errors() == 0, (
      f"the scoreboard reported {sb.total_errors()} violation(s) against a "
      f"completer that sent CompCMO before the write's Comp. Section 2.8 does "
      f"not order those two responses")

    self.logger.info(
      "Test (tc_chi_e_combined_write_cmo_first) PASS: a combined Write + PCMO "
      "whose CompCMO preceded the write's Comp completed normally")

    self.drop_objection()
