// Negative control for the monitor's DataID placement checks. With
// cfg.snf_duplicate_dat_beat the SN-F sends the final beat of a read burst
// carrying DataID 0 again instead of its own position, so one position is
// delivered twice and the last position never at all. Both checks must fire:
// reassembly by arrival order cannot see either fault, because the beat count
// still adds up and every slot still gets written.

class tc_chi_dataid_duplicate extends chi_base_test;

  `uvm_component_utils(tc_chi_dataid_duplicate)

  localparam int BEATS_C = 4;   // size 6 = 64 bytes over a 16-byte CHI-D bus

  chi_dataid_negctl_catcher dataid_catcher;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // The malformed burst is not a data-integrity failure to report twice: the
  // DataID checks own this scenario, so keep the scoreboard's payload check out
  // of the verdict. Everything else about the transfer stays checked.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_tb_cfg();

    super.configure_tb_cfg();
    super.tb_cfg.scoreboard_check_data = 1'b0;

    // Same reasoning for the SVA DataID-ordering checks: the repeated position
    // makes the burst 0,1,2,0, which those checks correctly call non-sequential.
    // They hold this VIP's in-order emission convention and own a different
    // question from the one under test here, and being plain $error they cannot
    // be demoted by a report catcher -- so stand them down and let the monitor's
    // duplicate / missing-beat checks be what judges this burst.
    super.tb_cfg.dat_reorder_allowed = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Arm the malformed burst on the completer.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    super.snf_cfg.snf_duplicate_dat_beat = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Create the report catcher once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.dataid_catcher = new("dataid_negctl_catcher");
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one multi-beat read and require both DataID checks to have fired.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t dat_item;

    phase.raise_objection(this);

    uvm_report_cb::add(null, this.dataid_catcher);

    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(READ_ADDR_C);
    super.rni0_rd_seq.set_size(3'd6);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.tb_env.rni_dat_fifo.get(dat_item);

    super.wait_clocks(8);

    uvm_report_cb::delete(null, this.dataid_catcher);

    if (dat_item.data.size() != BEATS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor reassembled %0d beats, expected %0d",
        super.tc_name, dat_item.data.size(), BEATS_C))
    end

    if (!this.dataid_catcher.saw_duplicate_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor did NOT flag the repeated DataID - the duplicate check may be vacuous",
        super.tc_name))
    end

    if (!this.dataid_catcher.saw_missing_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Monitor did NOT flag the position no beat carried - the missing-beat check may be vacuous",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Monitor flagged both the duplicated and the missing DataID (negative control passed)",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
