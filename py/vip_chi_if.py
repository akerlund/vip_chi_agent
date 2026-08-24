################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# pyUVM port of vip_chi_if.sv (the role-gated CHI interface).
#
# SystemVerilog clocking blocks have no cocotb equivalent. ChiBus replaces them
# with a signal-handle wrapper that centralises the sample/drive timing
# discipline the monitor_cb / rni_cb / snf_cb / hni_cb clocking blocks used to
# guarantee, AND owns the packed-flit codec: the wire carries a whole packed
# struct per channel (tx{req,rsp,dat,snp}flit), so ChiBus packs a field dict ->
# int before driving and unpacks int -> dict after sampling, via
# vip_chi_types_pkg.
#
# This is the keystone every driver and monitor sits on (the CHI analog of
# vip_axi4_if.py's Axi4Bus). It handles 4 flit channels x tx/rx and the 6 CHI
# roles; the role selects which signals this endpoint drives (the SV `generate`
# clocking-block arms).
#
################################################################################

from __future__ import annotations

from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly, ReadWrite
from cocotb.utils import get_sim_time

from vip_chi_types_pkg import ChiCfg, Role, pack, unpack, flit_width

# The four CHI flit channels.
CHANNELS = ("req", "rsp", "dat", "snp")

# Link-layer activation + service-active signals (no channel prefix).
LINK_SIGNALS = [
  "txlinkactivereq", "txlinkactiveack", "rxlinkactivereq", "rxlinkactiveack",
  "txsactive", "rxsactive",
]


def _chan_signals(ch: str):
  """The eight per-channel signals (both directions)."""
  return [
    f"tx{ch}flitpend", f"tx{ch}flitv", f"tx{ch}flit", f"tx{ch}lcrdv",
    f"rx{ch}flitpend", f"rx{ch}flitv", f"rx{ch}flit", f"rx{ch}lcrdv",
  ]


ALL_SIGNALS = LINK_SIGNALS + [s for ch in CHANNELS for s in _chan_signals(ch)]

# Signals each ROLE drives (the SV role-gated clocking-block outputs). A CHI
# endpoint drives its own tx* payload and the lcrdv that GRANTS credit for the
# channels it *receives*. RN-I sends REQ (rx REQ credit -> not driven here) and
# grants RSP/DAT credit; SN-F/HN-I grant REQ credit and send RSP/DAT.
_LINK_OUT = ["txlinkactivereq", "txlinkactiveack", "txsactive"]

_RNI_OUT = _LINK_OUT + [
  "txreqflitpend", "txreqflitv", "txreqflit",              # sends REQ
  "txrspflitpend", "txrspflitv", "txrspflit", "txrsplcrdv",  # sends RSP + grants RSP credit
  "txdatflitpend", "txdatflitv", "txdatflit", "txdatlcrdv",  # sends DAT + grants DAT credit
]

_SNF_OUT = _LINK_OUT + [
  "txreqlcrdv",                                            # grants REQ credit
  "txrspflitpend", "txrspflitv", "txrspflit", "txrsplcrdv",
  "txdatflitpend", "txdatflitv", "txdatflit", "txdatlcrdv",
]

# RN-F = RN-I plus it receives snoops and grants SNP credit.
_RNF_OUT = _RNI_OUT + ["txsnplcrdv"]
# HN-F = completer toward RN-F (SNF-like) plus it sources snoops on txsnp*.
_HNF_OUT = _SNF_OUT + ["txsnpflitpend", "txsnpflitv", "txsnpflit"]

ROLE_OUTPUTS = {
  Role.RNI: _RNI_OUT,
  Role.SNF: _SNF_OUT,
  Role.HNI: _SNF_OUT,   # HN-I RN-facing port plays the completer/SN-F role
  Role.RNF: _RNF_OUT,
  Role.HNF: _HNF_OUT,
  Role.MONITOR: [],
}


class ChiBus:
  """Signal-handle wrapper + flit codec + sample/drive timing discipline.

  Resolves the CHI signals present on `dut` for one interface (optionally with
  a name prefix, e.g. "rni_"), exposes flit pack/drive and sample/unpack keyed
  by the ChiCfg-derived layout, and centralises the RisingEdge/ReadOnly/
  ReadWrite discipline. Drivers/monitors consume this, not raw handles."""

  def __init__(self, dut, cfg: ChiCfg, role: Role, prefix: str = "",
               clock_name: str = "clk", reset_name: str = "rst_n"):
    self.dut = dut
    self.cfg = cfg
    self.role = role
    self.prefix = prefix
    self.clk = getattr(dut, clock_name)
    self.rst_n = getattr(dut, reset_name)
    self.outputs = ROLE_OUTPUTS[role]
    # Resolve only the signals actually present on this DUT/top.
    self.sig = {}
    for name in ALL_SIGNALS:
      h = getattr(dut, prefix + name, None)
      if h is not None:
        self.sig[name] = h
    # Observed-input-race state; see input_race_hold().
    self._race_t = None
    self._race_prev = None
    self._race_now = False
    self._race_hold = False

  # -- observed input race (E 14.6.3 / D 13.6.3) ----------------------------
  #
  # "For all input race conditions, a component that observes the input race is
  # required to wait for both signals before changing any output signals."
  #
  # Hosted on the bus rather than in each driver for the reason the SystemVerilog
  # twin puts it in vip_chi_if: a race is identified by the STEP the two inputs
  # took, which needs state, and the sideband tasks run from several coroutines
  # in a cycle. A per-call copy of "last cycle's inputs" collapses the moment two
  # callers coincide -- the hazard that cost three attempts on the activation
  # stagger. Keying the advance on simulation time makes it idempotent within a
  # cycle and advance exactly once, which is what replaces the always_ff.
  #
  # It reads only the rx* pair, which this endpoint never drives, so the answer
  # does not depend on when in the cycle a driver asks.
  #
  # THIS PORT RETURNS THE LIVE DECISION AND THE SYSTEMVERILOG TWIN RETURNS A
  # REGISTERED ONE. That asymmetry is deliberate, it is measured in both
  # directions, and swapping either to match the other reintroduces the defect --
  # so do not "fix the inconsistency".
  #
  # The two ports differ in WHEN a driver observes the edge. cocotb wakes a
  # coroutine on RisingEdge before non-blocking-style updates have landed, so the
  # raw reads here are the PRE-edge values -- the same ones the assertions sample
  # -- and the step visible now is exactly the step that armed the obligation. A
  # SystemVerilog driver resumed on a clocking-block event reads raw wires that
  # have ALREADY advanced past the edge, so there the live term describes the
  # NEXT step and the registered one is the arming step.
  #
  # Measured, both ways round: with this port consuming the registered term the
  # completer still reported its violation (1 at the SN-F), and with the
  # SystemVerilog port consuming the live term it did too. Each port at its own
  # term reports 0.
  #
  # It advances only when a driver asks, unlike the always_ff. Every active
  # link's sideband task calls it once a cycle, and an idle link needs no hold.
  #
  # bind_chi DELIBERATELY DOES NOT CALL THIS and keeps its own copy. A checker
  # that judged the drivers against the drivers' own belief could only report
  # that they read the flag correctly: CHI_LASM_INPUT_RACE_HOLD would pass by
  # construction, and a negative control that cannot fail is the failure mode the
  # per-check mechanism exists to prevent. The duplication IS the independence.
  _RACE_C = (
    (True, 1, 0, 1),    # their ack rose with their req low
    (False, 1, 0, 0),   # their ack fell with their req still high
    (True, 0, 1, 0),    # their req rose with their ack still high
    (False, 0, 1, 1),   # their req fell with their ack low
  )

  def input_race_hold(self) -> bool:
    """True if the drive issued this cycle must not move either output."""
    now = get_sim_time("step")
    if now == self._race_t:
      return self._race_hold
    self._race_t = now

    cur = (int(self.get_or("rxlinkactivereq")), int(self.get_or("rxlinkactiveack")))
    prev = self._race_prev
    self._race_prev = cur

    if prev is None or cur == prev:
      # THE OBLIGATION IS ONE CYCLE. A race is two signals driven in one cycle
      # and observed in different ones, so the resynchronisation window is a
      # cycle; if the second has not arrived by then, what was observed was a
      # peer changing one signal at a time and 14.6.3's wait does not apply.
      # The bound is also what lets a one-shot writer wait a race out.
      self._race_now = False
    else:
      # RESOLVE TAKES PRECEDENCE OVER ARM: the change IS the arrival of the other
      # signal, so it closes an open race whatever it is, and only an unarmed
      # step can open a new one. The second half of a raced pair is itself out of
      # order almost by definition, so arming on it would chain one race into a
      # permanent hold.
      step = False
      for rising, idx, other, need in self._RACE_C:
        if cur[idx] != (1 if rising else 0) or prev[idx] == cur[idx]:
          continue
        if cur[other] != need:
          step = True
          break
      self._race_now = (not self._race_hold) and step
    self._race_hold = self._race_now
    return self._race_hold

  # -- introspection --------------------------------------------------------
  def has(self, name: str) -> bool:
    return name in self.sig

  def present_signals(self):
    return sorted(self.sig)

  def flit_net_width(self, channel: str) -> int:
    """Width the compiled top actually declared for tx{channel}flit."""
    return len(self.sig[f"tx{channel}flit"])

  def expected_flit_width(self, channel: str) -> int:
    """Width the Python codec computes for this cfg/channel."""
    return flit_width(self.cfg, channel)

  # -- drive ----------------------------------------------------------------
  def drive(self, **values):
    """Assign raw signal values immediately. Unknown signals raise (catch typos)."""
    for name, val in values.items():
      if name not in self.sig:
        raise KeyError(f"ChiBus: signal '{name}' not present "
                       f"(have: {self.present_signals()})")
      self.sig[name].value = int(val)

  def drive_flit(self, channel: str, fields: dict):
    """Pack a field dict via the codec and drive tx{channel}flit."""
    self.sig[f"tx{channel}flit"].value = pack(self.cfg, channel, fields)

  def park(self, names, value=0):
    for name in names:
      if name in self.sig:
        self.sig[name].value = value

  def reset_role(self):
    """Park every signal this role drives to 0 (safe link-idle)."""
    self.park([n for n in self.outputs if n in self.sig], 0)
    # 14.1.3 has both peers holding the sideband idle through reset, so nothing
    # is in flight; a race carried across would freeze the bring-up that
    # follows. The SystemVerilog twin clears the same state on !rst_n.
    self._race_t = None
    self._race_prev = None
    self._race_now = False
    self._race_hold = False

  # -- sample ---------------------------------------------------------------
  def get(self, name: str) -> int:
    return int(self.sig[name].value)

  def get_or(self, name: str, default: int = 0) -> int:
    h = self.sig.get(name)
    return int(h.value) if h is not None else default

  def sample_flit(self, channel: str, direction: str = "rx") -> dict:
    """Unpack {direction}{channel}flit back into a field dict."""
    return unpack(self.cfg, channel, int(self.sig[f"{direction}{channel}flit"].value))

  # -- timing (mirrors Axi4Bus discipline) ---------------------------------
  async def rising(self):
    await RisingEdge(self.clk)

  async def falling(self):
    await FallingEdge(self.clk)

  async def settle(self):
    """Enter ReadWrite -- where drives for this timestep belong."""
    await ReadWrite()

  async def read_only(self):
    await ReadOnly()

  async def clocks(self, n: int):
    for _ in range(n):
      await RisingEdge(self.clk)

  def in_reset(self) -> bool:
    return int(self.rst_n.value) == 0
