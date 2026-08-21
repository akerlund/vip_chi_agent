################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_rsp_field_legality.sv.
#
# Field-legality regression for SN-F RSP responses:
#   * split DECERR write: DBIDRespOrd RespErr is zero, deferred Comp is NDERR
#   * CleanSharedPersistSep: Comp carries request TxnID, Persist carries zero
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DataType, ReqOpcode, ReqOrder, RespErr, RspOpcode
from chi_e_base_test import chi_e_base_test
from vip_chi_persist_seq import vip_chi_persist_seq
from chi_tb_pkg import (
  E_DBID_RESP_ORD_ADDR_C, E_DBID_RESP_ORD_RNI_NODE_ID_C,
  E_DBID_RESP_ORD_SNF_NODE_ID_C, E_PERSIST_SEP_ADDR_C,
  E_PERSIST_SEP_RNI_NODE_ID_C, E_PERSIST_SEP_SNF_NODE_ID_C,
)

DECERR_WRITE_ADDR_C = E_DBID_RESP_ORD_ADDR_C + 0x400
PERSIST_SEP_ADDR_C = E_PERSIST_SEP_ADDR_C + 0x300


class tc_chi_e_rsp_field_legality(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.split_write_rsp = True
    snf_cfg.ordered_dbid_resp = True
    snf_cfg.add_decerr_range(DECERR_WRITE_ADDR_C, DECERR_WRITE_ADDR_C + 0x3F)

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(DECERR_WRITE_ADDR_C)
    wr.set_size(6)
    wr.set_src_id(E_DBID_RESP_ORD_RNI_NODE_ID_C)
    wr.set_tgt_id(E_DBID_RESP_ORD_SNF_NODE_ID_C)
    wr.set_qos(0xD)
    wr.set_order(int(ReqOrder.REQ_ORDER))
    wr.set_data_type(DataType.COUNTER)
    wr.set_counter_value(0xB0)
    wr.set_counter_increment(0x1)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)

    write_responses = wr.get_responses()
    assert len(write_responses) == 1, \
      f"expected 1 split DECERR write response, got {len(write_responses)}"

    _req_item = await self.tb_env.rni_req_fifo.get()
    _dat_item = await self.tb_env.rni_dat_fifo.get()
    grant_rsp = await self.tb_env.rni_rsp_fifo.get()
    comp_rsp = await self.tb_env.rni_rsp_fifo.get()

    assert int(grant_rsp.rsp_opcode) == int(RspOpcode.DBID_RESP_ORD), \
      f"split DECERR write grant opcode 0x{int(grant_rsp.rsp_opcode):x} was not DBIDRespOrd"
    assert int(grant_rsp.rsp_resp_err) == int(RespErr.OKAY), \
      f"DBIDRespOrd RespErr 0x{int(grant_rsp.rsp_resp_err):x} was not zero"
    assert int(comp_rsp.rsp_opcode) == int(RspOpcode.COMP), \
      f"split DECERR write completion opcode 0x{int(comp_rsp.rsp_opcode):x} was not Comp"
    assert int(comp_rsp.rsp_resp_err) == int(RespErr.NDERR), \
      f"deferred Comp RespErr 0x{int(comp_rsp.rsp_resp_err):x} was not NDERR"
    assert int(write_responses[0].rsp_resp_err) == int(RespErr.NDERR), \
      "sequence response did not preserve NDERR after zeroed DBIDRespOrd"

    persist_seq = vip_chi_persist_seq("persist_seq", cfg=self.chi_cfg)
    persist_seq.reset()
    persist_seq.set_sep_persist(True)
    persist_seq.set_requests(1)
    persist_seq.set_initial_addr(PERSIST_SEP_ADDR_C)
    persist_seq.set_size(6)
    persist_seq.set_src_id(E_PERSIST_SEP_RNI_NODE_ID_C)
    persist_seq.set_tgt_id(E_PERSIST_SEP_SNF_NODE_ID_C)
    persist_seq.set_qos(0xC)
    persist_seq.set_get_response(True)
    persist_seq.set_verbose(False)
    await persist_seq.start(self.tb_env.rni_agent.sequencer)

    persist_responses = persist_seq.get_responses()
    assert len(persist_responses) == 1, \
      f"expected 1 CleanSharedPersistSep response, got {len(persist_responses)}"

    req_item = await self.tb_env.rni_req_fifo.get()
    comp_rsp = await self.tb_env.rni_rsp_fifo.get()
    persist_rsp = await self.tb_env.rni_rsp_fifo.get()

    assert int(req_item.opcode) == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP), \
      f"persist request opcode 0x{int(req_item.opcode):x} was not CleanSharedPersistSep"
    assert int(comp_rsp.rsp_opcode) == int(RspOpcode.COMP), \
      f"persistSep first RSP opcode 0x{int(comp_rsp.rsp_opcode):x} was not Comp"
    assert int(comp_rsp.txn_id) == int(req_item.txn_id), \
      "persistSep Comp did not carry the request TxnID"
    assert int(persist_rsp.rsp_opcode) == int(RspOpcode.PERSIST), \
      f"persistSep second RSP opcode 0x{int(persist_rsp.rsp_opcode):x} was not Persist"
    assert int(persist_rsp.txn_id) == 0, \
      f"Persist TxnID 0x{int(persist_rsp.txn_id):x} was not zero"
    assert int(persist_responses[0].rsp_opcode) == int(RspOpcode.PERSIST), \
      f"persistSep sequence response opcode 0x{int(persist_responses[0].rsp_opcode):x} was not Persist"

    self.logger.info(
      "Test (tc_chi_e_rsp_field_legality) PASS: split DECERR DBIDRespOrd "
      "RespErr zero with deferred NDERR Comp, and Persist TxnID zero")
    self.drop_objection()
