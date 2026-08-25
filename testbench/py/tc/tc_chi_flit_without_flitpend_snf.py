################################################################################
# pyUVM/cocotb port of tc/tc_chi_flit_without_flitpend_snf.sv.
#
# NEGATIVE control for CHI_RSP_VALID_REQUIRES_PEND on the COMPLETER's flits.
#
# tc_chi_flit_without_flitpend is the same control on the requester. This one
# exists because, until then it could not: cfg.flit_without_flitpend was
# honoured only inside the RN-I announce path, and the config layer REJECTED the
# knob on any other role with "on any other role it would set a flag nothing
# reads" -- which was true, and was the defect. The gap had been written down as
# a rule instead of closed.
#
# Every driver that announces a flit now routes it through a helper that
# consults the knob, so setting it on a role selects WHICH role drops its
# announcement. scripts/check_flitpend_negctl.py holds that property: it fails
# if any driver announces a flit outside a helper honouring the knob.
#
# Why it matters that this is the SN-F. The rule tallied plenty of passes on
# completer flits already, so nobody would have called it unexercised -- but a
# rule that has never been shown to FAIL on a path has not been shown to be
# watching that path at all. Passes prove the flits arrive; only a failure
# proves the check is reading them.
#
# Both halves are asserted:
#   * the rule must report exactly once -- one unannounced flit;
#   * the flits after it must still pass, or the rule would be firing on
#     well-formed traffic too.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_RSP_C = "CHI_RSP_VALID_REQUIRES_PEND"

ADDR_C = 0x3E20_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_flit_without_flitpend_snf(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.flit_without_flitpend = True

  # The checker exists by connect_phase and the dropped announcement happens on
  # the first flit in run_phase, so this is early enough to declare the waiver
  # and late enough for the checker to be there.
  def connect_phase(self):
    super().connect_phase()
    self.tb_env.snf_sva.expect_failure(_RSP_C)

  async def run_phase(self):
    self.raise_objection()

    snf = self.tb_env.snf_sva

    # Two writes: the first carries the unannounced flit, the second is ordinary
    # traffic the rule has to pass. One write alone could not tell a rule that
    # fires once from one that fires on everything.
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(2)
    wr.set_initial_addr(ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_exp_comp_ack(True)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    fails = snf.fail_count.get(_RSP_C, 0)
    passes = snf.pass_count.get(_RSP_C, 0)

    # Exactly one: the control is one-shot. Zero means the rule cannot see the
    # violation it exists for; more than one means the control did not stop.
    assert fails == 1, (
      f"{_RSP_C} reported {fails} time(s) against exactly one unannounced flit; "
      f"at 0 the rule cannot see its own violation, above 1 the one-shot control "
      f"did not stop")

    # And the announced flits around it must still pass, or the rule would be
    # rejecting well-formed traffic -- exactly the defect it replaced.
    assert passes > 0, (
      f"{_RSP_C} recorded no passes, so this run does not show the rule "
      f"accepting the announced flits either side of the one it caught")

    self.logger.info(
      f"Test (tc_chi_flit_without_flitpend_snf) PASS: one unannounced COMPLETER "
      f"flit was caught once, and {passes} announced flit(s) passed the same "
      f"rule")
    self.drop_objection()
