################################################################################
# pyUVM port of tc/chi_coh_req_final_state_negctl_base_test.sv.
#
# Negative control for chi_coh_req_retain_base_test. RN-F1 is put back on the
# pre-Table-4-14 behaviour with cfg.rnf_req_final_state_verbatim: its final cache
# state becomes the granted Resp on its own, and the fetched beats overwrite
# whatever it held. Its dirty copy is then gone, so the snoop that follows is
# answered with NO data while the shadow still (correctly) holds UD.
#
# The line is acquired with MakeUnique rather than ReadUnique + make_line_dirty,
# and that choice is the whole scenario. A local store is SILENT: the checker
# cannot see it either, so a shadow built the honest way reads UC and rule D7 --
# which keys off the state the SHADOW believed the snoopee held -- has nothing to
# fire on. MakeUnique is the one path in this VIP that grants an OBSERVABLE
# Unique-Dirty, so it is the only way to give the checker a dirty snoopee to have
# an opinion about.
#
# Catalogue rule D7 MUST fire there: a snoopee holding Dirty has to hand the
# dirty data over unless it is keeping it, and this one has done neither. That is
# the whole reason D7 is worth having -- the reported STATE is legal (D5 and D6
# both pass SC from UD, and the response-form rule reads the other direction), so
# without D7 a silently discarded dirty line produces no violation anywhere.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher
from vip_chi_readclean_seq import vip_chi_readclean_seq
from vip_chi_makeunique_seq import vip_chi_makeunique_seq
from chi_tb_pkg import WRITE_READ_ADDR_C


class chi_coh_req_final_state_negctl_base_test(chi_coherent_base_test):

  # Put RN-F1 -- the requester under test -- back on the verbatim assignment.
  def configure_agent_cfgs(self):
    self.hrnf1_cfg.rnf_req_final_state_verbatim = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    catcher = chi_coherency_negctl_catcher("coh_violation_catcher")
    self.tb_env.coh_checker.logger.addFilter(catcher)

    dirty_pattern = int("5A" * self.chi_cfg.data_bytes, 16)

    mu_seq = vip_chi_makeunique_seq("hrnf1_mu_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(mu_seq)
    await mu_seq.start(self.tb_env.hrnf1_agent.sequencer)
    mu_seq.get_responses()

    self.tb_env.hrnf1_agent.rnf_driver.make_line_dirty(WRITE_READ_ADDR_C, dirty_pattern)

    rc_seq = vip_chi_readclean_seq("hrnf1_rdclean_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(rc_seq)
    await rc_seq.start(self.tb_env.hrnf1_agent.sequencer)
    rc_seq.get_responses()

    await self.wait_clocks(8)

    # The knob did what it says: RN-F1 took the granted SC verbatim. Asserted so
    # a future change that quietly stops honouring the knob turns into a failure
    # here rather than a negative control that silently tests nothing.
    rnf1_state = self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C)
    assert rnf1_state == int(Resp.SC), \
      f"RN-F1 cache 0x{rnf1_state:x}, expected the verbatim SC the " \
      f"negative-control knob induces"

    # Now make the home snoop it. The shadow still holds UD -- correctly, it
    # applied Table 4-14 -- so the data-less response is the dirty line going
    # missing.
    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdshared_seq.get_responses()

    await self.wait_clocks(8)
    self.tb_env.coh_checker.logger.removeFilter(catcher)

    assert catcher.saw_coherency_error, \
      "Checker D did NOT flag the discarded dirty copy -- catalogue rule D7 may " \
      "be vacuous"
    assert self.tb_env.coh_checker.get_snp_dirty_lost_count() > 0, \
      "D7 reported no dirty-copy loss, so the coherency error above came from a " \
      "different rule"

    self.logger.info(
      "Test (coh_req_final_state_negctl) PASS: Checker D flagged the dirty copy "
      "discarded by a verbatim final-state assignment")
    self.drop_objection()
