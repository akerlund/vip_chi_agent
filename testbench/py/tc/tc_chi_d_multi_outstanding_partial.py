################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_multi_outstanding_partial.sv.
#
# Pipeline N partial (WriteNoSnpPtl) writes to distinct fresh addresses, each with
# its own data and byte-enable mask, then read every address back and confirm the
# masked merge image survived the overlapped custom-BE bursts. Custom data + BE
# make the write sequence emit WriteNoSnpPtl.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, RspOpcode, DatOpcode
from chi_base_test import chi_base_test

N_C = 6
BASE_ADDR_C = 0x2A00_0000
SIZE_C = 4          # 16 bytes => one beat on the CHI-D cut
STRIDE_C = 16
SETTLE_C = 20


def _expected_partial(data, be, data_bytes):
  result = 0
  for byte_index in range(data_bytes):
    if (be >> byte_index) & 1:
      result |= ((data >> (8 * byte_index)) & 0xFF) << (8 * byte_index)
  return result


class tc_chi_d_multi_outstanding_partial(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.multi_outstanding_write = True
    rni_cfg.max_outstanding_write = N_C
    snf_cfg.multi_outstanding = True

  async def run_phase(self):
    self.raise_objection()
    dbytes = self.chi_cfg.data_bytes

    # Build N distinct payload/BE pairs and the expected masked image per addr.
    data_q, be_q, expected = [], [], {}
    for k in range(N_C):
      data = int(str(f"{(0xAABB0000 | k):08x}") * 4, 16)   # replicate 32b across 128b
      be = (0xF00F ^ (1 << k)) & ((1 << dbytes) - 1)        # varied, non-zero
      data_q.append(data)
      be_q.append(be)
      expected[BASE_ADDR_C + k * STRIDE_C] = _expected_partial(data, be, dbytes)

    # -- Phase 1: pipeline N partial writes. -----------------------------------
    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_initial_addr(BASE_ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_data(data_q)                   # custom data => CUSTOM mode
    wr.set_be(be_q)                       # custom BE   => WriteNoSnpPtl
    wr.set_get_response(True)
    wr.set_pipelined_send(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    wr_rsp = wr.get_responses()
    assert len(wr_rsp) == N_C, f"expected {N_C} partial-write responses, got {len(wr_rsp)}"
    for k, w in enumerate(wr_rsp):
      assert int(w.opcode) == int(ReqOpcode.WRITE_NO_SNP_PTL), \
        f"write {k} was not WriteNoSnpPtl (opcode 0x{int(w.opcode):x})"
      assert int(w.rsp_opcode) == int(RspOpcode.COMP_DBID_RESP), \
        f"partial write {k} carried wrong RSP opcode 0x{int(w.rsp_opcode):x}"

    await self.wait_clocks(SETTLE_C)

    # -- Phase 2: read every address back and check the masked merge image. ----
    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(N_C)
    rd.set_initial_addr(BASE_ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_pipelined_send(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    rd_rsp = rd.get_responses()
    assert len(rd_rsp) == N_C, f"expected {N_C} read responses, got {len(rd_rsp)}"
    for k, r in enumerate(rd_rsp):
      assert int(r.dat_opcode) == int(DatOpcode.COMP_DATA), \
        f"read {k} carried wrong DAT opcode 0x{int(r.dat_opcode):x}"
      assert int(r.addr) in expected, f"read {k} addr 0x{int(r.addr):x} has no write"
      assert int(r.data[0]) == expected[int(r.addr)], \
        f"partial merge mismatch addr 0x{int(r.addr):x}: read 0x{int(r.data[0]):x} " \
        f"expected 0x{expected[int(r.addr)]:x}"

    peak = self.rni_cfg.observed_peak_outstanding
    assert peak > 1, f"partial writes did not overlap: peak was {peak} (expected > 1)"

    self.logger.info(
      f"Test (tc_chi_d_multi_outstanding_partial) PASS: {N_C} WriteNoSnpPtl writes "
      f"pipelined, masked read-back verified, peak in-flight = {peak}")
    self.drop_objection()
