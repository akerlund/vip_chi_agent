// ===========================================================================
// tc_chi_d_qos_echo
//
// Regression test for §7 B1 (+ P3c): the SN-F must echo the request QoS on its
// auto-responses, not truncate it to 1 bit. Before the fix the SN-F assigned
// `rsp.qos = logic'(req.qos)` (1-bit cast) on its RSP legs and left the read
// CompData qos at 0, so any QoS with a clear bit 0 was mangled. This drives a
// write and a read with QoS = 0xA (0b1010, bit0=0 -> the old 1-bit cast yielded
// 0) and asserts the completions carry the full 0xA back:
//   - write completion (CompDBIDResp) QoS == 0xA   (B1, RSP leg)
//   - read completion  (CompData)     QoS == 0xA   (P3c, DAT leg)
// ===========================================================================
class tc_chi_d_qos_echo extends chi_base_test;

  `uvm_component_utils(tc_chi_d_qos_echo)

  localparam logic [VIP_CHI_QOS_WIDTH_C-1:0] QOS_C = 4'hA;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(input uvm_phase phase);

    item_t write_responses[$];
    item_t read_responses[$];

    phase.raise_objection(this);

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(WRITE_READ_ADDR_C);
    super.rni0_wr_seq.set_size(3'd6);
    super.rni0_wr_seq.set_qos(QOS_C);
    super.rni0_wr_seq.set_allow_retry(1'b0);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(WRITE_READ_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_qos(QOS_C);
    super.rni0_rd_seq.set_allow_retry(1'b0);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    write_responses = super.rni0_wr_seq.get_responses();
    read_responses  = super.rni0_rd_seq.get_responses();

    if ((write_responses.size() != 1) || (read_responses.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 write + 1 read response, got %0d/%0d",
        super.tc_name, write_responses.size(), read_responses.size()))
    end

    // B1: the write completion (CompDBIDResp, RSP leg) must echo the full QoS.
    if (write_responses[0].qos !== QOS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] write completion QoS 0x%0h, expected 0x%0h (SN-F truncated the QoS echo)",
        super.tc_name, write_responses[0].qos, QOS_C))
    end

    // P3c: the read completion (CompData, DAT leg) must echo the full QoS.
    if (read_responses[0].qos !== QOS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] read completion QoS 0x%0h, expected 0x%0h (SN-F did not echo CompData QoS)",
        super.tc_name, read_responses[0].qos, QOS_C))
    end

    phase.drop_objection(this);
  endtask
endclass
