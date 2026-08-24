################################################################################
# pyUVM/cocotb port of tc/tc_chi_lasm_output_race_negctl.sv.
#
# Negative control for E section 14.6.3 / D 13.6.3's SECOND ordering.
#
# The section states ONE relationship -- "Output X must change after or at the
# same time as output Y, but it is not permitted to change before output Y" --
# and instantiates it four times on a component's own two LINKACTIVE outputs. All
# four report under one check id, CHI_LASM_OUTPUT_RACE, because they are one
# statement about one pair of signals.
#
# That single id is what makes this test necessary. Three of the four are
# provoked elsewhere: tc_chi_lasm_illegal_transition's aborted activation reaches
# the FOURTH and then the FIRST, and tc_chi_lasm_race's tear-down window reaches
# the THIRD. Nothing reached the SECOND:
#
#   "The deassertion of RXACK must not occur before the deassertion of TXREQ."
#
# So the rule read as exercised in the vacuity report while a quarter of it had
# never once failed -- the cost of the one-id decision, worth paying only if the
# gap is closed rather than left implicit.
#
# cfg.lasm_ack_falls_first has the completer drop its acknowledge once while its
# own request is still asserted: the banned step directly, with no peer behaviour
# involved. It is a genuine violation rather than stimulus tuned to the check --
# the acknowledge is the answer to a request this component is still making.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_base_test import chi_base_test

_RACE_RULE_C = "CHI_LASM_OUTPUT_RACE"
_TRANS_RULE_C = "CHI_LASM_LEGAL_TRANSITION"
_HOLD_RULE_C = "CHI_LASM_INPUT_RACE_HOLD"

# One dropped acknowledge is one banned step, at the bind whose outputs they are.
# The requester reports NONE: 14.6.3 constrains each component's OWN pair, and
# observing a peer's two inputs arrive out of order is expressly permitted --
# that is the Async Input Race, and it is a different rule.
_RACE_REPORTS_RNI_C = 0
_RACE_REPORTS_SNF_C = 1
# The same step is also an illegal transition, and BOTH ends see it.
_TRANS_REPORTS_C = 1

ADDR_C = 0x3F00_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_lasm_output_race_negctl(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.lasm_ack_falls_first = True

  def connect_phase(self):
    super().connect_phase()
    for checker in (self.tb_env.rni_sva, self.tb_env.snf_sva):
      checker.expect_failure(_RACE_RULE_C)
      checker.expect_failure(_TRANS_RULE_C)
      checker.expect_failure(_HOLD_RULE_C)

  async def run_phase(self):
    self.raise_objection()

    # Traffic, so the link is genuinely up when the acknowledge is dropped -- the
    # banned step has to happen on a running link, not during bring-up.
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    rni = self.tb_env.rni_sva
    snf = self.tb_env.snf_sva

    rni_race = rni.fail_count.get(_RACE_RULE_C, 0)
    snf_race = snf.fail_count.get(_RACE_RULE_C, 0)
    assert rni_race == _RACE_REPORTS_RNI_C and snf_race == _RACE_REPORTS_SNF_C, (
      f"the dropped acknowledge produced {rni_race} (RN-I) / {snf_race} (SN-F) "
      f"banned-output-race report(s), expected exactly {_RACE_REPORTS_RNI_C} / "
      f"{_RACE_REPORTS_SNF_C}; zero at the completer means the second ordering "
      f"is still unprovoked, which is the gap this test exists to close")

    # The rule must have PASSED as well -- available here where the input-race
    # control could not offer it, because the ordering rules evaluate on every
    # real edge of either output, so a link that came up and ran has passed them
    # many times. A rule reporting on everything would show no passes at all.
    assert snf.pass_count.get(_RACE_RULE_C, 0) > 0, (
      "the output-race rule recorded no passes at the completer, so the one "
      "failure cannot be distinguished from a rule that fires on every edge")

    # One banned step, THREE reports, and the decomposition is the point. The
    # acknowledge falls while the request is still up, so {1,1} -> {1,0}: that is
    # RUN -> ACTIVATE, which the one-way cycle forbids, and it is off-axis on the
    # completer's TRANSMIT machine and on the requester's RECEIVE machine -- the
    # same handshake seen from both ends.
    #
    # The two rules are NOT redundant, and this is the cleanest place to see why.
    # The transition rule says the state moved backwards; the output-race rule
    # says WHICH OF THE TWO OUTPUTS moved first, and so which component is at
    # fault. A monitor at a midpoint can see the state step without being able to
    # attribute it -- 14.6.3 says as much -- and only the ordering rule answers
    # that, which is why it reports at the completer alone while the transition
    # reports at both.
    rni_trans = rni.fail_count.get(_TRANS_RULE_C, 0)
    snf_trans = snf.fail_count.get(_TRANS_RULE_C, 0)
    assert rni_trans == _TRANS_REPORTS_C and snf_trans == _TRANS_REPORTS_C, (
      f"the dropped acknowledge produced {rni_trans} (RN-I) / {snf_trans} "
      f"(SN-F) illegal-transition report(s), expected exactly "
      f"{_TRANS_REPORTS_C} at each end")

    # The observer half, bounded rather than ignored. The requester sees the
    # completer's pair arrive out of order and must hold its own outputs; it
    # does, so this is zero -- and a non-zero count would mean the hold fixed in
    # the same phase as this rule had regressed.
    rni_hold = rni.fail_count.get(_HOLD_RULE_C, 0)
    snf_hold = snf.fail_count.get(_HOLD_RULE_C, 0)
    assert rni_hold == 0 and snf_hold == 0, (
      f"the observer hold reported {rni_hold} (RN-I) / {snf_hold} (SN-F) "
      f"violation(s) where none was expected; a component that sees a peer's "
      f"outputs arrive out of order must wait for both before moving its own")

    self.logger.info(
      f"Test (tc_chi_lasm_output_race_negctl) PASS: an acknowledge dropped "
      f"ahead of its own request was flagged {snf_race} time(s) at the "
      f"completer and {rni_race} at the requester, and the link carried a read "
      f"to completion")
    self.drop_objection()
