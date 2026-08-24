################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_txnid_reuse_srcid_scope.sv.
#
# The TxnID-reuse rules read against the scope section 2.5 actually gives them:
#
#   "It is required that the TxnID, except for PrefetchTgt, must be unique for a
#    given Requester. The Requester is identified by the SrcID."
#
# So the rule has two halves that pull in opposite directions, and a checker can
# get one right while getting the other wrong:
#
#   step 2  two SOURCES holding the same TxnID at once is LEGAL, and on a fan-in
#           link unavoidable -- each requester allocates from its own pool and
#           nothing coordinates them. The rule must not report.
#   step 3  ONE source reusing its own live TxnID is the violation, and it stays
#           a violation after another source has touched the same value.
#
# Step 3 is the one that matters, and it is why this test exists rather than
# resting on tc_chi_e_write_unique_zero_negctl, which already proves a plain
# self-reuse reports. The shadow behind these rules used to be one slot per TxnID
# with a note of the LAST source to claim it. Under that shape:
#
#   A takes TxnID T          slot T is live, owner A
#   B takes TxnID T          legal, and the owner becomes B
#   A takes TxnID T again    owner is B, so A != owner -- PASSES, wrongly
#
# The violation went missing exactly because a legal event happened in between.
# That is a MISSED violation, which no ordinary test can see: the run is green
# either way. Only a control that walks the three steps in order can tell the two
# shadows apart, and this one fails against the old one at step 3.
#
# Raw injection, because SrcID is what is under test and a sequence stamps its
# own. The flits are otherwise the same well-formed WriteUniqueZero that
# tc_chi_e_write_unique_zero_negctl uses, for the same reason: it has a modeled
# completion, so the reuse rule arms on it, and its completion form is a single
# CompDBIDResp.
#
# Completions are TARGETED, and that is load-bearing. A response retires the
# request it is aimed at, so the checker reads the requester's identity out of
# the response's TgtID -- a completion aimed at A must not retire B's claim on
# the same TxnID. Injecting one completion per source is what proves it does not.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import ReqOpcode, Resp, RespErr, RspOpcode
from chi_e_base_test import chi_e_base_test
from vip_chi_raw_seq import vip_chi_raw_seq
from chi_tb_pkg import (E_WUZ_NEGCTL_ADDR_C, E_WUZ_NEGCTL_SNF_NODE_ID_C,
                        TXNID_SCOPE_SRC_A_C, TXNID_SCOPE_SRC_B_C,
                        TXNID_SCOPE_TXN_ID_C)

NON_SECURE_C = 1
SETTLE_C = 40
# Same hold, and the same reason, as tc_chi_e_write_unique_zero_negctl: the
# raw-inject path scopes a REQ's outstanding window to the flit, and these
# requests stay outstanding until the completions below. Under-assertion is the
# violation TXSACTIVE_COVERS_OUTSTANDING reports; over-assertion is legal.
TXSACTIVE_EXTEND_C = 48
REUSE_REQUESTER_C = "CHI_TXNID_REUSE_REQUESTER"
REUSE_COMPLETER_C = "CHI_TXNID_REUSE_COMPLETER"
COMPLETION_C = "CHI_COMPLETION_FOLLOWS_REQ"
# One report, on step 3's flit alone. Steps 1 and 2 are legal traffic and must
# contribute nothing, which is what makes "exactly one" the right assertion and
# "at least one" the wrong one.
EXPECTED_REUSE_C = 1


class tc_chi_txnid_reuse_srcid_scope(chi_e_base_test):

  def configure_tb_cfg(self):
    super().configure_tb_cfg()
    # The injected requests are completed by this test, not by the responder.
    self.tb_cfg.scoreboard_enable = False
    self.tb_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    rni_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C
    # The SN-F needs the same hold, and for a reason this testbench creates
    # rather than the VIP: a raw-injected request is one the SN-F does not
    # service, so it opens its window at capture and closes it again with
    # nothing to send, while the completion this test supplies arrives cycles
    # later. Section 14.7.2 requires the sideband to cover the gap, and the
    # checker is right to report it -- there is simply no completer here to be
    # wrong, because the test is driving both ends. Over-assertion is legal;
    # under-assertion is the violation.
    snf_cfg.txsactive_extend_max_cycles = TXSACTIVE_EXTEND_C

  def _write_unique_zero(self, src_id: int, txn_id: int) -> dict:
    return {
      "txnid": txn_id,
      "srcid": src_id,
      "tgtid": E_WUZ_NEGCTL_SNF_NODE_ID_C,
      "opcode": int(ReqOpcode.WRITE_UNIQUE_ZERO),
      "addr": E_WUZ_NEGCTL_ADDR_C,
      "size": 6,
      # Snoopable only (Table 2-14), and Table 2-12 lists no Snoopable row
      # without Cacheable and EWA. A raw flit bypasses the sequence's per-opcode
      # defaults, so both are set here.
      "snpattr": 1,
      "memattr": 0b0101,
      "ns": NON_SECURE_C,
      "allowretry": 1,
      "qos": 0x7,
    }

  # TgtID is the requester this completion is aimed at, and it is the field the
  # checker keys the retirement on.
  def _comp_dbid_resp(self, tgt_id: int, txn_id: int) -> dict:
    return {
      "opcode": int(RspOpcode.COMP_DBID_RESP),
      "txnid": txn_id,
      "dbid": txn_id,
      "resp": int(Resp.I),
      "resperr": int(RespErr.OKAY),
      "srcid": E_WUZ_NEGCTL_SNF_NODE_ID_C,
      "tgtid": tgt_id,
      "qos": 0x7,
    }

  def _fails(self) -> tuple[int, int]:
    return (self.tb_env.rni_sva.fail_count.get(REUSE_REQUESTER_C, 0),
            self.tb_env.snf_sva.fail_count.get(REUSE_COMPLETER_C, 0))

  def _passes(self) -> tuple[int, int]:
    return (self.tb_env.rni_sva.pass_count.get(REUSE_REQUESTER_C, 0),
            self.tb_env.snf_sva.pass_count.get(REUSE_COMPLETER_C, 0))

  async def _inject_req(self, src_id: int, txn_id: int) -> None:
    seq = vip_chi_raw_seq("rni_raw_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.add_raw_req(self._write_unique_zero(src_id, txn_id))
    await seq.start(self.tb_env.rni_agent.sequencer)

  async def _inject_completion(self, tgt_id: int, txn_id: int) -> None:
    seq = vip_chi_raw_seq("snf_raw_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.add_raw_rsp(self._comp_dbid_resp(tgt_id, txn_id))
    await seq.start(self.tb_env.snf_agent.sequencer)

  async def run_phase(self):
    self.raise_objection()

    # Compliant traffic first, so the silence asserted below is a statement
    # about compliant flits rather than about an idle link.
    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(E_WUZ_NEGCTL_ADDR_C)
    wr.set_size(6)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.tb_env.rni_agent.sequencer)

    await self.wait_clocks(4)
    self.drain_observation_fifos()

    fails = self._fails()
    assert fails == (0, 0), (
      f"the reuse rules already reported rni_e={fails[0]} snf_e={fails[1]} "
      f"time(s) on compliant traffic; the counts below would prove nothing")

    # -- Step 1: source A claims the TxnID. -----------------------------------
    await self._inject_req(TXNID_SCOPE_SRC_A_C, TXNID_SCOPE_TXN_ID_C)
    await self.wait_clocks(4)

    # -- Step 2: source B claims the SAME TxnID. Legal, and must pass. --------
    pass_before = self._passes()
    await self._inject_req(TXNID_SCOPE_SRC_B_C, TXNID_SCOPE_TXN_ID_C)
    await self.wait_clocks(4)

    fails = self._fails()
    assert fails == (0, 0), (
      f"a second SOURCE claiming TxnID 0x{TXNID_SCOPE_TXN_ID_C:x} reported "
      f"rni_e={fails[0]} snf_e={fails[1]}; section 2.5 scopes uniqueness to a "
      f"requester identified by SrcID, so this is legal traffic and the rule "
      f"is reading 'unique per link' instead")

    pass_after = self._passes()
    assert (pass_after[0] > pass_before[0] and pass_after[1] > pass_before[1]), (
      f"the reuse rules recorded no pass for the second source: "
      f"rni_e {pass_before[0]} -> {pass_after[0]}, "
      f"snf_e {pass_before[1]} -> {pass_after[1]}. Silence here is a rule that "
      f"never evaluated, not a rule that held")

    # -- Step 3: source A reuses its OWN live TxnID. Must report. -------------
    #
    # Suppress the report, keep the count, because both ends are about to fail.
    self.tb_env.rni_sva.off_check(REUSE_REQUESTER_C)
    self.tb_env.snf_sva.off_check(REUSE_COMPLETER_C)

    await self._inject_req(TXNID_SCOPE_SRC_A_C, TXNID_SCOPE_TXN_ID_C)
    await self.wait_clocks(4)

    # One completion per source, each aimed at the requester that holds the
    # claim. Two are needed, and that is the point: a single completion would
    # leave one source's claim live and time the completion rule out.
    await self._inject_completion(TXNID_SCOPE_SRC_A_C, TXNID_SCOPE_TXN_ID_C)
    await self.wait_clocks(4)
    await self._inject_completion(TXNID_SCOPE_SRC_B_C, TXNID_SCOPE_TXN_ID_C)
    await self.wait_clocks(SETTLE_C)

    reuse_rni, reuse_snf = self._fails()

    assert reuse_rni == EXPECTED_REUSE_C, (
      f"{REUSE_REQUESTER_C} reported {reuse_rni} time(s) at the RN-I against "
      f"exactly {EXPECTED_REUSE_C}. Zero means the shadow lost source A's claim "
      f"when source B touched the same TxnID -- the missed violation this test "
      f"exists for; more means it is also firing on the legal step 2")
    assert reuse_snf == EXPECTED_REUSE_C, (
      f"{REUSE_COMPLETER_C} reported {reuse_snf} time(s) at the SN-F against "
      f"exactly {EXPECTED_REUSE_C}; the receiving vantage is not doing its half")

    completion_fails = (self.tb_env.rni_sva.fail_count.get(COMPLETION_C, 0),
                        self.tb_env.snf_sva.fail_count.get(COMPLETION_C, 0))
    assert completion_fails == (0, 0), (
      f"{COMPLETION_C} reported rni_e={completion_fails[0]} "
      f"snf_e={completion_fails[1]}; a completion timeout would mean one "
      f"source's claim was never retired, which would mix the verdicts")

    self.logger.info(
      f"Test (tc_chi_txnid_reuse_srcid_scope) PASS: two sources held TxnID "
      f"0x{TXNID_SCOPE_TXN_ID_C:x} at once without a report, and source A "
      f"reusing its own live TxnID afterwards reported {reuse_rni} time(s) at "
      f"each end")

    self.drop_objection()
