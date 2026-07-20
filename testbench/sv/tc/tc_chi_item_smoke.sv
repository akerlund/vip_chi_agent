class tc_chi_item_smoke extends uvm_test;

  `uvm_component_utils(tc_chi_item_smoke)

  string tc_name;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

    tc_name = name;
    void'($value$plusargs("UVM_TESTNAME=%s", tc_name));
  endfunction

  // ---------------------------------------------------------------------------
  // Verify issue-aware item randomization and legality helpers.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    vip_chi_item #(CHI_D_WIDE_CFG_C) chi_d_item;
    vip_chi_item #(CHI_D_WIDE_CFG_C) chi_d_copy;
    vip_chi_item #(CHI_E_WIDE_CFG_C) chi_e_item;
    string                           item_summary;

    phase.raise_objection(this);

    chi_d_item = new("chi_d_item");
    chi_e_item = new("chi_e_item");

    chi_d_item.set_config(CHI_D_WIDE_CFG_C);
    chi_d_item.set_size(3'd6);
    chi_d_item.set_data_type(VIP_CHI_DATA_COUNTER_E);
    chi_d_item.set_counter_value(vip_chi_item #(CHI_D_WIDE_CFG_C)::data_t'('h10));

    if (!chi_d_item.randomize() with {
      direction == VIP_CHI_DIR_WRITE_E;
      role      == VIP_CHI_ROLE_RNI_E;
      opcode    == VIP_CHI_REQ_WRITE_NO_SNP_FULL_C;
    }) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D full-write item failed to randomize",
        tc_name))
    end

    if (chi_d_item.data.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D full-write item expected one payload beat, got %0d",
        tc_name, chi_d_item.data.size()))
    end

    if (chi_d_item.be.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D full-write item expected one BE beat, got %0d",
        tc_name, chi_d_item.be.size()))
    end

    chi_d_copy = new("chi_d_copy");
    chi_d_copy.copy(chi_d_item);
    if (!chi_d_copy.compare(chi_d_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D item copy/compare did not preserve the payload-bearing item state",
        tc_name))
    end

    if ((chi_d_copy.data.size() != chi_d_item.data.size()) ||
        (chi_d_copy.be.size() != chi_d_item.be.size()) ||
        (chi_d_copy.data[0] != chi_d_item.data[0]) ||
        (chi_d_copy.be[0] != chi_d_item.be[0])) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D item copy() did not preserve dynamic payload arrays",
        tc_name))
    end

    item_summary = chi_d_copy.convert2string();
    if (item_summary.len() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D item convert2string() returned an empty summary",
        tc_name))
    end

    chi_d_copy.data[0] ^= vip_chi_item #(CHI_D_WIDE_CFG_C)::data_t'(1);
    if (chi_d_copy.compare(chi_d_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D item compare() failed to detect a payload mutation",
        tc_name))
    end

    if (chi_d_item.exp_comp_ack) begin
      if (chi_d_item.dat_opcode != vip_chi_item #(CHI_D_WIDE_CFG_C)::dat_opcode_t'(VIP_CHI_DAT_NCB_WR_DATA_COMP_ACK_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-D full-write item chose wrong CompAck DAT opcode",
          tc_name))
      end
    end
    else begin
      if (chi_d_item.dat_opcode != vip_chi_item #(CHI_D_WIDE_CFG_C)::dat_opcode_t'(VIP_CHI_DAT_NON_COPY_BACK_WR_DATA_C)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CHI-D full-write item chose wrong DAT opcode",
          tc_name))
      end
    end

    if (!chi_d_item.randomize() with {
      direction == VIP_CHI_DIR_READ_E;
      role      == VIP_CHI_ROLE_RNI_E;
    }) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D read item failed to randomize",
        tc_name))
    end

    if (!chi_d_item.req_opcode_is_legal(chi_d_item.opcode, chi_d_item.direction)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D read item randomized an illegal opcode",
        tc_name))
    end

    if (chi_d_item.req_opcode_is_legal(
          vip_chi_item #(CHI_D_WIDE_CFG_C)::req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C),
          VIP_CHI_DIR_READ_E)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D legality helper accepted CHI-E ReadNoSnpSep opcode",
        tc_name))
    end

    chi_d_item.min_addr = vip_chi_item #(CHI_D_WIDE_CFG_C)::addr_t'('h1000);
    chi_d_item.max_addr = vip_chi_item #(CHI_D_WIDE_CFG_C)::addr_t'('h1003);
    chi_d_item.set_size(3'd2);
    chi_d_item.set_enforce_addr_alignment(1'b1);
    if (!chi_d_item.randomize() with {
      direction == VIP_CHI_DIR_READ_E;
      role      == VIP_CHI_ROLE_RNI_E;
      opcode    == VIP_CHI_REQ_READ_NO_SNP_C;
    }) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D item failed to randomize while alignment was enforced",
        tc_name))
    end

    if ((chi_d_item.addr & vip_chi_item #(CHI_D_WIDE_CFG_C)::addr_t'('h3)) != '0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D item produced an unaligned address while alignment was enforced",
        tc_name))
    end

    chi_d_item.min_addr = vip_chi_item #(CHI_D_WIDE_CFG_C)::addr_t'('h1003);
    chi_d_item.max_addr = vip_chi_item #(CHI_D_WIDE_CFG_C)::addr_t'('h1003);
    chi_d_item.set_enforce_addr_alignment(1'b0);
    if (!chi_d_item.randomize() with {
      direction == VIP_CHI_DIR_READ_E;
      role      == VIP_CHI_ROLE_RNI_E;
      opcode    == VIP_CHI_REQ_READ_NO_SNP_C;
    }) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D item failed to randomize a fixed unaligned address after alignment was disabled",
        tc_name))
    end

    if (chi_d_item.addr != vip_chi_item #(CHI_D_WIDE_CFG_C)::addr_t'('h1003)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-D item did not preserve the explicit unaligned address",
        tc_name))
    end

    chi_e_item.set_config(CHI_E_WIDE_CFG_C);
    chi_e_item.set_size(3'd6);
    if (!chi_e_item.randomize() with {
      direction == VIP_CHI_DIR_READ_E;
      role      == VIP_CHI_ROLE_RNI_E;
      opcode    == VIP_CHI_REQ_READ_NO_SNP_SEP_C;
    }) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-E separated-read item failed to randomize",
        tc_name))
    end

    if (chi_e_item.return_nid != chi_e_item.src_id) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-E separated-read item did not constrain return_nid to src_id",
        tc_name))
    end

    if (!chi_e_item.req_opcode_is_legal(
          vip_chi_item #(CHI_E_WIDE_CFG_C)::req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_SEP_C),
          VIP_CHI_DIR_READ_E)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-E legality helper rejected ReadNoSnpSep opcode",
        tc_name))
    end

    if (chi_e_item.req_opcode_is_legal(
          vip_chi_item #(CHI_E_WIDE_CFG_C)::req_opcode_t'(VIP_CHI_REQ_MAKE_READ_UNIQUE_C),
          VIP_CHI_DIR_READ_E)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-E legality helper accepted deferred MakeReadUnique opcode",
        tc_name))
    end

    if (chi_e_item.data.size() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-E separated-read request should not pre-populate DAT payload",
        tc_name))
    end

    if (!chi_e_item.randomize() with {
      direction == VIP_CHI_DIR_WRITE_E;
      role      == VIP_CHI_ROLE_RNI_E;
      opcode    == VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C;
    }) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-E WriteNoSnpZero item failed to randomize",
        tc_name))
    end

    if (chi_e_item.data.size() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI-E WriteNoSnpZero should not carry request DAT payload",
        tc_name))
    end

    phase.drop_objection(this);
  endtask
endclass