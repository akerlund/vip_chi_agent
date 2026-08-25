################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_dwt_dbid_return_nid.sv.
#
# Where a Direct Write Transfer's DBIDResp is addressed.
#
# This is the OTHER limb of the rule tc_chi_e_persist_return_nid covers. IHI
# 0050 E Table 2-8 gives both in three rows:
#
#     DoDWT  CMO type                    DBIDResp          Persist
#       1    All                         HN.Req.ReturnNID  HN.Req.ReturnNID
#       0    CleanShared / CleanInvalid  HN.Req.SrcID      -
#       0    Persistent                  HN.Req.SrcID      HN.Req.ReturnNID
#
# and section 2.5 sends the TxnID with the target: "when DoDWT = 1, ReturnTxnID
# value is expected to be the original Requester TxnID [...] Used as the TxnID
# in the DBIDResp response". A DBIDResp under DWT is the one response in this
# VIP that changes BOTH addressing fields on a single request bit.
#
# The limb was unreachable rather than merely unchecked. DoDWT is REQ bit 17,
# shared with SnpAttr, and until then was fixed the item modelled that bit
# as DoDWT alone and every sequence pinned it to zero -- so no request could ask
# for DWT, and the routing rule had nothing to be wrong about. Fixing the field
# identity is what made this testable, which is the whole argument for fixing
# the field identity before the routing.
#
# Both fields are moved off the requester, and deliberately not to the same
# value: ReturnNID and ReturnTxnID are separate obligations, and a completer
# that got one right and the other wrong would pass a test that only separated
# one of them.
#
# What is asserted, at both ends of the claim:
#   * CHI_SB_RSP_TGTID_CORRECT records a pass and no failure, which is the rule
#     reading the grant's TgtID/TxnID off the wire;
#   * the write still completes, so the reroute is not achieved by dropping the
#     response -- the requester had to find its grant at the new address to
#     send its data at all.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_write_seq import vip_chi_write_seq
from chi_e_base_test import chi_e_base_test

ADDR_C = 0x4C00_0000
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


class tc_chi_e_dwt_dbid_return_nid(chi_e_base_test):

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard
    self.drain_observation_fifos()

    before_pass = sb.chk_pass.get(RULE_C, 0)
    before_fail = sb.chk_fail.get(RULE_C, 0)

    seq = vip_chi_write_seq("write_dwt_return_nid", cfg=self.chi_cfg)
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
    await seq.start(self.v_sqr.rni_sequencer)

    responses = seq.get_responses()
    assert len(responses) == 1, (
      f"the DWT write returned {len(responses)} responses, expected 1; "
      f"a reroute that drops the transaction proves nothing")

    await self.wait_clocks(SETTLE_C)

    after_pass = sb.chk_pass.get(RULE_C, 0)
    after_fail = sb.chk_fail.get(RULE_C, 0)

    assert after_fail == before_fail, (
      f"{RULE_C} reported {after_fail - before_fail} time(s) against a DBIDResp "
      f"the completer should have addressed to ReturnNID 0x{RETURN_NID_C:x} "
      f"under ReturnTxnID 0x{RETURN_TXN_ID_C:x}: Table 2-8 routes a DWT grant "
      f"there, not to the requester's SrcID/TxnID")
    assert after_pass > before_pass, (
      f"{RULE_C} recorded no pass, so this testcase proves nothing. Either the "
      f"grant never reached the scoreboard or the rule is not reading it -- "
      f"and a rule with no passes is indistinguishable from one that is absent")

    self.logger.info(
      f"Test (tc_chi_e_dwt_dbid_return_nid) PASS: the DBIDResp for a DoDWT "
      f"write was addressed to ReturnNID 0x{RETURN_NID_C:x} under ReturnTxnID "
      f"0x{RETURN_TXN_ID_C:x}, checked {after_pass - before_pass} time(s) "
      f"by {RULE_C}")

    self.drop_objection()
