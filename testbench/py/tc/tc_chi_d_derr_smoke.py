################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_derr_smoke.sv.
#
# A priming write (NormalOkay, commits) then a read to a DERR-configured SN-F
# address: the read completion + every DAT beat carry DERR while still returning
# the committed data.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, DataType, RespErr
from chi_base_test import chi_base_test
from chi_tb_pkg import DERR_ADDR_C


class tc_chi_d_derr_smoke(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.add_derr_range(DERR_ADDR_C, DERR_ADDR_C + 0x3F)

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(DERR_ADDR_C)
    wr.set_size(6)
    wr.set_data_type(DataType.COUNTER)
    wr.set_counter_value(0x70)
    wr.set_counter_increment(0x1)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(DERR_ADDR_C)
    rd.set_size(6)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    write_responses = wr.get_responses()
    read_responses = rd.get_responses()

    await self.tb_env.rni_dat_fifo.get()               # write DAT (RN-I)
    dat_item = await self.tb_env.rni_dat_fifo.get()    # read DAT (SN-F)

    assert len(write_responses) == 1 and len(read_responses) == 1
    assert int(write_responses[0].rsp_resp_err) == int(RespErr.OKAY)
    assert int(read_responses[0].rsp_resp_err) == int(RespErr.DERR)

    for i in range(len(read_responses[0].data)):
      assert int(read_responses[0].dat_resp_err[i]) == int(RespErr.DERR)
      assert int(read_responses[0].data[i]) == (0x70 + i)

    assert int(dat_item.role) == int(Role.SNF)
    for i in range(len(dat_item.dat_resp_err)):
      assert int(dat_item.dat_resp_err[i]) == int(RespErr.DERR)

    self.logger.info("Test (tc_chi_d_derr_smoke) PASS")
    self.drop_objection()
