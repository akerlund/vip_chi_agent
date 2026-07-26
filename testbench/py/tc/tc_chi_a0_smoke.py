################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# Tier A0 gate: the pyUVM/cocotb keystone, end to end.
#
#   1. WIDTH PARITY -- the compiled flat-net flit widths (from $bits of the SV
#      vip_chi_types_d structs) equal the Python codec widths, for all four
#      channels. This is the guard that the Python flit layout never drifts from
#      the RTL structs.
#   2. LINK ACTIVATION -- a minimal RN-I <-> SN-F txlinkactivereq/ack handshake
#      transits the link adapter (tx<->rx cross-wire).
#   3. FLIT ROUND-TRIP -- an RN-I packs a distinctive REQ flit via the codec,
#      drives it, and the SN-F samples + unpacks it on its rx and gets exactly
#      the same fields back. Proves codec + ChiBus + link wiring together.
#
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

import cocotb
from cocotb.clock import Clock

from vip_chi_types_pkg import ChiCfg, Issue, Role, ReqOpcode, pack, unpack
from vip_chi_if import ChiBus, CHANNELS

# Must match the A0_CFG geometry in tb/chi_hdl_top.sv.
A0_CFG = ChiCfg(issue=Issue.D, node_id_width=7, addr_width=44, data_bytes=32)


async def _drive_edge(bus: ChiBus):
  """Advance to just after a rising edge (drives are legal here)."""
  await bus.rising()


async def _sample_edge(bus: ChiBus):
  """Advance to the ReadOnly region of a rising edge (registered values settled)."""
  await bus.rising()
  await bus.read_only()


@cocotb.test()
async def tc_chi_a0_smoke(dut):
  rni = ChiBus(dut, A0_CFG, Role.RNI, prefix="rni_")
  snf = ChiBus(dut, A0_CFG, Role.SNF, prefix="snf_")

  # -- 1. width parity: compiled net width == Python codec width -------------
  for ch in CHANNELS:
    net_w = rni.flit_net_width(ch)
    py_w = rni.expected_flit_width(ch)
    assert net_w == py_w, f"{ch}: net width {net_w} != codec width {py_w}"
    cocotb.log.info(f"width parity {ch}: net={net_w} codec={py_w} OK")

  # -- clock + reset ---------------------------------------------------------
  cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
  rni.reset_role()
  snf.reset_role()
  dut.rst_n.value = 0
  await rni.clocks(3)
  dut.rst_n.value = 1
  await rni.clocks(2)

  # -- 2. link activation handshake (RN-I requests, SN-F acks) ---------------
  await _drive_edge(rni)
  rni.drive(txlinkactivereq=1, txsactive=1)

  seen = False
  for _ in range(10):
    await _sample_edge(snf)
    if snf.get("rxlinkactivereq") == 1:
      seen = True
      break
  assert seen, "SN-F never saw rxlinkactivereq across the link adapter"

  await _drive_edge(snf)
  snf.drive(txlinkactiveack=1, txsactive=1)

  acked = False
  for _ in range(10):
    await _sample_edge(rni)
    if rni.get("rxlinkactiveack") == 1:
      acked = True
      break
  assert acked, "RN-I never saw rxlinkactiveack (activation did not complete)"
  cocotb.log.info("link activation handshake completed")

  # -- 3. flit round-trip through the codec + link adapter -------------------
  fields = {
    "tgtid": 0x5,
    "srcid": 0x3,
    "txnid": 0x2AA,
    "opcode": int(ReqOpcode.READ_NO_SNP),
    "addr": 0x0123_4567_89AB,
    "size": 6,
    "ns": 1,
    "order": 2,
    "qos": 0xA,
    "returnnid": 0x7,
    "returntxnid": 0x155,
  }
  await _drive_edge(rni)
  rni.drive_flit("req", fields)
  rni.drive(txreqflitpend=1, txreqflitv=1)

  await _sample_edge(snf)
  assert snf.get("rxreqflitv") == 1, "SN-F did not see rxreqflitv"
  got = snf.sample_flit("req")                       # unpack rxreqflit
  expected = unpack(A0_CFG, "req", pack(A0_CFG, "req", fields))
  assert got == expected, f"REQ flit mismatch:\n got={got}\n exp={expected}"

  # spot-check a couple of fields explicitly for a human-readable assertion
  assert got["opcode"] == int(ReqOpcode.READ_NO_SNP)
  assert got["addr"] == fields["addr"]
  assert got["qos"] == 0xA
  cocotb.log.info(f"REQ flit round-trip OK: txnid={got['txnid']:#x} "
                  f"addr={got['addr']:#x} opcode={got['opcode']:#x}")

  cocotb.log.info("Test (tc_chi_a0_smoke) PASS")
