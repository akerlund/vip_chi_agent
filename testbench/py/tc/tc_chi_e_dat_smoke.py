################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_dat_smoke.sv.
#
# A CHI-E WriteNoSnpFull carrying the exact-CHI-E DAT tagging fields (dat_tagop,
# tag, tu); the monitor must observe them on the reassembled write DAT item.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, RspOpcode
from chi_e_base_test import chi_e_base_test


class tc_chi_e_dat_smoke(chi_e_base_test):

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(0x0012_3456_7C00)
    wr.set_size(6)
    wr.set_src_id(0x1C)
    wr.set_tgt_id(0x22)
    wr.set_lp_id(0xB)
    wr.set_qos(0xD)
    wr.set_dat_tagop(0x1)
    wr.set_tag([0x1234])
    wr.set_tu([0xA])
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)

    req_item = await self.tb_env.rni_req_fifo.get()
    rsp_item = await self.tb_env.rni_rsp_fifo.get()
    dat_item = await self.tb_env.rni_dat_fifo.get()

    assert int(req_item.opcode) == int(ReqOpcode.WRITE_NO_SNP_FULL)
    assert int(rsp_item.rsp_opcode) == int(RspOpcode.COMP_DBID_RESP)
    assert int(dat_item.src_id) == 0x1C and int(dat_item.tgt_id) == 0x22
    assert int(dat_item.qos) == 0xD
    assert int(dat_item.dat_tagop) == 0x1
    assert len(dat_item.tag) == 1 and int(dat_item.tag[0]) == 0x1234
    assert len(dat_item.tu) == 1 and int(dat_item.tu[0]) == 0xA

    self.logger.info("Test (tc_chi_e_dat_smoke) PASS")
    self.drop_objection()
