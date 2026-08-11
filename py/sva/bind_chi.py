################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM/cocotb port of sv/vip_chi_sva.sv -- CHI link-layer protocol checker.
#
# The SV concurrent assertions become a per-clock-edge monitor coroutine, the
# same idiom the vip_axi4_agent sibling uses (py/sva/bind_axi4_rd.py). Every
# reported violation increments `self.errors` and names its rule and its
# IHI 0050 clause; tests assert errors == 0.
#
# Start with: cocotb.start_soon(bind_chi(bus).run())
#
# ---------------------------------------------------------------------------
# X-propagation checks are absent BY DESIGN
# ---------------------------------------------------------------------------
# Verilator is 2-state, so a net cannot hold X and a check for it could never
# fire. Three SV checks are therefore not ported, and are listed here so the
# omission is a recorded decision rather than a gap someone re-derives later:
#
#   p_req_known_when_valid   "txreqflit contains X/Z while valid"
#   p_rsp_known_when_valid   "txrspflit contains X/Z while valid"
#   p_dat_known_when_valid   "txdatflit contains X/Z while valid"
#
# Everything else in vip_chi_sva.sv has a 2-state meaning and is portable.
#
# ---------------------------------------------------------------------------
# Severity control is deliberately NOT ported
# ---------------------------------------------------------------------------
# The AXI4 sibling routes its checks through a registry offering per-rule
# disable/warn. The CHI SV checker has no such package -- it reports through
# plain $error -- so building one here would give the Python port a control
# plane the SV port lacks, which is the exact divergence this layer exists to
# prevent. A plain counter, and a per-rule tally for the summary, matches the
# SV behaviour. If severity control is wanted, it belongs in sv/ first.
#
################################################################################

from __future__ import annotations

import logging

from cocotb.triggers import RisingEdge

# L-credit tracking caps, mirroring REQ/RSP/DAT_SEND_CAP_C in the SV checker.
# These bound the shadow counter, not the protocol: a grant past the cap means
# the peer is granting more credit than any sane pool holds.
_REQ_SEND_CAP_C = 64
_RSP_SEND_CAP_C = 64
_DAT_SEND_CAP_C = 64

# Cycles allowed between reset release and the link activating, mirroring the
# SV LINK_ACT_WINDOW_P default. Must comfortably exceed
# cfg_agent.link_act_delay_max plus the req->ack handshake.
_LINK_ACT_WINDOW_C = 32

# Channels carrying a flit/credit pair in this checker. SNP lives in
# bind_chi_snp.py, matching the SV split across two bind modules.
_CHANNELS_C = ("req", "rsp", "dat")

_CAPS_C = {
  "req": _REQ_SEND_CAP_C,
  "rsp": _RSP_SEND_CAP_C,
  "dat": _DAT_SEND_CAP_C,
}


class bind_chi:
  """CHI link-layer protocol checker for one interface.

  Sampling discipline: every check reads the values captured at a rising edge,
  so a rule expressed in SV as `a |-> b` becomes "if a, require b" on the same
  sample, and one expressed as `a |=> b` compares the previous sample against
  the current one.
  """

  def __init__(self, bus, name: str = "bind_chi",
               checks_enable: bool | None = None):
    self.bus = bus
    self.log = logging.getLogger(name)
    self.errors = 0
    # Per-rule fire counts, so a summary can say which rule fired rather than
    # only how many times something did.
    self.fail_count: dict[str, int] = {}
    self.pass_count: dict[str, int] = {}
    # None means "gate on this interface's own link activity", mirroring the
    # inline checks_enable expression on each SV bind: an interface whose agent
    # never activates its link raises no spurious violations. A bool forces the
    # gate, which is what the negative-control test uses.
    self._checks_enable = checks_enable
    self._lcrd = {}
    # Sticky "this interface has carried link traffic at least once". Gates the
    # reset-restart check only; deliberately NOT cleared by _reset_state, since
    # surviving reset is exactly what makes it usable as that gate.
    self._link_ever_active = False
    self._reset_state()

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------
  def _chk(self, rule: str, ok: bool, msg: str, where: str) -> None:
    """One check site: count the evaluation, and report it if it did not hold.

    `ok` is the violation predicate negated under the enclosing guard -- the
    guard is the antecedent. A condition that IS the antecedent belongs in an
    enclosing `if`, not folded in here, or the pass would be counted on traffic
    the rule never applied to and the rule would look exercised in a run that
    never reached it.
    """
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
    """End-of-test summary, one line per rule that was evaluated."""
    log = log or self.log
    names = self.rule_names()
    if not names:
      log.info("[VIP_CHI_CHECK] no protocol checks were evaluated")
      return
    log.info("VIP_CHI CHECK SUMMARY")
    for rule in names:
      fails = self.fail_count.get(rule, 0)
      tag = "[FAILING]" if fails else "[exercised]"
      log.info(f"  {rule:<38s} pass={self.pass_count.get(rule, 0):>7d}  "
               f"fail={fails:>5d}  {tag}")

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------
  def _reset_state(self) -> None:
    # The L-credit shadow. One pool per channel per direction, each starting at
    # 0 on reset and capturing its initial pool automatically, because that
    # pool arrives as real LCRDV pulses on the wire once the link activates.
    self._lcrd = {f"{d}{ch}": 0 for d in ("tx", "rx") for ch in _CHANNELS_C}
    self._act_countdown = None

  # ---------------------------------------------------------------------------
  # Link state predicates, mirroring the SV functions of the same names.
  # ---------------------------------------------------------------------------
  @staticmethod
  def _link_is_active(s: dict) -> bool:
    return bool(s["txlinkactivereq"] or s["txlinkactiveack"]
                or s["rxlinkactivereq"] or s["rxlinkactiveack"])

  @staticmethod
  def _link_is_running(s: dict) -> bool:
    """TX link is RUN -- the only state in which flits may be sent.

    Link activation is modelled asymmetrically: a requester raises
    txlinkactivereq and waits for the peer's rxlinkactiveack, while a completer
    never raises txlinkactivereq and only mirrors the peer's request onto
    txlinkactiveack. RUN therefore cannot be pinned to this node's own req/ack
    pair; "some request AND some acknowledge" holds for both roles. This is
    strictly tighter than _link_is_active, which only excludes full STOP.
    """
    return bool((s["txlinkactivereq"] or s["rxlinkactivereq"])
                and (s["txlinkactiveack"] or s["rxlinkactiveack"]))

  # ---------------------------------------------------------------------------
  def _sample(self) -> dict:
    g = self.bus.get_or
    names = ["txlinkactivereq", "txlinkactiveack", "txsactive",
             "rxlinkactivereq", "rxlinkactiveack", "rxsactive"]
    for ch in _CHANNELS_C:
      names += [f"tx{ch}flitv", f"tx{ch}flitpend", f"tx{ch}lcrdv",
                f"rx{ch}flitv", f"rx{ch}flitpend", f"rx{ch}lcrdv"]
    return {n: g(n) for n in names}

  def _enabled(self, s: dict) -> bool:
    if self._checks_enable is not None:
      return self._checks_enable
    # Mirrors the SV bind expression: this interface's own link activity.
    return bool(s["txlinkactivereq"] or s["rxlinkactivereq"])

  # ---------------------------------------------------------------------------
  async def run(self) -> None:
    bus = self.bus
    prev = None
    prev_rst = bus.get_rst() if hasattr(bus, "get_rst") else int(bus.rst_n.value)

    while True:
      await RisingEdge(bus.clk)
      cur = self._sample()
      rst = int(bus.rst_n.value)
      enabled = self._enabled(cur)

      if rst == 0:
        # Held in reset. The SV form is (!rst_n && $past(!rst_n)), i.e. from the
        # second reset cycle onward, so the edge itself is not judged.
        if enabled and prev_rst == 0:
          self._check_reset_idle(cur)
        self._reset_state()
        prev, prev_rst = cur, rst
        continue

      if self._link_is_active(cur):
        self._link_ever_active = True

      if prev_rst == 0:
        # Reset just released: arm the restart window. Armed outside the enable
        # gate for the reason given on _check_restart_window.
        self._act_countdown = _LINK_ACT_WINDOW_C
      if self._link_ever_active:
        self._check_restart_window(cur)

      if enabled:
        self._check_link_gating(cur)
        self._check_pend_requires_valid(cur)
        self._check_lcrd(cur)
        if prev is not None and prev_rst == 1:
          self._check_deactivate_idle(prev, cur)

      prev, prev_rst = cur, rst

  # ---------------------------------------------------------------------------
  # Reset: sideband and every channel must be idle while rst_n is low.
  # ---------------------------------------------------------------------------
  def _check_reset_idle(self, s: dict) -> None:
    self._chk(
      "CHI_LINK_SIDEBAND_IDLE_IN_RESET",
      not (s["txlinkactivereq"] or s["txlinkactiveack"] or s["txsactive"]),
      "link sideband was not held idle during reset",
      "section 13.4",
    )
    for ch in _CHANNELS_C:
      self._chk(
        f"CHI_{ch.upper()}_IDLE_IN_RESET",
        not (s[f"tx{ch}flitv"] or s[f"tx{ch}flitpend"] or s[f"tx{ch}lcrdv"]),
        f"{ch.upper()} channel was not held idle during reset",
        "section 13.4",
      )

  # ---------------------------------------------------------------------------
  # No flit and no credit before the link is RUN.
  # ---------------------------------------------------------------------------
  def _check_link_gating(self, s: dict) -> None:
    running = self._link_is_running(s)
    for ch in _CHANNELS_C:
      if s[f"tx{ch}flitv"]:
        self._chk(
          f"CHI_{ch.upper()}_FLITV_REQUIRES_LINK", running,
          f"tx{ch}flitv asserted before link activation",
          "section 13.7",
        )
      if s[f"tx{ch}lcrdv"]:
        self._chk(
          f"CHI_{ch.upper()}_LCRDV_REQUIRES_LINK", running,
          f"tx{ch}lcrdv asserted before link activation",
          "section 13.7",
        )

  # ---------------------------------------------------------------------------
  # FLITPEND is a look-ahead for a flit that must actually arrive.
  # ---------------------------------------------------------------------------
  def _check_pend_requires_valid(self, s: dict) -> None:
    for ch in _CHANNELS_C:
      if s[f"tx{ch}flitpend"]:
        self._chk(
          f"CHI_{ch.upper()}_PEND_REQUIRES_VALID", bool(s[f"tx{ch}flitv"]),
          f"tx{ch}flitpend asserted without tx{ch}flitv",
          "section 13.3",
        )

  # ---------------------------------------------------------------------------
  # L-credit shadow, mirroring lcrd_next() in the SV checker.
  # ---------------------------------------------------------------------------
  def _check_lcrd(self, s: dict) -> None:
    """Track one send-credit pool per channel per direction.

    The pairing is what makes this sound: a tx<chan>flitv send is credited by
    the INBOUND rx<chan>lcrdv, not by the outbound tx<chan>lcrdv, which credits
    the peer's rx<chan>flitv. Grant is applied before consume so a same-cycle
    grant and consume is safe (0 -> 1 -> 0) rather than racing.

    The driver refuses to send at zero credit, so a fired underflow is always a
    real violation: a flit driven with no credit authorizing it.
    """
    pairs = [
      (f"tx{ch}", s[f"rx{ch}lcrdv"], s[f"tx{ch}flitv"], _CAPS_C[ch])
      for ch in _CHANNELS_C
    ] + [
      (f"rx{ch}", s[f"tx{ch}lcrdv"], s[f"rx{ch}flitv"], _CAPS_C[ch])
      for ch in _CHANNELS_C
    ]

    for pool, grant, consume, cap in pairs:
      count = self._lcrd[pool]
      if grant:
        self._chk(
          "CHI_LCRD_OVERFLOW", count != cap,
          f"{pool} L-credit grant overflowed the tracked count",
          "section 13.6",
        )
        if count != cap:
          count += 1
      if consume:
        self._chk(
          "CHI_LCRD_UNDERFLOW", count != 0,
          f"{pool} L-credit consumed with no credit available (underflow)",
          "section 13.6",
        )
        if count != 0:
          count -= 1
      self._lcrd[pool] = count

  # ---------------------------------------------------------------------------
  # TXSACTIVE must drop once the link is no longer active.
  # ---------------------------------------------------------------------------
  def _check_deactivate_idle(self, prev: dict, cur: dict) -> None:
    # SV: !link_is_active() |=> !txsactive -- judged on the FOLLOWING cycle,
    # so the antecedent comes from the previous sample.
    if not self._link_is_active(prev):
      self._chk(
        "CHI_LINK_DEACTIVATE_WHEN_IDLE", not cur["txsactive"],
        "link entered DEACTIVATE while transmit activity was still present",
        "section 13.4",
      )

  # ---------------------------------------------------------------------------
  # After reset releases, the link must activate within the window.
  # ---------------------------------------------------------------------------
  def _check_restart_window(self, s: dict) -> None:
    """The link must come back up within the window after reset releases.

    Gated on _link_ever_active rather than on the usual enable, and the
    exception is the point. The usual gate is this interface's CURRENT link
    activity, and the check arms at reset release -- the one moment the link is
    guaranteed idle, because the reset-idle rule requires it. Gating on it made
    the check read as "if the link is up, the link comes up" and it could never
    fire. An interface whose agent is never built stays unarmed and cannot
    report a spurious failure; one that has carried traffic must reactivate.
    """
    if self._act_countdown is None:
      return
    if self._link_is_active(s):
      self._chk("CHI_LINK_RESTARTS_AFTER_RESET", True,
                "link activation did not restart after reset release",
                "section 13.4")
      self._act_countdown = None
      return
    self._act_countdown -= 1
    if self._act_countdown <= 0:
      self._err("CHI_LINK_RESTARTS_AFTER_RESET",
                "link activation did not restart after reset release",
                "section 13.4")
      self._act_countdown = None
