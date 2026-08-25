################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_raw_txsactive_negctl.sv.
#
# The negative control for the raw path's TXSACTIVE window.
#
# cfg.raw_req_txsactive_flit_scoped_negctl reverts the raw-injection path to the
# window it used to have -- scoped to the injected flit, with nothing holding the
# sideband up while the transaction that flit started is still outstanding. IHI
# 0050 E section 14.7.2 / D section 13.7.2 requires TXSACTIVE to cover every
# outstanding transaction, so CHI_TXSACTIVE_COVERS_OUTSTANDING must report it.
#
# The control is the DEFECT, not an invented one. That is what makes it worth a
# testcase rather than a mutation: the fix is a behaviour that has to keep
# working as opcodes are classified, and only a control re-proves it on every
# run. tc_chi_e_write_unique_zero_negctl is the positive half -- it injects the
# same opcode with no compensating hold on the requester and must stay silent.
#
# The rule is turned down to OFF rather than disabled: OFF still evaluates and
# still counts, and only suppresses the report, which is what a negative control
# needs.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_tb_pkg import E_WUZ_NEGCTL_ADDR_C, E_WUZ_NEGCTL_TXN_ID_PASS_C
from tc_chi_e_write_unique_zero_negctl import tc_chi_e_write_unique_zero_negctl

COVERS_C = "CHI_TXSACTIVE_COVERS_OUTSTANDING"
# The neighbour that must NOT move. A window closed too early is
# UNDER-assertion; the bound on over-assertion has nothing to say about it, and
# a control that tripped both would not tell the two rules apart.
BOUNDED_C = "CHI_TXSACTIVE_DEASSERT_BOUNDED"
SETTLE_C = 40


class tc_chi_e_raw_txsactive_negctl(tc_chi_e_write_unique_zero_negctl):

  # The requester reverts to the flit-scoped window. The completer's hold stays
  # as the parent sets it: it is a property of a test that drives both ends, not
  # of the defect under control here, and removing it would make the SN-F report
  # a violation of its own and muddle the count below.
  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    rni_cfg.raw_req_txsactive_flit_scoped_negctl = True

  async def run_phase(self):
    self.raise_objection()

    rni_sva = self.tb_env.rni_sva

    # Compliant traffic first, so the link is in RUN and the silence asserted
    # here is a statement about the injection rather than about an idle link.
    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_WUZ_NEGCTL_ADDR_C)
    wr.set_size(6)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)

    await self.wait_clocks(4)
    self.drain_observation_fifos()

    before = rni_sva.fail_count.get(COVERS_C, 0)
    assert before == 0, (
      f"{COVERS_C} already reported {before} time(s) on compliant traffic; the "
      f"count below would prove nothing")

    rni_sva.off_check(COVERS_C)

    # One WriteUniqueZero, injected raw, completed by this test. Between the two
    # the transaction is outstanding and the sideband is down.
    await self._inject_req(E_WUZ_NEGCTL_TXN_ID_PASS_C)
    await self.wait_clocks(4)
    await self._inject_completion(E_WUZ_NEGCTL_TXN_ID_PASS_C)
    await self.wait_clocks(SETTLE_C)

    fails = rni_sva.fail_count.get(COVERS_C, 0)
    assert fails > 0, (
      f"{COVERS_C} did not report a raw WriteUniqueZero whose TXSACTIVE window "
      f"was scoped to its flit; either the control is not reaching the driver "
      f"or the rule has stopped watching the requester's own window")

    neighbour = rni_sva.fail_count.get(BOUNDED_C, 0)
    assert neighbour == 0, (
      f"{BOUNDED_C} reported {neighbour} time(s) as well; a window closed too "
      f"early is under-assertion and must not move the over-assertion bound, "
      f"so this control is no longer isolating one rule")

    self.logger.info(
      f"Test (tc_chi_e_raw_txsactive_negctl) PASS: a flit-scoped raw window "
      f"was reported {fails} time(s) by {COVERS_C}, with {BOUNDED_C} silent")

    self.drop_objection()
