################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_multi_outstanding_split.sv.
#
# Pipeline N writes against a SN-F that uses the split DBIDResp+Comp policy: each
# write's grant (DBIDResp) and completion (Comp) arrive as separate RSP flits.
# The pipeline's RSP monitor must correlate both to retire on Comp. Confirms the
# split-response writes overlap and each is handed back showing Comp.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import RspOpcode, DatOpcode
from chi_base_test import chi_base_test

N_C = 6
BASE_ADDR_C = 0x2B00_0000
SIZE_C = 6
SETTLE_C = 20


class tc_chi_d_multi_outstanding_split(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.multi_outstanding_write = True
    rni_cfg.max_outstanding_write = N_C
    snf_cfg.multi_outstanding = True
    snf_cfg.split_write_rsp = True

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(N_C)
    wr.set_initial_addr(BASE_ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_pipelined_send(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    wr_rsp = wr.get_responses()
    assert len(wr_rsp) == N_C, f"expected {N_C} write responses, got {len(wr_rsp)}"
    written = {}
    for k, w in enumerate(wr_rsp):
      assert int(w.rsp_opcode) == int(RspOpcode.COMP), \
        f"split write {k} final opcode 0x{int(w.rsp_opcode):x} was not Comp"
      written[int(w.addr)] = w

    await self.wait_clocks(SETTLE_C)

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(N_C)
    rd.set_initial_addr(BASE_ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_allow_retry(0)
    rd.set_get_response(True)
    rd.set_pipelined_send(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    rd_rsp = rd.get_responses()
    assert len(rd_rsp) == N_C, f"expected {N_C} read responses, got {len(rd_rsp)}"
    for k, r in enumerate(rd_rsp):
      assert int(r.dat_opcode) == int(DatOpcode.COMP_DATA), \
        f"read {k} carried wrong DAT opcode 0x{int(r.dat_opcode):x}"
      assert int(r.addr) in written, f"read {k} addr 0x{int(r.addr):x} has no write"
      w = written[int(r.addr)]
      assert len(r.data) == len(w.data), \
        f"read {k} addr 0x{int(r.addr):x} beat count {len(r.data)} != {len(w.data)}"

    peak = self.rni_cfg.observed_peak_outstanding
    assert peak > 1, f"split writes did not overlap: peak was {peak} (expected > 1)"

    self.logger.info(
      f"Test (tc_chi_d_multi_outstanding_split) PASS: {N_C} split-response writes "
      f"pipelined, peak in-flight = {peak}")
    self.drop_objection()
