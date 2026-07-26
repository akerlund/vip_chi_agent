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
