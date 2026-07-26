// ===========================================================================
// chi_coh_write_unique_ptl_base_test
//
// WriteUniquePtl is a non-allocating coherent partial write. RN-F0 first takes a
// Shared copy of the line. RN-F1 then writes 16 byte-enabled bytes at line offset
// 16. The home must invalidate RN-F0, collect the NonCopyBackWrData at the REQ
// address (not the line base), apply the byte enables, and leave RN-F1 Invalid.
// A full-line readback must match the original image everywhere except the
// enabled byte lanes.
//
// Used by:
//   tc_chi_coh_d_write_unique_ptl  (CHI-D)
//   tc_chi_coh_e_write_unique_ptl  (wide CHI-E)
// ===========================================================================
class chi_coh_write_unique_ptl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_write_unique_ptl_base_test #(CFG_P, TYPES_T))

  localparam int       WRITE_BYTES_C        = 16;
  localparam int       WRITE_OFFSET_BYTES_C = 16;
  localparam bit [2:0] WRITE_SIZE_C         = 3'd4;

  vip_chi_writeunique_seq #(CFG_P) hrnf1_wu_ptl_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf1_wu_ptl_seq = vip_chi_writeunique_seq #(CFG_P)::type_id::create("hrnf1_wu_ptl_seq");
  endfunction

  task run_phase(input uvm_phase phase);

    item_t::addr_t write_addr;
    item_t::data_t write_payload[$];
    item_t::be_t   write_be[$];
    item_t::data_t expected[$];
    item_t         snp_item;
    item_t         discard_item;
    item_t         wu_item;
    item_t         rd_item;
    item_t         orig_item;
    item_t         rds_rsp[$];
    item_t         wu_rsp[$];
    item_t         rd_rsp[$];
    bit            differs_from_original;

    phase.raise_objection(this);

    super.wait_reset_settle();

    if (CFG_P.DATA_BYTES_P < WRITE_BYTES_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] DATA_BYTES_P=%0d cannot cover the %0d-byte WriteUniquePtl payload",
        super.tc_name, CFG_P.DATA_BYTES_P, WRITE_BYTES_C))
    end

    write_addr = item_t::addr_t'(WRITE_READ_ADDR_C) + item_t::addr_t'(WRITE_OFFSET_BYTES_C);

    // 1) RN-F0 takes a Shared copy and captures the pre-write image.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    rds_rsp = super.hrnf0_rdshared_seq.get_responses();
    if (rds_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 initial ReadShared response, got %0d",
        super.tc_name, rds_rsp.size()))
    end

    orig_item = rds_rsp[0];
    foreach (orig_item.data[i]) begin
      expected.push_back(orig_item.data[i]);
    end

    // 2) RN-F1 performs a 16-byte WriteUniquePtl at offset 16.
    write_payload.push_back('0);
    write_be.push_back('0);
    for (int byte_idx = 0; byte_idx < WRITE_BYTES_C; byte_idx++) begin
      write_payload[0][8 * byte_idx +: 8] = 8'hA0 + byte_idx;
      write_be[0][byte_idx]              = 1'b1;
    end

    this.hrnf1_wu_ptl_seq.reset();
    this.hrnf1_wu_ptl_seq.set_partial(1'b1);
    this.hrnf1_wu_ptl_seq.set_initial_addr(write_addr);
    this.hrnf1_wu_ptl_seq.set_size(WRITE_SIZE_C);
    this.hrnf1_wu_ptl_seq.set_allow_retry(1'b0);
    this.hrnf1_wu_ptl_seq.set_data(write_payload);
    this.hrnf1_wu_ptl_seq.set_be(write_be);
    this.hrnf1_wu_ptl_seq.set_get_response(1'b1);
    this.hrnf1_wu_ptl_seq.set_verbose(1'b0);
    this.hrnf1_wu_ptl_seq.start(super.tb_env.hrnf1_agent.sequencer);
    wu_rsp = this.hrnf1_wu_ptl_seq.get_responses();

    if (wu_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 WriteUniquePtl response, got %0d",
        super.tc_name, wu_rsp.size()))
    end

    wu_item = wu_rsp[0];
    if (wu_item.opcode != item_t::req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] generated opcode 0x%0h instead of WriteUniquePtl",
        super.tc_name, wu_item.opcode))
    end
    if (wu_item.rsp_opcode != item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteUniquePtl completion opcode 0x%0h was not CompDBIDResp",
        super.tc_name, wu_item.rsp_opcode))
    end
    if (wu_item.be.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteUniquePtl carried %0d BE beats instead of 1",
        super.tc_name, wu_item.be.size()))
    end
    if (wu_item.be[0] !== write_be[0]) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteUniquePtl BE 0x%0h != expected 0x%0h",
        super.tc_name, wu_item.be[0], write_be[0]))
    end

    super.wait_clocks(8);

    // RN-F0 must have been invalidated; RN-F1 remains non-allocating/Invalid.
    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 not invalidated by WriteUniquePtl", super.tc_name))
    end
    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache not Invalid after WriteUniquePtl", super.tc_name))
    end
    if (!super.tb_env.hrnf0_snp_fifo.try_get(snp_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 never observed the invalidating WriteUniquePtl snoop",
        super.tc_name))
    end
    while (super.tb_env.hrnf0_snp_fifo.try_get(discard_item)) begin end

    // 3) Apply the byte-enabled write to the expected line image.
    for (int byte_idx = 0; byte_idx < WRITE_BYTES_C; byte_idx++) begin
      int line_byte;
      int beat_idx;
      int lane_idx;

      line_byte = WRITE_OFFSET_BYTES_C + byte_idx;
      beat_idx  = line_byte / CFG_P.DATA_BYTES_P;
      lane_idx  = line_byte % CFG_P.DATA_BYTES_P;
      expected[beat_idx][8 * lane_idx +: 8] = write_payload[0][8 * byte_idx +: 8];
    end

    // 4) Full-line readback must equal the BE-applied expected image.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    rd_rsp = super.hrnf0_rdshared_seq.get_responses();
    if (rd_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 readback response, got %0d",
        super.tc_name, rd_rsp.size()))
    end

    rd_item = rd_rsp[0];
    if (rd_item.data.size() != expected.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] readback beat count %0d != expected %0d",
        super.tc_name, rd_item.data.size(), expected.size()))
    end

    foreach (expected[i]) begin
      if (rd_item.data[i] !== expected[i]) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] readback beat %0d 0x%0h != BE-applied expected 0x%0h",
          super.tc_name, i, rd_item.data[i], expected[i]))
      end
    end

    differs_from_original = 1'b0;
    foreach (expected[i]) begin
      if (expected[i] !== orig_item.data[i]) begin
        differs_from_original = 1'b1;
      end
    end
    if (!differs_from_original) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteUniquePtl expected image equals the original image",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations on legal WriteUniquePtl",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
