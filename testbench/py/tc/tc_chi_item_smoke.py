################################################################################
# pyUVM/cocotb port of tc/tc_chi_item_smoke.sv.
#
# Object-level smoke for vip_chi_item across both CHI shapes: issue-aware
# randomization, the payload arrays a write allocates, copy/compare including the
# dynamic payload, convert2string, address-alignment enforcement, and the
# issue-gated legality helper. No link topology is built.
#
# ONE assertion from the SV twin is deliberately not ported -- that
# req_opcode_is_legal() rejects MakeReadUnique for a READ. The two ports disagree
# there and the disagreement is not this test's to settle: see the note above
# that block below.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from pyuvm import uvm_test

from vip_chi_types_pkg import Dir, Role, ReqOpcode, DatOpcode, DataType
from vip_chi_item import vip_chi_item
from chi_tb_pkg import CHI_D_WIDE_CFG, CHI_E_WIDE_CFG


class tc_chi_item_smoke(uvm_test):

  async def run_phase(self):
    self.raise_objection()

    d_item = vip_chi_item("chi_d_item", CHI_D_WIDE_CFG)
    e_item = vip_chi_item("chi_e_item", CHI_E_WIDE_CFG)

    rni = int(Role.RNI)
    rd = int(Dir.READ)
    wr = int(Dir.WRITE)

    # ---- CHI-D full write: payload arrays, copy/compare, DAT opcode ---------
    d_item.set_size(6)
    d_item.set_data_type(DataType.COUNTER)
    d_item.set_counter_value(0x10)

    with d_item.randomize_with() as x:
      x.direction == wr
      x.role == rni
      x.opcode == int(ReqOpcode.WRITE_NO_SNP_FULL)

    # 64-byte transfer over a 64-byte bus = one beat.
    assert len(d_item.data) == 1, \
      f"CHI-D full-write expected one payload beat, got {len(d_item.data)}"
    assert len(d_item.be) == 1, \
      f"CHI-D full-write expected one BE beat, got {len(d_item.be)}"

    d_copy = vip_chi_item("chi_d_copy", CHI_D_WIDE_CFG)
    d_copy.do_copy(d_item)
    assert d_copy.do_compare(d_item), \
      "CHI-D copy/compare did not preserve the payload-bearing item state"
    assert len(d_copy.data) == len(d_item.data)
    assert len(d_copy.be) == len(d_item.be)
    assert int(d_copy.data[0]) == int(d_item.data[0])
    assert int(d_copy.be[0]) == int(d_item.be[0])

    assert len(d_copy.convert2string()) > 0, \
      "convert2string() returned an empty summary"

    # compare() must notice a payload mutation, not just the scalar fields.
    d_copy.data[0] = int(d_copy.data[0]) ^ 1
    assert not d_copy.do_compare(d_item), \
      "compare() failed to detect a payload mutation"

    expected_dat = (DatOpcode.NCB_WR_DATA_COMP_ACK if d_item.exp_comp_ack
                    else DatOpcode.NON_COPY_BACK_WR_DATA)
    assert int(d_item.dat_opcode) == int(expected_dat), \
      "CHI-D full-write chose the wrong DAT opcode for its ExpCompAck setting"

    # ---- CHI-D read: legality of the drawn opcode, issue gating ------------
    with d_item.randomize_with() as x:
      x.direction == rd
      x.role == rni

    assert d_item.req_opcode_is_legal(d_item.opcode, d_item.direction), \
      "CHI-D read randomized an illegal opcode"
    assert not d_item.req_opcode_is_legal(int(ReqOpcode.READ_NO_SNP_SEP), rd), \
      "CHI-D legality helper accepted the CHI-E-only ReadNoSnpSep"
    assert not d_item.req_opcode_is_legal(int(ReqOpcode.MAKE_READ_UNIQUE), rd), \
      "CHI-D legality helper accepted MakeReadUnique, whose 0x41 encoding does " \
      "not fit the 6-bit CHI-D REQ opcode field"

    # ---- Address alignment -------------------------------------------------
    d_item.set_addr_range(0x1000, 0x1003)
    d_item.set_size(2)
    d_item.set_enforce_addr_alignment(True)
    with d_item.randomize_with() as x:
      x.direction == rd
      x.role == rni
      x.opcode == int(ReqOpcode.READ_NO_SNP)
    assert (int(d_item.addr) & 0x3) == 0, \
      "produced an unaligned address while alignment was enforced"

    d_item.set_addr_range(0x1003, 0x1003)
    d_item.set_enforce_addr_alignment(False)
    with d_item.randomize_with() as x:
      x.direction == rd
      x.role == rni
      x.opcode == int(ReqOpcode.READ_NO_SNP)
    assert int(d_item.addr) == 0x1003, \
      "did not preserve the explicit unaligned address once alignment was off"

    # ---- CHI-E separated read and zero write -------------------------------
    e_item.set_size(6)
    with e_item.randomize_with() as x:
      x.direction == rd
      x.role == rni
      x.opcode == int(ReqOpcode.READ_NO_SNP_SEP)

    assert int(e_item.return_nid) == int(e_item.src_id), \
      "CHI-E separated read did not constrain return_nid to src_id"
    assert e_item.req_opcode_is_legal(int(ReqOpcode.READ_NO_SNP_SEP), rd), \
      "CHI-E legality helper rejected ReadNoSnpSep"
    assert len(e_item.data) == 0, \
      "CHI-E separated-read request should not pre-populate DAT payload"

    # MakeReadUnique is the mirror of the CHI-D assertion above: the opcode is
    # legal for a coherent read exactly when the REQ opcode field is wide enough
    # to carry 0x41, which is issue E.
    assert e_item.req_opcode_is_legal(int(ReqOpcode.MAKE_READ_UNIQUE), rd), \
      "CHI-E legality helper rejected MakeReadUnique"

    with e_item.randomize_with() as x:
      x.direction == wr
      x.role == rni
      x.opcode == int(ReqOpcode.WRITE_NO_SNP_ZERO)
    assert len(e_item.data) == 0, \
      "WriteNoSnpZero should not carry request DAT payload"

    self.logger.info("Test (tc_chi_item_smoke) PASS")
    self.drop_objection()
