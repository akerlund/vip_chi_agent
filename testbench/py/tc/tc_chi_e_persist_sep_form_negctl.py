################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# The negative control for the separated-persist completion FORM: the completer
# sends a standalone Persist first and CompPersist after it, and the requester
# must refuse the sequence.
#
# A requester must accept either of two forms, and only those two:
#
#   * Comp then Persist -- Point of Coherency reached, then Point of
#     Persistence. Two milestones, two responses.
#   * CompPersist alone -- the completer combined them.
#
# Persist-then-CompPersist is neither: no bare Comp ever arrives, and
# persistence is signalled twice, once alone and again inside the combined
# response. It is also the shape this VIP's own completer used to produce, which
# is why its requester used to demand it -- the two agreed with each other and
# were wrong together, which is the failure mode a control on ONE side cannot
# find.
#
# cfg.snf_persist_before_comp_negctl reproduces that shape in full, TxnID
# included, and the TxnID is the reason this test asserts TWO rules rather than
# one. A standalone Persist is not tied to a transaction, so carrying the
# request's TxnID is a second defect in the same flit, and CHI_RSP_FIELD_ZERO
# judges it independently of the requester's opinion. Asserting both is what
# distinguishes a completer put back on the old shape from one that merely sent
# an unexpected opcode.
#
# The refusal arrives through reject() rather than as a raised exception, so it
# is recorded as a tested OUTCOME and the run continues -- the pyUVM counterpart
# of a demoted `uvm_fatal in the SV twin.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_e_base_test import chi_e_base_test
from vip_chi_reject import expect_rejection
from vip_chi_persist_seq import vip_chi_persist_seq

ADDR_C = 0x4D40_0000
SIZE_C = 6
SETTLE_C = 20

# The field rule the same flit breaks: Table A-4 requires a standalone Persist to
# carry TxnID = 0.
FIELD_RULE_C = "CHI_RSP_FIELD_ZERO"
# The collateral, and it is inherent rather than sloppy: a refused completion is
# never retired, so the transaction stays outstanding for the rest of the run
# while the requester's activity window closes over it. Any control that makes a
# requester ABANDON a transaction produces this, and a control that suppressed it
# without saying so would be hiding the consequence of its own injection.
OUTSTANDING_RULE_C = "CHI_TXSACTIVE_COVERS_OUTSTANDING"


class tc_chi_e_persist_sep_form_negctl(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    snf_cfg.snf_persist_before_comp_negctl = True

  async def run_phase(self):
    self.raise_objection()

    # Declared at both binds, because the flit is seen at both. Declaring it
    # keeps the deliberate violation out of the environment's verdict; the rule
    # still evaluates and still counts, which is what the assertion below reads.
    for checker in (self.tb_env.rni_sva, self.tb_env.snf_sva):
      checker.expect_failure(FIELD_RULE_C)
      checker.expect_failure(OUTSTANDING_RULE_C)

    self.drain_observation_fifos()

    before = (self.tb_env.rni_sva.fail_count.get(FIELD_RULE_C, 0) +
              self.tb_env.snf_sva.fail_count.get(FIELD_RULE_C, 0))
    outstanding_before = (
      self.tb_env.rni_sva.fail_count.get(OUTSTANDING_RULE_C, 0) +
      self.tb_env.snf_sva.fail_count.get(OUTSTANDING_RULE_C, 0))
    assert before == 0, (
      f"{FIELD_RULE_C} already reported {before} time(s) on bring-up traffic; "
      f"the count below would prove nothing")

    # A STANDALONE CleanSharedPersistSep, not the combined Write + CMO. Only the
    # standalone form is collected by collect_persist_sep_completion, which is
    # the guard under test; a combined request completes through the obligation
    # loop and would never reach it.
    seq = vip_chi_persist_seq("persist_sep_form_negctl", cfg=self.chi_cfg)
    seq.reset()
    seq.set_sep_persist(True)
    # TWO requests, and the reason is the TxnID. The requester's first wait is
    # TxnID-matched, so the injected Persist must carry the request's TxnID to
    # reach the opcode check at all -- which means whether it ALSO breaks the
    # field rule depends on whether that TxnID happens to be zero. Two
    # consecutive requests cannot both draw zero, so the field arm is reached
    # whatever the allocator starts from, and neither assertion below is hostage
    # to it.
    seq.set_requests(2)
    seq.set_initial_addr(ADDR_C)
    seq.set_size(SIZE_C)
    seq.set_get_response(True)
    seq.set_verbose(False)

    # One refusal per request, and each on the FIRST completion: Persist is wrong
    # as an opening move whatever follows it, so a requester that waited to see
    # the CompPersist before objecting would be judging the pair rather than the
    # form.
    with expect_rejection("PERSIST_SEP_FIRST_COMPLETION", count=2) as refusal:
      await seq.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    assert refusal.hits == 2, (
      f"the requester refused Persist-then-CompPersist {refusal.hits} time(s), "
      f"expected 2 -- one per request. Fewer means it accepted a completion "
      f"sequence that is neither of the two legal forms")

    after = (self.tb_env.rni_sva.fail_count.get(FIELD_RULE_C, 0) +
             self.tb_env.snf_sva.fail_count.get(FIELD_RULE_C, 0))
    assert after > before, (
      f"{FIELD_RULE_C} did not report on a standalone Persist carrying the "
      f"request's TxnID. One of the two requests must have drawn a non-zero "
      f"TxnID, so either the control is not reflecting it into the Persist -- in "
      f"which case it is not the shape this test claims to drive -- or the field "
      f"rule stopped reading Persist")

    # The collateral, counted rather than merely permitted. It is the direct
    # consequence of the refusal -- an abandoned transaction is never retired --
    # so a run where it did NOT appear would mean the requester accepted the
    # sequence somewhere after all.
    outstanding_after = (
      self.tb_env.rni_sva.fail_count.get(OUTSTANDING_RULE_C, 0) +
      self.tb_env.snf_sva.fail_count.get(OUTSTANDING_RULE_C, 0))
    assert outstanding_after > outstanding_before, (
      f"{OUTSTANDING_RULE_C} did not report, but two transactions were "
      f"abandoned by the refusals above. Either they were retired after all -- "
      f"in which case the refusal did not abandon them -- or the rule stopped "
      f"reading the outstanding count")

    self.logger.info(
      f"Test (tc_chi_e_persist_sep_form_negctl) PASS: Persist-then-CompPersist "
      f"was refused {refusal.hits} time(s), and the standalone Persist's "
      f"non-zero TxnID was reported {after - before} time(s) -- "
      f"{refusal.messages[0]}")

    self.drop_objection()
