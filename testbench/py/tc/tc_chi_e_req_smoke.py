################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_req_smoke.sv.
#
# A CHI-E WriteNoSnpZero carrying the exact-CHI-E REQ fields (tracetag, endian,
# group_id_ext, tagop, plus the common src/tgt/lpid/qos); the monitor must
# observe every one of them on the REQ, and the SN-F completes with Comp.
# DoDWT and LikelyShared are checked as zero rather than driven: this opcode
# carries neither (E sections 13.10.25 and 2.9.5).
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
    # DoDWT is deliberately absent from the stamped set. IHI 0050 E section
    # 13.10.25 makes it applicable only in WriteNoSnpFull, WriteNoSnpPtl and
    # Combined Write, and Table 2-14 lists WriteNoSnpZero as Non-snoopable only --
    # so on this opcode REQ bit 17 has no legal non-zero value under either of
    # the two names it carries. The field is proven drivable on an opcode that
    # does carry it by tc_chi_e_signal_drivability; what is worth checking here
    # is that the inapplicable field is held at zero.
    # LikelyShared is deliberately absent too. IHI 0050 E section 2.9.5 names
    # the opcodes that may assert it -- the three WriteUnique forms, four
    # coherent reads, the StashOnce forms, WriteBackFull, WriteCleanFull,
    # WriteEvictFull and WriteEvictOrEvict -- and closes with "Must not be
    # asserted in any other Read, Write or Combined Write transaction".
    # WriteNoSnpZero is one of those others. Table 2-12 agrees from the other
    # direction: LikelyShared is 0/1 only on its two Snoopable rows, and
    # WriteNoSnp is Non-snoopable only.
    # Endian too. Table A-3's Endian column is "Y" only on the Atomics: the field
    # selects an Atomic operand's byte order, so on a WriteNoSnpZero it is
    # inapplicable and must be zero. That is the THIRD field this testcase
    # stamped onto an opcode that does not carry it, after DoDWT and
    # LikelyShared -- the test was written as "drive every CHI-E-only REQ field"
    # without asking which of them this opcode has.
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
    assert int(req_item.tracetag) == 1 and int(req_item.dodwt) == 0
    assert int(req_item.likelyshared) == 0 and int(req_item.endian) == 0
    assert int(req_item.group_id_ext) == 0x3 and int(req_item.tagop) == 0x2
    # WriteNoSnpZero completes with a combined CompDBIDResp (or DBIDResp then
    # Comp under cfg.split_write_rsp); a bare Comp is not a legal completion.
    assert int(rsp_item.rsp_opcode) == int(RspOpcode.COMP_DBID_RESP)

    self.logger.info("Test (tc_chi_e_req_smoke) PASS")
    self.drop_objection()
