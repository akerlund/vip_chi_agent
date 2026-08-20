################################################################################
# pyUVM/cocotb port of tc/tc_chi_e_link_lifecycle.sv.
#
# The whole life of a CHI-E link: up, reset, up again, torn down, up again.
#
# This exists because of a measurement, not a hunch. The per-bind vacuity split
# showed six link-layer rules alive on the CHI-D link and dead on both CHI-E
# binds -- the four "channel idle in reset" rules, the activation restart, and the
# tear-down idle rule. Not one of the CHI-E testcases touched reset or link
# state, so the six had never been evaluated on a CHI-E link at all.
#
# That gap is not covered by the CHI-D equivalents. The link layer is not
# issue-invariant: CHI-E widens NodeID and Address, moves the flit layout, and
# the reset rules judge the FLITPEND / FLITV / LCRDV wires of channels whose
# widths changed underneath them. A rule that holds on a 44-bit address and a
# 16-byte data bus is not thereby known to hold on 52 bits and 64.
#
# The three phases in order, each one a prerequisite for the next:
#
#   phase 1  traffic, so link_ever_active latches and the reset rules arm. They
#            are deliberately gated on it -- an interface whose agent was never
#            built must not be judged -- so a reset before any traffic would walk
#            past all six without evaluating one.
#   phase 2  reset in the middle of the run. The four channel rules and the
#            sideband rule apply while rst_n is low; the restart rule applies
#            when it is released. The pulse is written out here rather than
#            calling pulse_reset(), because the sideband has to be SAMPLED while
#            rst_n is still low and that helper returns with it already high.
#   phase 3  a graceful deactivation to STOP and back. This is the only way to
#            reach CHI_LINK_DEACTIVATE_WHEN_IDLE's antecedent: reset takes the
#            link down without ever entering DEACTIVATE.
#
# The test then requires that each of the six recorded an evaluation on BOTH
# CHI-E binds. That check is the point of the testcase. A run that drives the
# stimulus but leaves a rule unevaluated has proved nothing about it, and a green
# verdict would say otherwise.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from cocotb.triggers import RisingEdge

from pyuvm import ConfigDB

from chi_e_base_test import chi_e_base_test

ADDR_C = 0x0033_0000_0000
SIZE_C = 6
SETTLE_C = 20
# Deadlock guard, not a timing budget: the drain sends one flit per banked
# L-credit on three channels. The test waits on the published flag.
DEACT_TIMEOUT_C = 4000

# The six rules this testcase is for, in the order the phases reach them.
LIFECYCLE_CHECKS_C = (
  "CHI_LINK_SIDEBAND_IDLE_IN_RESET",
  "CHI_REQ_IDLE_IN_RESET",
  "CHI_RSP_IDLE_IN_RESET",
  "CHI_DAT_IDLE_IN_RESET",
  "CHI_LINK_RESTARTS_AFTER_RESET",
  "CHI_LINK_DEACTIVATE_WHEN_IDLE",
)


class tc_chi_e_link_lifecycle(chi_e_base_test):

  def _snf_bus(self):
    return ConfigDB().get(self, "", "snf_vif")

  async def _one_write(self, addr):
    """One write, to prove the link carries traffic in each phase and to arm the
    reset rules by latching link_ever_active."""
    wr = self.rni_wr_seq
    wr.reset()
    wr.set_requests(1)
    wr.set_initial_addr(addr)
    wr.set_size(SIZE_C)
    wr.set_allow_retry(0)
    wr.set_get_response(True)
    wr.set_verbose(False)
    await wr.start(self.v_sqr.rni_sequencer)

  async def _wait_deactivate_done(self, want):
    """Wait on the driver's published flag, not on the sideband wires.

    The wires fall as soon as the handshake completes; the drain that has to
    finish first is the part worth waiting for.
    """
    waited = 0
    while bool(self.rni_cfg.link_deactivate_done) != want:
      await self.wait_clocks(1)
      waited += 1
      assert waited <= DEACT_TIMEOUT_C, (
        f"link_deactivate_done never reached {want} within {DEACT_TIMEOUT_C} "
        f"cycles -- the link is stuck")

  async def run_phase(self):
    self.raise_objection()

    rni = self._bus()
    snf = self._snf_bus()

    await self.wait_clocks(4)
    assert rni.get("txlinkactivereq") and snf.get("txlinkactiveack"), (
      "CHI-E link handshake was not active on both agents before phase 1")

    # -- Phase 1: traffic, so the reset rules arm. ---------------------------
    await self._one_write(ADDR_C)
    await self.wait_clocks(SETTLE_C)

    # -- Phase 2: reset in the middle of the run. ----------------------------
    rni.rst_n.value = 0
    await self.wait_clocks(2)

    # Read the sideband while reset is still asserted. This is the same claim
    # CHI_LINK_SIDEBAND_IDLE_IN_RESET makes, asked from the testcase as well,
    # because a rule that stood itself down would leave nothing to notice.
    saw_sideband_idle = (not rni.get("txlinkactivereq") and
                         not snf.get("txlinkactiveack"))

    await self.wait_clocks(2)
    rni.rst_n.value = 1
    await RisingEdge(rni.clk)

    assert saw_sideband_idle, (
      "CHI-E link handshake did not drop to idle during reset")

    saw_reactivation = False
    for _ in range(20):
      if rni.get("txlinkactivereq") and snf.get("txlinkactiveack"):
        saw_reactivation = True
        break
      await self.wait_clocks(1)

    assert saw_reactivation, (
      "CHI-E link handshake was not re-asserted after reset release")

    await self.wait_clocks(SETTLE_C)
    self.drain_observation_fifos()

    # A reset the link did not survive is worse than no reset at all, so the
    # link has to carry traffic again before the tear-down is attempted.
    await self._one_write(ADDR_C + 0x100)
    await self.wait_clocks(SETTLE_C)

    # -- Phase 3: graceful deactivation, the only path into DEACTIVATE. ------
    self.rni_cfg.link_deactivate_request = True
    await self._wait_deactivate_done(True)
    await self.wait_clocks(SETTLE_C)

    self.rni_cfg.link_deactivate_request = False
    await self._wait_deactivate_done(False)
    await self.wait_clocks(SETTLE_C)

    self.drain_observation_fifos()
    await self._one_write(ADDR_C + 0x200)
    await self.wait_clocks(SETTLE_C)

    # -- The verdict: every one of the six was EVALUATED, at BOTH ends. ------
    #
    # Both ends, because the two interfaces are the same wires at opposite
    # polarity and these six rules judge a node's OWN outputs. One end passing
    # says nothing about the other, and the RN-I and SN-F drivers hold their
    # channels idle by separate code.
    rni_sva, snf_sva = self.tb_env.rni_sva, self.tb_env.snf_sva
    vacuous = []
    for rule in LIFECYCLE_CHECKS_C:
      rni_pass = rni_sva.pass_count.get(rule, 0)
      snf_pass = snf_sva.pass_count.get(rule, 0)
      if rni_pass == 0 or snf_pass == 0:
        vacuous.append(f"{rule} (rni_e={rni_pass} snf_e={snf_pass})")

    assert not vacuous, (
      "still vacuous on the CHI-E link after a full link lifecycle: " +
      ", ".join(vacuous))

    self.logger.info(
      f"Test (tc_chi_e_link_lifecycle) PASS: CHI-E link ran, reset mid-run, "
      f"restarted, deactivated to STOP and carried traffic again; all "
      f"{len(LIFECYCLE_CHECKS_C)} link-lifecycle rules evaluated at both ends")
    self.drop_objection()
