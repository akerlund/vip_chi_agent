################################################################################
# pyUVM port of tc/chi_coh_snf_writeback_readback_base_test.sv.
#
# Two-level hierarchy: RN-F0 ReadUniques (miss -> downstream ReadNoSnp), writes the
# line back (-> downstream WriteNoSnpFull, local image dropped), then RN-F1
# ReadShareds (miss again -> downstream ReadNoSnp). The re-fetched data must equal
# the written-back payload (differing from the original). Exactly 3 downstream
# REQs: ReadNoSnp / WriteNoSnpFull / ReadNoSnp. No violations.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode
from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_writeback_seq import vip_chi_writeback_seq


class chi_coh_snf_writeback_readback_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_downstream_en = True

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

    await self.wait_clocks(8)

    assert len(rdu_rsp) == 1 and len(wb_rsp) == 1 and len(rd_rsp) == 1, \
      f"expected 1/1/1 responses, got {len(rdu_rsp)}/{len(wb_rsp)}/{len(rd_rsp)}"
    assert len(wb_rsp[0].data) == len(rd_rsp[0].data) == len(rdu_rsp[0].data), \
      "beat-count mismatch"
    for i in range(len(rd_rsp[0].data)):
      assert int(rd_rsp[0].data[i]) == int(wb_rsp[0].data[i]), \
        f"beat {i} re-fetched 0x{int(rd_rsp[0].data[i]):x} != written-back 0x{int(wb_rsp[0].data[i]):x}"
    differs = any(int(rd_rsp[0].data[i]) != int(rdu_rsp[0].data[i])
                  for i in range(len(rd_rsp[0].data)))
    assert differs, "re-fetched data equals the original image - check is vacuous"

    dn_ops = []
    while self.tb_env.dsnf0_req_fifo.can_get():
      dn = await self.tb_env.dsnf0_req_fifo.get()
      dn_ops.append(int(dn.opcode))
    assert len(dn_ops) == 3, \
      f"SN-F saw {len(dn_ops)} downstream REQs, expected 3 (read/write/read)"
    assert dn_ops == [int(ReqOpcode.READ_NO_SNP), int(ReqOpcode.WRITE_NO_SNP_FULL),
                      int(ReqOpcode.READ_NO_SNP)], \
      f"downstream REQ sequence {[hex(o) for o in dn_ops]}, expected ReadNoSnp/WriteNoSnpFull/ReadNoSnp"

    assert (self.tb_env.coh_checker.get_multi_owner_count() == 0 and
            self.tb_env.coh_checker.get_coherent_data_mismatch_count() == 0), \
      "coherency violation on a legal writeback+refetch"

    self.logger.info("Test (coh_snf_writeback_readback) PASS")
    self.drop_objection()
