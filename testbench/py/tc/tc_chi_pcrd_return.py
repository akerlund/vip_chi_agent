################################################################################
# pyUVM/cocotb port of tc/tc_chi_pcrd_return.sv.
#
# The other half of the retry handshake. tc_chi_pcrd_leak proves the requester
# NOTICES a P-credit it was granted and never used; this proves it can GIVE ONE
# BACK, which is what the specification actually requires: "any credits that are
# not required must be returned in a timely manner", because a held credit keeps
# a re-issue slot reserved at the completer forever.
#
# The setup is deliberately the leak test's setup -- pipelined RN-I, one clean
# write to bring the link to RUN, then a raw PCrdGrant that bounces nothing --
# with cfg.return_unused_pcrd turned ON. Same stimulus, opposite verdict: the
# credit must be handed back rather than counted as a leak.
#
# What is asserted, in order of what would otherwise go unnoticed:
#
#   * a PCrdReturn REQ actually reaches the wire, observed through the monitor.
#     Draining the driver's internal bank without emitting a flit would satisfy
#     every counter here and return nothing to the completer.
#   * its PCrdType matches the grant. A return naming the wrong type frees a
#     resource the completer never reserved and leaves the real one held.
#   * TxnID is zero and TgtID is the granter -- the identifier rules for this
#     transaction are fixed by the specification, not chosen by the requester.
#   * the bank is empty afterwards, so the leak check the sibling test guards
#     has nothing left to report.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, Resp, RespErr, RspOpcode
from chi_base_test import chi_base_test, WRITE_READ_ADDR_C
from vip_chi_raw_seq import vip_chi_raw_seq
from chi_tb_pkg import RNI_NODE_ID_C, SNF_NODE_ID_C

PCRD_TYPE_C = 0x3


class tc_chi_pcrd_return(chi_base_test):

  def configure_tb_cfg(self):
    # The injected PCrdGrant bounces nothing, so the scoreboard opens a context
    # for it that never completes and reports the stray flit as an incomplete
    # transaction. That is correct of the scoreboard and beside the point here:
    # this test is a guard on the driver's credit accounting.
    self.tb_cfg.scoreboard_enable = False

  def configure(self, rni_cfg, snf_cfg):
    # Only the pipelined path banks P-credits, so that is the path with anything
    # to return; the serial retry handler pairs its RetryAck and PCrdGrant
    # directly and never holds one.
    rni_cfg.multi_outstanding = True
    rni_cfg.return_unused_pcrd = True

  async def run_phase(self):
    self.raise_objection()

    driver = self.tb_env.rni_agent.rni_driver

    wr = self.rni0_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(WRITE_READ_ADDR_C)
    wr.set_size(6)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(4)
    self.drain_observation_fifos()

    raw_rsp = {
      "dbid": 0, "fwdstate": 0,
      "resp": int(Resp.I), "resperr": int(RespErr.OKAY),
      "opcode": int(RspOpcode.PCRD_GRANT), "txnid": 0,
      "pcrdtype": PCRD_TYPE_C,
      "srcid": SNF_NODE_ID_C, "tgtid": RNI_NODE_ID_C, "qos": 0x0,
    }

    snf_raw_seq = vip_chi_raw_seq("snf_raw_seq", cfg=self.chi_cfg)
    snf_raw_seq.reset()
    snf_raw_seq.add_raw_rsp(raw_rsp)
    await snf_raw_seq.start(self.v_sqr.snf_sequencer)

    await self.wait_clocks(16)

    # The credit went back on the wire, not just out of a dictionary.
    returned = None
    while True:
      ok, item = self.tb_env.rni_req_fifo.try_get()
      if not ok:
        break
      if int(item.opcode) == int(ReqOpcode.PCRD_RETURN):
        returned = item

    assert returned is not None, (
      "no PCrdReturn reached the wire: the banked credit was never handed back")
    assert int(returned.pcrd_type) == PCRD_TYPE_C, (
      f"PCrdReturn PCrdType 0x{int(returned.pcrd_type):x} did not match the "
      f"granted 0x{PCRD_TYPE_C:x}")
    assert int(returned.txn_id) == 0, (
      f"PCrdReturn TxnID 0x{int(returned.txn_id):x} was not zero")
    assert int(returned.tgt_id) == SNF_NODE_ID_C, (
      f"PCrdReturn TgtID 0x{int(returned.tgt_id):x} was not the granter "
      f"0x{SNF_NODE_ID_C:x}")

    assert driver.n_pcrd_returned == 1, (
      f"expected 1 returned credit, driver counted {driver.n_pcrd_returned}")
    assert driver.pcrd_pool.get(PCRD_TYPE_C, 0) == 0, (
      "the credit is still banked after the PCrdReturn went out")

    self.logger.info(
      "Test (tc_chi_pcrd_return) PASS: the unused P-credit was returned with a "
      "PCrdReturn carrying the granted PCrdType, TxnID zero and the granter as "
      "TgtID, leaving nothing banked")
    self.drop_objection()
