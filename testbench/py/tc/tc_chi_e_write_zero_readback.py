################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_write_zero_readback.sv.
#
# Seed a non-zero line (ONES), confirm the readback is non-zero, then a
# WriteNoSnpZero over the same range and confirm the readback is all zeros.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DataType, RspOpcode, chi_xfer_dat_beats
from vip_chi_e_base_test import vip_chi_e_base_test
from vip_chi_write_zero_seq import vip_chi_write_zero_seq
from vip_chi_tb_pkg import E_WRITE_ZERO_ADDR_C

SIZE_C = 6


class tc_chi_e_write_zero_readback(vip_chi_e_base_test):

  async def run_phase(self):
    self.raise_objection()
    expected_beats = chi_xfer_dat_beats(SIZE_C, self.chi_cfg.data_bytes)

    # Seed a concrete non-zero line first.
    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_WRITE_ZERO_ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_allow_retry(0)
    wr.set_data_type(DataType.ONES)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)
    wr_rsp = wr.get_responses()
    assert len(wr_rsp) == 1
    assert int(wr_rsp[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP)

    # Pre-zero readback must see non-zero data.
    pre = self._read()
    await pre.start(self.tb_env.rni_agent.sequencer)
    pre_rsp = pre.get_responses()
    assert len(pre_rsp) == 1 and len(pre_rsp[0].data) == expected_beats
    assert any(int(d) != 0 for d in pre_rsp[0].data), "seed line read back all zero"

    # WriteNoSnpZero over the same range.
    zseq = vip_chi_write_zero_seq("rni_wr_zero_seq", cfg=self.chi_cfg)
    zseq.reset()
    zseq.set_requests(1)
    zseq.set_initial_addr(E_WRITE_ZERO_ADDR_C)
    zseq.set_size(SIZE_C)
    zseq.set_allow_retry(0)
    zseq.set_get_response(True)
    zseq.set_verbose(False)
    await zseq.start(self.tb_env.rni_agent.sequencer)
    zero_rsp = zseq.get_responses()
    assert len(zero_rsp) == 1 and int(zero_rsp[0].rsp_opcode) == int(RspOpcode.COMP)

    # Post-zero readback must be all zeros.
    post = self._read()
    await post.start(self.tb_env.rni_agent.sequencer)
    post_rsp = post.get_responses()
    assert len(post_rsp) == 1 and len(post_rsp[0].data) == expected_beats
    for i, d in enumerate(post_rsp[0].data):
      assert int(d) == 0, f"post-zero readback beat {i} was 0x{int(d):x}"

    self.logger.info("Test (tc_chi_e_write_zero_readback) PASS")
    self.drop_objection()

  def _read(self):
    rd = self.rni_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(E_WRITE_ZERO_ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_verbose(False)
    return rd
