################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_sep_read_negctl.sv.
#
# The negative control for CHI_SB_ORIGINATOR_LEGAL, in two phases, because the
# rule has two ways of being reached and only one of them is a defect.
#
# PHASE 1 -- a Slave emits a Home-only response. cfg.snf_resp_sep_data_negctl
# restores what both ports did previously: the completer answers a
# ReadNoSnpSep with RespSepData. Appendix B Table B-3 gives RespSepData one From
# row, ICN(HN-F, HN-I), and section 2.3.1 says it in prose -- "RespSepData is
# permitted from the Home only." Every field on that flit is legal, it arrives
# on the right channel at the right moment, and the requester accepts it. The
# ONLY thing wrong with it is who sent it, which is precisely the class of
# defect no other check in either port can see.
#
# PHASE 2 -- the stand-in switched off. This link is point-to-point RN-I <-> SN-F
# with no Home component on it, so the RN-I plays the Home's REQ leg for the
# separated read and the checker grants it a Home's originator rights for that
# one opcode. Clearing scoreboard.home_standin takes the grant away and makes the
# checker judge the link as literal Appendix B, where ReadNoSnpSep from an RN-I
# has no row at all. That is not a defect being injected -- it is the VIP's
# documented departure being made visible. An exemption nothing can switch off is
# an exemption nobody can audit, and this phase is what proves the rule reaches
# the separated-read REQ rather than passing it by.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import RspOpcode
from chi_e_base_test import chi_e_base_test

RNI_NID_C = 0x15
SNF_NID_C = 0x2A
SEP_READ_ADDR_C = 0x0012_3456_7A00
SEP_RETURN_TXN_ID_C = 0x5A
SETTLE_C = 20
RULE_C = "CHI_SB_ORIGINATOR_LEGAL"


class tc_chi_e_sep_read_negctl(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    # Phase 1 only. Phase 2 clears it again -- the two provocations must be
    # counted apart or a single increment could stand in for both.
    rni_cfg.snf_resp_sep_data_negctl = True
    snf_cfg.snf_resp_sep_data_negctl = True

  async def issue_sep_read(self, txn_id):
    rd = self.rni_rd_seq
    rd.reset()
    rd.set_requests(1)
    rd.set_initial_addr(SEP_READ_ADDR_C)
    rd.set_size(6)
    rd.set_sep_read(True)
    rd.set_src_id(RNI_NID_C)
    rd.set_tgt_id(SNF_NID_C)
    rd.set_return_nid(RNI_NID_C)          # must == src_id
    rd.set_return_txn_id(txn_id)
    rd.set_get_response(True)
    rd.set_verbose(False)
    await rd.start(self.tb_env.rni_agent.sequencer)

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard
    # Declared, so the environment's end-of-test check knows this run provokes
    # it on purpose. expect_failure only changes what the aggregation and the
    # env make of the count -- the rule still evaluates, still counts and still
    # reports, which is what the assertions below read.

    sb.expect_failure(RULE_C)
    self.drain_observation_fifos()

    before = sb.chk_fail.get(RULE_C, 0)
    assert before == 0, (
      f"{RULE_C} already reported {before} time(s) on bring-up traffic; the "
      f"counts below would prove nothing")

    # -- Phase 1: a Slave emitting a Home-only response --------------------
    await self.issue_sep_read(SEP_RETURN_TXN_ID_C)
    await self.wait_clocks(SETTLE_C)

    # The illegal flit really went out. Without this the phase passes against a
    # completer that emitted nothing, because the rule is silent then too -- it
    # judges an arriving flit, and no flit is no judgement.
    saw_resp_sep_data = False
    while True:
      ok, obs = self.tb_env.rni_rsp_fifo.try_get()
      if not ok:
        break
      if int(obs.rsp_opcode) == int(RspOpcode.RESP_SEP_DATA):
        saw_resp_sep_data = True
    assert saw_resp_sep_data, (
      "the control did not emit a RespSepData at all, so nothing was provoked")

    after_phase1 = sb.chk_fail.get(RULE_C, 0)
    assert after_phase1 > before, (
      f"{RULE_C} did not report a RespSepData emitted by a node in the SN-F "
      f"role. Appendix B Table B-3 permits it from a Home only, so either the "
      f"RSP table is not being consulted or the monitor is not attributing the "
      f"flit to the node that sent it")

    # The stand-in is a REQ-side grant and must not have absorbed an RSP-side
    # violation: if this moved, the exemption is wider than it claims to be.
    assert sb.n_originator_standin == 1, (
      f"the Home stand-in fired {sb.n_originator_standin} time(s); it may cover "
      f"the ReadNoSnpSep REQ and nothing else")

    # -- Phase 2: the departure made visible -------------------------------
    self.rni_cfg.snf_resp_sep_data_negctl = False
    self.snf_cfg.snf_resp_sep_data_negctl = False
    sb.home_standin = False
    self.drain_observation_fifos()

    standin_before = sb.n_originator_standin
    await self.issue_sep_read(SEP_RETURN_TXN_ID_C + 1)
    await self.wait_clocks(SETTLE_C)

    after_phase2 = sb.chk_fail.get(RULE_C, 0)
    assert after_phase2 > after_phase1, (
      f"{RULE_C} did not report ReadNoSnpSep from an RN-I with the Home "
      f"stand-in switched off. Table B-1 gives that opcode two From rows, both "
      f"ICN, so with no stand-in it has no legal originator on this link -- a "
      f"silent pass here means the REQ table is not being consulted at all")
    assert sb.n_originator_standin == standin_before, (
      "the Home stand-in fired again after being switched off")

    self.logger.info(
      f"Test (tc_chi_e_sep_read_negctl) PASS: {RULE_C} reported a Home-only "
      f"RespSepData from a Slave {after_phase1 - before} time(s) and an "
      f"unexempted ReadNoSnpSep from an RN-I {after_phase2 - after_phase1} "
      f"time(s)")

    self.drop_objection()
