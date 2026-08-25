################################################################################
# The Python port's negative-control mechanism, tested as a mechanism.
#
# Python-only, and the asymmetry is the subject rather than an oversight. The SV
# port catches a driver's refusal with a uvm_report_catcher, and seven existing
# negative controls exercise that path every sweep -- there is nothing to add
# there. This port had no equivalent at all: a driver's refusal is an exception
# raised inside a cocotb coroutine the AGENT started, so the test cannot wrap it
# and nothing observes it as a tested outcome. Every negative control of that
# shape could be written in SV and not here.
#
# py/vip_chi_reject.py closes that, and this is the test that says it works. It
# checks the behaviours the mechanism has to have, and the third is the one most
# worth a test:
#
#   1. Unarmed, a refusal raises -- an unexpected refusal must still stop a test,
#      so converting a driver site changes nothing about the negative path.
#   2. Armed and matching, it records and RETURNS, so the driver carries on with
#      the offending flit accepted. That is what a demoted `uvm_fatal does, and a
#      mechanism that killed the coroutine instead would test the refusal and
#      nothing after it.
#   3. Armed and NOTHING fires, leaving the scope raises. This is the half that
#      is easy to leave out and the half that matters: the risk in a negative
#      control is not that it fails, it is that it silently stops provoking
#      anything and passes for years.
#   4. A scope armed for a different rule does not swallow the refusal.
#   5. A count that does not match fails, in either direction.
#
# It tests the mechanism rather than a protocol rule on purpose. The two controls
# this unblocks -- a bare Comp for WriteNoSnpZero, and Persist where Comp or
# CompPersist is due -- each need a completer-side knob to provoke them, and
# those belong with the findings they serve. What was missing was the ability to
# write them at all.
#
# Runs under: testbench/py/tb/chi_tb_top.py (topology-free)
################################################################################

from __future__ import annotations

from pyuvm import uvm_test

from vip_chi_reject import (reject, expect_rejection, VipChiRejection,
                            armed_scopes)


def _must_raise(what, fn):
  try:
    fn()
  except VipChiRejection:
    return
  raise AssertionError(f"{what}: expected VipChiRejection, none was raised")


def _silent():
  with expect_rejection("R_ONE"):
    pass


def _wrong_rule():
  with expect_rejection("R_OTHER"):
    reject("R_ONE", "refused a flit")


def _too_few():
  with expect_rejection("R_ONE", count=2):
    reject("R_ONE", "once")


def _too_many():
  with expect_rejection("R_ONE", count=1):
    reject("R_ONE", "once")
    reject("R_ONE", "twice")


class tc_chi_reject_scope(uvm_test):

  async def run_phase(self):
    self.raise_objection()

    assert list(armed_scopes()) == [], (
      "a scope was already armed before this test started: the module's state "
      "leaked out of an earlier test")

    # 1. Unarmed.
    _must_raise("unarmed refusal", lambda: reject("R_ONE", "unexpected"))

    # 2. Armed and matching: records, returns, and the caller keeps going.
    reached_after = False
    with expect_rejection("R_ONE", "refused *") as scope:
      reject("R_ONE", "refused a flit")
      reached_after = True
    assert reached_after, (
      "reject() did not return inside an armed scope, so a driver would stop at "
      "the refusal instead of carrying on as a demoted uvm_fatal does")
    assert scope.hits == 1, f"expected 1 recorded refusal, got {scope.hits}"
    assert scope.messages == ["refused a flit"], (
      f"the message was not recorded verbatim: {scope.messages}")

    # 3. Armed and silent: the scope itself must fail.
    _must_raise("a control that provoked nothing", _silent)

    # 4. A scope for another rule must not swallow this one.
    _must_raise("a refusal outside the armed rule", _wrong_rule)

    # 5. Counts, both directions.
    _must_raise("one refusal against a count of two", _too_few)
    _must_raise("two refusals against a count of one", _too_many)

    # The at-least-one form, for a control whose count is not fixed.
    with expect_rejection("R_ONE", count=None) as any_scope:
      reject("R_ONE", "a")
      reject("R_ONE", "b")
    assert any_scope.hits == 2, f"expected 2, got {any_scope.hits}"

    # Nesting: the innermost matching scope takes it.
    with expect_rejection("R_ONE", count=1) as outer:
      with expect_rejection("R_ONE", count=1) as inner:
        reject("R_ONE", "inner")
      reject("R_ONE", "outer")
    assert inner.hits == 1 and outer.hits == 1, (
      f"nesting matched the wrong scope: inner={inner.hits} outer={outer.hits}")

    assert list(armed_scopes()) == [], (
      f"scopes leaked out of this test: {list(armed_scopes())}")

    self.logger.info(
      "Test (reject_scope) PASS: the rejection scope records a refusal, lets "
      "the driver continue, and fails when nothing is provoked")
    self.drop_objection()
