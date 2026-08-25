################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# The negative control for the DoNotGoToSD obedience rule.
#
# IHI 0050 E: "Snoopee receiving a Snoop request with the DoNotGoToSD bit set,
# except when the Snoop is SnpOnceFwd, must not transition to SD." The SNP
# channel already has CHI_SNP_DO_NOT_GO_TO_SD_LEGAL, which judges whether the
# bit was SET where the specification requires it. This is the other half --
# whether the snoopee OBEYED it -- and that is the half a third-party DUT can
# get wrong.
#
# Why it takes a control rather than a mutation. The RN-F responder cannot
# produce SD at all: its state map returns only I, SC or the current state,
# which is this VIP's never-SD reduction. So the rule had nothing in the
# regression that could exercise it, and a rule nothing can exercise is
# indistinguishable from one that is absent. cfg.rnf_snp_resp_sd_negctl makes
# the snoopee REPORT SD -- the shadow is untouched, because what the rule judges
# is the response.
#
# Neither neighbouring rule catches this, which is why it needed its own arm:
# catalogue D5 bounds the reported state by the snoop OPCODE and SD is not
# Unique, so a shared snoop answered SD passes it; D6 bounds the state by what
# the snoopee HELD, and an SD holder answering SD passes that too.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher
from chi_tb_pkg import WRITE_READ_ADDR_C

SETTLE_C = 40


class chi_coh_do_not_go_to_sd_negctl_base_test(chi_coherent_base_test):

  # Whether the home's snoop carries DoNotGoToSD on this cut, and therefore
  # whether the rule must fire. The two issues answer differently and BOTH
  # answers are asserted, because that is what shows the rule reads the bit
  # rather than reporting SD unconditionally:
  #
  #   Issue E  13.10.35 lists the invalidating snoops and SnpCleanShared as
  #            must-be-one, so the bit IS set and a snoopee reporting SD is
  #            violating it -- the rule must report.
  #   Issue D  12.9.32 lets the same bit take any value, so the cleared bit is
  #            CONFORMANT and SD is a legal answer -- the rule must stay silent.
  #
  # A control that only ran on E would pass equally well against a rule that
  # ignored the bit and fired on every SD.
  EXPECT_REPORT_C = True

  def configure_agent_cfgs(self):
    super().configure_agent_cfgs()
    self.hrnf0_cfg.rnf_snp_resp_sd_negctl = True

  async def run_phase(self):
    self.raise_objection()

    coh = self.tb_env.coh_checker

    # The provocation is declared, not merely provoked. Checker D's violations
    # are in the env's verdict, so a control that induces one and says nothing
    # fails on its own stimulus; the catcher demotes exactly what this test asked
    # for and counts it, and the count is held against the rule tallies below.
    catcher = chi_coherency_negctl_catcher("coh_do_not_go_to_sd_catcher")
    coh.logger.addFilter(catcher)

    before = coh.n_bad_snp_sd_under_no_sd
    # The rules that judge the same response beside the target one. This cut
    # makes the snoopee report a state its own shadow never reaches, so their
    # reports are collateral of the injection rather than independent findings --
    # counted, so the catcher's total below is accounted for rather than absorbed.
    #
    # D6 is named explicitly because it is easy to miss: in the checker's report
    # it sits between two OBSERVATIONAL counters, and a cross-check that took the
    # violation set from their neighbourhood rather than from what actually
    # reports would come up short by exactly this rule.
    state_before = coh.n_bad_snp_resp_state
    form_before = coh.n_bad_snp_resp_form
    gains_before = coh.n_snp_resp_gains_permission
    assert before == 0, (
      f"the DoNotGoToSD obedience rule already reported {before} time(s) before "
      f"the control ran; the count below would prove nothing")

    # RN-F0 takes the line, so RN-F1's read has something to snoop it for. The
    # home's snoop carries DoNotGoToSD per E 13.10.35, and RN-F0 answers SD.
    self.cfg_read_seq(self.hrnf0_rdshared_seq, WRITE_READ_ADDR_C)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)

    self.cfg_read_seq(self.hrnf1_rdunique_seq, WRITE_READ_ADDR_C)
    await self.hrnf1_rdunique_seq.start(self.tb_env.hrnf1_agent.sequencer)

    await self.wait_clocks(SETTLE_C)

    coh.logger.removeFilter(catcher)

    after = coh.n_bad_snp_sd_under_no_sd
    collateral = ((coh.n_bad_snp_resp_state - state_before) +
                  (coh.n_bad_snp_resp_form - form_before) +
                  (coh.n_snp_resp_gains_permission - gains_before))

    # Every demoted report is one of the four tallies, and every movement in
    # those tallies produced a report. A mismatch either way means the control is
    # not measuring what it claims to.
    assert catcher.claimed == (after - before) + collateral, (
      f"the catcher demoted {catcher.claimed} report(s) but the rule tallies "
      f"moved by {(after - before) + collateral}: either a report escaped the "
      f"catcher or a tally moved without one")

    if self.EXPECT_REPORT_C:
      assert after > before, (
        f"the snoopee reported SD under a set DoNotGoToSD and nothing said so. "
        f"Either the control is not reaching the responder, or the rule is not "
        f"reading the bit off the snoop that caused the response")
    else:
      assert after == before, (
        f"the rule reported {after - before} time(s) on a cut where the snoop's "
        f"DoNotGoToSD is legitimately CLEAR: D 12.9.32 lets the bit take any "
        f"value, so SD is a conformant answer here. A rule that fires anyway is "
        f"reading the state and not the bit")

    self.logger.info(
      f"Test (coh_do_not_go_to_sd_negctl) PASS: a snoopee reporting SD was "
      f"reported {after - before} time(s), and this cut "
      f"{'sets' if self.EXPECT_REPORT_C else 'does not set'} DoNotGoToSD")

    self.drop_objection()
