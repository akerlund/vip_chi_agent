################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_req_smoke.sv.
#
# A CHI-E WriteNoSnpZero carrying the exact-CHI-E REQ fields (tracetag, dodwt,
# likelyshared, endian, group_id_ext, tagop, plus the common src/tgt/lpid/qos);
# the monitor must observe every one of them on the REQ, and the SN-F completes
# with Comp.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, RspOpcode
from chi_e_base_test import chi_e_base_test
from vip_chi_write_zero_seq import vip_chi_write_zero_seq


class tc_chi_e_req_smoke(chi_e_base_test):

  async def run_phase(self):
    self.raise_objection()

    seq = vip_chi_write_zero_seq("rni_wr_zero_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(0x0012_3456_7800)
    seq.set_size(6)
    seq.set_src_id(0x15)
    seq.set_tgt_id(0x2A)
    seq.set_lp_id(0x9)
    seq.set_qos(0xB)
    seq.set_tracetag(1)
    seq.set_dodwt(1)
    seq.set_likelyshared(1)
    seq.set_endian(1)
    seq.set_group_id_ext(0x3)
    seq.set_tagop(0x2)
    seq.set_get_response(True)
    seq.set_verbose(False)
    await seq.start(self.tb_env.rni_agent.sequencer)

    req_item = await self.tb_env.rni_req_fifo.get()
    rsp_item = await self.tb_env.rni_rsp_fifo.get()

    assert int(req_item.opcode) == int(ReqOpcode.WRITE_NO_SNP_ZERO)
    assert int(req_item.addr) == 0x0012_3456_7800
    assert int(req_item.src_id) == 0x15 and int(req_item.tgt_id) == 0x2A
    assert int(req_item.lp_id) == 0x9 and int(req_item.qos) == 0xB
    assert int(req_item.tracetag) == 1 and int(req_item.dodwt) == 1
    assert int(req_item.likelyshared) == 1 and int(req_item.endian) == 1
    assert int(req_item.group_id_ext) == 0x3 and int(req_item.tagop) == 0x2
    assert int(rsp_item.rsp_opcode) == int(RspOpcode.COMP)

    self.logger.info("Test (tc_chi_e_req_smoke) PASS")
    self.drop_objection()
