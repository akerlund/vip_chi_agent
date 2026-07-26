################################################################################
# pyUVM port of tc/chi_coh_make_unique_negctl_base_test.sv.
#
# Negative control (F1): force snoop suppression, RN-F0 ReadUniques a line (-> UC),
# then RN-F1 MakeUniques it. With snoops suppressed, RN-F0 keeps UC while RN-F1 is
# granted Unique-Dirty -> a duplicate Unique owner Checker D MUST flag via the
# MakeUnique RSP-only ownership path. Proves that path is not vacuous.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher
from vip_chi_makeunique_seq import vip_chi_makeunique_seq


class chi_coh_make_unique_negctl_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_suppress_snoops = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    catcher = chi_coherency_negctl_catcher("coh_violation_catcher")
    self.tb_env.coh_checker.logger.addFilter(catcher)

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()

    mu_seq = vip_chi_makeunique_seq("hrnf1_mu_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(mu_seq)
    await mu_seq.start(self.tb_env.hrnf1_agent.sequencer)
    mu_seq.get_responses()

    await self.wait_clocks(8)
    self.tb_env.coh_checker.logger.removeFilter(catcher)

    assert catcher.saw_coherency_error, \
      "Checker D did NOT flag the duplicate Unique owner from MakeUnique (F1 vacuous)"
    assert self.tb_env.coh_checker.get_multi_owner_count() > 0, \
      "Checker D multi-owner counter is zero despite the induced MakeUnique violation"

    self.logger.info(
      "Test (coh_make_unique_negctl) PASS: Checker D flagged the MakeUnique "
      "duplicate Unique owner (F1)")
    self.drop_objection()
