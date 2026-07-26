################################################################################
# pyUVM port of tc/chi_coh_negctl_base_test.sv.
#
# Negative control: force the HN-F to suppress snoops, then have both RN-Fs
# ReadUnique the same line -> a duplicate Unique owner. Checker D MUST flag it
# (COHERENCY VIOLATION); the demoting catcher records the intentional error and
# the multi-owner counter must be non-zero. Proves the single-writer invariant is
# not vacuous.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher


class chi_coh_negctl_base_test(chi_coherent_base_test):

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
    self.cfg_read_seq(self.hrnf1_rdunique_seq)
    await self.hrnf1_rdunique_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdunique_seq.get_responses()

    await self.wait_clocks(8)
    self.tb_env.coh_checker.logger.removeFilter(catcher)

    assert catcher.saw_coherency_error, \
      "Checker D did NOT flag the duplicate Unique owner (vacuous or disconnected)"
    assert self.tb_env.coh_checker.get_multi_owner_count() > 0, \
      "Checker D multi-owner counter is zero despite the induced violation"

    self.logger.info(
      "Test (coh_negctl) PASS: Checker D flagged the duplicate Unique owner")
    self.drop_objection()
