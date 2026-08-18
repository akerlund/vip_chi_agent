################################################################################
# pyUVM/cocotb port of tc/tc_chi_flit_without_flitpend.sv.
#
# NEGATIVE control for CHI_REQ_VALID_REQUIRES_PEND: a flit sent with no FLITPEND
# in the cycle before it, which E section 14.4 / D section 13.4 require.
#
# This is the control the suite did not have. The rule it replaced ran the
# obligation backwards -- `flitpend |-> flitv` -- and its control drove a lone
# FLITPEND, which the specification explicitly permits; that stimulus is now the
# POSITIVE control in tc_chi_flitpend_without_valid. Nothing anywhere drove the
# thing the rule actually forbids, so the corrected rule needs this to show it
# can fail at all.
#
# cfg.flit_without_flitpend drops the one-cycle announcement in front of exactly
# one flit and then stops, so the rest of the run is legal traffic the same rule
# must pass. Both halves are asserted:
#   * the rule must report exactly once -- one unannounced flit;
#   * the flits after it must still pass, or the rule would be firing on
#     well-formed traffic too.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_REQ_C = "CHI_REQ_VALID_REQUIRES_PEND"

ADDR_C = 0x3E10_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_flit_without_flitpend(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.flit_without_flitpend = True

  # The checker exists by connect_phase and the dropped announcement happens on
  # the first flit in run_phase, so this is early enough to declare the waiver
  # and late enough for the checker to be there.
  def connect_phase(self):
    super().connect_phase()
    self.tb_env.rni_sva.expect_failure(_REQ_C)

  async def run_phase(self):
    self.raise_objection()

    rni = self.tb_env.rni_sva

    # Two writes: the first carries the unannounced flit, the second is ordinary
    # traffic the rule has to pass. One write alone could not tell a rule that
    # fires once from one that fires on everything.
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(2)
    wr.set_initial_addr(ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_exp_comp_ack(True)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    fails = rni.fail_count.get(_REQ_C, 0)
    passes = rni.pass_count.get(_REQ_C, 0)

    # Exactly one: the control is one-shot. Zero means the rule cannot see the
    # violation it exists for; more than one means the control did not stop.
    assert fails == 1, (
      f"{_REQ_C} reported {fails} time(s) against exactly one unannounced flit; "
      f"at 0 the rule cannot see its own violation, above 1 the one-shot control "
      f"did not stop")

    # And the announced flits around it must still pass, or the rule would be
    # rejecting well-formed traffic -- exactly the defect it replaced.
    assert passes > 0, (
      f"{_REQ_C} recorded no passes, so this run does not show the rule "
      f"accepting the announced flits either side of the one it caught")

    self.logger.info(
      f"Test (tc_chi_flit_without_flitpend) PASS: one unannounced flit was "
      f"caught once, and {passes} announced flit(s) passed the same rule")
    self.drop_objection()
