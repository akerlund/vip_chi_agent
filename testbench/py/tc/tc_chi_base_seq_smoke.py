################################################################################
# pyUVM/cocotb port of tc/tc_chi_base_seq_smoke.sv.
#
# Object-level smoke for the sequence-library building blocks: the seq config,
# the address iterator's auto and fixed strides plus its address list, the custom
# payload buffer, the counter iterator, the base-sequence setters and reset(),
# the direction pinned by each concrete sequence, and preview_next_request()
# preserving every stamped field on both CHI shapes. No link topology is built.
#
# Two SV assertions have no Python counterpart and are noted inline where they
# would have gone: get_access_name() (SV-only introspection) and the CHI-D
# WriteNoSnpZero fatal, which this port raises as an exception rather than a
# uvm_fatal, so it is asserted as one.
# Runs under: testbench/py/tb/chi_tb_top.py
################################################################################

from __future__ import annotations

from pyuvm import uvm_test

from vip_chi_types_pkg import Dir, Role, ReqOpcode, DatOpcode, DataType, ReqOrder
from vip_chi_item import vip_chi_item
from vip_chi_cfg_item import VipChiCfgItem
from vip_chi_seq_config import vip_chi_seq_config
from vip_chi_addr_iterator import vip_chi_addr_iterator
from vip_chi_seq_payload_buffer import vip_chi_seq_payload_buffer
from vip_chi_seq_counter_iter import vip_chi_seq_counter_iter
from vip_chi_base_seq import vip_chi_base_seq
from vip_chi_read_seq import vip_chi_read_seq
from vip_chi_write_seq import vip_chi_write_seq
from vip_chi_write_zero_seq import vip_chi_write_zero_seq
from vip_chi_reject import expect_rejection
from vip_chi_write_cmo_seq import vip_chi_write_cmo_seq, CMO_CLEAN_SH_PER_SEP
from vip_chi_pipelined_seq import vip_chi_pipelined_seq
from chi_tb_pkg import CHI_D_WIDE_CFG, CHI_E_WIDE_CFG


class tc_chi_base_seq_smoke(uvm_test):

  async def run_phase(self):
    self.raise_objection()

    # ---- seq config --------------------------------------------------------
    seq_cfg = vip_chi_seq_config("seq_cfg")
    seq_cfg.reset()
    assert seq_cfg.requests == 1, "seq_config reset() did not restore requests"

    # ---- address iterator --------------------------------------------------
    addr_iter = vip_chi_addr_iterator("addr_iter")
    addr_iter.set_initial_addr(0x1000)
    assert addr_iter.current() == 0x1000, "addr_iterator current() mismatch"

    # Auto stride: one 2**6 = 64-byte transfer.
    assert addr_iter.advance(6) == 0x1040, "addr_iterator auto-stride mismatch"

    addr_iter.set_increment(16)
    assert addr_iter.advance(0) == 0x1050, "addr_iterator fixed-stride mismatch"

    addr_iter.load_list([0x2000, 0x3000])
    assert addr_iter.list_size() == 2, "addr_iterator list_size() mismatch"
    assert addr_iter.pop_list_front() == 0x2000, \
      "addr_iterator pop_list_front() mismatch"

    # ---- custom payload buffer --------------------------------------------
    cfg_item = VipChiCfgItem("cfg_item")
    cfg_item.direction = Dir.WRITE
    cfg_item.data_type = DataType.CUSTOM
    cfg_item.min_size = 6
    cfg_item.max_size = 6

    payload_buf = vip_chi_seq_payload_buffer(
      "payload_buf", data_bytes=CHI_D_WIDE_CFG.data_bytes)
    payload_buf.set_data([0x1234])
    payload_buf.set_be([(1 << CHI_D_WIDE_CFG.be_width) - 1])
    payload_buf.clamp_size(cfg_item)

    item = vip_chi_item("custom_item", CHI_D_WIDE_CFG)
    item.set_size(6)
    item.set_data_type(DataType.CUSTOM)
    item.set_deferred_custom_payload(True)
    with item.randomize_with() as x:
      x.direction == int(Dir.WRITE)
      x.role == int(Role.RNI)
      x.opcode == int(ReqOpcode.WRITE_NO_SNP_PTL)

    payload_buf.apply(item, cfg_item)
    assert len(item.data) == 1 and int(item.data[0]) == 0x1234, \
      "payload_buffer apply() did not stamp custom data"
    assert len(item.be) == 1 and \
      int(item.be[0]) == (1 << CHI_D_WIDE_CFG.be_width) - 1, \
      "payload_buffer apply() did not stamp custom BE"
    assert payload_buf.exhausted(), \
      "payload_buffer did not consume the custom slice"

    # ---- counter iterator --------------------------------------------------
    counter_iter = vip_chi_seq_counter_iter("counter_iter")
    counter_iter.set_counter(0x10)
    counter_iter.set_increment(0x4)

    cfg_item.data_type = DataType.COUNTER
    item = vip_chi_item("counter_item", CHI_D_WIDE_CFG)
    item.set_size(6)
    item.set_data_type(DataType.COUNTER)
    counter_iter.configure_item(item)
    with item.randomize_with() as x:
      x.direction == int(Dir.WRITE)
      x.role == int(Role.RNI)
      x.opcode == int(ReqOpcode.WRITE_NO_SNP_FULL)

    counter_iter.advance(item, cfg_item)
    assert counter_iter.get_counter() == 0x14, \
      "counter_iter did not advance after one beat"

    # ---- base-sequence setters and reset() ---------------------------------
    seq = vip_chi_base_seq("seq", cfg=CHI_D_WIDE_CFG)
    seq.set_initial_addr(0x4000)
    seq.set_size(6)
    seq.set_requests(4)
    seq.set_data_type(DataType.COUNTER)
    seq.set_counter_value(0x20)
    seq.set_counter_increment(0x2)
    assert seq.get_counter() == 0x20, "base_seq counter setter/getter mismatch"

    seq.set_ns(0)
    seq.set_order(ReqOrder.REQ_ORDER)
    seq.set_mem_attr(0xF)
    seq.set_allow_retry(0)
    seq.set_exp_comp_ack(1)
    seq.set_excl(1)
    seq.set_pcrd_type(0x5)
    seq.set_get_response(True)
    seq.set_request_delay(True, 1, 2, 10)
    seq.set_verbose(False)
    seq.set_log_denominator(8)
    seq.reset()
    assert seq.get_counter() == 0, \
      "base_seq reset() did not reset the counter iterator"

    # ---- direction pinned by the concrete sequences ------------------------
    # body() is what pins the direction, so run it with zero requests: it sends
    # nothing and needs no sequencer, exactly as the SV twin does.
    read_seq = vip_chi_read_seq("read_seq", cfg=CHI_D_WIDE_CFG)
    read_seq.set_requests(0)
    await read_seq.body()
    assert read_seq.get_direction() == Dir.READ, \
      "read_seq did not pin READ direction"
    read_seq.reset()
    assert read_seq.get_direction() == Dir.READ, \
      "read_seq reset() did not preserve READ direction"

    write_seq = vip_chi_write_seq("write_seq", cfg=CHI_D_WIDE_CFG)
    write_seq.set_requests(0)
    await write_seq.body()
    assert write_seq.get_direction() == Dir.WRITE, \
      "write_seq did not pin WRITE direction"
    write_seq.reset()
    assert write_seq.get_direction() == Dir.WRITE, \
      "write_seq reset() did not preserve WRITE direction"

    # ---- CHI-D write preview keeps every stamped field ---------------------
    write_seq.set_initial_addr(0x4400)
    write_seq.set_size(6)
    write_seq.set_data_type(DataType.COUNTER)
    write_seq.set_src_id(0x12)
    write_seq.set_tgt_id(0x34)
    write_seq.set_lp_id(0x7)
    write_seq.set_qos(0x9)
    write_seq.set_ns(0)
    write_seq.set_order(ReqOrder.REQ_ORDER)
    write_seq.set_mem_attr(0xF)
    write_seq.set_allow_retry(0)
    write_seq.set_exp_comp_ack(1)
    write_seq.set_excl(1)
    write_seq.set_pcrd_type(0x5)
    preview = write_seq.preview_next_request()

    assert int(preview.addr) == 0x4400, \
      "write_seq preview did not preserve the stamped address"
    assert int(preview.direction) == int(Dir.WRITE), \
      "write_seq preview did not preserve WRITE direction"
    assert int(preview.role) == int(Role.RNI), \
      "write_seq preview did not preserve RN-I role"
    assert (int(preview.src_id), int(preview.tgt_id), int(preview.lp_id)) == \
      (0x12, 0x34, 0x7), \
      "write_seq preview did not preserve stamped identity fields"
    assert int(preview.qos) == 0x9, \
      "write_seq preview did not preserve stamped QoS"
    assert int(preview.opcode) == int(ReqOpcode.WRITE_NO_SNP_FULL), \
      "write_seq preview chose the wrong write opcode"
    assert (int(preview.ns), int(preview.order), int(preview.mem_attr)) == \
      (0, int(ReqOrder.REQ_ORDER), 0xF), \
      "write_seq preview did not preserve stamped control fields"
    assert (int(preview.allow_retry), int(preview.exp_comp_ack),
            int(preview.excl), int(preview.pcrd_type)) == (0, 1, 1, 0x5), \
      "write_seq preview did not preserve stamped control fields"
    assert int(preview.dat_opcode) == int(DatOpcode.NCB_WR_DATA_COMP_ACK), \
      "write_seq preview did not derive the CompAck-capable DAT opcode"

    # ---- CHI-E separated-read preview --------------------------------------
    read_seq_e = vip_chi_read_seq("read_seq_e", cfg=CHI_E_WIDE_CFG)
    read_seq_e.set_initial_addr(0x4600)
    read_seq_e.set_size(6)
    read_seq_e.set_sep_read(True)
    read_seq_e.set_src_id(0x5)
    read_seq_e.set_tgt_id(0x2)
    read_seq_e.set_return_nid(0x5)
    read_seq_e.set_return_txn_id(0x2A)
    read_seq_e.set_qos(0x6)
    read_seq_e.set_tracetag(1)
    # DoDWT is deliberately absent from the stamped set. IHI 0050 E section
    # 13.10.25 makes it applicable only in WriteNoSnpFull, WriteNoSnpPtl and
    # Combined Write, and Table 2-14 lists ReadNoSnpSep as Non-snoopable only --
    # so on this opcode REQ bit 17 has no legal non-zero value under either of
    # the two names it carries. The field is proven drivable on an opcode that
    # does carry it by tc_chi_e_signal_drivability; what is worth checking here
    # is that the inapplicable field is held at zero.
    read_seq_e.set_likelyshared(1)
    read_seq_e.set_endian(1)
    read_seq_e.set_group_id_ext(0x5)
    read_seq_e.set_tagop(0x2)
    preview_e = read_seq_e.preview_next_request()

    assert int(preview_e.opcode) == int(ReqOpcode.READ_NO_SNP_SEP), \
      "read_seq CHI-E preview did not choose ReadNoSnpSep"
    assert (int(preview_e.return_nid), int(preview_e.return_txn_id),
            int(preview_e.qos)) == (0x5, 0x2A, 0x6), \
      "read_seq CHI-E preview did not preserve return-path / QoS fields"
    assert (int(preview_e.tracetag), int(preview_e.dodwt),
            int(preview_e.likelyshared), int(preview_e.endian),
            int(preview_e.group_id_ext), int(preview_e.tagop)) == \
      (1, 0, 1, 1, 0x5, 0x2), \
      "read_seq CHI-E preview did not preserve control / tagop fields"

    # ---- CHI-E write preview carries the DAT tagging fields ----------------
    write_seq_e = vip_chi_write_seq("write_seq_e", cfg=CHI_E_WIDE_CFG)
    write_seq_e.set_initial_addr(0x4800)
    write_seq_e.set_size(6)
    write_seq_e.set_dat_tagop(0x1)
    write_seq_e.set_tag([0x3])
    write_seq_e.set_tu([0x1])
    preview_e_dat = write_seq_e.preview_next_request()

    assert int(preview_e_dat.dat_tagop) == 0x1
    assert len(preview_e_dat.tag) == 1 and int(preview_e_dat.tag[0]) == 0x3
    assert len(preview_e_dat.tu) == 1 and int(preview_e_dat.tu[0]) == 0x1

    # ---- write-zero sequence -----------------------------------------------
    write_zero_e = vip_chi_write_zero_seq("write_zero_seq_e", cfg=CHI_E_WIDE_CFG)
    write_zero_e.set_requests(0)
    assert int(write_zero_e._choose_opcode()) == int(ReqOpcode.WRITE_NO_SNP_ZERO), \
      "write_zero_seq did not force WriteNoSnpZero"
    # The SV twin also checks get_access_name() == "WriteNoSnpZero"; this port
    # has no access-name introspection, so there is nothing to compare.

    await write_zero_e.body()
    assert write_zero_e.get_direction() == Dir.WRITE, \
      "write_zero_seq did not pin WRITE direction"
    write_zero_e.reset()
    assert write_zero_e.get_direction() == Dir.WRITE, \
      "write_zero_seq reset() did not preserve WRITE direction"

    # WriteNoSnpZero is CHI-E only. The SV twin catches a uvm_fatal with
    # chi_write_zero_fatal_catcher and asserts it fired; this is the same
    # statement in this port's form. It used to be a try/except/else, which works
    # only because the refusal is raised in code the test awaits directly -- the
    # scope below is the general form, and it is the one a refusal raised inside a
    # driver coroutine needs (F-CHK-003).
    write_zero_d = vip_chi_write_zero_seq("write_zero_seq_d", cfg=CHI_D_WIDE_CFG)
    write_zero_d.set_requests(0)
    with expect_rejection("WRITE_ZERO_ISSUE", count=None):
      await write_zero_d.body()

    # ---- combined Write + CMO sequence --------------------------------------
    # The combined forms are opt-in in the item's opcode pool, and the sequence
    # is what opts in. Previewing is the path where that is easiest to forget,
    # because it forces the same opcode through the same constraints without ever
    # starting the sequence: if the preview did not opt in, this call would raise
    # a solver failure rather than return an item.
    write_cmo_e = vip_chi_write_cmo_seq("write_cmo_seq_e", cfg=CHI_E_WIDE_CFG)
    write_cmo_e.set_initial_addr(0x4C00)
    write_cmo_e.set_size(6)
    write_cmo_e.set_partial(True)
    write_cmo_e.set_cmo(CMO_CLEAN_SH_PER_SEP)
    preview_e_cmo = write_cmo_e.preview_next_request()

    assert int(preview_e_cmo.opcode) == \
      int(ReqOpcode.WRITE_NO_SNP_PTL_CLEAN_SH_PER_SEP), (
        f"write_cmo_seq preview chose opcode 0x{int(preview_e_cmo.opcode):x}, "
        f"not WriteNoSnpPtlCleanShPerSep")
    assert int(preview_e_cmo.direction) == int(Dir.WRITE), \
      "write_cmo_seq preview did not pin WRITE direction"
    assert write_cmo_e.is_persist(), \
      "write_cmo_seq did not report the persistent CMO as persistent"

    # Combined Write + CMO is CHI-E only. The SV twin catches a uvm_fatal here;
    # this port raises, so the refusal is asserted as an exception.
    write_cmo_d = vip_chi_write_cmo_seq("write_cmo_seq_d", cfg=CHI_D_WIDE_CFG)
    write_cmo_d.set_requests(0)
    try:
      await write_cmo_d.body()
    except RuntimeError:
      pass
    else:
      raise AssertionError(
        "write_cmo_seq accepted CHI-D; combined Write+CMO is CHI-E only")

    # ---- pipelined sequence ------------------------------------------------
    pipelined = vip_chi_pipelined_seq("pipelined_seq", cfg=CHI_D_WIDE_CFG)
    assert pipelined.max_outstanding == 8, \
      "pipelined_seq default max_outstanding mismatch"
    assert pipelined.item_count() == 0, \
      "pipelined_seq should start with an empty queue"

    pipelined.add_item(vip_chi_item("pipelined_item", CHI_D_WIDE_CFG))
    assert pipelined.item_count() == 1, \
      "pipelined_seq add_item() did not queue the item"

    pipelined.set_get_response(True)
    pipelined.reset()
    assert pipelined.item_count() == 0, \
      "pipelined_seq reset() did not clear queued items"
    assert pipelined.response_count() == 0, \
      "pipelined_seq reset() did not clear collected responses"
    assert pipelined.max_outstanding == 8, \
      "pipelined_seq reset() did not restore max_outstanding"

    self.logger.info("Test (tc_chi_base_seq_smoke) PASS")
    self.drop_objection()
