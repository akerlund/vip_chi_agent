################################################################################
# pyUVM port of tc/vip_chi_coh_write_unique_base_test.sv.
#
# RN-F0 ReadShareds a line; RN-F1 WriteUniques a fresh payload -- the home must
# snoop-invalidate RN-F0. Asserts RN-F0 + RN-F1 Invalid, snoop observed, read-back
# equals the written data (differing from the original), no violations.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_writeunique_seq import vip_chi_writeunique_seq
from vip_chi_tb_pkg import WRITE_READ_ADDR_C


class vip_chi_coh_write_unique_base_test(vip_chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    rds_rsp = self.hrnf0_rdshared_seq.get_responses()

    wu_seq = vip_chi_writeunique_seq("hrnf1_wu_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(wu_seq)
    await wu_seq.start(self.tb_env.hrnf1_agent.sequencer)
    wu_rsp = wu_seq.get_responses()

    await self.wait_clocks(8)

    assert len(rds_rsp) == 1 and len(wu_rsp) == 1, \
      f"expected 1+1 responses, got {len(rds_rsp)}/{len(wu_rsp)}"
    assert self.tb_env.hrnf0_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F0 not invalidated by the WriteUnique snoop"
    assert self.tb_env.hrnf1_agent.rnf_driver.get_cache_state(WRITE_READ_ADDR_C) == int(Resp.I), \
      "RN-F1 cache not Invalid after WriteUnique (non-allocating)"
    assert self.tb_env.hrnf0_snp_fifo.can_get(), \
      "RN-F0 never observed the invalidating WriteUnique snoop"

    self.cfg_read_seq(self.hrnf0_rdshared_seq)
    await self.hrnf0_rdshared_seq.start(self.tb_env.hrnf0_agent.sequencer)
    rd_rsp = self.hrnf0_rdshared_seq.get_responses()
    assert len(rd_rsp) == 1, f"expected 1 read-back response, got {len(rd_rsp)}"

    assert len(wu_rsp[0].data) == len(rd_rsp[0].data) == len(rds_rsp[0].data), \
      "beat-count mismatch"
    for i in range(len(rd_rsp[0].data)):
      assert int(rd_rsp[0].data[i]) == int(wu_rsp[0].data[i]), \
        f"beat {i} read-back 0x{int(rd_rsp[0].data[i]):x} != written 0x{int(wu_rsp[0].data[i]):x}"

    differs = any(int(rd_rsp[0].data[i]) != int(rds_rsp[0].data[i])
                  for i in range(len(rd_rsp[0].data)))
    assert differs, "written data equals the original image - check is vacuous"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "coherency violations on a legal WriteUnique"

    self.logger.info("Test (coh_write_unique) PASS")
    self.drop_objection()
