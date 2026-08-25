################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_dwt_dbid_return_nid_negctl.sv.
#
# The negative control for the DWT limb of CHI_SB_RSP_TGTID_CORRECT.
#
# cfg.snf_dwt_dbid_target_srcid_negctl makes the completer address the write's
# DBIDResp at the request's SrcID under the request's own TxnID, when DoDWT = 1
# puts it at ReturnNID under ReturnTxnID (Table 2-8, and section 2.5 for the
# TxnID). That is what both ports did before this finding was fixed, so the
# control reproduces a real defect rather than an invented one.
#
# tc_chi_e_dwt_dbid_return_nid is the positive half: same traffic, same distinct
# return path, completer behaving, rule silent.
#
# The requester also refuses the misrouted grant, because it is waiting on
# ReturnTxnID and the flit carries the request's own -- so the refusal is not
# incidental to the control, it is the second observer of the same defect.
#
# What is asserted, at both ends of the claim:
#   * CHI_SB_RSP_TGTID_CORRECT reports at least once, which is the rule reading
#     the grant's address off the wire and finding it wrong;
#   * the requester refused it, which proves the control reached the completer.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_reject import expect_rejection
from vip_chi_write_seq import vip_chi_write_seq
from chi_e_base_test import chi_e_base_test

ADDR_C = 0x4C10_0000
SIZE_C = 6
SETTLE_C = 20
RULE_C = "CHI_SB_RSP_TGTID_CORRECT"

# A node that is deliberately NOT the requester and NOT the completer, so a
# grant addressed to SrcID and one addressed to ReturnNID are distinguishable.
# It does not have to exist: the link is point to point, so the flit arrives
# here whatever its TgtID says, and the TgtID is the thing under test.
RETURN_NID_C = 0x1A5

# Likewise off the requester's own TxnID. Picked high so it cannot collide with
# an allocated TxnID and be right by accident.
RETURN_TXN_ID_C = 0x5C


class tc_chi_e_dwt_dbid_return_nid_negctl(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    snf_cfg.snf_dwt_dbid_target_srcid_negctl = True

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard
    # Declared, so the environment's end-of-test check knows this run provokes
    # it on purpose. expect_failure only changes what the aggregation and the
    # env make of the count -- the rule still evaluates, still counts and still
    # reports, which is what the assertions below read.

    sb.expect_failure(RULE_C)
    self.drain_observation_fifos()

    before_fail = sb.chk_fail.get(RULE_C, 0)
    assert before_fail == 0, (
      f"{RULE_C} already reported {before_fail} time(s) on bring-up traffic; "
      f"the count below would prove nothing")

    seq = vip_chi_write_seq("write_dwt_return_nid_negctl", cfg=self.chi_cfg)
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(ADDR_C)
    seq.set_size(SIZE_C)
    # The three settings that make the routing observable. Without the first
    # there is no DWT; without the other two the return path names the
    # requester and a grant sent either way lands in the same place.
    seq.set_dodwt(1)
    seq.set_return_nid(RETURN_NID_C)
    seq.set_return_txn_id(RETURN_TXN_ID_C)
    seq.set_get_response(True)
    seq.set_verbose(False)

    with expect_rejection("DWT_GRANT_ROUTE"):
      await seq.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    after_fail = sb.chk_fail.get(RULE_C, 0)
    assert after_fail > before_fail, (
      f"{RULE_C} did not report a DWT grant addressed to SrcID/TxnID when "
      f"Table 2-8 requires ReturnNID/ReturnTxnID. Either the control is not "
      f"reaching the completer, or the rule has gone back to pairing the grant "
      f"by the very fields it is supposed to judge -- which would make it "
      f"unable to fail")

    self.logger.info(
      f"Test (tc_chi_e_dwt_dbid_return_nid_negctl) PASS: a DWT grant misrouted "
      f"to SrcID/TxnID was reported {after_fail - before_fail} time(s) by "
      f"{RULE_C}, and the requester refused it")

    self.drop_objection()
