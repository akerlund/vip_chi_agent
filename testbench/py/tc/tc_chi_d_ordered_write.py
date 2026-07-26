################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_ordered_write.sv.
#
# WriteNoSnpFull with ExpCompAck: the write data is NCBWrDataCompAck and the RN-I
# drives a CompAck after the CompDBIDResp grant.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, DataType, RspOpcode, DatOpcode
from chi_base_test import chi_base_test
from chi_tb_pkg import WRITE_ADDR_C


class tc_chi_d_ordered_write(chi_base_test):

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(WRITE_ADDR_C + 0x100)
    wr.set_size(6)
    wr.set_allow_retry(0)
    wr.set_data_type(DataType.COUNTER)
    wr.set_counter_value(0x20)
    wr.set_counter_increment(0x1)
    wr.set_exp_comp_ack(1)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    write_responses = wr.get_responses()
    assert len(write_responses) == 1

    req_item = await self.tb_env.rni_req_fifo.get()
    dat_item = await self.tb_env.rni_dat_fifo.get()
    rsp_items = [await self.tb_env.rni_rsp_fifo.get() for _ in range(2)]

    assert int(req_item.exp_comp_ack) == 1
    assert int(dat_item.dat_opcode) == int(DatOpcode.NCB_WR_DATA_COMP_ACK)
    assert int(rsp_items[0].role) == int(Role.SNF)
    assert int(rsp_items[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP)
    assert int(rsp_items[0].dbid) == int(req_item.txn_id)
    assert int(rsp_items[1].role) == int(Role.RNI)
    assert int(rsp_items[1].rsp_opcode) == int(RspOpcode.COMP_ACK)
    assert int(rsp_items[1].txn_id) == int(req_item.txn_id)
    assert int(write_responses[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP)

    self.logger.info("Test (tc_chi_d_ordered_write) PASS")
    self.drop_objection()
