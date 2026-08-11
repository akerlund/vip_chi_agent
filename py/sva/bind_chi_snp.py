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

from cocotb.triggers import RisingEdge

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

  # ---------------------------------------------------------------------------
  def _chk(self, rule: str, ok: bool, msg: str, where: str) -> None:
    if ok:
      self.pass_count[rule] = self.pass_count.get(rule, 0) + 1
    else:
      self._err(rule, msg, where)

  def _err(self, rule: str, msg: str, where: str) -> None:
    self.fail_count[rule] = self.fail_count.get(rule, 0) + 1
    self.errors += 1
    self.log.error(f"{rule}: {msg}. IHI 0050 {where}.")

  def rule_names(self):
    return sorted(set(self.pass_count) | set(self.fail_count))

  def report(self, log=None) -> None:
    log = log or self.log
    names = self.rule_names()
    if not names:
      log.info("[VIP_CHI_SNP_CHECK] no SNP protocol checks were evaluated")
      return
    log.info("VIP_CHI SNP CHECK SUMMARY")
    for rule in names:
      fails = self.fail_count.get(rule, 0)
      tag = "[FAILING]" if fails else "[exercised]"
      log.info(f"  {rule:<38s} pass={self.pass_count.get(rule, 0):>7d}  "
               f"fail={fails:>5d}  {tag}")

  # ---------------------------------------------------------------------------
  @staticmethod
  def _link_is_active(s: dict) -> bool:
    return bool(s["txlinkactivereq"] or s["txlinkactiveack"]
                or s["rxlinkactivereq"] or s["rxlinkactiveack"])

  @staticmethod
  def _link_is_running(s: dict) -> bool:
    return bool((s["txlinkactivereq"] or s["rxlinkactivereq"])
                and (s["txlinkactiveack"] or s["rxlinkactiveack"]))

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

    while True:
      await RisingEdge(bus.clk)
      cur = self._sample()
      rst = int(bus.rst_n.value)
      enabled = self._enabled(cur)

      if rst == 0:
        if enabled and prev_rst == 0:
          self._chk(
            "CHI_SNP_IDLE_IN_RESET",
            not (cur["txsnpflitv"] or cur["txsnpflitpend"]
                 or cur["txsnplcrdv"]),
            "SNP outputs not idle during reset",
            "section 13.4",
          )
        self._lcrd = {"txsnp": 0, "rxsnp": 0}
        prev_rst = rst
        continue

      if enabled:
        if cur["txsnpflitv"]:
          self._chk(
            "CHI_SNP_FLITV_REQUIRES_LINK", self._link_is_running(cur),
            "txsnpflitv asserted before link RUN", "section 13.7",
          )
        if cur["txsnplcrdv"]:
          self._chk(
            "CHI_SNP_LCRDV_REQUIRES_LINK", self._link_is_active(cur),
            "txsnplcrdv asserted before link activation", "section 13.7",
          )
        if cur["txsnpflitpend"]:
          self._chk(
            "CHI_SNP_PEND_REQUIRES_VALID", bool(cur["txsnpflitv"]),
            "txsnpflitpend asserted without txsnpflitv", "section 13.3",
          )
        self._check_lcrd(cur)

      prev_rst = rst

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
