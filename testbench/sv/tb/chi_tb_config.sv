class chi_tb_config extends uvm_object;

  // Enable the wide CHI-E datapath link (set by chi_e_base_test).
  bit run_e_wide_integrated;
  // One-shot, test-requested mid-run reset pulse length in cycles.
  int reset_pulse_cycles;
  // Standalone scoreboard gating (a test may disable it in configure_tb_cfg()).
  bit scoreboard_enable;
  bit scoreboard_check_data;
  bit scoreboard_check_order;
  // Standalone perf-counter gating (always-on instrumentation, opt-out per test).
  bit perf_enable;
  // Stand the SVA DataID-ordering checks down: set by a test whose completer
  // deliberately returns DAT beats out of DataID order. Those checks hold this
  // VIP's own in-order emission convention, not a CHI rule -- CHI places a beat
  // by its DataID -- so a reordering test must clear them and nothing else.
  bit dat_reorder_allowed;
  // Cycles a sender may keep TXSACTIVE asserted past the close of its
  // outstanding window. 0 (the default) is the tightest legal behaviour: drop
  // it as soon as the window closes. Raising it models a node that keeps the
  // sideband up speculatively, and widens the bound the checkers allow.
  int txsactive_extend_max_cycles;
  // Stand the SVA link-activation transition ERROR down while still counting it:
  // set by the negative-control test that deliberately aborts a bring-up. An SVA
  // $error cannot be demoted by a report catcher the way a UVM report can, so a
  // test that must PROVE the rule fired needs the report suppressed and the
  // count left intact -- otherwise proving the check works means printing an
  // error that looks exactly like a real one.
  bit lasm_illegal_expected;

  `uvm_object_utils_begin(chi_tb_config)
    `uvm_field_int(run_e_wide_integrated, UVM_DEFAULT)
    `uvm_field_int(reset_pulse_cycles, UVM_DEFAULT)
    `uvm_field_int(scoreboard_enable, UVM_DEFAULT)
    `uvm_field_int(scoreboard_check_data, UVM_DEFAULT)
    `uvm_field_int(scoreboard_check_order, UVM_DEFAULT)
    `uvm_field_int(perf_enable, UVM_DEFAULT)
    `uvm_field_int(dat_reorder_allowed, UVM_DEFAULT)
    `uvm_field_int(txsactive_extend_max_cycles, UVM_DEFAULT)
    `uvm_field_int(lasm_illegal_expected, UVM_DEFAULT)
  `uvm_object_utils_end

  function new(input string name = "chi_tb_config");
    super.new(name);
    this.reset();
  endfunction

  function void reset();
    this.run_e_wide_integrated  = 1'b0;
    this.reset_pulse_cycles     = 0;
    this.scoreboard_enable      = 1'b1;
    this.scoreboard_check_data  = 1'b1;
    this.scoreboard_check_order = 1'b1;
    this.perf_enable            = 1'b1;
    this.dat_reorder_allowed    = 1'b0;
    this.txsactive_extend_max_cycles = 0;
    this.lasm_illegal_expected  = 1'b0;
  endfunction

  function void request_reset_pulse(input int cycles = 3);
    if (cycles < 1) begin
      cycles = 1;
    end
    this.reset_pulse_cycles = cycles;
  endfunction

endclass
