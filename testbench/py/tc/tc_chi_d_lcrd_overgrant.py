################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_lcrd_overgrant.sv.
#
# Negative control for the L-Credit overflow rule, which could not fire before.
#
# IHI 0050 E 14.2.1 / D 13.2.1: "The minimum number of L-Credits that a receiver
# can provide is one. The maximum number of L-Credits that a receiver can provide
# is 15." One LCRDV signal per channel, so the bound is per channel.
#
# The checker's bound was 64 -- a number the specification does not contain --
# and the comment beside it said as much, describing it as a bound on "the shadow
# counter, not the protocol". At 64 the rule was a false NEGATIVE: a receiver
# advertising 16 through 64 credits on a channel was over-granting, and every one
# of those grants was reported as fine. Nothing in the regression advertised more
# than 8, so the rule had also never been asked.
#
# This test asks it. The SN-F advertises 16 REQ receive credits after link
# activation, one more than the protocol permits, and the sixteenth grant must be
# reported at BOTH vantages -- the RN-I counting the grants that arrive and the
# SN-F counting the grants it emits.
#
# Exactly one report, not "at least one": the fifteen legal grants that precede
# it must not be flagged, and the rule must not keep firing afterwards on a link
# that then carries ordinary traffic.
#
# The cfg validator deliberately still ACCEPTS 16. A configuration that could not
# express an over-granting receiver could not model a broken peer, and then this
# control could not exist.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_RULE_C = "CHI_LCRD_OVERFLOW"
ADDR_C = 0x3F00_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 40
EXPECTED_FAILS_C = 1            # one over-grant, so one report per vantage
OVERGRANT_C = 16                # the protocol maximum is 15


class tc_chi_d_lcrd_overgrant(chi_base_test):

  # Over-advertise on REQ only, so the other two channels stay conformant and any
  # report from them would be a separate defect rather than this stimulus.
  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.initial_req_credits = OVERGRANT_C

  async def run_phase(self):
    self.raise_objection()

    rni, snf = self.tb_env.rni_sva, self.tb_env.snf_sva

    # Suppress the report, keep the count, at both ends: both are about to be
    # made to fail by the same sixteenth grant.
    rni.off_check(_RULE_C)
    snf.off_check(_RULE_C)

    # Let the whole initial advertisement land before any flit consumes a credit,
    # or the count would never reach the bound.
    await self.wait_clocks(SETTLE_C)

    rni_fails = rni.fail_count.get(_RULE_C, 0)
    snf_fails = snf.fail_count.get(_RULE_C, 0)
    rni_passes = rni.pass_count.get(_RULE_C, 0)

    assert rni_passes > 0, (
      f"{_RULE_C} recorded no passes at all; the credit accounting is not "
      f"running and the count below would mean nothing")

    assert rni_fails == EXPECTED_FAILS_C, (
      f"{_RULE_C} reported {rni_fails} time(s) at the RN-I against one "
      f"over-grant, expected exactly {EXPECTED_FAILS_C}; below means the bound "
      f"is still above the protocol maximum of 15, above means the legal grants "
      f"are being flagged too")

    assert snf_fails == EXPECTED_FAILS_C, (
      f"{_RULE_C} reported {snf_fails} time(s) at the SN-F, expected exactly "
      f"{EXPECTED_FAILS_C}; the emitting vantage is not counting its own grants")

    # The link must still work on the credits it legally has. An over-granting
    # peer is a reportable defect, not a reason for the requester to stop.
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    assert rni.fail_count.get(_RULE_C, 0) == EXPECTED_FAILS_C, (
      f"{_RULE_C} kept firing after the over-grant, on traffic that spends "
      f"credits rather than granting them")

    self.logger.info(
      f"Test (tc_chi_d_lcrd_overgrant) PASS: a receiver advertising "
      f"{OVERGRANT_C} REQ credits was reported once at each vantage "
      f"({rni_passes} legal grants passed first), and the link then carried a "
      f"read to completion")
    self.drop_objection()
