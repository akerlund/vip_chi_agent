################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_persist.sv.
#
# Drive one non-separated CleanSharedPersist and one separated
# CleanSharedPersistSep through the CHI-E integrated RN-I/SN-F path and verify the
# observed completions: the non-sep form retires on a single Comp; the sep form
# retires on a Persist + CompPersist pair. Neither produces DAT traffic, and the
# completion routing fields must mirror the request.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, RspOpcode
from chi_e_base_test import chi_e_base_test
from vip_chi_persist_seq import vip_chi_persist_seq
from chi_tb_pkg import (
  E_PERSIST_ADDR_C, E_PERSIST_SEP_ADDR_C,
  E_PERSIST_RNI_NODE_ID_C, E_PERSIST_SNF_NODE_ID_C,
  E_PERSIST_SEP_RNI_NODE_ID_C, E_PERSIST_SEP_SNF_NODE_ID_C,
)


class tc_chi_e_persist(chi_e_base_test):

  async def run_phase(self):
    self.raise_objection()

    persist_seq = vip_chi_persist_seq("persist_seq", cfg=self.chi_cfg)

    # --- Non-separated CleanSharedPersist -----------------------------------
    persist_seq.reset()
    persist_seq.set_requests(1)
    persist_seq.set_initial_addr(E_PERSIST_ADDR_C)
    persist_seq.set_size(6)
    persist_seq.set_src_id(E_PERSIST_RNI_NODE_ID_C)
    persist_seq.set_tgt_id(E_PERSIST_SNF_NODE_ID_C)
    persist_seq.set_qos(0x9)
    persist_seq.set_allow_retry(0)
    persist_seq.set_get_response(True)
    persist_seq.set_verbose(False)
    await persist_seq.start(self.v_sqr.rni_sequencer)

    responses = persist_seq.get_responses()
    assert len(responses) == 1, \
      f"expected 1 CleanSharedPersist response, got {len(responses)}"

    req_item = await self.tb_env.rni_req_fifo.get()
    rsp_item = await self.tb_env.rni_rsp_fifo.get()
    ok, _dat = self.tb_env.rni_dat_fifo.try_get()
    assert not ok, "CleanSharedPersist unexpectedly produced DAT traffic"

    assert int(req_item.opcode) == int(ReqOpcode.CLEAN_SHARED_PERSIST), \
      f"monitor observed wrong persist REQ opcode 0x{int(req_item.opcode):x}"
    assert int(rsp_item.rsp_opcode) == int(RspOpcode.COMP), \
      f"persist RSP opcode 0x{int(rsp_item.rsp_opcode):x} was not Comp"
    assert int(responses[0].rsp_opcode) == int(RspOpcode.COMP), \
      f"persist sequence response opcode 0x{int(responses[0].rsp_opcode):x} was not Comp"
    assert (int(rsp_item.txn_id) == int(req_item.txn_id) and
            int(rsp_item.src_id) == int(req_item.tgt_id) and
            int(rsp_item.tgt_id) == int(req_item.src_id)), \
      "persist completion routing fields did not match the request"

    # --- Separated CleanSharedPersistSep ------------------------------------
    persist_seq.reset()
    persist_seq.set_sep_persist(True)
    persist_seq.set_requests(1)
    persist_seq.set_initial_addr(E_PERSIST_SEP_ADDR_C)
    persist_seq.set_size(6)
    persist_seq.set_src_id(E_PERSIST_SEP_RNI_NODE_ID_C)
    persist_seq.set_tgt_id(E_PERSIST_SEP_SNF_NODE_ID_C)
    persist_seq.set_qos(0xA)
    persist_seq.set_allow_retry(0)
    persist_seq.set_get_response(True)
    persist_seq.set_verbose(False)
    await persist_seq.start(self.v_sqr.rni_sequencer)

    responses = persist_seq.get_responses()
    assert len(responses) == 1, \
      f"expected 1 CleanSharedPersistSep response, got {len(responses)}"

    req_item = await self.tb_env.rni_req_fifo.get()
    persist_rsp = await self.tb_env.rni_rsp_fifo.get()
    comp_persist_rsp = await self.tb_env.rni_rsp_fifo.get()
    ok, _dat = self.tb_env.rni_dat_fifo.try_get()
    assert not ok, "CleanSharedPersistSep unexpectedly produced DAT traffic"

    assert int(req_item.opcode) == int(ReqOpcode.CLEAN_SHARED_PERSIST_SEP), \
      f"monitor observed wrong persist-sep REQ opcode 0x{int(req_item.opcode):x}"
    assert int(persist_rsp.rsp_opcode) == int(RspOpcode.PERSIST), \
      f"persistSep first RSP opcode 0x{int(persist_rsp.rsp_opcode):x} was not Persist"
    assert int(comp_persist_rsp.rsp_opcode) == int(RspOpcode.COMP_PERSIST), \
      f"persistSep second RSP opcode 0x{int(comp_persist_rsp.rsp_opcode):x} was not CompPersist"
    assert (int(persist_rsp.txn_id) == int(req_item.txn_id) and
            int(comp_persist_rsp.txn_id) == int(req_item.txn_id) and
            int(persist_rsp.src_id) == int(req_item.tgt_id) and
            int(persist_rsp.tgt_id) == int(req_item.src_id) and
            int(comp_persist_rsp.src_id) == int(req_item.tgt_id) and
            int(comp_persist_rsp.tgt_id) == int(req_item.src_id)), \
      "persistSep completion routing fields did not match the request"
    assert int(responses[0].rsp_opcode) == int(RspOpcode.COMP_PERSIST), \
      f"persistSep sequence response opcode 0x{int(responses[0].rsp_opcode):x} was not CompPersist"

    self.logger.info(
      "Test (tc_chi_e_persist) PASS: CleanSharedPersist retired on Comp and "
      "CleanSharedPersistSep on Persist+CompPersist")
    self.drop_objection()
