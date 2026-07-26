################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_decerr_smoke.sv.
#
# A write + read to a DECERR-configured SN-F address: both completions carry
# NDERR, the write is not committed, and the read returns zeroed placeholders.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, DataType, RespErr, chi_xfer_dat_beats
from chi_base_test import chi_base_test
from chi_tb_pkg import DECERR_ADDR_C


class tc_chi_d_decerr_smoke(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.add_decerr_range(DECERR_ADDR_C, DECERR_ADDR_C + 0x3F)

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(DECERR_ADDR_C)
    wr.set_size(6)
    wr.set_allow_retry(0)
    wr.set_data_type(DataType.COUNTER)
    wr.set_counter_value(0x40)
    wr.set_counter_increment(0x1)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(DECERR_ADDR_C)
    rd.set_size(6)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    write_responses = wr.get_responses()
    read_responses = rd.get_responses()
    expected_beats = chi_xfer_dat_beats(6, self.chi_cfg.data_bytes)

    assert len(write_responses) == 1 and len(read_responses) == 1

    req_items = [await self.tb_env.rni_req_fifo.get() for _ in range(2)]
    rsp_item = await self.tb_env.rni_rsp_fifo.get()
    write_dat_item = await self.tb_env.rni_dat_fifo.get()
    dat_item = await self.tb_env.rni_dat_fifo.get()

    assert int(write_dat_item.role) == int(Role.RNI)
    assert int(req_items[0].addr) == DECERR_ADDR_C
    assert int(req_items[1].addr) == DECERR_ADDR_C
    assert int(write_responses[0].rsp_resp_err) == int(RespErr.NDERR)
    assert int(rsp_item.rsp_resp_err) == int(RespErr.NDERR)
    assert int(read_responses[0].rsp_resp_err) == int(RespErr.NDERR)
    assert len(dat_item.dat_resp_err) == expected_beats

    for i in range(len(dat_item.dat_resp_err)):
      assert int(dat_item.dat_resp_err[i]) == int(RespErr.NDERR)
      assert int(read_responses[0].dat_resp_err[i]) == int(RespErr.NDERR)
      assert int(dat_item.data[i]) == 0 and int(read_responses[0].data[i]) == 0

    self.logger.info("Test (tc_chi_d_decerr_smoke) PASS")
    self.drop_objection()
