################################################################################
# pyUVM port of tc/chi_coh_writeback_evict_base_test.sv.
#
# WriteBackFull path: RN-F0 ReadUniques then writes the line back -> directory
# port0 + RN-F0 cache Invalid. Evict path: RN-F1 ReadShareds then Evicts (RSP-only)
# -> directory port1 + RN-F1 cache Invalid. No multi-owner violations.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_writeback_seq import vip_chi_writeback_seq
from vip_chi_evict_seq import vip_chi_evict_seq
from chi_tb_pkg import WRITE_READ_ADDR_C


class chi_coh_writeback_evict_base_test(chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # WriteBackFull path.
    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()

    wb_seq = vip_chi_writeback_seq("hrnf0_wb_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(wb_seq)
    await wb_seq.start(self.tb_env.hrnf0_agent.sequencer)
    wb_rsp = wb_seq.get_responses()

    await self.wait_clocks(8)

    hnf = self.tb_env.hnf_agent.hnf_driver
    assert len(wb_rsp) == 1, f"expected 1 writeback response, got {len(wb_rsp)}"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 0) == int(Resp.I), \
      "directory port0 not Invalid after WriteBackFull"
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F0 cache not Invalid after WriteBackFull"

    # Evict path.
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()

    ev_seq = vip_chi_evict_seq("hrnf1_ev_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(ev_seq)
    await ev_seq.start(self.tb_env.hrnf1_agent.sequencer)
    ev_rsp = ev_seq.get_responses()

    await self.wait_clocks(8)

    assert len(ev_rsp) == 1, f"expected 1 evict response, got {len(ev_rsp)}"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.I), \
      "directory port1 not Invalid after Evict"
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F1 cache not Invalid after Evict"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "multi-owner violations on eviction traffic"

    self.logger.info("Test (coh_writeback_evict) PASS")
    self.drop_objection()
