class vip_chi_tb_config extends uvm_object;

  // Enable the wide CHI-E datapath link (set by vip_chi_e_base_test).
  bit run_e_wide_integrated;
  // One-shot, test-requested mid-run reset pulse length in cycles.
  int reset_pulse_cycles;
  // Standalone scoreboard gating (a test may disable it in configure_tb_cfg()).
  bit scoreboard_enable;
  bit scoreboard_check_data;
  // Standalone perf-counter gating (always-on instrumentation, opt-out per test).
  bit perf_enable;

  `uvm_object_utils_begin(vip_chi_tb_config)
    `uvm_field_int(run_e_wide_integrated, UVM_DEFAULT)
    `uvm_field_int(reset_pulse_cycles, UVM_DEFAULT)
    `uvm_field_int(scoreboard_enable, UVM_DEFAULT)
    `uvm_field_int(scoreboard_check_data, UVM_DEFAULT)
    `uvm_field_int(perf_enable, UVM_DEFAULT)
  `uvm_object_utils_end

  function new(input string name = "vip_chi_tb_config");
    super.new(name);
    this.reset();
  endfunction

  function void reset();
    this.run_e_wide_integrated  = 1'b0;
    this.reset_pulse_cycles     = 0;
    this.scoreboard_enable      = 1'b1;
    this.scoreboard_check_data  = 1'b1;
    this.perf_enable            = 1'b1;
  endfunction

  function void request_reset_pulse(input int cycles = 3);
    if (cycles < 1) begin
      cycles = 1;
    end
    this.reset_pulse_cycles = cycles;
  endfunction

endclass
