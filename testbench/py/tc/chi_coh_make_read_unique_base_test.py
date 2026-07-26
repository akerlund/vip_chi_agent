################################################################################
# pyUVM port of tc/tc_chi_coh_e_make_read_unique.sv (E-only standalone body).
#
# RN-F0 ReadShareds a line; RN-F1 MakeReadUniques it -- acquire Unique AND fetch
# data, snoop-invalidating RN-F0. Asserts MakeReadUnique granted UC with data,
# RN-F0 -> I, RN-F1 -> UC, directory {I, UC}, snoop observed, no violations.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_makereadunique_seq import vip_chi_makereadunique_seq
from chi_tb_pkg import WRITE_READ_ADDR_C


class chi_coh_make_read_unique_base_test(chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    shared_rsp = self.hrnf0_rdshared_seq.get_responses()

    mru_seq = vip_chi_makereadunique_seq("hrnf1_mru_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(mru_seq)
    await mru_seq.start(self.tb_env.hrnf1_agent.sequencer)
    mru_rsp = mru_seq.get_responses()

    assert len(shared_rsp) == 1 and len(mru_rsp) == 1, \
      f"expected 1+1 responses, got {len(shared_rsp)}/{len(mru_rsp)}"
    assert int(mru_rsp[0].rsp_resp) == int(Resp.UC), \
      f"MakeReadUnique granted 0x{int(mru_rsp[0].rsp_resp):x}, expected UC"
    assert len(mru_rsp[0].data) != 0, "MakeReadUnique completed with no data beats"

    await self.wait_clocks(8)

    hnf = self.tb_env.hnf_agent.hnf_driver
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F0 cache not I after invalidating snoop"
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.UC), \
      "RN-F1 cache not UC"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 0) == int(Resp.I), \
      "directory port0 not Invalid after MakeReadUnique grant to port1"
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.UC), \
      "directory port1 not UC after MakeReadUnique grant"
    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 never observed the invalidating snoop"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "coherency violations on a legal MakeReadUnique"

    self.logger.info("Test (coh_make_read_unique) PASS")
    self.drop_objection()
