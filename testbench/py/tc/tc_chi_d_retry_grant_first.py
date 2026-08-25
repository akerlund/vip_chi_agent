################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_retry_grant_first.sv.
#
# The same retry flow as tc_chi_d_retry, with the two responses REORDERED: the
# SN-F sends the PCrdGrant before the RetryAck it answers.
#
# IHI 0050 E section 2.11 names this case and makes absorbing it mandatory:
# "It is possible that a reordering interconnect can reorder the responses such
# that the PCrdGrant is received by the Requester before the RetryAck response
# for the transaction is received. In this case, the Requester must record the
# credit it has received, including the credit type, so that it can assign the
# credit appropriately when it does receive the RetryAck response." The spec
# then softens the likelihood -- "It is expected to be rare" -- but not the
# requirement.
#
# The serial requester used to fatal here. Its retry loop returned on any RSP
# that was not a RetryAck, so the early grant was handed to the completion
# collector, which died on the unexpected opcode -- a VIP crash reported as a
# DUT failure, against a completer doing something the specification permits in
# so many words. The pipelined path in the same class already banked credits by
# type and absorbed it correctly; the two are selected by cfg.max_outstanding_*,
# which is not a knob anyone reading section 2.11 would think to check.
#
# cfg.snf_pcrd_grant_before_ack is NOT a negative control. It selects a legal
# completer behaviour, and nothing here is expected to be reported by anything --
# which is why the assertions below are the ordinary ones: the write completes,
# both responses were seen, and the data committed.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import RspOpcode
from chi_base_test import chi_base_test

ADDR_C = 0x3110_0000
SIZE_C = 4          # one 16-byte beat
BE_FULL_C = (1 << 16) - 1   # every byte of that beat enabled
SETTLE_C = 20
WRITTEN = 0xCAFE_0002


class tc_chi_d_retry_grant_first(chi_base_test):

  def configure(self, rni_cfg, snf_cfg):
    snf_cfg.force_retry_count = 1
    snf_cfg.snf_pcrd_grant_before_ack = True

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_initial_addr(ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_allow_retry(1)          # let the SN-F bounce it
    wr.set_data([WRITTEN])         # custom data => bounded by payload
    # Full byte enables for the one beat. This is what makes a sub-line write
    # legal: Table A-3 and Chapter 4 fix WriteNoSnpFull at a cache line length,
    # so a 16-byte write has to be a WriteNoSnpPtl -- and a Ptl with every byte
    # enabled in its Size window is exactly "write these 16 bytes". Supplying BE
    # is also what selects the Ptl opcode, and it keeps the enables deterministic
    # rather than randomized, which the readback below depends on.
    wr.set_be([BE_FULL_C])
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    wr_rsp = wr.get_responses()
    assert len(wr_rsp) == 1
    assert int(wr_rsp[0].rsp_opcode) == int(RspOpcode.COMP_DBID_RESP)

    # The ORDER is recorded, not just the presence of both. Without this the
    # testcase passes identically against a completer that ignored the knob and
    # sent RetryAck first -- which is to say, against no reordering at all, and
    # it would prove nothing about the requester absorbing one.
    retry_order = []
    while True:
      ok, obs = self.tb_env.rni_rsp_fifo.try_get()
      if not ok:
        break
      opcode = int(obs.rsp_opcode)
      if opcode in (int(RspOpcode.RETRY_ACK), int(RspOpcode.PCRD_GRANT)):
        retry_order.append(opcode)

    assert int(RspOpcode.RETRY_ACK) in retry_order, \
      "retryable write was never bounced with a RetryAck"
    assert int(RspOpcode.PCRD_GRANT) in retry_order, \
      "the RetryAck's PCrdGrant was never observed"
    assert retry_order[0] == int(RspOpcode.PCRD_GRANT), \
      "the PCrdGrant did not precede its RetryAck, so the reordering this " \
      "testcase exists to absorb never happened on the wire"

    await self.wait_clocks(SETTLE_C)

    rd = self.rni0_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(ADDR_C)
    rd.set_size(SIZE_C)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.v_sqr.rni_sequencer)

    rd_rsp = rd.get_responses()
    assert len(rd_rsp) == 1 and len(rd_rsp[0].data) == 1
    assert int(rd_rsp[0].data[0]) == WRITTEN, \
      f"retried write did not commit: read 0x{int(rd_rsp[0].data[0]):x}. The " \
      f"requester banked a P-credit that arrived before its RetryAck, so the " \
      f"re-issue had to spend that exact credit"

    self.logger.info("Test (tc_chi_d_retry_grant_first) PASS")
    self.drop_objection()
