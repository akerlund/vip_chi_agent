################################################################################
# pyUVM port of tc/chi_coh_snp_query_base_test.sv.
#
# SnpQuery (SNP 0x10, CHI-E only): the home asks a Requester what it holds
# instead of reading the answer out of its own snoop filter.
#
# IHI 0050 E 4.5: "Home can send a SnpQuery snoop without any corresponding
# request from a Requester", "The Snoop response must include the precise state
# of the cache line at the targeted Snoopee", "Snoopee must not return data with
# the Snoop response", and "The SnpQuery snoop must not change the state of the
# cache line at the Snoopee". Table 4-26 repeats the last of those row by row --
# all seven initial states have themselves as the expected final state, with no
# permitted alternative.
#
# The stimulus is chosen so the answer is one the encoding cannot say. RN-F0
# ReadUniques the line (the home records UC) and then dirties it locally, which
# is a silent transition the home never sees: the port holds UD and the filter
# holds UC. RN-F1 then reads, and the home queries RN-F0 first.
#
# Table 4-9 gives UC and UD ONE Resp encoding, because "Pass Dirty must only be
# asserted for a Snoop response with data" and Resp[2] is that bit. So the
# correct answer to this query is 0b010 from a port holding UD, the home's
# expectation from UC is the same 0b010, and the two agree -- a query cannot
# detect a silent clean-to-dirty transition, and must not claim to. A responder
# that reported its raw UD_PD instead would put a Pass Dirty bit on a data-less
# SnpResp and be flagged as a mismatch it did not commit.
#
# What is asserted here is therefore three things at once: the query was sent
# and answered, the answer left RN-F0's state untouched (rule D10 judged it and
# found nothing), and the reconciliation agreed with the filter.
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from chi_tb_pkg import WRITE_READ_ADDR_C

_SETTLE_C = 16


class chi_coh_snp_query_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    self.hnf_cfg.hnf_snp_query_enable = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    dirty_pattern = int("5A" * self.chi_cfg.data_bytes, 16)

    self.cfg_read_seq(self.hrnf0_rdunique_seq)
    await self.hrnf0_rdunique_seq.start(self.tb_env.hrnf0_agent.sequencer)
    unique_rsp = self.hrnf0_rdunique_seq.get_responses()
    self.tb_env.hrnf0_agent.rnf_driver.make_line_dirty(WRITE_READ_ADDR_C, dirty_pattern)

    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    shared_rsp = self.hrnf1_rdshared_seq.get_responses()

    await self.wait_clocks(_SETTLE_C)

    assert len(unique_rsp) == 1 and len(shared_rsp) == 1, \
      f"expected 1+1 responses, got {len(unique_rsp)}/{len(shared_rsp)}"

    hnf = self.tb_env.hnf_agent.hnf_driver
    assert hnf.n_snp_query_sent > 0, \
      "the home sent no SnpQuery, so nothing below judged anything"
    assert hnf.n_snp_query_dir_mismatch == 0, (
      f"the home reported {hnf.n_snp_query_dir_mismatch} SnpQuery/directory "
      f"mismatch(es); a silent UC->UD transition is invisible to Table 4-9's "
      f"encoding and must not be reported as one")

    checker = self.tb_env.coh_checker
    judged = checker.get_snp_preserving_judged_count()
    assert judged > 0, (
      "catalogue rule D10 judged no response, so the run says nothing about "
      "whether a query is allowed to move a line")
    assert checker.get_bad_snp_state_preserved_count() == 0, \
      "D10 flagged a conformant SnpQuery response"

    # The dirty copy survived the query. This is the property the opcode exists
    # for and the one a state-changing responder would break silently: a line
    # dropped here is dropped before the SnpShared that follows, so the dirty
    # data would never reach RN-F1 and the read would return stale memory.
    assert len(unique_rsp[0].data) == len(shared_rsp[0].data), "beat-count mismatch"
    for i in range(len(shared_rsp[0].data)):
      exp = int(unique_rsp[0].data[i]) ^ dirty_pattern
      assert int(shared_rsp[0].data[i]) == exp, \
        f"beat {i} carried 0x{int(shared_rsp[0].data[i]):x}, expected dirtied 0x{exp:x}"

    assert int(shared_rsp[0].rsp_resp) == int(Resp.SC), \
      f"ReadShared granted 0x{int(shared_rsp[0].rsp_resp):x}, expected SC"
    assert checker.total_violations() == 0, \
      "coherency violations on a run whose only added traffic is a query"

    self.logger.info(
      f"Test (coh_snp_query) PASS: {hnf.n_snp_query_sent} SnpQuery sent, D10 "
      f"judged {judged} response(s) and found nothing")
    self.drop_objection()
