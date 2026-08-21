################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_multi_outstanding_concurrent.sv.
#
# Seed a read region, then fire N reads (of that region) and N writes (to a
# disjoint region) CONCURRENTLY on the same sequencer. Proves the mixed loop
# keeps a read and a write in flight at the same instant
# (observed_peak_mixed_inflight > 1) while returning the seeded read data intact.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

import cocotb

from vip_chi_types_pkg import RspOpcode, DatOpcode
from chi_base_test import chi_base_test

N_C = 6
READ_ADDR_C = 0x2800_0000
WRITE_ADDR_C = 0x2900_0000
SIZE_C = 6
SETTLE_C = 20


class tc_chi_d_multi_outstanding_concurrent(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.multi_outstanding_mixed = True
    rni_cfg.max_outstanding_read = N_C
    rni_cfg.max_outstanding_write = N_C
    snf_cfg.multi_outstanding = True

  async def run_phase(self):
    self.raise_objection()
    sqr = self.v_sqr.rni_sequencer

    # -- Phase 1: seed the read region with N writes and capture the payloads. -
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(N_C)
    wr.set_initial_addr(READ_ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_get_response(True)
    wr.set_pipelined_send(True)
    wr.set_verbose(False)
    await wr.start(sqr)

    seed_rsp = wr.get_responses()
    assert len(seed_rsp) == N_C, f"expected {N_C} seed-write responses, got {len(seed_rsp)}"
    seeded = {int(s.addr): s for s in seed_rsp}

    await self.wait_clocks(SETTLE_C)

    # -- Phase 2: reads (read region) and writes (write region) concurrently. --
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(N_C)
    rd.set_initial_addr(READ_ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_pipelined_send(True)
    rd.set_verbose(False)

    wr.reset()
    wr.set_requests(N_C)
    wr.set_initial_addr(WRITE_ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_get_response(True)
    wr.set_pipelined_send(True)
    wr.set_verbose(False)

    t_rd = cocotb.start_soon(rd.start(sqr))
    t_wr = cocotb.start_soon(wr.start(sqr))
    await t_rd
    await t_wr

    rd_rsp = rd.get_responses()
    wr_rsp = wr.get_responses()
    assert len(rd_rsp) == N_C, f"expected {N_C} read responses, got {len(rd_rsp)}"
    assert len(wr_rsp) == N_C, f"expected {N_C} write responses, got {len(wr_rsp)}"

    for k, w in enumerate(wr_rsp):
      assert int(w.rsp_opcode) == int(RspOpcode.COMP_DBID_RESP), \
        f"concurrent write {k} carried wrong RSP opcode 0x{int(w.rsp_opcode):x}"

    for k, r in enumerate(rd_rsp):
      assert int(r.dat_opcode) == int(DatOpcode.COMP_DATA), \
        f"read {k} carried wrong DAT opcode 0x{int(r.dat_opcode):x}"
      assert int(r.addr) in seeded, f"read {k} addr 0x{int(r.addr):x} has no seed"
      w = seeded[int(r.addr)]
      assert len(r.data) == len(w.data), \
        f"read {k} addr 0x{int(r.addr):x} beat count {len(r.data)} != seeded {len(w.data)}"
      for i in range(len(r.data)):
        assert int(r.data[i]) == int(w.data[i]), \
          f"read {k} addr 0x{int(r.addr):x} beat {i} != seeded"

    peak_mixed = self.rni_cfg.observed_peak_mixed_inflight
    assert peak_mixed > 1, \
      f"reads and writes never overlapped: peak mixed in-flight was {peak_mixed} (expected > 1)"

    self.logger.info(
      f"Test (tc_chi_d_multi_outstanding_concurrent) PASS: {N_C} reads + {N_C} "
      f"writes concurrent, seeded read-back verified, peak mixed in-flight = "
      f"{peak_mixed} (total peak = {self.rni_cfg.observed_peak_outstanding})")
    self.drop_objection()
