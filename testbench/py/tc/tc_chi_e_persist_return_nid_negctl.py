################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of tc/tc_chi_e_persist_return_nid_negctl.sv.
#
# The negative control for CHI_SB_RSP_TGTID_CORRECT.
#
# cfg.snf_persist_target_srcid_negctl makes the completer address a PCMO's
# Persist at the request's SrcID instead of its ReturnNID -- which is exactly
# what both ports did before that finding was fixed, so the control reproduces a
# real defect rather than an invented one.
#
# IHI 0050 E section 2.8 names ReturnNID as the target for that response, so the
# scoreboard must report it. tc_chi_e_persist_return_nid is the positive half:
# same traffic, same distinct ReturnNID, completer behaving, rule silent.
#
# The requester also refuses the misrouted Persist -- it looks for the response
# where the request asked for it -- and that refusal goes through reject(), so
# expect_rejection() records it here instead of ending the run. Both halves are
# asserted: the driver noticed, and the scoreboard reported.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_reject import expect_rejection
from vip_chi_write_cmo_seq import vip_chi_write_cmo_seq, CMO_CLEAN_SH_PER_SEP
from chi_e_base_test import chi_e_base_test

ADDR_C = 0x4B10_0000
SIZE_C = 6
SETTLE_C = 20
RULE_C = "CHI_SB_RSP_TGTID_CORRECT"
RETURN_NID_C = 0x1A5


class tc_chi_e_persist_return_nid_negctl(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    snf_cfg.snf_persist_target_srcid_negctl = True

  async def run_phase(self):
    self.raise_objection()

    sb = self.tb_env.scoreboard
    self.drain_observation_fifos()

    before_fail = sb.chk_fail.get(RULE_C, 0)
    assert before_fail == 0, (
      f"{RULE_C} already reported {before_fail} time(s) on bring-up traffic; "
      f"the count below would prove nothing")

    seq = vip_chi_write_cmo_seq("write_cmo_persist_negctl", cfg=self.chi_cfg)
    seq.set_partial(False)
    seq.set_cmo(CMO_CLEAN_SH_PER_SEP)
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(ADDR_C)
    seq.set_size(SIZE_C)
    # SrcID and ReturnNID must name different nodes or targeting the wrong one
    # is indistinguishable from targeting the right one.
    seq.set_return_nid(RETURN_NID_C)
    seq.set_get_response(True)
    seq.set_verbose(False)

    with expect_rejection("PERSIST_ROUTE"):
      await seq.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    after_fail = sb.chk_fail.get(RULE_C, 0)
    assert after_fail > before_fail, (
      f"{RULE_C} did not report a Persist addressed to SrcID when section 2.8 "
      f"requires ReturnNID. Either the control is not reaching the completer, "
      f"or the rule has gone back to pairing the Persist by the very field it "
      f"is supposed to judge -- which would make it unable to fail")

    self.logger.info(
      f"Test (tc_chi_e_persist_return_nid_negctl) PASS: a Persist misrouted to "
      f"SrcID was reported {after_fail - before_fail} time(s) by {RULE_C}, and "
      f"the requester refused it")

    self.drop_objection()
