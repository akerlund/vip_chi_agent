################################################################################
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
################################################################################
#
# Driver refusals, and how a test says it wanted one.
#
# The SystemVerilog port has had this since the first negative control: a driver
# refuses a flit with `uvm_fatal, a uvm_report_catcher demotes the expected one,
# the test asserts it fired exactly once, and the run stays green. Seven catchers
# do it today.
#
# This port could not. A Python driver's refusal is an exception raised inside a
# cocotb coroutine that the AGENT started, not the test -- so the test cannot wrap
# it, and nothing observes it as a tested outcome. The consequence was not that
# the Python port was weaker at catching violations; it was that a whole SHAPE of
# negative control could only exist in one port. That inverts this repository's
# central discipline, which is that the two ports check each other: SV gets a test
# proving a violation is caught, Python gets silence, and check_test_counts.py
# records the difference as a deliberate asymmetry. That is how a one-port
# capability becomes permanent.
#
# The mechanism, and why it has the semantics it does:
#
#   * reject(rule, message) is what a driver calls instead of raising. With no
#     scope armed it raises VipChiRejection, which is what it did before -- an
#     unexpected refusal must still stop the test.
#
#   * Inside an armed scope whose pattern matches, it RECORDS and RETURNS. The
#     driver then carries on with the offending flit accepted, which is exactly
#     what a demoted `uvm_fatal does in the SV port: report severity drops to
#     INFO and the task runs on. Faithfulness here is not decoration -- a
#     mechanism that killed the coroutine instead would test the refusal and
#     nothing after it, and the SV twin tests both.
#
#   * Leaving a scope that never fired RAISES. This is the half that is easy to
#     leave out and the half that matters: the risk in a negative control is not
#     that it fails, it is that it silently stops provoking anything and passes
#     for years. The SV catchers all assert a count for the same reason.
#
# Scopes nest and are matched innermost-first, so a test may arm an outer
# expectation for a rule its own inner scope also provokes.
################################################################################

from __future__ import annotations

import fnmatch
import logging
from typing import Iterator


class VipChiRejection(AssertionError):
  """A driver refused a flit the protocol does not permit.

  An AssertionError subclass on purpose: an unexpected refusal must fail a
  cocotb test exactly as the bare `raise AssertionError` it replaces did, so
  converting a site changes nothing about the negative path.
  """


class _Scope:
  __slots__ = ("rule", "pattern", "expected", "hits", "messages")

  def __init__(self, rule: str, pattern: str, expected: int | None):
    self.rule = rule
    self.pattern = pattern
    self.expected = expected
    self.hits = 0
    self.messages: list[str] = []

  def matches(self, rule: str, message: str) -> bool:
    if self.rule not in ("*", rule):
      return False
    return fnmatch.fnmatch(message, self.pattern)


# Innermost last. Module state rather than per-test, mirroring uvm_report_cb's
# global registration -- a driver has no handle on the test that armed the scope,
# which is the whole difficulty this module exists to solve.
_SCOPES: list[_Scope] = []
_LOG = logging.getLogger("vip_chi_reject")


class expect_rejection:
  """Arm a scope in which a driver refusal is the expected outcome.

  `rule` names the refusal, matched exactly, or "*" for any. `pattern` is an
  fnmatch glob against the message, defaulting to any. `count` is how many
  refusals must occur; None means "at least one".

      with expect_rejection("PERSIST_SEP_FIRST_COMPLETION"):
        await seq.start(sequencer)

  On leaving the scope, a count that does not match raises -- including zero,
  which is the case worth guarding.
  """

  def __init__(self, rule: str = "*", pattern: str = "*",
               count: int | None = 1):
    self._scope = _Scope(rule, pattern, count)

  def __enter__(self) -> "expect_rejection":
    _SCOPES.append(self._scope)
    return self

  def __exit__(self, exc_type, exc, tb) -> bool:
    _SCOPES.remove(self._scope)
    # An exception already in flight wins: reporting "the control did not fire"
    # on top of the real failure that stopped it would bury the cause.
    if exc_type is not None:
      return False
    want = self._scope.expected
    got = self._scope.hits
    if want is None:
      if got == 0:
        raise VipChiRejection(
          f"expected at least one driver rejection matching "
          f"rule={self._scope.rule!r} pattern={self._scope.pattern!r}, and none "
          f"occurred: the negative control provoked nothing")
    elif got != want:
      raise VipChiRejection(
        f"expected {want} driver rejection(s) matching "
        f"rule={self._scope.rule!r} pattern={self._scope.pattern!r}, saw {got}: "
        f"{'the negative control provoked nothing' if got == 0 else 'the count moved'}")
    return False

  @property
  def hits(self) -> int:
    return self._scope.hits

  @property
  def messages(self) -> list[str]:
    return list(self._scope.messages)


def reject(rule: str, message: str) -> None:
  """A driver's refusal to accept a flit.

  Raises VipChiRejection unless an armed scope expects this refusal, in which
  case it records it and returns so the driver continues -- the behaviour of a
  demoted `uvm_fatal in the SV port.
  """
  for scope in reversed(_SCOPES):
    if scope.matches(rule, message):
      scope.hits += 1
      scope.messages.append(message)
      _LOG.info("expected driver rejection [%s] observed and demoted: %s",
                rule, message)
      return
  raise VipChiRejection(f"[{rule}] {message}")


def armed_scopes() -> Iterator[str]:
  """The armed scopes, innermost last. For diagnostics only."""
  return iter(f"{s.rule}:{s.pattern}" for s in _SCOPES)
