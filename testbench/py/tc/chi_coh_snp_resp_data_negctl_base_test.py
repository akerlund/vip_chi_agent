################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# The negative control for the snoop response-FORM rule: a dirty snoopee answers
# SnpMakeInvalid on DAT, carrying the copy that snoop asks it to discard.
#
# IHI 0050 Chapter 4 defines SnpMakeInvalid by exactly that property -- the
# snoopee invalidates and discards any Dirty copy -- and Tables 4-9 / 4-11 list
# no SnpRespData form among its permitted responses. The encoding on the wire is
# legal in itself; what is prohibited is sending it IN ANSWER TO THIS SNOOP, so
# the rule needs the request and the response paired and cannot be written on
# encodings alone.
#
# Why a control is needed at all. The conforming snoopee never emits this
# pairing, so the rule's zero in every other run is unfalsifiable on its own:
# silence and absence look identical. cfg.rnf_snp_resp_data_negctl puts a dirty
# holder back on the data-bearing path for a no-data snoop, which is a response a
# real snoopee could emit -- the decision is corrupted, not the flit.
#
# The stimulus is the shortest path to a dirty holder meeting an invalidating
# snoop: RN-F0 takes the line with MakeUnique, which grants Unique-Dirty and
# materializes beats, then RN-F1 issues MakeInvalid, which makes the home send
# SnpMakeInvalid to RN-F0.
#
# The neighbouring rules must stay SILENT, and that is asserted rather than
# assumed. What is wrong here is the CHANNEL alone: the reported state is
# Invalid, which is what every response Chapter 4 permits to an invalidating
# snoop reports, so D5 passes it; and D7, which catches dirty data NOT handed
# over, excludes this opcode because discarding is what it asks for. A report
# from either would mean the form rule is being credited with a violation
# something else found.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_coherent_base_test import chi_coherent_base_test
from chi_coherency_negctl_catcher import chi_coherency_negctl_catcher
from chi_tb_pkg import WRITE_READ_ADDR_C
from vip_chi_makeinvalid_seq import vip_chi_makeinvalid_seq
from vip_chi_makeunique_seq import vip_chi_makeunique_seq

SETTLE_C = 40


class chi_coh_snp_resp_data_negctl_base_test(chi_coherent_base_test):

  def configure_agent_cfgs(self):
    super().configure_agent_cfgs()
    self.hrnf0_cfg.rnf_snp_resp_data_negctl = True

  async def run_phase(self):
    self.raise_objection()
    await self.wait_reset_settle()

    coh = self.tb_env.coh_checker

    # The provocation is declared, not merely provoked. Checker D's violations
    # are in the env's verdict, so a control that induces one and says nothing
    # fails on its own stimulus; the catcher demotes exactly what this test asked
    # for and counts it, and the count is held against the rule tallies below.
    catcher = chi_coherency_negctl_catcher("coh_snp_resp_data_catcher")
    coh.logger.addFilter(catcher)

    form_before = coh.get_bad_snp_resp_form_count()
    state_before = coh.get_bad_snp_resp_state_count()
    dirty_snoops_before = coh.get_snp_no_data_on_dirty_count()

    assert form_before == 0, (
      f"the response-form rule already reported {form_before} time(s) before "
      f"the control ran; the count below would prove nothing")

    # RN-F0 to Unique-Dirty, so the snoop that follows meets a holder with beats
    # to hand over.
    mu_seq = vip_chi_makeunique_seq("mu_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(mu_seq, WRITE_READ_ADDR_C)
    await mu_seq.start(self.tb_env.hrnf0_agent.sequencer)
    mu_seq.get_responses()

    # RN-F1 invalidates the same line: the home sends SnpMakeInvalid to RN-F0.
    mi_seq = vip_chi_makeinvalid_seq("mi_seq", cfg=self.chi_cfg)
    self.cfg_read_seq(mi_seq, WRITE_READ_ADDR_C)
    await mi_seq.start(self.tb_env.hrnf1_agent.sequencer)
    mi_seq.get_responses()

    await self.wait_clocks(SETTLE_C)

    # The snoop reached a DIRTY holder, which is the only combination that can
    # distinguish the two behaviours: a clean holder answers on RSP whatever the
    # opcode says, so a verdict taken over one would hold equally against a rule
    # that never ran.
    assert coh.get_snp_no_data_on_dirty_count() > dirty_snoops_before, (
      "no no-data snoop reached a dirty holder, so the control had nothing to "
      "corrupt and the verdict below would be about nothing")

    coh.logger.removeFilter(catcher)

    form_after = coh.get_bad_snp_resp_form_count()

    # Every demoted report is a response-form report, and every movement in that
    # tally produced one. The state rule is asserted silent below, so the form
    # rule is the only source the catcher can have had.
    assert catcher.claimed == (form_after - form_before), (
      f"the catcher demoted {catcher.claimed} report(s) but the response-form "
      f"tally moved by {form_after - form_before}: either a report escaped the "
      f"catcher, or a rule other than the one under test also fired")

    assert form_after > form_before, (
      "a dirty snoopee answered SnpMakeInvalid with data and nothing said so. "
      "Either the control is not reaching the responder, or the rule is not "
      "pairing the response channel with the snoop that asked")

    # The state axis is untouched by this control, and D5 judging the same
    # response must say so. A report here would mean the two rules are reading
    # one field between them.
    assert coh.get_bad_snp_resp_state_count() == state_before, (
      f"the state rule reported "
      f"{coh.get_bad_snp_resp_state_count() - state_before} time(s) on a "
      f"response whose state is Invalid, which is the only state Chapter 4 "
      f"permits to an invalidating snoop")

    assert coh.get_multi_owner_count() == 0, (
      f"{coh.get_multi_owner_count()} single-writer violation(s) while only the "
      f"response form was corrupted")

    self.logger.info(
      f"Test (coh_snp_resp_data_negctl) PASS: a dirty snoopee answering "
      f"SnpMakeInvalid on DAT was reported {form_after - form_before} time(s), "
      f"and the state rule beside it stayed silent")

    self.drop_objection()
