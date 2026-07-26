################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_multi_outstanding_write.sv.
#
# Launch N pipelined WriteNoSnpFull requests through the multi-outstanding WRITE
# datapath, confirm each returns its combined CompDBIDResp completion with
# NormalOkay, and confirm the write REQs actually overlapped in flight.
# Runs under: testbench/py/tb/vip_chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Role, RspOpcode, RespErr
from vip_chi_base_test import vip_chi_base_test

N_WRITES_C = 6
WR_BASE_ADDR_C = 0x2400_0000
WRITE_SIZE_C = 6


class tc_chi_d_multi_outstanding_write(vip_chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.multi_outstanding_write = True
    rni_cfg.max_outstanding_write = N_WRITES_C
    snf_cfg.multi_outstanding = True

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(N_WRITES_C)
    wr.set_initial_addr(WR_BASE_ADDR_C)
    wr.set_size(WRITE_SIZE_C)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_pipelined_send(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    responses = wr.get_responses()
    assert len(responses) == N_WRITES_C, \
      f"expected {N_WRITES_C} write responses, got {len(responses)}"

    for k, rsp in enumerate(responses):
      assert int(rsp.role) == int(Role.SNF), \
        f"write {k} response carried wrong role {int(rsp.role)}"
      assert int(rsp.rsp_opcode) == int(RspOpcode.COMP_DBID_RESP), \
        f"write {k} response carried wrong RSP opcode 0x{int(rsp.rsp_opcode):x}"
      assert int(rsp.rsp_resp_err) == int(RespErr.OKAY), \
        f"write {k} completed with error status 0x{int(rsp.rsp_resp_err):x}"

    peak = self.rni_cfg.observed_peak_outstanding
    assert peak > 1, f"writes did not overlap: peak in-flight was {peak} (expected > 1)"

    self.logger.info(
      f"Test (tc_chi_d_multi_outstanding_write) PASS: {N_WRITES_C} pipelined "
      f"writes, peak in-flight = {peak}")
    self.drop_objection()
