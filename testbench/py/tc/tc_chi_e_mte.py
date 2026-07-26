################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_mte.sv.
#
# Write one tagged exact-CHI-E beat (dat_tagop / tag / tu) through the real
# RN-I/SN-F path, then read it back and verify the SN-F auto-read CompData replays
# the same DAT tag metadata and data -- i.e. the SN-F stores and returns the MTE
# tags alongside the data.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, DatOpcode, RspOpcode
from chi_e_base_test import chi_e_base_test
from chi_tb_pkg import (
  E_MTE_ADDR_C, E_MTE_RNI_NODE_ID_C, E_MTE_SNF_NODE_ID_C,
  E_MTE_WRITE_DATA_C, E_MTE_WRITE_TAGOP_C, E_MTE_WRITE_TAG_C, E_MTE_WRITE_TU_C,
)


class tc_chi_e_mte(chi_e_base_test):

  async def _get_snf_compdata(self):
    # Ignore write-side DAT observations; return the SN-F read CompData item.
    while True:
      dat_item = await self.tb_env.snf_dat_fifo.get()
      if (int(dat_item.role) == int(Role.SNF) and
          int(dat_item.dat_opcode) == int(DatOpcode.COMP_DATA)):
        return dat_item

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_MTE_ADDR_C)
    wr.set_size(6)
    wr.set_src_id(E_MTE_RNI_NODE_ID_C)
    wr.set_tgt_id(E_MTE_SNF_NODE_ID_C)
    wr.set_qos(0xD)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_verbose(False)
    wr.set_data([E_MTE_WRITE_DATA_C])
    wr.set_dat_tagop(E_MTE_WRITE_TAGOP_C)
    wr.set_tag([E_MTE_WRITE_TAG_C])
    wr.set_tu([E_MTE_WRITE_TU_C])
    await wr.start(self.tb_env.rni_agent.sequencer)

    rd = self.rni_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(E_MTE_ADDR_C)
    rd.set_size(6)
    rd.set_src_id(E_MTE_RNI_NODE_ID_C)
    rd.set_tgt_id(E_MTE_SNF_NODE_ID_C)
    rd.set_qos(0x6)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.tb_env.rni_agent.sequencer)

    write_responses = wr.get_responses()
    read_responses = rd.get_responses()

    assert (len(write_responses) == 1 and
            int(write_responses[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP)), \
      "exact-E tagged write did not complete with CompDBIDResp"
    assert (len(read_responses) == 1 and len(read_responses[0].data) == 1 and
            int(read_responses[0].data[0]) == E_MTE_WRITE_DATA_C), \
      "exact-E tagged readback did not return the expected data"

    write_req_item = await self.tb_env.rni_req_fifo.get()
    read_req_item = await self.tb_env.rni_req_fifo.get()
    write_rsp_item = await self.tb_env.snf_rsp_fifo.get()

    assert int(write_rsp_item.rsp_opcode) == int(RspOpcode.COMP_DBID_RESP), \
      f"monitor observed wrong write completion opcode 0x{int(write_rsp_item.rsp_opcode):x}"
    assert (int(write_rsp_item.txn_id) == int(write_req_item.txn_id) and
            int(write_rsp_item.dbid) == int(write_req_item.txn_id) and
            int(write_rsp_item.src_id) == int(write_req_item.tgt_id) and
            int(write_rsp_item.tgt_id) == int(write_req_item.src_id)), \
      "monitor observed wrong write completion routing fields"

    dat_item = await self._get_snf_compdata()

    assert (int(dat_item.txn_id) == int(read_req_item.txn_id) and
            int(dat_item.dbid) == int(read_req_item.txn_id) and
            int(dat_item.src_id) == int(read_req_item.tgt_id) and
            int(dat_item.tgt_id) == int(read_req_item.src_id)), \
      "monitor observed wrong autonomous read DAT routing fields"
    assert (len(dat_item.data) == 1 and int(dat_item.data[0]) == E_MTE_WRITE_DATA_C and
            len(dat_item.be) == 1), \
      "monitor observed wrong autonomous read DAT payload"
    assert (int(dat_item.dat_tagop) == E_MTE_WRITE_TAGOP_C and
            len(dat_item.tag) == 1 and int(dat_item.tag[0]) == E_MTE_WRITE_TAG_C and
            len(dat_item.tu) == 1 and int(dat_item.tu[0]) == E_MTE_WRITE_TU_C), \
      "monitor observed wrong autonomous read DAT tagging fields (MTE tags did not round-trip)"

    self.logger.info(
      "Test (tc_chi_e_mte) PASS: SN-F stored and replayed the MTE DAT tags "
      "(dat_tagop / tag / tu) across a tagged write -> read")
    self.drop_objection()
