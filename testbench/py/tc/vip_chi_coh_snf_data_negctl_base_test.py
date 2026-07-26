################################################################################
# pyUVM port of tc/vip_chi_coh_snf_data_negctl_base_test.sv.
#
# Negative control: two-level hierarchy + corrupt the downstream-fetched data the
# HN-F relays. A ReadShared misses -> the home fetches from the SN-F but corrupts
# the value it fills/relays, while the checker seeds the authoritative line data
# from the SN-F's TRUE CompData. Checker D MUST flag the coherent data mismatch.
################################################################################

from __future__ import annotations

from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_coherency_negctl_catcher import vip_chi_coherency_negctl_catcher


class vip_chi_coh_snf_data_negctl_base_test(vip_chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_downstream_en = True
    self.hnf_cfg.hnf_downstream_corrupt_data = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    catcher = vip_chi_coherency_negctl_catcher("coh_violation_catcher")
    self.tb_env.coh_checker.logger.addFilter(catcher)

    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdshared_seq.get_responses()

    await self.wait_clocks(8)
    self.tb_env.coh_checker.logger.removeFilter(catcher)

    assert catcher.saw_coherency_error, \
      "Checker D did NOT flag the corrupted downstream fetch (vacuous integrity seed)"
    assert self.tb_env.coh_checker.get_coherent_data_mismatch_count() > 0, \
      "Checker D data-mismatch counter is zero despite the induced corruption"

    self.logger.info(
      "Test (coh_snf_data_negctl) PASS: Checker D flagged the corrupted downstream fetch")
    self.drop_objection()
