################################################################################
# pyUVM port of tc/tc_chi_coh_d_wr_direction.sv (D-only standalone body).
#
# RN-F0 ReadUniques then WriteBackFulls a line. Verify the monitored WriteBackFull
# REQ item and its CopyBackWrData DAT item both carry direction WRITE (P3).
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Dir, ReqOpcode, DatOpcode
from vip_chi_coherent_base_test import vip_chi_coherent_base_test
from vip_chi_writeback_seq import vip_chi_writeback_seq


class vip_chi_coh_wr_direction_base_test(vip_chi_coherent_base_test):

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    self.hrnf0_rdunique_seq.get_responses()

    wb_seq = vip_chi_writeback_seq("hrnf0_wb_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(wb_seq)
    await wb_seq.start(self.tb_env.hrnf0_agent.sequencer)
    wb_seq.get_responses()

    await self.wait_clocks(8)

    saw_wb_req = False
    while self.tb_env.hrnf0_req_fifo.can_get():
      it = await self.tb_env.hrnf0_req_fifo.get()
      if int(it.opcode) == int(ReqOpcode.WRITE_BACK_FULL):
        saw_wb_req = True
        assert int(it.direction) == int(Dir.WRITE), \
          "P3(a): WriteBackFull REQ direction is not WRITE"
    assert saw_wb_req, "P3(a): never observed a WriteBackFull REQ item"

    saw_cbwd_dat = False
    while self.tb_env.hrnf0_dat_fifo.can_get():
      it = await self.tb_env.hrnf0_dat_fifo.get()
      if int(it.dat_opcode) == int(DatOpcode.COPY_BACK_WR_DATA):
        saw_cbwd_dat = True
        assert int(it.direction) == int(Dir.WRITE), \
          "P3(b): CopyBackWrData DAT direction is not WRITE"
    assert saw_cbwd_dat, "P3(b): never observed a CopyBackWrData DAT item"

    self.logger.info("Test (coh_wr_direction) PASS")
    self.drop_objection()
