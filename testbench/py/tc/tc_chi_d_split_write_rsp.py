################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_split_write_rsp.sv.
#
# With split_write_rsp the SN-F grants a separate DBIDResp then a deferred Comp.
# Runs the non-CompAck and the CompAck (ordered) case; the latter also drives an
# RN-I CompAck and uses the NCBWrDataCompAck write-data opcode.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, DataType, RspOpcode, DatOpcode
from chi_base_test import chi_base_test
from chi_tb_pkg import WRITE_ADDR_C


class tc_chi_d_split_write_rsp(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.split_write_rsp = True

  async def run_phase(self):
    self.raise_objection()
    await self._run_split_case(False, WRITE_ADDR_C + 0x200)
    await self._run_split_case(True, WRITE_ADDR_C + 0x300)
    self.logger.info("Test (tc_chi_d_split_write_rsp) PASS")
    self.drop_objection()

  async def _run_split_case(self, exp_comp_ack, addr):
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(addr)
    wr.set_size(6)
    wr.set_allow_retry(0)
    wr.set_data_type(DataType.COUNTER)
    wr.set_counter_value(0x70 if exp_comp_ack else 0x40)
    wr.set_counter_increment(0x1)
    wr.set_exp_comp_ack(1 if exp_comp_ack else 0)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    write_responses = wr.get_responses()
    assert len(write_responses) == 1

    req_item = await self.tb_env.rni_req_fifo.get()
    dat_item = await self.tb_env.rni_dat_fifo.get()
    expected_rsp_count = 3 if exp_comp_ack else 2
    rsp_items = [await self.tb_env.rni_rsp_fifo.get() for _ in range(expected_rsp_count)]

    assert int(rsp_items[0].role) == int(Role.SNF)
    assert int(rsp_items[0].rsp_opcode) == int(RspOpcode.DBID_RESP)
    assert int(rsp_items[1].role) == int(Role.SNF)
    assert int(rsp_items[1].rsp_opcode) == int(RspOpcode.COMP)
    assert int(rsp_items[0].dbid) == int(req_item.txn_id)
    assert int(write_responses[0].rsp_opcode) == int(RspOpcode.COMP)
    assert int(write_responses[0].dbid) == int(req_item.txn_id)

    if exp_comp_ack:
      assert int(dat_item.dat_opcode) == int(DatOpcode.NCB_WR_DATA_COMP_ACK)
      assert int(rsp_items[2].rsp_opcode) == int(RspOpcode.COMP_ACK)
      assert int(rsp_items[2].role) == int(Role.RNI)
    else:
      assert int(dat_item.dat_opcode) == int(DatOpcode.NON_COPY_BACK_WR_DATA)
