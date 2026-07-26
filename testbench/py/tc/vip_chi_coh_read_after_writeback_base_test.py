################################################################################
# pyUVM port of tc/vip_chi_coh_read_after_writeback_base_test.sv.
#
# RN-F0 ReadUniques, writes a fresh payload back to the home, then RN-F1 reads the
# line Shared and must see the written-back data (differing from the original). No
# multi-owner violations.
################################################################################

from __future__ import annotations

from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_writeback_seq import vip_chi_writeback_seq
from vip_chi_tb_pkg import WRITE_READ_ADDR_C


class vip_chi_coh_read_after_writeback_base_test(vip_chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    rdu_rsp = self.hrnf0_rdunique_seq.get_responses()

    wb_seq = vip_chi_writeback_seq("hrnf0_wb_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(wb_seq)
    await wb_seq.start(self.tb_env.hrnf0_agent.sequencer)
    wb_rsp = wb_seq.get_responses()

    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    rd_rsp = self.hrnf1_rdshared_seq.get_responses()

    assert len(rdu_rsp) == 1 and len(wb_rsp) == 1 and len(rd_rsp) == 1, \
      f"expected 1/1/1 responses, got {len(rdu_rsp)}/{len(wb_rsp)}/{len(rd_rsp)}"
    assert len(wb_rsp[0].data) == len(rd_rsp[0].data) == len(rdu_rsp[0].data), \
      "beat-count mismatch"
    for i in range(len(rd_rsp[0].data)):
      assert int(rd_rsp[0].data[i]) == int(wb_rsp[0].data[i]), \
        f"beat {i} read-back 0x{int(rd_rsp[0].data[i]):x} != written 0x{int(wb_rsp[0].data[i]):x}"

    differs = any(int(rd_rsp[0].data[i]) != int(rdu_rsp[0].data[i])
                  for i in range(len(rd_rsp[0].data)))
    assert differs, "written data equals the original image - check is vacuous"
    assert self.tb_env.coh_checker.get_multi_owner_count() == 0, \
      "multi-owner violations"

    self.logger.info("Test (coh_read_after_writeback) PASS")
    self.drop_objection()
