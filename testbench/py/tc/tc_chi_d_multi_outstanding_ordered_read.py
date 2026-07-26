################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_multi_outstanding_ordered_read.sv.
#
# Seed N addresses, then pipeline N ordered (Order=RequestOrder) reads. An
# ordered read receives a ReadReceipt on RSP ahead of its CompData on DAT; the
# pipeline's RSP monitor must consume the receipt (a non-ordered pipeline would
# fatal on the unexpected RSP) and retire the read on DAT gated by receipt_seen.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import DatOpcode, ReqOrder
from chi_base_test import chi_base_test

N_C = 6
BASE_ADDR_C = 0x2E00_0000
SIZE_C = 6
SETTLE_C = 20


class tc_chi_d_multi_outstanding_ordered_read(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.max_outstanding_read = N_C
    rni_cfg.max_outstanding_write = N_C
    snf_cfg.multi_outstanding = True

  async def run_phase(self):
    self.raise_objection()

    # -- Phase 1: seed the region with N pipelined writes. ---------------------
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
    assert len(wr.get_responses()) == N_C

    await self.wait_clocks(SETTLE_C)

    # -- Phase 2: pipeline N ordered reads and check receipt + data. -----------
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(N_C)
    rd.set_initial_addr(BASE_ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_order(int(ReqOrder.REQ_ORDER))
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

    peak = self.rni_cfg.observed_peak_outstanding
    assert peak > 1, f"ordered reads did not overlap: peak was {peak} (expected > 1)"

    self.logger.info(
      f"Test (tc_chi_d_multi_outstanding_ordered_read) PASS: {N_C} ordered reads "
      f"pipelined (ReadReceipt consumed), peak in-flight = {peak}")
    self.drop_objection()
