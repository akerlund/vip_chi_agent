################################################################################
# pyUVM/cocotb port of tc/tc_chi_flitpend_without_valid.sv.
#
# POSITIVE control for CHI_REQ/RSP_VALID_REQUIRES_PEND: legal traffic that the
# rule must NOT report.
#
# E section 14.4 / D section 13.4 permit a transmitter to "assert and then
# deassert this signal without sending a flit", and permit holding it
# permanently asserted, and permit asserting it while holding no L-Credit. The
# obligation runs the other way -- from the flit backwards -- so a lone FLITPEND
# owes nothing.
#
# This test was a NEGATIVE control until the rule was corrected. It drove the
# same stimulus and asserted that each channel reported exactly one violation,
# because the rule then read `flitpend |-> flitv` and this pulse tripped it. The
# suite therefore asserted that legal CHI traffic must be reported as a
# violation, and passed for doing so. The stimulus was always right; only the
# expected verdict was backwards, so the knob and the pulse are kept and the
# assertions inverted.
#
# cfg.flitpend_without_valid pulses FLITPEND on REQ and RSP for one cycle with
# no flit behind it, once, after the link is up. Both halves are asserted:
#   * neither rule may report at all -- the pulse is permitted;
#   * ordinary traffic afterwards must still be judged, or a run that checked
#     nothing would pass this test just as well.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_REQ_C = "CHI_REQ_VALID_REQUIRES_PEND"
_RSP_C = "CHI_RSP_VALID_REQUIRES_PEND"
_DAT_C = "CHI_DAT_VALID_REQUIRES_PEND"

ADDR_C = 0x3E00_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_flitpend_without_valid(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.flitpend_without_valid = True

  async def run_phase(self):
    self.raise_objection()

    rni = self.tb_env.rni_sva

    # A write, not a read: the requester transmits a REQ flit and then the
    # WriteData beats, so all three rules are exercised on well-formed traffic
    # after the lone pulse. A read would leave the RSP side untouched.
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_exp_comp_ack(True)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    # The pulse is permitted, so nothing may be reported for it.
    for rule in (_REQ_C, _RSP_C, _DAT_C):
      fails = rni.fail_count.get(rule, 0)
      assert fails == 0, (
        f"{rule} reported {fails} time(s) against a FLITPEND pulse that E "
        f"section 14.4 explicitly permits")

    # ...and the run has to have judged something, or a checker that never ran
    # would satisfy the assertions above just as well as a correct one.
    for rule in (_REQ_C, _RSP_C, _DAT_C):
      passes = rni.pass_count.get(rule, 0)
      assert passes > 0, (
        f"{rule} recorded no passes, so this run says nothing about the rule "
        f"holding on the flits the write drove")

    self.logger.info(
      "Test (tc_chi_flitpend_without_valid) PASS: a lone FLITPEND on REQ and "
      "RSP was not reported, and the write that followed was judged on all "
      "three channels")
    self.drop_objection()
