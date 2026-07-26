################################################################################
# pyUVM port of tc/chi_coh_dirty_forward_base_test.sv.
#
# RN-F0 ReadUniques + dirties a line; RN-F1 ReadShareds it. The home snoop-
# downgrades RN-F0 (SnpShared), RN-F0 forwards its dirty data (SnpRespData, merged
# to memory), and the CompData to RN-F1 carries the dirtied value. Both end SC.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C


class chi_coh_dirty_forward_base_test(chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    dirty_pattern = int("A5" * self.chi_cfg.data_bytes, 16)

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    unique_rsp = self.hrnf0_rdunique_seq.get_responses()
    self.tb_env.hrnf0_agent.rnf_driver.make_line_dirty(WRITE_READ_ADDR_C, dirty_pattern)

    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    shared_rsp = self.hrnf1_rdshared_seq.get_responses()

    assert len(unique_rsp) == 1 and len(shared_rsp) == 1, \
      f"expected 1+1 responses, got {len(unique_rsp)}/{len(shared_rsp)}"
    assert int(shared_rsp[0].rsp_resp) == int(Resp.SC), \
      f"ReadShared granted 0x{int(shared_rsp[0].rsp_resp):x}, expected SC"
    assert len(unique_rsp[0].data) == len(shared_rsp[0].data), "beat-count mismatch"
    for i in range(len(shared_rsp[0].data)):
      exp = int(unique_rsp[0].data[i]) ^ dirty_pattern
      assert int(shared_rsp[0].data[i]) == exp, \
        f"beat {i} forwarded 0x{int(shared_rsp[0].data[i]):x}, expected dirtied 0x{exp:x}"

    await self.wait_clocks(8)

    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.SC), \
      "RN-F0 cache not SC after passing dirty data"
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.SC), \
      "RN-F1 cache not SC"
    assert self.tb_env.hrnf0_snp_fifo.can_get(), "RN-F0 never observed the downgrading snoop"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "multi-owner violations on a legal dirty transfer"

    self.logger.info("Test (coh_dirty_forward) PASS")
    self.drop_objection()
