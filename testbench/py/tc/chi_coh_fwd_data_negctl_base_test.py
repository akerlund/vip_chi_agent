################################################################################
# pyUVM port of tc/chi_coh_fwd_data_negctl_base_test.sv.
#
# Negative control: DCT forwarding + corrupt the relayed forwarded data. RN-F0
# ReadUniques, RN-F1 ReadShareds -> SnpSharedFwd, RN-F0 forwards its true data, but
# the home relays a corrupted copy to RN-F1 while the checker recorded the true
# forwarded data. Checker D MUST flag the coherent data mismatch.
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher


class chi_coh_fwd_data_negctl_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_enable_snoop_fwd = True
    self.hnf_cfg.hnf_corrupt_fwd_data = True

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

    await self.wait_clocks(8)
    self.tb_env.coh_checker.logger.removeFilter(catcher)

    assert catcher.saw_coherency_error, \
      "Checker D did NOT flag the corrupted forwarded data (vacuous fwd-integrity check)"
    assert self.tb_env.coh_checker.get_coherent_data_mismatch_count() > 0, \
      "Checker D data-mismatch counter is zero despite the induced corruption"

    self.logger.info(
      "Test (coh_fwd_data_negctl) PASS: Checker D flagged the corrupted forward")
    self.drop_objection()
