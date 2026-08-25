################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of tc/chi_coh_evict_allocate_negctl_base_test.sv.
#
# Negative control for CHI_REQ_ALLOCATE_LEGAL, and the proof that the rule is not
# redundant with the two that already read MemAttr.
#
# E section 2.9.3 / D section 2.9.3 puts Evict on the Allocate field's
# inapplicable-and-must-be-zero list, and Table A-3's Allocate column gives it a
# literal zero. Nothing else in the checker can see it: Table 2-12's Snoopable
# rows leave Allocate free, so an Evict carrying it is a legal tuple with an
# inapplicable field set.
#
# That is what this control turns into evidence. The Evict is issued with
# MemAttr = {Allocate 1, Cacheable 1, Device 0, EWA 1}, which is Table 2-12
# row-legal against the SnpAttr = 1 the opcode requires -- so
# CHI_REQ_ATTR_COMBINATION_LEGAL and CHI_REQ_SNP_ATTR_LEGAL must both stay SILENT
# while this rule reports. Asserting their silence is the whole point: it is what
# separates a rule with its own content from an id that can only fail behind
# another.
#
# The Evict is still required to COMPLETE and the directory to clear. A control
# that leaves the transaction broken has proved the stimulus rather than the rule.
#
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import Resp
from chi_coherent_base_test import chi_coherent_base_test
from vip_chi_evict_seq import vip_chi_evict_seq
from chi_tb_pkg import WRITE_READ_ADDR_C

_CHK_C = "CHI_REQ_ALLOCATE_LEGAL"
_TUPLE_C = "CHI_REQ_ATTR_COMBINATION_LEGAL"
_SNP_ATTR_C = "CHI_REQ_SNP_ATTR_LEGAL"
# {Allocate, Cacheable, Device, EWA} in Table 13-21 bit order. Allocate is the
# inapplicable bit; the other three carry the values the opcode requires, so the
# tuple this drives is one Table 2-12 lists.
_MEM_ATTR_C = 0b1101


class chi_coh_evict_allocate_negctl_base_test(chi_coherent_base_test):

  # Both ends of the link the Evict crosses: the requester drives the flit and
  # the home receives it, and a field-applicability rule has to hold at both.
  def connect_phase(self):
    super().connect_phase()
    self.tb_env.hrnf_sva[1].expect_failure(_CHK_C)
    self.tb_env.hnfr_sva[1].expect_failure(_CHK_C)

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    # RN-F1 has to hold the line before it can evict it.
    self.cfg_read_seq(self.hrnf1_rdshared_seq)
    await self.hrnf1_rdshared_seq.start(self.tb_env.hrnf1_agent.sequencer)
    self.hrnf1_rdshared_seq.get_responses()

    ev_seq = vip_chi_evict_seq("hrnf1_ev_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(ev_seq)
    ev_seq.set_mem_attr(_MEM_ATTR_C)
    await ev_seq.start(self.tb_env.hrnf1_agent.sequencer)
    ev_rsp = ev_seq.get_responses()

    await self.wait_clocks(8)

    assert len(ev_rsp) == 1, (
      f"the Evict never completed (got {len(ev_rsp)} response(s)), so the "
      f"control proved the stimulus and not the rule")

    reported = self.tb_env.hrnf_sva[1].fail_count.get(_CHK_C, 0)
    assert reported > 0, (
      f"{_CHK_C} did not report an Evict carrying Allocate at the requester "
      f"vantage")
    assert self.tb_env.hnfr_sva[1].fail_count.get(_CHK_C, 0) > 0, (
      "the home received the same flit and did not report it, so the rule is "
      "wired at one vantage only")

    # The non-redundancy claim, asserted rather than argued.
    tuple_fails = self.tb_env.hrnf_sva[1].fail_count.get(_TUPLE_C, 0)
    snp_fails = self.tb_env.hrnf_sva[1].fail_count.get(_SNP_ATTR_C, 0)
    assert tuple_fails == 0 and snp_fails == 0, (
      f"the tuple rule reported {tuple_fails} and the SnpAttr rule "
      f"{snp_fails}: this MemAttr is Table 2-12 legal for a Snoopable request, "
      f"and if either of those fires the new rule has not been shown to have "
      f"content of its own")

    hnf = self.tb_env.hnf_agent.hnf_driver
    assert hnf.get_directory_port_state(WRITE_READ_ADDR_C, 1) == int(Resp.I), \
      "the home's directory port1 is not Invalid after the Evict"

    self.logger.info(
      f"Test (coh_evict_allocate_negctl) PASS: {_CHK_C} reported an Evict "
      f"carrying Allocate {reported} time(s) at the requester and at the home, "
      f"the tuple and SnpAttr rules stayed silent, and the Evict completed")
    self.drop_objection()
