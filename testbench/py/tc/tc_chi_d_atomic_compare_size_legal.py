################################################################################
# pyUVM/cocotb port of tc/tc_chi_d_atomic_compare_size_legal.sv.
#
# The POSITIVE control for CHI_ATOMIC_SIZE_LEGAL (F-CHK-019).
#
# The five wide-operand atomic testcases prove the rule FIRES: they drive Sizes
# Table 2-17 does not list, arm the rule at OFF, and require it to have reported.
# Nothing proved the other half -- that the rule permits what the table DOES
# list -- and a rule that fires on everything would pass all five of them.
#
# AtomicCompare at Size 5 is the case worth controlling, because it is the one a
# plausible implementation gets wrong. Its Size is the COMBINED compare+swap
# size, so Table 2-17 gives it a ceiling one step above the ordinary atomic
# limit: 32 bytes, two 16-byte operands. Deriving that ceiling from the ordinary
# 8-byte limit yields Size <= 4 and rejects a legal request. On this 16-byte cut
# Size 5 is also the only value that is both legal and beat-representable, since
# con_atomic_compare_beat_align requires Size >= clog2(data_bytes) + 1 = 5.
#
# The rule is ARMED here -- not turned down to OFF -- which is the whole point:
# the assertions below are about a live rule seeing conformant traffic.
#
# atomic_strict_size is enabled as well, so the SOLVER's view of Table 2-17 is
# exercised alongside the checker's. If the constraint's ceiling regressed to
# Size 4, randomization would fail outright rather than quietly drawing
# something else, and this testcase would say so.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from vip_chi_types_pkg import AtomicOp, ReqOpcode, clog2
from chi_base_test import chi_base_test
from vip_chi_atomic_seq import vip_chi_atomic_seq
from chi_tb_pkg import ATOMIC_ADDR_C

RULE_C = "CHI_ATOMIC_SIZE_LEGAL"
COMPARE_OPERAND_C = 0x4455
COMPARE_SWAP_C = 0x99AA


class tc_chi_d_atomic_compare_size_legal(chi_base_test):

  async def run_phase(self):
    self.raise_objection()

    checkers = (self.tb_env.rni_sva, self.tb_env.snf_sva)

    # Table 2-17's AtomicCompare ceiling, and on a 16-byte bus also its floor.
    size = clog2(self.chi_cfg.data_bytes) + 1
    assert size == 5, (
      f"this control is written for the 16-byte cut, where Table 2-17's "
      f"32-byte AtomicCompare is Size 5; this cut wants Size {size}")

    seq = vip_chi_atomic_seq("atomic_compare_legal_seq", cfg=self.chi_cfg)
    seq.reset()
    seq.set_atomic_op(AtomicOp.COMPARE)
    seq.set_requests(1)
    seq.set_initial_addr(ATOMIC_ADDR_C)
    seq.set_size(size)
    # The solver's half of Table 2-17. Unsatisfiable if the ceiling regresses.
    seq.set_atomic_strict_size(True)
    seq.set_get_response(True)
    seq.set_verbose(False)
    seq.set_data([COMPARE_OPERAND_C, COMPARE_SWAP_C])
    await seq.start(self.v_sqr.rni_sequencer)

    resp = seq.get_responses()
    assert len(resp) == 1, (
      f"the legal AtomicCompare returned {len(resp)} responses, expected 1; "
      f"the rest of this testcase says nothing if the request never completed")

    req_item = await self.tb_env.rni_req_fifo.get()
    assert int(req_item.opcode) == int(ReqOpcode.ATOMIC_COMPARE), (
      f"observed opcode 0x{int(req_item.opcode):x}, not AtomicCompare")
    assert int(req_item.size) == size, (
      f"observed Size {int(req_item.size)} on the wire, not {size}; the rule "
      f"judges what it sees, so a request that did not carry the legal size "
      f"would make the counts below prove nothing")

    fails = sum(c.fail_count.get(RULE_C, 0) for c in checkers)
    passes = sum(c.pass_count.get(RULE_C, 0) for c in checkers)

    assert fails == 0, (
      f"{RULE_C} reported {fails} time(s) against a 32-byte AtomicCompare, "
      f"which Table 2-17 lists: the rule's ceiling has been derived from the "
      f"ordinary 8-byte atomic limit instead of from the table, and it is now "
      f"rejecting conformant traffic")
    assert passes > 0, (
      f"{RULE_C} recorded no pass, so this testcase proves nothing about it. "
      f"The rule is armed here on purpose -- if it is not reaching this link, "
      f"the five stress testcases that assert it FIRES are the only evidence "
      f"it exists, and a rule that only ever fails is indistinguishable from "
      f"one that is wrong")

    self.logger.info(
      f"Test (tc_chi_d_atomic_compare_size_legal) PASS: a 32-byte AtomicCompare "
      f"(Size {size}) passed {RULE_C} {passes} time(s) with the rule armed and "
      f"reported {fails} time(s)")

    self.drop_objection()
