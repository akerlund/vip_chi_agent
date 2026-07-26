################################################################################
# pyUVM port of tc/tc_chi_coh_e_cmo_negctl.sv (E-only standalone body).
#
# Negative control: force snoop suppression, RN-F0 ReadUniques (-> UC), then RN-F1
# MakeReadUniques the same line. With snoops suppressed RN-F0 keeps UC while RN-F1
# is granted Unique -> a duplicate Unique owner Checker D MUST flag. Proves the
# MakeReadUnique ownership path is not vacuous.
################################################################################

from __future__ import annotations

from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_coherency_negctl_catcher import vip_chi_coherency_negctl_catcher
from vip_chi_makereadunique_seq import vip_chi_makereadunique_seq


class vip_chi_coh_cmo_negctl_base_test(vip_chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_suppress_snoops = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    catcher = vip_chi_coherency_negctl_catcher("coh_violation_catcher")
    self.tb_env.coh_checker.logger.addFilter(catcher)

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()

    mru_seq = vip_chi_makereadunique_seq("hrnf1_mru_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(mru_seq)
    await mru_seq.start(self.tb_env.hrnf1_agent.sequencer)
    mru_seq.get_responses()

    await self.wait_clocks(8)
    self.tb_env.coh_checker.logger.removeFilter(catcher)

    assert catcher.saw_coherency_error, \
      "Checker D did NOT flag the duplicate Unique owner on MakeReadUnique (vacuous?)"
    assert self.tb_env.coh_checker.get_multi_owner_count() > 0, \
      "Checker D multi-owner counter is zero despite the induced violation"

    self.logger.info(
      "Test (coh_cmo_negctl) PASS: Checker D flagged the MakeReadUnique duplicate owner")
    self.drop_objection()
