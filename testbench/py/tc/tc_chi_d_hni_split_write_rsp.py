################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_hni_split_write_rsp.sv.
#
# The RN-I runs its multi-outstanding pipeline while the SN-F behind the proxy
# uses the split DBIDResp+Comp write policy. The HN-I is single-outstanding per
# RN (1-deep REQ credit), so it holds the RN's REQ credit until the deferred Comp
# has crossed back -- forcing observed_peak_outstanding to exactly 1 even though
# the sequence is pipelined. Each write completes on Comp; readback confirms the
# data landed through the proxy.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, RspOpcode, DatOpcode, DataType
from chi_hni_base_test import chi_hni_base_test

N_C = 3
BASE_ADDR_C = 0x2C00_0000
SIZE_C = 6


class tc_chi_d_hni_split_write_rsp(chi_hni_base_test):

  def configure(self):
    self.hrni0_cfg.multi_outstanding = True
    self.hrni0_cfg.multi_outstanding_write = True
    self.hrni0_cfg.max_outstanding_write = N_C
    self.hsnf0_cfg.multi_outstanding = True
    self.hsnf0_cfg.split_write_rsp = True

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(N_C)
    wr.set_initial_addr(BASE_ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_allow_retry(0)
    wr.set_data_type(DataType.COUNTER)
    wr.set_counter_value(0xC0)
    wr.set_counter_increment(0x1)
    wr.set_get_response(True)
    wr.set_pipelined_send(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.hrni0_sequencer)

    wr_rsp = wr.get_responses()
    assert len(wr_rsp) == N_C, f"expected {N_C} write responses, got {len(wr_rsp)}"
    for i, w in enumerate(wr_rsp):
      assert int(w.rsp_opcode) == int(RspOpcode.COMP), \
        f"split write {i} final opcode 0x{int(w.rsp_opcode):x} was not Comp"

    peak = self.hrni0_cfg.observed_peak_outstanding
    assert peak == 1, \
      f"proxy is 1-deep per RN: expected peak in-flight 1, got {peak}"

    for _ in range(N_C):
      snf_req = await self.tb_env.hsnf0_req_fifo.get()
      assert int(snf_req.opcode) == int(ReqOpcode.WRITE_NO_SNP_FULL), \
        f"SN-F observed opcode 0x{int(snf_req.opcode):x} instead of WriteNoSnpFull"

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(N_C)
    rd.set_initial_addr(BASE_ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_pipelined_send(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.hrni0_sequencer)

    rd_rsp = rd.get_responses()
    assert len(rd_rsp) == N_C, f"expected {N_C} proxied readbacks, got {len(rd_rsp)}"
    for i, r in enumerate(rd_rsp):
      assert int(r.dat_opcode) == int(DatOpcode.COMP_DATA), \
        f"proxied readback {i} DAT opcode 0x{int(r.dat_opcode):x} instead of CompData"
      assert len(r.data) == 4, \
        f"proxied readback {i} returned {len(r.data)} beats instead of 4"

    self.logger.info(
      "Test (tc_chi_d_hni_split_write_rsp) PASS: HN-I split writes held RN REQ "
      "credit until deferred Comp (peak in-flight = 1)")
    self.drop_objection()
