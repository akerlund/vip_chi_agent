################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_combined_write_comp_persist.sv.
#
# A combined Write + PCMO answered with CompPersist.
#
# IHI 0050 E section 2.8, in the SN response summary: the Slave "is permitted to
# combine CompCMO with Persist as a CompPersist response if the two are sent to
# Home". So a conformant completer may answer this request with two responses
# where the default completer sends three, and a requester must accept both
# shapes.
#
# This one could not previously be RUN, let alone passed. The requester demanded
# exactly CompCMO and then exactly Persist, and fatalled on anything else -- not
# a mis-score, a stopped simulation on legal CHI. And the completer could not
# produce the encoding on this path at all, so the intolerance had nothing to
# meet it: cfg.combined_persist_rsp reached only the standalone
# CleanSharedPersistSep flow. Both halves are fixed here, which is why the test
# is evidence rather than a restatement of the driver.
#
# The combination is legal only where CompCMO's target and the Persist's
# coincide -- SrcID and ReturnNID -- so the completer emits it only when they do
# rather than obeying the knob blindly. Here the sequence leaves ReturnNID at
# the requester's own node, which is the case that makes it available.
#
# What is asserted:
#   * the transaction completes and returns exactly one response, so the
#     obligation set retired on two flits rather than hanging on a third;
#   * the scoreboard reports no incomplete transaction, which is the check that
#     the CMO and persist milestones were both ticked by the one response.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_write_cmo_seq import vip_chi_write_cmo_seq, CMO_CLEAN_SH_PER_SEP
from vip_chi_types_pkg import RspOpcode
from chi_e_base_test import chi_e_base_test

ADDR_C = 0x4D00_0000
SIZE_C = 6
SETTLE_C = 20


class tc_chi_e_combined_write_comp_persist(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    snf_cfg.combined_persist_rsp = True

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard
    self.drain_observation_fifos()

    seq = vip_chi_write_cmo_seq("write_cmo_comp_persist", cfg=self.chi_cfg)
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

    # The completer actually took the encoding, rather than sending the default
    # pair and being accepted anyway. Both complete, so completion alone would
    # not distinguish them and this test would pass against a knob that did
    # nothing.
    log = self.tb_env.rni_agent.rni_driver.combined_completion_log
    assert int(RspOpcode.COMP_PERSIST) in log, (
      f"the combined Write + PCMO retired its obligations from "
      f"{[hex(o) for o in log]}, which contains no CompPersist. The requester "
      f"accepting the default CompCMO + Persist pair proves nothing about the "
      f"combined encoding")

    assert sb.total_errors() == 0, (
      f"the scoreboard reported {sb.total_errors()} violation(s) against a "
      f"combined Write + PCMO answered with CompPersist. Section 2.8 permits "
      f"that encoding, and the milestones it ticks are CompCMO and Persist -- "
      f"not Comp and Persist, which is what the standalone form combines")

    self.logger.info(
      "Test (tc_chi_e_combined_write_comp_persist) PASS: a combined Write + "
      "PCMO answered with CompPersist retired both the CMO and the persist "
      "obligation from one response")

    self.drop_objection()
