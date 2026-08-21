################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_hni_backpressure.sv.
#
# Starve the SN-facing links: both proxy SN targets advertise only a single
# inbound REQ and DAT credit, so the proxy's SN-facing send-credit managers can
# only hold one outstanding REQ / one outstanding write-DAT beat toward each SN at
# a time. Every proxied request must therefore lock-step against the SN returning
# a fresh credit -- the SN-facing analog of tc_chi_d_credit_starvation. Drive
# several write-then-read pairs through the proxy while the SN-facing links are
# credit-starved: the proxy must serialize its forwarding against the trickle of
# SN credits yet still relay every transaction end-to-end with its payload intact.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import RspOpcode, DataType
from chi_hni_base_test import chi_hni_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C

N_TXNS_C = 3


class tc_chi_d_hni_backpressure(chi_hni_base_test):

  def configure(self):
    # Runtime credit-hold is RN-I only; the SN-F driver seeds its advertised
    # credits statically, so a constrained initial pool is the SN-side lever.
    # Both targets are constrained so the backpressure applies regardless of how
    # the HN-I routes each address.
    self.hsnf0_cfg.initial_req_credits = 1
    self.hsnf0_cfg.initial_dat_credits = 1
    self.hsnf1_cfg.initial_req_credits = 1
    self.hsnf1_cfg.initial_dat_credits = 1

  async def run_phase(self):
    self.raise_objection()

    await self.wait_clocks(4)

    for i in range(N_TXNS_C):
      addr = WRITE_READ_ADDR_C + i * 0x100
      base_val = 0xB0 + i * 16

      wr = self.rni0_wr_seq
      wr.reset()
      wr.set_requests(1)
      wr.set_initial_addr(addr)
      wr.set_size(6)
      wr.set_data_type(DataType.COUNTER)
      wr.set_counter_value(base_val)
      wr.set_counter_increment(0x1)
      wr.set_get_response(True)
      wr.set_verbose(False)
      await wr.start(self.v_sqr.hrni0_sequencer)

      write_responses = wr.get_responses()
      assert len(write_responses) == 1, \
        f"write {i} expected 1 proxied completion under backpressure, got {len(write_responses)}"
      assert int(write_responses[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP), \
        f"write {i} completion carried wrong opcode 0x{int(write_responses[0].rsp_opcode):x}"

      rd = self.rni0_rd_seq
      rd.reset()
      rd.set_requests(1)
      rd.set_initial_addr(addr)
      rd.set_size(6)
      rd.set_get_response(True)
      rd.set_verbose(False)
      await rd.start(self.v_sqr.hrni0_sequencer)

      read_responses = rd.get_responses()
      assert len(read_responses) == 1, \
        f"read {i} expected 1 proxied completion under backpressure, got {len(read_responses)}"
      assert len(read_responses[0].data) == 4, \
        f"read {i} returned {len(read_responses[0].data)} beats instead of 4 under backpressure"

      # Readback data integrity: each read returns exactly what was written.
      assert [int(x) for x in read_responses[0].data] == \
             [int(x) for x in write_responses[0].data], \
        f"read {i} payload did not match the write under backpressure"

    self.logger.info(
      f"Test (tc_chi_d_hni_backpressure) PASS: HN-I proxy relayed {N_TXNS_C} "
      "write+read pairs under SN-facing credit backpressure")
    self.drop_objection()
