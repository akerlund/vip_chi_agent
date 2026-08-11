################################################################################
#
# tc_chi_sva_smoke
#
# Negative control for py/sva/bind_chi.py: one deliberate violation per check
# family, asserting the checker REPORTS it. Without this the checkers could be
# silently vacuous -- every one of the 129 regression testcases passes with them
# enabled, and a checker that can never fire passes exactly as loudly as one
# that works.
#
# The checker is driven with synthetic per-cycle samples rather than through the
# DUT. That is deliberate, and it is what makes a negative control possible at
# all here: the env builds its own bind_chi on each interface and asserts zero
# violations in report_phase, so provoking a real violation on the wires would
# fail the test it is trying to prove. Driving a private instance keeps the
# induced errors owned by this testcase.
#
# What this does NOT cover: that the checker is wired to the right nets. That is
# covered by every other testcase in the suite -- the env checkers report their
# rules as `exercised` against real traffic, which they could only do by reading
# live signals.
#
# Runs under: testbench/py/tb/chi_tb_top.py (topology-free)
################################################################################

from __future__ import annotations

import logging

from pyuvm import uvm_test

from sva.bind_chi import bind_chi, _LINK_ACT_WINDOW_C

# A link in RUN: some request and some acknowledge, which is the role-agnostic
# condition bind_chi._link_is_running tests for.
_RUN = {
  "txlinkactivereq": 1, "txlinkactiveack": 0,
  "rxlinkactivereq": 0, "rxlinkactiveack": 1,
  "txsactive": 1, "rxsactive": 1,
}
_STOP = {
  "txlinkactivereq": 0, "txlinkactiveack": 0,
  "rxlinkactivereq": 0, "rxlinkactiveack": 0,
  "txsactive": 0, "rxsactive": 0,
}
_CHANNELS = ("req", "rsp", "dat")


def _sample(base: dict, **over) -> dict:
  """One cycle of checker input: link state plus all-quiet channels."""
  s = dict(base)
  for ch in _CHANNELS:
    for d in ("tx", "rx"):
      s[f"{d}{ch}flitv"] = 0
      s[f"{d}{ch}flitpend"] = 0
      s[f"{d}{ch}lcrdv"] = 0
  s.update(over)
  return s


def _checker() -> bind_chi:
  """A bind_chi with no bus, driven by hand.

  The checks are pure functions of the sampled dict, so they can be called
  directly; only `run()` needs a bus, and this bypasses it.
  """
  c = bind_chi.__new__(bind_chi)
  c.bus = None
  # Every violation below is induced on purpose, so its log line is silenced
  # rather than left to read as a real failure -- the same discipline the SV
  # negative controls apply with report catchers. The counts are unaffected:
  # _err increments fail_count before it logs, and the assertions read those.
  c.log = logging.getLogger("tc_chi_sva_smoke_induced")
  c.log.setLevel(logging.CRITICAL)
  c.errors = 0
  c.fail_count = {}
  c.pass_count = {}
  c._checks_enable = True
  c._lcrd = {}
  c._link_ever_active = False
  c._reset_state()
  return c


def _feed(checker: bind_chi, samples: list[dict]) -> None:
  prev = None
  for s in samples:
    checker._check_link_gating(s)
    checker._check_pend_requires_valid(s)
    checker._check_lcrd(s)
    if prev is not None:
      checker._check_deactivate_idle(prev, s)
    prev = s


class tc_chi_sva_smoke(uvm_test):

  def _fired(self, checker: bind_chi, rule: str) -> int:
    return checker.fail_count.get(rule, 0)

  async def run_phase(self):
    self.raise_objection()

    # ---- FLITPEND without FLITV ------------------------------------------
    c = _checker()
    _feed(c, [_sample(_RUN, txreqflitpend=1)])
    assert self._fired(c, "CHI_REQ_PEND_REQUIRES_VALID") == 1, (
      "flitpend without flitv was not reported")

    # ---- Flit sent before the link is RUN ---------------------------------
    # One-sided ACTIVATING: a request with no acknowledge yet. This is the case
    # link_is_running catches and link_is_active would not, so it also pins the
    # tighter of the two predicates.
    activating = _sample(_RUN, txreqflitv=1)
    activating["rxlinkactiveack"] = 0
    c = _checker()
    _feed(c, [activating])
    assert self._fired(c, "CHI_REQ_FLITV_REQUIRES_LINK") == 1, (
      "flit sent during one-sided ACTIVATING was not reported")

    # ---- L-credit underflow ----------------------------------------------
    # A flit launched with no credit ever granted. The driver refuses to send at
    # zero credit, so this can only mean a flit went out unauthorized.
    c = _checker()
    _feed(c, [_sample(_RUN, txreqflitv=1)])
    assert self._fired(c, "CHI_LCRD_UNDERFLOW") == 1, (
      "L-credit underflow was not reported")

    # ---- L-credit overflow -----------------------------------------------
    c = _checker()
    _feed(c, [_sample(_RUN, rxreqlcrdv=1) for _ in range(65)])
    assert self._fired(c, "CHI_LCRD_OVERFLOW") >= 1, (
      "L-credit grant past the tracked cap was not reported")

    # ---- Same-cycle grant and consume must NOT underflow ------------------
    # The positive control for the pair above, and the one that matters most:
    # the SV checker's comments record two earlier attempts that false-fired
    # here because grant and consume raced. The pool must sequence 0 -> 1 -> 0.
    c = _checker()
    _feed(c, [_sample(_RUN, rxreqlcrdv=1, txreqflitv=1)])
    assert self._fired(c, "CHI_LCRD_UNDERFLOW") == 0, (
      "a same-cycle grant and consume was miscounted as an underflow")

    # ---- TXSACTIVE still asserted after the link went down ----------------
    c = _checker()
    _feed(c, [_sample(_STOP), _sample(_STOP, txsactive=1)])
    assert self._fired(c, "CHI_LINK_DEACTIVATE_WHEN_IDLE") == 1, (
      "txsactive held past link deactivation was not reported")

    # ---- Reset idle -------------------------------------------------------
    c = _checker()
    c._check_reset_idle(_sample(_RUN, txreqflitv=1))
    assert self._fired(c, "CHI_REQ_IDLE_IN_RESET") == 1, (
      "REQ traffic during reset was not reported")
    assert self._fired(c, "CHI_LINK_SIDEBAND_IDLE_IN_RESET") == 1, (
      "link sideband active during reset was not reported")

    # ---- Link fails to restart after reset --------------------------------
    # Armed only once the interface has been active, so an unbuilt interface
    # stays silent; see the gate comment in bind_chi._check_restart_window.
    c = _checker()
    c._link_ever_active = True
    c._act_countdown = _LINK_ACT_WINDOW_C
    for _ in range(_LINK_ACT_WINDOW_C + 2):
      c._check_restart_window(_sample(_STOP))
    assert self._fired(c, "CHI_LINK_RESTARTS_AFTER_RESET") == 1, (
      "a link that never reactivated after reset was not reported")

    # ---- ...and does not fire when it does restart in time ----------------
    c = _checker()
    c._link_ever_active = True
    c._act_countdown = _LINK_ACT_WINDOW_C
    for i in range(_LINK_ACT_WINDOW_C + 2):
      c._check_restart_window(
        _sample(_RUN if i == _LINK_ACT_WINDOW_C - 2 else _STOP))
    assert self._fired(c, "CHI_LINK_RESTARTS_AFTER_RESET") == 0, (
      "a link that reactivated inside the window was reported as failing")

    # ---- An unused interface must never arm the restart check -------------
    c = _checker()
    assert not c._link_ever_active, (
      "a checker must start unarmed so an interface with no agent cannot "
      "report a spurious restart failure")

    self.logger.info(
      "Test (tc_chi_sva_smoke) PASS: every bind_chi check family reported its "
      "induced violation, and neither positive control false-fired")
    self.drop_objection()
