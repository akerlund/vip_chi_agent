################################################################################
# pyUVM/cocotb port of tc/tc_chi_ordered_write_no_comp_ack.sv.
#
# Ordered write stream WITHOUT ExpCompAck.
#
# An ordered write does not have to ask for a CompAck. The Order field asks the
# completer to acknowledge in receipt order; ExpCompAck asks for a separate
# requester-driven acknowledgement afterwards. They are independent, and a source
# is entitled to set the first without the second.
#
# This combination had no coverage: every other ordered-write test sets
# ExpCompAck, so the pipeline retired ordered writes only ever on the path where
# a CompAck follows the completion. That left the plain path -- where a write
# retires the moment its data is sent and its completion is seen -- unexercised
# for ordered traffic, which is precisely where a missing retire condition would
# strand the pipeline with no diagnostic beyond a test that never finishes.
#
# The completion opcode is asserted, not just the response count. A run that
# merely terminated would prove the pipeline did not deadlock; requiring each
# write to hand back the combined CompDBIDResp proves it retired on the
# completion the completer actually sent.
#
# Scope: the SN-F's default combined-completion policy on the CHI-D cut. The
# split DBIDResp+Comp policy and the CHI-E DBIDRespOrd variant are each a
# separate static SN-F configuration and are not covered here.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOrder, RspOpcode
from chi_base_test import chi_base_test

N_C = 6
BASE_ADDR_C = 0x3C80_0000
SIZE_C = 6                      # 64 B = 4 beats on the CHI-D cut
SETTLE_C = 20


class tc_chi_ordered_write_no_comp_ack(chi_base_test):

  # Both ends have to overlap: the RN-I must keep several writes in flight and
  # the SN-F must buffer them rather than servicing each to completion before
  # sampling the next. A stream one deep would retire on the serial path and
  # never reach the pipeline retire condition this test exists to exercise.
  def configure(self, rni_cfg, snf_cfg):
    rni_cfg.multi_outstanding = True
    rni_cfg.multi_outstanding_write = True
    rni_cfg.max_outstanding_write = N_C
    snf_cfg.multi_outstanding = True

  async def run_phase(self):
    self.raise_objection()

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(N_C)
    wr.set_initial_addr(BASE_ADDR_C)
    wr.set_size(SIZE_C)
    wr.set_order(int(ReqOrder.REQ_ORDER))
    wr.set_exp_comp_ack(0)
    wr.set_get_response(True)
    wr.set_pipelined_send(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    wr_peak = self.rni_cfg.observed_peak_outstanding
    wr_rsp = wr.get_responses()

    await self.wait_clocks(SETTLE_C)

    # Every write must have come back. A stranded pipeline would hang rather than
    # return short, but a short return is the cheaper failure to diagnose and
    # costs nothing to check.
    assert len(wr_rsp) == N_C, (
      f"expected {N_C} write responses, got {len(wr_rsp)}")

    # Retired on the completer's own completion flit, not merely retired.
    for k, w in enumerate(wr_rsp):
      assert int(w.rsp_opcode) == int(RspOpcode.COMP_DBID_RESP), (
        f"write {k} (txn 0x{int(w.txn_id):x}) completed with opcode "
        f"0x{int(w.rsp_opcode):x}, expected CompDBIDResp "
        f"0x{int(RspOpcode.COMP_DBID_RESP):x}")
      assert int(w.exp_comp_ack) == 0, (
        f"write {k} (txn 0x{int(w.txn_id):x}) carried ExpCompAck - this test "
        f"covers the path where it is clear")

    # A stream one deep can never be out of order, so a run that never overlapped
    # proves nothing and must not be read as a pass.
    assert wr_peak > 1, (
      f"ordered write stream did not overlap: peak in-flight was {wr_peak}, "
      f"expected > 1")

    # The ordering guarantee still applies without ExpCompAck: the acknowledging
    # flit is the CompDBIDResp itself.
    sb = self.tb_env.scoreboard
    acks = sb.get_order_checked_count()

    assert acks >= N_C, (
      f"ordered-stream check compared only {acks} acknowledgements, expected at "
      f"least {N_C} -- the check did not see this traffic")
    assert sb.get_order_violation_count() == 0, (
      f"ordered-stream check reported {sb.get_order_violation_count()} "
      f"out-of-order acknowledgement(s) on a completer that serves requests "
      f"first-come-first-served")

    self.logger.info(
      f"Test (tc_chi_ordered_write_no_comp_ack) PASS: {N_C} ordered writes "
      f"without ExpCompAck retired on CompDBIDResp in order ({acks} compared; "
      f"peak in-flight {wr_peak})")
    self.drop_objection()
