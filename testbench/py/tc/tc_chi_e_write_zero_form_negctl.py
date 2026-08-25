################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# The negative control for the zero-write completion FORM: the completer answers
# WriteNoSnpZero with a bare Comp, and the requester must refuse it.
#
# IHI 0050 answers WriteNoSnpZero with DBIDResp and a Comp, or with a combined
# CompDBIDResp. A bare Comp is neither. The request carries no write data, so the
# granted buffer is never used and the DBID looks pointless -- which is exactly
# why a completer leaves it out, and why a requester that had never been told
# otherwise accepts it. The completion form is normative regardless of whether
# the requester uses what it is granted.
#
# Why the guard needed a control. The requester's refusal is unreachable from
# conformant traffic, so its silence in every other run says nothing: a guard
# nothing can provoke is indistinguishable from one that was deleted.
# cfg.snf_write_zero_bare_comp_negctl provokes it.
#
# The refusal arrives through reject() rather than as a raised exception, so it
# is recorded as a tested OUTCOME and the run continues -- the pyUVM counterpart
# of a demoted `uvm_fatal in the SV twin. With no scope armed the same call
# raises, so the guard is unchanged outside this test.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from chi_e_base_test import chi_e_base_test
from vip_chi_reject import expect_rejection
from vip_chi_write_zero_seq import vip_chi_write_zero_seq

ADDR_C = 0x4D30_0000
SIZE_C = 6
SETTLE_C = 20


class tc_chi_e_write_zero_form_negctl(chi_e_base_test):

  def configure(self, rni_cfg, snf_cfg):
    super().configure(rni_cfg, snf_cfg)
    snf_cfg.snf_write_zero_bare_comp_negctl = True

  async def run_phase(self):
    self.raise_objection()

    self.drain_observation_fifos()

    seq = vip_chi_write_zero_seq("write_zero_form_negctl", cfg=self.chi_cfg)
    seq.reset()
    seq.set_requests(1)
    seq.set_initial_addr(ADDR_C)
    seq.set_size(SIZE_C)
    seq.set_get_response(True)
    seq.set_verbose(False)

    # Exactly one refusal, and on the FIRST response rather than the second: a
    # bare Comp is wrong as an opening move, and a requester that waited for a
    # grant before objecting would hang instead of refusing.
    with expect_rejection("WRITE_ZERO_FIRST_RESPONSE", count=1) as refusal:
      await seq.start(self.v_sqr.rni_sequencer)

    await self.wait_clocks(SETTLE_C)

    assert refusal.hits == 1, (
      f"the requester refused a bare Comp {refusal.hits} time(s), expected 1")

    self.logger.info(
      f"Test (tc_chi_e_write_zero_form_negctl) PASS: a bare Comp answering "
      f"WriteNoSnpZero was refused as the first response -- {refusal.messages[0]}")

    self.drop_objection()
