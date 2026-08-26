################################################################################
# pyUVM port of tc/chi_coh_snp_query_negctl_base_test.sv.
#
# Negative control for catalogue rule D10, the state-preserving snoop.
#
# IHI 0050 E 4.5, SnpQuery: "The SnpQuery snoop must not change the state of the
# cache line at the Snoopee." cfg.rnf_snp_query_mutates_negctl makes RN-F0
# invalidate the line under the query and answer SnpResp_I, which is a
# self-consistent response: it reports exactly what the responder did.
#
# That self-consistency is what makes it a control and not merely a broken flit.
# The other snoop-response rules bound the answer from above and all of them pass
# it. D5 bounds it by what the opcode asked for, and a query asks for nothing.
# D6 bounds it by what the snoopee held, and I claims less rather than more. D7
# wants a dirty copy accounted for and excludes the snoops that return no data,
# which is the set SnpQuery is in. A line can therefore be lost to a query with
# every other rule agreeing, which is the gap D10 was written for -- so the test
# asserts not only that a violation was reported but that this rule reported it.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher
from chi_tb_pkg import WRITE_READ_ADDR_C

_SETTLE_C = 16


class chi_coh_snp_query_negctl_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_snp_query_enable = True
    self.hrnf0_cfg.rnf_snp_query_mutates_negctl = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    catcher = chi_coherency_negctl_catcher("coh_violation_catcher")
    self.tb_env.coh_checker.logger.addFilter(catcher)

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()

    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()

    await self.wait_clocks(_SETTLE_C)
    self.tb_env.coh_checker.logger.removeFilter(catcher)

    checker = self.tb_env.coh_checker
    judged = checker.get_snp_preserving_judged_count()
    assert judged > 0, \
      "D10 judged no response, so the control had nothing to corrupt"

    assert catcher.saw_coherency_error, (
      "the checker did NOT flag a snoopee that moved its line under a snoop "
      "forbidden to change it -- catalogue rule D10 may be vacuous")

    bad = checker.get_bad_snp_state_preserved_count()
    assert bad > 0, (
      "D10 counted no violation, so the coherency error above came from a "
      "different rule")

    # And nothing ELSE reported. This is the claim the docstring above makes and
    # the one worth proving: if some other rule also fired, D10 could be removed
    # tomorrow and this test would still pass, which is the shape of a rule that
    # looks exercised and is not.
    assert catcher.claimed == bad, (
      f"another coherency rule reported alongside D10 ({catcher.claimed} "
      f"coherency errors for {bad} preserved-state failures); the control is no "
      f"longer isolating the one property under test")

    # The home's reconciliation, held against the same number. It is not a second
    # opinion on D10: D10 reads the response off the wire, this compares the
    # answer with a directory the checker never sees, and the control moves both
    # at once. Asserting the count rather than the fact is what makes it evidence
    # -- a home that had stopped comparing would show zero here while D10 went on
    # passing. Inherent collateral, declared: a snoopee that drops the line under
    # a query necessarily desynchronises the filter the query was sent to
    # confirm, so the two are the same event seen from the two ends.
    hnf = self.tb_env.hnf_agent.hnf_driver
    assert hnf.n_snp_query_dir_mismatch == bad, (
      f"the home reported {hnf.n_snp_query_dir_mismatch} SnpQuery/directory "
      f"mismatch(es) for {bad} preserved-state failures; a snoopee that moved "
      f"under the query desynchronises the filter by construction, so the two "
      f"must agree")

    self.logger.info(
      f"Test (coh_snp_query_negctl) PASS: D10 reported {bad} of {judged} "
      f"judged response(s), as the negative control intended")
    self.drop_objection()
