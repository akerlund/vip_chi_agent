class tc_chi_cfg_item_smoke extends uvm_test;

  `uvm_component_utils(tc_chi_cfg_item_smoke)

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
  // Verify cfg-item defaults and reset behavior inside the shared test harness.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    vip_chi_cfg_item cfg_item;

    phase.raise_objection(this);

    cfg_item = new("cfg_item");

    if (cfg_item.direction != VIP_CHI_DIR_READ_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item default direction mismatch",
        tc_name))
    end

    if (cfg_item.data_type != VIP_CHI_DATA_RANDOM_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item default data_type mismatch",
        tc_name))
    end

    if (cfg_item.min_size != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item default min_size mismatch",
        tc_name))
    end

    if (cfg_item.max_size != 6) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item default max_size mismatch",
        tc_name))
    end

    if (cfg_item.get_response != 1'b0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item default get_response mismatch",
        tc_name))
    end

    if (cfg_item.atomic_oversized_operands != 1'b0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item default atomic_oversized_operands mismatch",
        tc_name))
    end

    cfg_item.direction          = VIP_CHI_DIR_WRITE_E;
    cfg_item.data_type          = VIP_CHI_DATA_COUNTER_E;
    cfg_item.min_size           = 2;
    cfg_item.max_size           = 4;
    cfg_item.atomic_oversized_operands = 1'b1;
    cfg_item.get_response       = 1'b1;
    cfg_item.reset();

    if (cfg_item.direction != VIP_CHI_DIR_WRITE_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item reset() did not preserve direction",
        tc_name))
    end

    if (cfg_item.data_type != VIP_CHI_DATA_RANDOM_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item reset() did not restore data_type",
        tc_name))
    end

    if (cfg_item.min_size != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item reset() did not restore min_size",
        tc_name))
    end

    if (cfg_item.max_size != 6) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item reset() did not restore max_size",
        tc_name))
    end

    if (cfg_item.get_response != 1'b0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item reset() did not restore get_response",
        tc_name))
    end

    if (cfg_item.atomic_oversized_operands != 1'b0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] vip_chi_cfg_item reset() did not restore atomic_oversized_operands",
        tc_name))
    end

    phase.drop_objection(this);
  endtask
endclass
