################################################################################
# pyUVM/cocotb port of tc/tc_chi_snp_flit_layout.sv.
#
# The SNP flit's field order was wrong in both ports for the life of the project,
# in three places at once, and nothing in either regression could see it. Both
# ports were wrong identically, so check_type_parity.py held them together
# through the defect; check_flit_layout.py can see it, but only when handed the
# specification PDFs, and without them it prints INCONCLUSIVE and verifies
# nothing -- which is how the standard gate runs.
#
# So this asserts the layout from inside the regression, where no PDF is
# available. Two independent statements, because either alone can pass over a
# real defect:
#
#   1. The declared field ORDER, LSB first, against the specification's.
#      A declaration list is what a reviewer reads, and it was wrong.
#   2. Where the bits actually LAND, by packing one field at a time set to all
#      ones and requiring the ones at the offset the order implies. A layout list
#      that is right while pack()/unpack() disagrees with it is the failure the
#      first check cannot see.
#
# MPAM is checked at both settings of mpam_en. It is the one field whose width is
# configuration-dependent, and no regression topology enables it, so a layout
# test at mpam_en=False would leave the wide flit as unbuilt as it was when the
# field was missing from the SNP flit altogether (F-CORR-011).
#
# Field order under test, LSB first, from IHI 0050 D Table 12-8 / E Table 13-8:
#   QoS, SrcID, TxnID, FwdNID, FwdTxnID, Opcode, Addr, NS, DoNotGoToSD,
#   RetToSrc, TraceTag, MPAM
#
# Runs under: testbench/py/tb/chi_tb_top.py (topology-free)
################################################################################

from __future__ import annotations

from pyuvm import uvm_test

from vip_chi_types_pkg import (
  ChiCfg, Issue, MPAM_WIDTH, flit_layout, flit_width, mask, pack, unpack,
)

# IHI 0050 D Table 12-8 / E Table 13-8, bit zero first.
_SNP_ORDER_C = (
  "qos", "srcid", "txnid", "fwdnid", "fwdtxnid", "opcode", "addr", "ns",
  "donotgotosd", "rettosrc", "tracetag", "mpam",
)


class tc_chi_snp_flit_layout(uvm_test):

  def _check_cfg(self, cfg, label):
    layout = flit_layout(cfg, "snp")
    names = tuple(n for n, _ in reversed(layout))
    assert names == _SNP_ORDER_C, (
      f"{label}: SNP field order is {names}, the specification's is "
      f"{_SNP_ORDER_C}")

    # Where the bits land. One field at a time, so a swapped pair shows up as
    # two failures naming both halves rather than one opaque mismatch.
    checked = 0
    off = 0
    widths = {n: w for n, w in layout}
    for name in _SNP_ORDER_C:
      w = widths[name]
      packed = pack(cfg, "snp", {name: mask(w)})
      want = mask(w) << off
      assert packed == want, (
        f"{label}: SNP {name} is not at bits [{off} +: {w}]: "
        f"packed=0x{packed:x} want=0x{want:x}")
      # And it comes back out of the same bits.
      assert unpack(cfg, "snp", want)[name] == mask(w), (
        f"{label}: SNP {name} did not survive a pack/unpack round trip")
      off += w
      checked += 1

    assert off == flit_width(cfg, "snp"), (
      f"{label}: SNP field widths sum to {off} but the flit is "
      f"{flit_width(cfg, 'snp')} bits: a field is unaccounted for")
    return checked

  async def run_phase(self):
    self.raise_objection()

    d_cfg = ChiCfg(Issue.D, node_id_width=7, addr_width=44, data_bytes=32)
    e_cfg = ChiCfg(Issue.E, node_id_width=11, addr_width=52, data_bytes=64)
    e_mpam_cfg = ChiCfg(Issue.E, node_id_width=11, addr_width=52,
                        data_bytes=64, mpam_en=True)

    checked = 0
    checked += self._check_cfg(d_cfg, "CHI-D")
    checked += self._check_cfg(e_cfg, "CHI-E")
    checked += self._check_cfg(e_mpam_cfg, "CHI-E mpam_en")

    # Enabling MPAM widens the flit by exactly the field's extra bits and moves
    # nothing below it, because MPAM is the most significant field. Before it was
    # added to the SNP flit, enabling mpam_en produced a flit MPAM_WIDTH - 1 bits
    # short of the specification's.
    grew = flit_width(e_mpam_cfg, "snp") - flit_width(e_cfg, "snp")
    assert grew == MPAM_WIDTH - 1, (
      f"mpam_en widened the SNP flit by {grew} bits, expected "
      f"{MPAM_WIDTH - 1} ({MPAM_WIDTH} minus the 1-bit placeholder)")

    assert checked == 3 * len(_SNP_ORDER_C), (
      f"{checked} field placements confirmed, expected "
      f"{3 * len(_SNP_ORDER_C)} -- the test itself skipped something")

    self.logger.info(
      f"Test (tc_chi_snp_flit_layout) PASS: SNP flit layout matches D Table "
      f"12-8 / E Table 13-8 in {checked} placements, MPAM both ways")
    self.drop_objection()
