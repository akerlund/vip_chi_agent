################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_dbid_resp_ord.sv.
#
# CHI-E ordered WriteNoSnpFull with ExpCompAck against a split-write SN-F that
# has ordered_dbid_resp enabled: the grant is DBIDRespOrd, followed by the
# deferred Comp and the RN-I CompAck. Write data is NCBWrDataCompAck.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, DataType, ReqOrder, RspOpcode, DatOpcode
from chi_e_base_test import chi_e_base_test
from chi_tb_pkg import (
  E_DBID_RESP_ORD_ADDR_C, E_DBID_RESP_ORD_RNI_NODE_ID_C, E_DBID_RESP_ORD_SNF_NODE_ID_C,
)


class tc_chi_e_dbid_resp_ord(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.split_write_rsp = True
    snf_cfg.ordered_dbid_resp = True

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_DBID_RESP_ORD_ADDR_C)
    wr.set_size(6)
    wr.set_src_id(E_DBID_RESP_ORD_RNI_NODE_ID_C)
    wr.set_tgt_id(E_DBID_RESP_ORD_SNF_NODE_ID_C)
    wr.set_qos(0xE)
    wr.set_order(int(ReqOrder.REQ_ORDER))
    wr.set_exp_comp_ack(1)
    wr.set_data_type(DataType.COUNTER)
    wr.set_counter_value(0x90)
    wr.set_counter_increment(0x1)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)

    write_responses = wr.get_responses()
    assert len(write_responses) == 1

    req_item = await self.tb_env.rni_req_fifo.get()
    dat_item = await self.tb_env.rni_dat_fifo.get()
    rsp_items = [await self.tb_env.rni_rsp_fifo.get() for _ in range(3)]

    assert int(req_item.order) == int(ReqOrder.REQ_ORDER)
    assert int(dat_item.dat_opcode) == int(DatOpcode.NCB_WR_DATA_COMP_ACK)
    assert int(rsp_items[0].rsp_opcode) == int(RspOpcode.DBID_RESP_ORD)
    assert int(rsp_items[1].rsp_opcode) == int(RspOpcode.COMP)
    assert int(rsp_items[2].rsp_opcode) == int(RspOpcode.COMP_ACK)
    assert int(rsp_items[0].role) == int(Role.SNF)
    assert int(rsp_items[1].role) == int(Role.SNF)
    assert int(rsp_items[2].role) == int(Role.RNI)
    assert int(rsp_items[0].dbid) == int(req_item.txn_id)
    assert int(rsp_items[1].dbid) == int(req_item.txn_id)
    assert int(rsp_items[2].txn_id) == int(req_item.txn_id)
    assert int(write_responses[0].rsp_opcode) == int(RspOpcode.COMP)
    assert int(write_responses[0].dbid) == int(req_item.txn_id)

    self.logger.info("Test (tc_chi_e_dbid_resp_ord) PASS")
    self.drop_objection()
