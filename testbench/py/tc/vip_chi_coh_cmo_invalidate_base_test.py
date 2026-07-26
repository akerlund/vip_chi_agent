################################################################################
# pyUVM port of tc/vip_chi_coh_cmo_invalidate_base_test.sv.
#
# CleanInvalid: both RN-Fs take the line Shared, RN-F0 CleanInvalids it (RSP-only
# Comp, a snoop originated, all copies invalidated). MakeInvalid: re-acquire Shared
# on both, RN-F1 MakeInvalids it (same). No coherency violations.
################################################################################

from __future__ import annotations

from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_cleaninvalid_seq import vip_chi_cleaninvalid_seq
from vip_chi_makeinvalid_seq import vip_chi_makeinvalid_seq
from vip_chi_tb_pkg import WRITE_READ_ADDR_C
from vip_chi_types_pkg import Resp


class vip_chi_coh_cmo_invalidate_base_test(vip_chi_coherent_base_test):

  def _check_line_invalidated(self, tag):
    hnf = self.tb_env.hnf_agent.hnf_driver
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      f"{tag}: RN-F0 cache not Invalid after CMO"
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      f"{tag}: RN-F1 cache not Invalid after CMO"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 0) == int(Resp.I), \
      f"{tag}: directory port0 not Invalid after CMO"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.I), \
      f"{tag}: directory port1 not Invalid after CMO"

  async def _both_read_shared(self):
    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdshared_seq.get_responses()
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # --- CleanInvalid ---
    await self._both_read_shared()
    snoops_before = self.tb_env.coh_checker.get_snoop_count()
    ci_seq = vip_chi_cleaninvalid_seq("hrnf0_ci_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(ci_seq)
    await ci_seq.start(self.tb_env.hrnf0_agent.sequencer)
    ci_rsp = ci_seq.get_responses()
    await self.wait_clocks(8)

    assert len(ci_rsp) == 1, f"CleanInvalid expected 1 completion, got {len(ci_rsp)}"
    assert len(ci_rsp[0].data) == 0, \
      f"CleanInvalid returned {len(ci_rsp[0].data)} data beats, expected 0"
    assert self.tb_env.coh_checker.get_snoop_count() > snoops_before, \
      "CleanInvalid originated no snoop"
    self._check_line_invalidated("CleanInvalid")

    # --- MakeInvalid ---
    await self._both_read_shared()
    snoops_before = self.tb_env.coh_checker.get_snoop_count()
    mi_seq = vip_chi_makeinvalid_seq("hrnf1_mi_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(mi_seq)
    await mi_seq.start(self.tb_env.hrnf1_agent.sequencer)
    mi_rsp = mi_seq.get_responses()
    await self.wait_clocks(8)

    assert len(mi_rsp) == 1, f"MakeInvalid expected 1 completion, got {len(mi_rsp)}"
    assert len(mi_rsp[0].data) == 0, \
      f"MakeInvalid returned {len(mi_rsp[0].data)} data beats, expected 0"
    assert self.tb_env.coh_checker.get_snoop_count() > snoops_before, \
      "MakeInvalid originated no snoop"
    self._check_line_invalidated("MakeInvalid")

    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "coherency violations on legal CMO invalidation"

    self.logger.info("Test (coh_cmo_invalidate) PASS")
    self.drop_objection()
