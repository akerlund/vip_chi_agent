################################################################################
# pyUVM port of tc/chi_coh_excl_negctl_base_test.sv.
#
# Negative control: force the HN-F to claim exclusive success regardless of the
# monitor. RN-F0 LL, RN-F1 WriteUnique (breaks the reservation), RN-F0 SC -> the
# home falsely reports ExclOkay. Checker D (self-derived monitor) MUST flag the
# EXCLUSIVE VIOLATION. Proves the exclusive invariant is not vacuous (needs the
# RSP stream).
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher
from vip_chi_excl_load_seq import vip_chi_excl_load_seq
from vip_chi_excl_store_seq import vip_chi_excl_store_seq
from vip_chi_writeunique_seq import vip_chi_writeunique_seq


class chi_coh_excl_negctl_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_force_excl_success = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    catcher = chi_coherency_negctl_catcher("coh_violation_catcher")
    self.tb_env.coh_checker.logger.addFilter(catcher)

    ll_seq = vip_chi_excl_load_seq("hrnf0_ll_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(ll_seq)
    await ll_seq.start(self.tb_env.hrnf0_agent.sequencer)
    ll_seq.get_responses()

    wu_seq = vip_chi_writeunique_seq("hrnf1_wu_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(wu_seq)
    await wu_seq.start(self.tb_env.hrnf1_agent.sequencer)
    wu_seq.get_responses()

    sc_seq = vip_chi_excl_store_seq("hrnf0_sc_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(sc_seq)
    await sc_seq.start(self.tb_env.hrnf0_agent.sequencer)
    sc_seq.get_responses()

    await self.wait_clocks(8)
    self.tb_env.coh_checker.logger.removeFilter(catcher)

    assert catcher.saw_coherency_error, \
      "Checker D did NOT flag the false SC success (exclusive invariant vacuous?)"
    assert self.tb_env.coh_checker.get_excl_violation_count() > 0, \
      "Checker D exclusive-violation counter is zero despite the induced false success"

    self.logger.info(
      "Test (coh_excl_negctl) PASS: Checker D flagged the false SC success")
    self.drop_objection()
