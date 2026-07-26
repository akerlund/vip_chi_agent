################################################################################
# pyUVM port of tc/chi_coh_data_negctl_base_test.sv.
#
# Negative control: force the HN-F to drop the dirty-forward merge, then RN-F0
# ReadUniques + dirties a line and RN-F1 ReadShareds it. The HN-F serves stale
# memory while the checker recorded the TRUE forwarded dirty data -> a data-
# integrity mismatch Checker D MUST flag. Proves the data-integrity check is not
# vacuous.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher
from chi_tb_pkg import WRITE_READ_ADDR_C


class chi_coh_data_negctl_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_corrupt_dirty_merge = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    catcher = chi_coherency_negctl_catcher("coh_data_violation_catcher")
    self.tb_env.coh_checker.logger.addFilter(catcher)

    dirty_pattern = int("5A" * self.chi_cfg.data_bytes, 16)

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()
    self.tb_env.hrnf0_agent.rnf_driver.make_line_dirty(WRITE_READ_ADDR_C, dirty_pattern)

    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()

    await self.wait_clocks(8)
    self.tb_env.coh_checker.logger.removeFilter(catcher)

    assert catcher.saw_coherency_error, \
      "Checker D did NOT flag the corrupted dirty forward (vacuous data-integrity check)"
    assert self.tb_env.coh_checker.get_coherent_data_mismatch_count() > 0, \
      "Checker D data-mismatch counter is zero despite the induced corruption"

    self.logger.info(
      "Test (coh_data_negctl) PASS: Checker D flagged the coherent data mismatch")
    self.drop_objection()
