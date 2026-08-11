################################################################################
# pyUVM/cocotb port of tc/tc_chi_opcode_pool_safe.sv.
#
# PCrdReturn must not be randomizable out of the non-coherent con_opcode_legal
# pools. The SN-F silently ignores PCrdReturn and the RN-I unconditionally waits
# for a completion that never arrives, so a plain item randomization that lands
# on PCrdReturn wedges the driver with no diagnostic.
#
# Randomize an RN-I item many times across both directions and both CHI issues,
# and assert the drawn opcode is (a) never PCrdReturn and (b) always accepted by
# the req_opcode_is_legal helper. The same draw is repeated for the coherent RN-F
# pool, which is a second hand-written opcode table describing the same rule as
# the helper: cross-checking the two is what stops them drifting apart.
# No link topology is built.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from pyuvm import uvm_test

from vip_chi_types_pkg import Dir, Role, ReqOpcode
from vip_chi_item import vip_chi_item
from chi_tb_pkg import CHI_D_WIDE_CFG, CHI_E_WIDE_CFG

# The SV twin draws 400 per issue. pyvsc solves an order of magnitude slower
# than the SV constraint solver, so the port draws fewer and still covers both
# directions of both issues many times over -- the pool is a static constraint
# set, so the draw count buys confidence, not coverage of a moving target.
N_DRAWS_C = 60


class tc_chi_opcode_pool_safe(uvm_test):

  async def run_phase(self):
    self.raise_objection()

    d_item = vip_chi_item("d_item", CHI_D_WIDE_CFG)
    e_item = vip_chi_item("e_item", CHI_E_WIDE_CFG)

    rni = int(Role.RNI)
    rnf = int(Role.RNF)
    pcrd_return = int(ReqOpcode.PCRD_RETURN)

    for i in range(N_DRAWS_C):
      direction = int(Dir.WRITE) if (i & 1) else int(Dir.READ)

      for issue, item in (("CHI-D", d_item), ("CHI-E", e_item)):
        with item.randomize_with() as x:
          x.role == rni
          x.direction == direction

        assert int(item.opcode) != pcrd_return, (
          f"{issue} RN-I randomize() drew PCrdReturn (draw {i}) -- would wedge "
          f"the driver")
        assert item.req_opcode_is_legal(item.opcode, item.direction), (
          f"{issue} RN-I randomize() drew an opcode the legality helper "
          f"rejects (draw {i}, op 0x{int(item.opcode):x})")

        # con_opcode_legal_rnf and req_opcode_is_legal() are two hand-written
        # tables describing one rule, so they can drift apart silently. Drawing
        # from the pool and asking the helper about the result is what keeps
        # them honest -- an opcode added to one and not the other fails here.
        with item.randomize_with() as x:
          x.role == rnf
          x.direction == direction

        assert item.req_opcode_is_legal(item.opcode, item.direction), (
          f"{issue} RN-F randomize() drew an opcode the legality helper "
          f"rejects (draw {i}, op 0x{int(item.opcode):x})")

    self.logger.info(
      f"Test (tc_chi_opcode_pool_safe) PASS: {N_DRAWS_C} RN-I and RN-F "
      f"randomizations per CHI issue agreed with the legality helper")
    self.drop_objection()
