################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# Combined cocotb/pyUVM testbench top for the Python Verilator flow.
#
# The HDL counterpart is tb/chi_hdl_top.sv. That file is only a flat-net
# signal container and link cross-wire shell. This Python top creates the
# ChiBus handles, publishes them through ConfigDB, and starts each pyUVM test.
#
################################################################################

from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from pyuvm import ConfigDB, uvm_root


_HERE = Path(__file__).resolve().parent
_PY_ROOT = _HERE.parent


def _find_vip_root(start: Path) -> Path:
  """Locate the repo root without depending on the current directory."""
  env = os.environ.get("VIP_ROOT")
  if env:
    return Path(env).expanduser().resolve()
  for directory in [start, *start.parents]:
    if (directory / ".git").exists():
      return directory
  return start.parents[1]


_ROOT = _find_vip_root(_HERE)
_PATHS = [
  _ROOT / "py",
  _ROOT / "py" / "seq_lib",
  _ROOT / "submodules" / "vip_memory" / "py",
  _PY_ROOT / "tb",
  _PY_ROOT / "tc",
]

for path in _PATHS:
  if path.is_dir() and str(path) not in sys.path:
    sys.path.insert(0, str(path))
  elif not path.is_dir():
    raise RuntimeError(f"chi_tb_top: expected source dir not found: {path}")


from vip_chi_if import CHANNELS, ChiBus
from vip_chi_types_pkg import ChiCfg, Issue, ReqOpcode, Role, pack, unpack
from chi_tb_pkg import CHI_D_CFG, CHI_E_WIDE_CFG


A0_CFG = ChiCfg(issue=Issue.D, node_id_width=7, addr_width=44, data_bytes=32)


async def _reset_and_publish(dut, test_name: str, entries: list[tuple[str, ChiBus]]) -> None:
  """Drive reset, publish buses, and start one pyUVM testcase."""
  importlib.import_module(test_name)
  cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
  for _, bus in entries:
    bus.reset_role()

  dut.rst_n.value = 0
  for _ in range(5):
    await RisingEdge(dut.clk)
  dut.rst_n.value = 1
  await RisingEdge(dut.clk)

  for key, bus in entries:
    ConfigDB().set(None, "*", key, bus)
  await uvm_root().run_test(test_name, keep_set={ConfigDB})


async def _run_unit(dut, test_name: str) -> None:
  """Run one object-level testcase that builds no link topology.

  No ChiBus is published because nothing under test touches the wires; the clock
  runs only so the cocotb scheduler has something to advance.
  """
  importlib.import_module(test_name)
  cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
  dut.rst_n.value = 1
  await RisingEdge(dut.clk)
  await uvm_root().run_test(test_name, keep_set={ConfigDB})


async def _run_d_link(dut, test_name: str) -> None:
  """Run one CHI-D integrated RN-I to SN-F testcase."""
  await _reset_and_publish(dut, test_name, [
    ("rni_vif", ChiBus(dut, CHI_D_CFG, Role.RNI, prefix="d_rni_")),
    ("snf_vif", ChiBus(dut, CHI_D_CFG, Role.SNF, prefix="d_snf_")),
  ])


async def _run_e_link(dut, test_name: str) -> None:
  """Run one CHI-E integrated RN-I to SN-F testcase."""
  await _reset_and_publish(dut, test_name, [
    ("rni_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.RNI, prefix="e_rni_")),
    ("snf_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.SNF, prefix="e_snf_")),
  ])


async def _run_d_hni(dut, test_name: str) -> None:
  """Run one CHI-D HN-I proxy testcase."""
  await _reset_and_publish(dut, test_name, [
    ("rni0_vif", ChiBus(dut, CHI_D_CFG, Role.RNI, prefix="d_hni_rni0_")),
    ("rni1_vif", ChiBus(dut, CHI_D_CFG, Role.RNI, prefix="d_hni_rni1_")),
    ("hrn0_vif", ChiBus(dut, CHI_D_CFG, Role.HNI, prefix="d_hni_hrn0_")),
    ("hrn1_vif", ChiBus(dut, CHI_D_CFG, Role.HNI, prefix="d_hni_hrn1_")),
    ("hsn0_vif", ChiBus(dut, CHI_D_CFG, Role.RNI, prefix="d_hni_hsn0_")),
    ("hsn1_vif", ChiBus(dut, CHI_D_CFG, Role.RNI, prefix="d_hni_hsn1_")),
    ("snf0_vif", ChiBus(dut, CHI_D_CFG, Role.SNF, prefix="d_hni_snf0_")),
    ("snf1_vif", ChiBus(dut, CHI_D_CFG, Role.SNF, prefix="d_hni_snf1_")),
  ])


async def _run_e_hni(dut, test_name: str) -> None:
  """Run one CHI-E HN-I proxy testcase."""
  await _reset_and_publish(dut, test_name, [
    ("rni_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.RNI, prefix="e_hni_rni0_")),
    ("hrn_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.HNI, prefix="e_hni_hrn0_")),
    ("hsn_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.RNI, prefix="e_hni_hsn0_")),
    ("snf_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.SNF, prefix="e_hni_snf0_")),
  ])


async def _run_d_coherent(dut, test_name: str) -> None:
  """Run one CHI-D coherent topology testcase."""
  await _reset_and_publish(dut, test_name, [
    ("hrnf0_vif", ChiBus(dut, CHI_D_CFG, Role.RNF, prefix="d_coh_hrnf0_")),
    ("hrnf1_vif", ChiBus(dut, CHI_D_CFG, Role.RNF, prefix="d_coh_hrnf1_")),
    ("hnfr0_vif", ChiBus(dut, CHI_D_CFG, Role.HNF, prefix="d_coh_hnfr0_")),
    ("hnfr1_vif", ChiBus(dut, CHI_D_CFG, Role.HNF, prefix="d_coh_hnfr1_")),
    ("hnfs0_vif", ChiBus(dut, CHI_D_CFG, Role.RNI, prefix="d_coh_hnfs0_")),
    ("dsnf0_vif", ChiBus(dut, CHI_D_CFG, Role.SNF, prefix="d_coh_dsnf0_")),
  ])


async def _run_e_coherent(dut, test_name: str) -> None:
  """Run one CHI-E coherent topology testcase."""
  await _reset_and_publish(dut, test_name, [
    ("hrnf0_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.RNF, prefix="e_coh_hrnf0_")),
    ("hrnf1_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.RNF, prefix="e_coh_hrnf1_")),
    ("hnfr0_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.HNF, prefix="e_coh_hnfr0_")),
    ("hnfr1_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.HNF, prefix="e_coh_hnfr1_")),
    ("hnfs0_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.RNI, prefix="e_coh_hnfs0_")),
    ("dsnf0_vif", ChiBus(dut, CHI_E_WIDE_CFG, Role.SNF, prefix="e_coh_dsnf0_")),
  ])


async def _drive_edge(bus: ChiBus) -> None:
  """Advance to just after a rising edge so drives are legal."""
  await bus.rising()


async def _sample_edge(bus: ChiBus) -> None:
  """Advance to the ReadOnly region of a rising edge."""
  await bus.rising()
  await bus.read_only()


@cocotb.test(name="tc_chi_a0_smoke")
async def tc_chi_a0_smoke(dut) -> None:
  """Run the direct A0 smoke on the combined HDL top."""
  test_name = "tc_chi_a0_smoke"
  rni = ChiBus(dut, A0_CFG, Role.RNI, prefix="a0_rni_")
  snf = ChiBus(dut, A0_CFG, Role.SNF, prefix="a0_snf_")

  for ch in CHANNELS:
    net_w = rni.flit_net_width(ch)
    py_w = rni.expected_flit_width(ch)
    assert net_w == py_w, f"{ch}: net width {net_w} != codec width {py_w}"
    cocotb.log.info(f"width parity {ch}: net={net_w} codec={py_w} OK")

  cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
  rni.reset_role()
  snf.reset_role()
  dut.rst_n.value = 0
  await rni.clocks(3)
  dut.rst_n.value = 1
  await rni.clocks(2)

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
  assert acked, "RN-I never saw rxlinkactiveack"
  cocotb.log.info("link activation handshake completed")

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
  got = snf.sample_flit("req")
  expected = unpack(A0_CFG, "req", pack(A0_CFG, "req", fields))
  assert got == expected, f"REQ flit mismatch:\n got={got}\n exp={expected}"
  cocotb.log.info(f"Test ({test_name}) PASS")


# Static cocotb tests let scripts discover public names from the core flow.


@cocotb.test(name="tc_chi_coh_d_cache_evict", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_cache_evict(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_cache_evict"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_cmo_invalidate", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_cmo_invalidate(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_cmo_invalidate"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_data_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_data_negctl(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_data_negctl"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_dirty_forward", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_dirty_forward(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_dirty_forward"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_excl_fail_snoop", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_excl_fail_snoop(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_excl_fail_snoop"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_excl_fail_store", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_excl_fail_store(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_excl_fail_store"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_excl_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_excl_negctl(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_excl_negctl"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_excl_success", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_excl_success(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_excl_success"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_fwd_data_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_fwd_data_negctl(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_fwd_data_negctl"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_fwd_dirty", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_fwd_dirty(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_fwd_dirty"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_fwd_shared", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_fwd_shared(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_fwd_shared"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_fwd_unique", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_fwd_unique(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_fwd_unique"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_line_granularity", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_line_granularity(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_line_granularity"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_make_unique", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_make_unique(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_make_unique"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_make_unique_dct", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_make_unique_dct(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_make_unique_dct"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_make_unique_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_make_unique_negctl(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_make_unique_negctl"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_negctl(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_negctl"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_read_after_writeback", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_read_after_writeback(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_read_after_writeback"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_read_no_snoop", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_read_no_snoop(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_read_no_snoop"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_read_once", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_read_once(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_read_once"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_read_then_unique", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_read_then_unique(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_read_then_unique"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_reset_mid_snoop", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_reset_mid_snoop(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_reset_mid_snoop"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_shared_read", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_shared_read(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_shared_read"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_snf_data_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_snf_data_negctl(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_snf_data_negctl"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_snf_read_miss", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_snf_read_miss(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_snf_read_miss"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_snf_writeback_readback", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_snf_writeback_readback(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_snf_writeback_readback"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_snp_backpressure", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_snp_backpressure(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_snp_backpressure"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_stress", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_stress(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_stress"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_transition_sweep", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_transition_sweep(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_transition_sweep"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_wr_direction", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_wr_direction(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_wr_direction"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_write_unique", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_write_unique(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_write_unique"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_write_unique_ptl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_write_unique_ptl(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_write_unique_ptl"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_d_writeback_evict", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_d_writeback_evict(dut) -> None:
  """Run this public testcase through the CHI-D coherent topology."""
  test_name = "tc_chi_coh_d_writeback_evict"
  await _run_d_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_cache_evict", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_cache_evict(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_cache_evict"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_cmo_invalidate", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_cmo_invalidate(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_cmo_invalidate"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_cmo_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_cmo_negctl(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_cmo_negctl"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_data_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_data_negctl(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_data_negctl"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_dirty_forward", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_dirty_forward(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_dirty_forward"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_excl_fail_snoop", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_excl_fail_snoop(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_excl_fail_snoop"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_excl_fail_store", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_excl_fail_store(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_excl_fail_store"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_excl_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_excl_negctl(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_excl_negctl"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_excl_success", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_excl_success(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_excl_success"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_fwd_data_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_fwd_data_negctl(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_fwd_data_negctl"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_fwd_dirty", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_fwd_dirty(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_fwd_dirty"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_fwd_shared", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_fwd_shared(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_fwd_shared"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_fwd_unique", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_fwd_unique(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_fwd_unique"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_make_read_unique", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_make_read_unique(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_make_read_unique"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_make_unique", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_make_unique(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_make_unique"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_make_unique_dct", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_make_unique_dct(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_make_unique_dct"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_make_unique_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_make_unique_negctl(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_make_unique_negctl"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_negctl(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_negctl"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_read_after_writeback", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_read_after_writeback(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_read_after_writeback"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_read_no_snoop", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_read_no_snoop(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_read_no_snoop"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_read_once", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_read_once(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_read_once"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_read_then_unique", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_read_then_unique(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_read_then_unique"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_reset_mid_snoop", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_reset_mid_snoop(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_reset_mid_snoop"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_shared_read", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_shared_read(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_shared_read"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_snf_data_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_snf_data_negctl(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_snf_data_negctl"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_snf_read_miss", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_snf_read_miss(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_snf_read_miss"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_snf_writeback_readback", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_snf_writeback_readback(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_snf_writeback_readback"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_snp_backpressure", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_snp_backpressure(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_snp_backpressure"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_stress", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_stress(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_stress"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_transition_sweep", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_transition_sweep(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_transition_sweep"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_write_unique", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_write_unique(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_write_unique"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_write_unique_ptl", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_write_unique_ptl(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_write_unique_ptl"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_coh_e_writeback_evict", timeout_time=20, timeout_unit="ms")
async def tc_chi_coh_e_writeback_evict(dut) -> None:
  """Run this public testcase through the CHI-E coherent topology."""
  test_name = "tc_chi_coh_e_writeback_evict"
  await _run_e_coherent(dut, test_name)


@cocotb.test(name="tc_chi_d_atomic", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_atomic(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_atomic"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_atomic_predict", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_atomic_predict(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_atomic_predict"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_atomic_variants", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_atomic_variants(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_atomic_variants"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_credit_starvation", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_credit_starvation(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_credit_starvation"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_base_seq_smoke", timeout_time=60, timeout_unit="ms")
async def tc_chi_base_seq_smoke(dut) -> None:
  """Run this public object-level testcase with no link topology."""
  test_name = "tc_chi_base_seq_smoke"
  await _run_unit(dut, test_name)


@cocotb.test(name="tc_chi_item_smoke", timeout_time=60, timeout_unit="ms")
async def tc_chi_item_smoke(dut) -> None:
  """Run this public object-level testcase with no link topology."""
  test_name = "tc_chi_item_smoke"
  await _run_unit(dut, test_name)


@cocotb.test(name="tc_chi_cfg_item_smoke", timeout_time=20, timeout_unit="ms")
async def tc_chi_cfg_item_smoke(dut) -> None:
  """Run this public object-level testcase with no link topology."""
  test_name = "tc_chi_cfg_item_smoke"
  await _run_unit(dut, test_name)


@cocotb.test(name="tc_chi_opcode_pool_safe", timeout_time=60, timeout_unit="ms")
async def tc_chi_opcode_pool_safe(dut) -> None:
  """Run this public object-level testcase with no link topology."""
  test_name = "tc_chi_opcode_pool_safe"
  await _run_unit(dut, test_name)


@cocotb.test(name="tc_chi_cfg_invalid", timeout_time=20, timeout_unit="ms")
async def tc_chi_cfg_invalid(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_cfg_invalid"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_dataid_duplicate", timeout_time=20, timeout_unit="ms")
async def tc_chi_dataid_duplicate(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_dataid_duplicate"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_dataid_out_of_order", timeout_time=20, timeout_unit="ms")
async def tc_chi_dataid_out_of_order(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_dataid_out_of_order"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_pcrd_leak", timeout_time=20, timeout_unit="ms")
async def tc_chi_pcrd_leak(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_pcrd_leak"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_decerr_smoke", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_decerr_smoke(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_decerr_smoke"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_derr_smoke", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_derr_smoke(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_derr_smoke"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_hni_atomic", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_hni_atomic(dut) -> None:
  """Run this public testcase through the CHI-D HN-I topology."""
  test_name = "tc_chi_d_hni_atomic"
  await _run_d_hni(dut, test_name)


@cocotb.test(name="tc_chi_d_hni_backpressure", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_hni_backpressure(dut) -> None:
  """Run this public testcase through the CHI-D HN-I topology."""
  test_name = "tc_chi_d_hni_backpressure"
  await _run_d_hni(dut, test_name)


@cocotb.test(name="tc_chi_d_hni_decerr", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_hni_decerr(dut) -> None:
  """Run this public testcase through the CHI-D HN-I topology."""
  test_name = "tc_chi_d_hni_decerr"
  await _run_d_hni(dut, test_name)


@cocotb.test(name="tc_chi_d_hni_fanin", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_hni_fanin(dut) -> None:
  """Run this public testcase through the CHI-D HN-I topology."""
  test_name = "tc_chi_d_hni_fanin"
  await _run_d_hni(dut, test_name)


@cocotb.test(name="tc_chi_d_hni_passthrough", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_hni_passthrough(dut) -> None:
  """Run this public testcase through the CHI-D HN-I topology."""
  test_name = "tc_chi_d_hni_passthrough"
  await _run_d_hni(dut, test_name)


@cocotb.test(name="tc_chi_d_hni_persist", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_hni_persist(dut) -> None:
  """Run this public testcase through the CHI-D HN-I topology."""
  test_name = "tc_chi_d_hni_persist"
  await _run_d_hni(dut, test_name)


@cocotb.test(name="tc_chi_d_hni_qos", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_hni_qos(dut) -> None:
  """Run this public testcase through the CHI-D HN-I topology."""
  test_name = "tc_chi_d_hni_qos"
  await _run_d_hni(dut, test_name)


@cocotb.test(name="tc_chi_d_hni_reset", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_hni_reset(dut) -> None:
  """Run this public testcase through the CHI-D HN-I topology."""
  test_name = "tc_chi_d_hni_reset"
  await _run_d_hni(dut, test_name)


@cocotb.test(name="tc_chi_d_hni_sam", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_hni_sam(dut) -> None:
  """Run this public testcase through the CHI-D HN-I topology."""
  test_name = "tc_chi_d_hni_sam"
  await _run_d_hni(dut, test_name)


@cocotb.test(name="tc_chi_d_hni_split_write_rsp", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_hni_split_write_rsp(dut) -> None:
  """Run this public testcase through the CHI-D HN-I topology."""
  test_name = "tc_chi_d_hni_split_write_rsp"
  await _run_d_hni(dut, test_name)


@cocotb.test(name="tc_chi_d_hni_xbar", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_hni_xbar(dut) -> None:
  """Run this public testcase through the CHI-D HN-I topology."""
  test_name = "tc_chi_d_hni_xbar"
  await _run_d_hni(dut, test_name)


@cocotb.test(name="tc_chi_d_link_reactivation", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_link_reactivation(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_link_reactivation"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding_atomic", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding_atomic(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding_atomic"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding_compack", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding_compack(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding_compack"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding_concurrent", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding_concurrent(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding_concurrent"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding_mixed", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding_mixed(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding_mixed"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding_ordered", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding_ordered(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding_ordered"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding_ordered_read", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding_ordered_read(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding_ordered_read"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding_partial", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding_partial(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding_partial"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding_persist", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding_persist(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding_persist"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding_retry", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding_retry(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding_retry"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding_split", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding_split(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding_split"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_multi_outstanding_write", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_multi_outstanding_write(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_multi_outstanding_write"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_ordered_read", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_ordered_read(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_ordered_read"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_ordered_write", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_ordered_write(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_ordered_write"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_perf_smoke", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_perf_smoke(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_perf_smoke"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_prefetch_tgt", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_prefetch_tgt(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_prefetch_tgt"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_qos_echo", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_qos_echo(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_qos_echo"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_raw_inject", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_raw_inject(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_raw_inject"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_read_smoke", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_read_smoke(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_read_smoke"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_reset", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_reset(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_reset"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_retry", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_retry(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_retry"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_scoreboard_negctl", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_scoreboard_negctl(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_scoreboard_negctl"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_split_write_rsp", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_split_write_rsp(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_split_write_rsp"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_write_partial_smoke", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_write_partial_smoke(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_write_partial_smoke"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_d_write_read_smoke", timeout_time=20, timeout_unit="ms")
async def tc_chi_d_write_read_smoke(dut) -> None:
  """Run this public testcase through the CHI-D link topology."""
  test_name = "tc_chi_d_write_read_smoke"
  await _run_d_link(dut, test_name)


@cocotb.test(name="tc_chi_e_dat_smoke", timeout_time=20, timeout_unit="ms")
async def tc_chi_e_dat_smoke(dut) -> None:
  """Run this public testcase through the CHI-E link topology."""
  test_name = "tc_chi_e_dat_smoke"
  await _run_e_link(dut, test_name)


@cocotb.test(name="tc_chi_e_dbid_resp_ord", timeout_time=20, timeout_unit="ms")
async def tc_chi_e_dbid_resp_ord(dut) -> None:
  """Run this public testcase through the CHI-E link topology."""
  test_name = "tc_chi_e_dbid_resp_ord"
  await _run_e_link(dut, test_name)


@cocotb.test(name="tc_chi_e_hni_passthrough", timeout_time=20, timeout_unit="ms")
async def tc_chi_e_hni_passthrough(dut) -> None:
  """Run this public testcase through the CHI-E HN-I topology."""
  test_name = "tc_chi_e_hni_passthrough"
  await _run_e_hni(dut, test_name)


@cocotb.test(name="tc_chi_e_mte", timeout_time=20, timeout_unit="ms")
async def tc_chi_e_mte(dut) -> None:
  """Run this public testcase through the CHI-E link topology."""
  test_name = "tc_chi_e_mte"
  await _run_e_link(dut, test_name)


@cocotb.test(name="tc_chi_e_multi_outstanding_persist_sep", timeout_time=20, timeout_unit="ms")
async def tc_chi_e_multi_outstanding_persist_sep(dut) -> None:
  """Run this public testcase through the CHI-E link topology."""
  test_name = "tc_chi_e_multi_outstanding_persist_sep"
  await _run_e_link(dut, test_name)


@cocotb.test(name="tc_chi_e_persist", timeout_time=20, timeout_unit="ms")
async def tc_chi_e_persist(dut) -> None:
  """Run this public testcase through the CHI-E link topology."""
  test_name = "tc_chi_e_persist"
  await _run_e_link(dut, test_name)


@cocotb.test(name="tc_chi_e_req_smoke", timeout_time=20, timeout_unit="ms")
async def tc_chi_e_req_smoke(dut) -> None:
  """Run this public testcase through the CHI-E link topology."""
  test_name = "tc_chi_e_req_smoke"
  await _run_e_link(dut, test_name)


@cocotb.test(name="tc_chi_e_sep_read", timeout_time=20, timeout_unit="ms")
async def tc_chi_e_sep_read(dut) -> None:
  """Run this public testcase through the CHI-E link topology."""
  test_name = "tc_chi_e_sep_read"
  await _run_e_link(dut, test_name)


@cocotb.test(name="tc_chi_e_signal_drivability", timeout_time=20, timeout_unit="ms")
async def tc_chi_e_signal_drivability(dut) -> None:
  """Run this public testcase through the CHI-E link topology."""
  test_name = "tc_chi_e_signal_drivability"
  await _run_e_link(dut, test_name)


@cocotb.test(name="tc_chi_e_snf_dat_smoke", timeout_time=20, timeout_unit="ms")
async def tc_chi_e_snf_dat_smoke(dut) -> None:
  """Run this public testcase through the CHI-E link topology."""
  test_name = "tc_chi_e_snf_dat_smoke"
  await _run_e_link(dut, test_name)


@cocotb.test(name="tc_chi_e_write_zero_readback", timeout_time=20, timeout_unit="ms")
async def tc_chi_e_write_zero_readback(dut) -> None:
  """Run this public testcase through the CHI-E link topology."""
  test_name = "tc_chi_e_write_zero_readback"
  await _run_e_link(dut, test_name)


@cocotb.test(name="tc_chi_sva_smoke", timeout_time=60, timeout_unit="ms")
async def tc_chi_sva_smoke(dut) -> None:
  """Run this public object-level testcase with no link topology."""
  test_name = "tc_chi_sva_smoke"
  await _run_unit(dut, test_name)
