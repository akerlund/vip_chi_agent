################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of sv/vip_chi_snp_sva.sv -- CHI SNP-channel protocol
# checker, the coherent counterpart to bind_chi.py.
#
# The SNP channel lives in its own module for the same reason it does in SV:
# only coherent endpoints (HN-F sources snoops, RN-F receives them) carry it,
# so a non-coherent link must not elaborate SNP checks at all.
#
# X-propagation check absent by design (2-state Verilator, see bind_chi.py):
#
#   p_snp_known_when_valid   "txsnpflit has X/Z while txsnpflitv asserted"
#
# Start with: cocotb.start_soon(bind_chi_snp(bus).run())
#
################################################################################

from __future__ import annotations

import logging
import os

from cocotb.triggers import RisingEdge

from sva.bind_chi import claim_export_tag

from vip_chi_types_pkg import (
  LasmState, lasm, CheckSeverity, CHECK_IDS_SNP, CHECK_IDS_SV_ONLY,
)

# Mirrors SNP_SEND_CAP_C in the SV checker.
_SNP_SEND_CAP_C = 64


class bind_chi_snp:
  """SNP-channel protocol checker for one coherent interface."""

  def __init__(self, bus, name: str = "bind_chi_snp",
               checks_enable: bool | None = None):
    self.bus = bus
    self.log = logging.getLogger(name)
    self.errors = 0
    self.fail_count: dict[str, int] = {}
    self.pass_count: dict[str, int] = {}
    self._checks_enable = checks_enable
    self._lcrd = {"txsnp": 0, "rxsnp": 0}
    # Sticky "this interface's link has come up at least once"; see the
    # reset-idle gate in run().
    self._link_ever_active = False
    self.init_check_control()

  # ---------------------------------------------------------------------------
  # Per-check identity, enable and statistics.
  #
  # The same contract bind_chi carries, and it was missing here entirely: this
  # checker had no enable map, no severity map, no CSV export, and a report()
  # whose rule list was built from the rules that had FIRED. A summary derived
  # from what fired cannot name what did not, so the SNP rules were the one
  # corner of the registry where "never exercised" could not be expressed at all
  # -- and the cross-run aggregation, which reads the CSV, had no rows for them
  # to read.
  # ---------------------------------------------------------------------------
  @staticmethod
  def _owned_rules():
    """The SNP range, and only it.

    Split from the full registry for the same reason bind_chi's is: this checker
    has nothing to say about whether the REQ/RSP/DAT rules were exercised, and
    printing them as "not exercised" would be a false alarm on every run.

    The X/Z rule is excluded for the same reason rather than reported as never
    exercised: Verilator is 2-state, so this port cannot own it at all, and
    listing it would put a permanent entry in a report whose value depends on
    every entry being actionable.
    """
    return tuple(r for r in CHECK_IDS_SNP if r not in CHECK_IDS_SV_ONLY)

  def init_check_control(self) -> None:
    """Seed the enable and severity maps from the whole canonical SNP range.

    Seeded from the registry rather than filled in as rules fire, so a rule can
    be disabled before it has ever been evaluated -- and so the vacuity report
    has the full universe to compare against.
    """
    self.check_enable: dict[str, bool] = {r: True for r in self._owned_rules()}
    self.check_severity: dict[str, CheckSeverity] = {
      r: CheckSeverity.ERROR for r in self._owned_rules()
    }

  def disable_check(self, rule: str) -> None:
    """Stop evaluating a rule entirely: no reports, and no pass or fail counts."""
    self.check_enable[rule] = False

  def warn_check(self, rule: str) -> None:
    """Keep evaluating and counting a rule, but report it as a warning."""
    self.check_severity[rule] = CheckSeverity.WARNING

  def off_check(self, rule: str) -> None:
    """Keep evaluating and counting a rule, but do not report it at all."""
    self.check_severity[rule] = CheckSeverity.OFF

  def expect_failure(self, rule: str) -> None:
    """Declare that this run deliberately provokes `rule`, so it must not fail.

    This IS severity OFF, spelled as a separate call because that is what a test
    means. See bind_chi.expect_failure for why the two are not kept apart.
    """
    self.check_severity[rule] = CheckSeverity.OFF

  def not_exercised(self):
    """Owned rules that were neither passed nor failed, in registry order."""
    return [r for r in self._owned_rules()
            if self.check_enable.get(r, True)
            and not self.pass_count.get(r, 0)
            and not self.fail_count.get(r, 0)]

  def export_check_csv(self, path: str, run_name: str) -> None:
    """Append this checker's per-rule tallies to the cross-run aggregation CSV.

    Same format and same reasoning as bind_chi's. Every bind must write, or the
    aggregation reports on the rules it happens to have rows for and says
    nothing about the ones it was never given -- which reads as a clean report
    rather than as a hole in the measurement.
    """
    if not claim_export_tag(run_name, self.log.name):
      self.errors += 1
      self.log.error(
        f"check-tally tag '{self.log.name}' was exported twice in run "
        f"{run_name}: two binds under one name merge into one set of rows, and "
        f"every per-bind question asked of the export afterwards is answered "
        f"about the wrong interface")

    new = not os.path.exists(path)
    with open(path, "a", encoding="utf-8") as fh:
      if new:
        fh.write("run,bind,check,enabled,severity,passes,fails\n")
      for rule in self._owned_rules():
        fh.write(
          f"{run_name},{self.log.name},{rule},"
          f"{int(self.check_enable.get(rule, True))},"
          f"{self.check_severity.get(rule, CheckSeverity.ERROR).name},"
          f"{self.pass_count.get(rule, 0)},{self.fail_count.get(rule, 0)}\n")

  # ---------------------------------------------------------------------------
  def _chk(self, rule: str, ok: bool, msg: str, where: str) -> None:
    # A DISABLED rule is skipped entirely -- neither pass nor fail is counted --
    # so the vacuity report shows it as not exercised rather than as quietly
    # holding. A rule at severity OFF is different: it still evaluates and still
    # counts, and only its report is suppressed.
    if not self.check_enable.get(rule, True):
      return
    if ok:
      self.pass_count[rule] = self.pass_count.get(rule, 0) + 1
    else:
      self._err(rule, msg, where)

  def _err(self, rule: str, msg: str, where: str) -> None:
    if not self.check_enable.get(rule, True):
      return
    self.fail_count[rule] = self.fail_count.get(rule, 0) + 1
    sev = self.check_severity.get(rule, CheckSeverity.ERROR)
    if sev is CheckSeverity.OFF:
      return
    if sev is CheckSeverity.WARNING:
      self.log.warning(f"{rule}: {msg}. IHI 0050 {where}.")
      return
    self.errors += 1
    self.log.error(f"{rule}: {msg}. IHI 0050 {where}.")

  def rule_names(self):
    return sorted(set(self.pass_count) | set(self.fail_count))

  def report(self, log=None) -> None:
    log = log or self.log
    names = self.rule_names()
    if names:
      log.info("VIP_CHI SNP CHECK SUMMARY")
      for rule in names:
        fails = self.fail_count.get(rule, 0)
        sev = self.check_severity.get(rule, CheckSeverity.ERROR)
        tag = "[FAILING]" if fails else "[exercised]"
        if not self.check_enable.get(rule, True):
          tag = "[disabled]"
        elif sev is not CheckSeverity.ERROR:
          tag += f"[{sev.name.lower()}]"
        log.info(f"  {rule:<38s} pass={self.pass_count.get(rule, 0):>7d}  "
                 f"fail={fails:>5d}  {tag}")

    # The half of the summary a clean run cannot show you any other way, and the
    # half this checker did not have: its rule list used to be built from the
    # rules that FIRED, so a rule that never ran could not appear in it at all.
    # Printed even when empty, and with the count on the same line, so a
    # regression-wide sweep is a grep rather than a parse.
    missing = self.not_exercised()
    log.info(f"VIP_CHI SNP CHECK VACUITY: not_exercised={len(missing)} "
             f"of={len(self._owned_rules())}")
    for rule in missing:
      why = CHECK_IDS_SV_ONLY.get(rule)
      log.info(f"  NOT EXERCISED  {rule}"
               + (f"  (SV-only: {why})" if why else ""))

  # ---------------------------------------------------------------------------
  @staticmethod
  def _lasm_of(s: dict) -> LasmState:
    """This link's LASM as seen from this endpoint, matching bind_chi.

    One state machine per link, formed from the live request/acknowledge pair
    whichever polarity this bind sits on. See the long docstring there.
    """
    return lasm(s["txlinkactivereq"] or s["rxlinkactivereq"],
                s["txlinkactiveack"] or s["rxlinkactiveack"])

  @classmethod
  def _link_is_active(cls, s: dict) -> bool:
    """Anywhere but STOP. Credit returns are legal from ACTIVATE onward."""
    return cls._lasm_of(s) is not LasmState.STOP

  def _sample(self) -> dict:
    g = self.bus.get_or
    return {n: g(n) for n in (
      "txlinkactivereq", "txlinkactiveack",
      "rxlinkactivereq", "rxlinkactiveack",
      "txsnpflitv", "txsnpflitpend", "txsnplcrdv",
      "rxsnpflitv", "rxsnpflitpend", "rxsnplcrdv",
    )}

  def _enabled(self, s: dict) -> bool:
    if self._checks_enable is not None:
      return self._checks_enable
    return bool(s["txlinkactivereq"] or s["rxlinkactivereq"])

  # ---------------------------------------------------------------------------
  async def run(self) -> None:
    bus = self.bus
    prev_rst = int(bus.rst_n.value)
    # The previous sample, for the one rule that reaches back a cycle. See
    # CHI_SNP_VALID_REQUIRES_PEND below.
    prev = None

    while True:
      await RisingEdge(bus.clk)
      cur = self._sample()
      rst = int(bus.rst_n.value)
      enabled = self._enabled(cur)

      if rst == 0:
        # Gated on _link_ever_active, NOT on the enable gate, and for the same
        # reason the reset-idle rules in bind_chi are: the gate IS this
        # interface's activation request, and nothing is driven during reset, so
        # the link is never active while this rule applies. Under that gate it
        # could not fire at all.
        if self._link_ever_active and prev_rst == 0:
          self._chk(
            "CHI_SNP_IDLE_IN_RESET",
            not (cur["txsnpflitv"] or cur["txsnpflitpend"]
                 or cur["txsnplcrdv"]),
            "SNP outputs not idle during reset",
            "section 13.4",
          )
        self._lcrd = {"txsnp": 0, "rxsnp": 0}
        prev, prev_rst = cur, rst
        continue

      if self._link_is_active(cur):
        self._link_ever_active = True

      if enabled:
        if cur["txsnpflitv"]:
          self._chk(
            "CHI_SNP_FLITV_REQUIRES_LINK",
            self._lasm_of(cur) is LasmState.RUN,
            "txsnpflitv asserted before link RUN", "section 13.7",
          )
        if cur["txsnplcrdv"]:
          self._chk(
            "CHI_SNP_LCRDV_REQUIRES_LINK", self._link_is_active(cur),
            "txsnplcrdv asserted before link activation", "section 13.7",
          )
        # FLITPEND announces a flit one cycle ahead; the obligation runs from
        # the flit backwards. See bind_chi._check_valid_requires_pend for why
        # this is one rule and not the two bullets the section lists.
        if cur["txsnpflitv"] and prev is not None:
          self._chk(
            "CHI_SNP_VALID_REQUIRES_PEND", bool(prev["txsnpflitpend"]),
            "txsnpflitv sent without txsnpflitpend in the preceding cycle",
            "E section 14.4 / D section 13.4",
          )
        self._check_lcrd(cur)

      prev, prev_rst = cur, rst

  # ---------------------------------------------------------------------------
  def _check_lcrd(self, s: dict) -> None:
    """SNP send-credit shadow, paired exactly as in bind_chi._check_lcrd."""
    for pool, grant, consume in (
      ("txsnp", s["rxsnplcrdv"], s["txsnpflitv"]),
      ("rxsnp", s["txsnplcrdv"], s["rxsnpflitv"]),
    ):
      count = self._lcrd[pool]
      if grant:
        self._chk(
          "CHI_SNP_LCRD_OVERFLOW", count != _SNP_SEND_CAP_C,
          f"{pool} SNP L-credit grant overflowed the tracked count",
          "section 13.6",
        )
        if count != _SNP_SEND_CAP_C:
          count += 1
      if consume:
        self._chk(
          "CHI_SNP_LCRD_UNDERFLOW", count != 0,
          f"{pool} SNP L-credit consumed with no credit available (underflow)",
          "section 13.6",
        )
        if count != 0:
          count -= 1
      self._lcrd[pool] = count
