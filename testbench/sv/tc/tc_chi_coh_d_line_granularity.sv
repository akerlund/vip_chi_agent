// ===========================================================================
// tc_chi_coh_d_line_granularity
//
// P1 validator: the RN-F cache, HN-F directory and coherency checker key their
// per-line state on the 64 B cache line (VIP_CHI_CACHE_LINE_BYTES_C), NOT the
// data-bus width. On the narrow CHI-D config (DATA_BYTES_P = 16) a 64 B line
// spans four beats, so an address 32 B into the line is bus-aligned yet belongs
// to the same cache line. This test brings a line into SC on one RN-F, then
// probes the model's line state at a MID-LINE offset and asserts it still
// resolves to the held line.
//
// Anti-vacuity: with the pre-P1 bus-width key (align to DATA_BYTES_P = 16) the
// mid-line probe would land on a DIFFERENT key that was never populated and the
// getters would return Invalid, firing the mid-line assertions below. It passes
// only because line_addr()/line_of() now align to the 64 B cache line.
//
// CHI-D only: under CHI-E (DATA_BYTES_P = 64) the bus width already equals the
// cache line, so line granularity and bus granularity coincide and the mid-line
// probe would be vacuous. No CHI-E variant exists, so this stays one concrete
// test class (no shared base).
// ===========================================================================
class tc_chi_coh_d_line_granularity extends chi_coherent_base_test #(CHI_D_CFG_C, chi_d_types_t);

  typedef vip_chi_item #(CHI_D_CFG_C) item_t;

  // A sub-64 B, bus-aligned offset that lands inside the same 64 B line but on a
  // distinct DATA_BYTES_P (16 B) granule, so it discriminates a 64 B line key
  // from the pre-P1 bus-width key. Kept a plain int (cast to addr_t at use): a
  // class-scoped localparam typed as a parameterized-class-nested type
  // (item_t::addr_t) hangs vcs1fe codegen.
  localparam int MID_LINE_OFFSET_C = 'h20;

  `uvm_component_utils(tc_chi_coh_d_line_granularity)

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Drive one ReadShared, then probe the model at the line base and at a
  // mid-line offset; both must report the held SC line.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t         read_responses[$];
    item_t::addr_t base_addr;
    item_t::addr_t mid_addr;
    vip_chi_resp_t rnf_state;
    vip_chi_resp_t hnf_state;

    base_addr = item_t::addr_t'(WRITE_READ_ADDR_C);
    mid_addr  = base_addr + item_t::addr_t'(MID_LINE_OFFSET_C);

    phase.raise_objection(this);

    super.wait_reset_settle();

    this.cfg_read_seq(super.hrnf0_rdshared_seq, base_addr);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);

    read_responses = super.hrnf0_rdshared_seq.get_responses();

    if (read_responses.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Expected 1 ReadShared response, got %0d",
        super.tc_name, read_responses.size()))
    end

    // Let the perf clock loop advance a few cycles past the completion.
    super.wait_clocks(8);

    // ----- Baseline: the line base resolves to the held SC line. --------------
    rnf_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(base_addr);
    if (rnf_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F cache state at line base 0x%0h is 0x%0h, expected SC (0x%0h)",
        super.tc_name, base_addr, rnf_state, VIP_CHI_RESP_STATE_SC_E))
    end

    hnf_state = super.tb_env.hnf_agent.hnf_driver.get_directory_state(base_addr);
    if (hnf_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] HN-F directory state at line base 0x%0h is 0x%0h, expected SC (0x%0h)",
        super.tc_name, base_addr, hnf_state, VIP_CHI_RESP_STATE_SC_E))
    end

    // ----- P1 discriminator: a mid-line address maps to the SAME line. --------
    // Fails under the pre-P1 bus-width key (returns Invalid on an unpopulated
    // per-beat key); passes only with 64 B line-granular keying.
    rnf_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(mid_addr);
    if (rnf_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] P1: RN-F cache state at mid-line 0x%0h is 0x%0h, expected SC (0x%0h) -- line key is not 64 B granular",
        super.tc_name, mid_addr, rnf_state, VIP_CHI_RESP_STATE_SC_E))
    end

    hnf_state = super.tb_env.hnf_agent.hnf_driver.get_directory_state(mid_addr);
    if (hnf_state != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] P1: HN-F directory state at mid-line 0x%0h is 0x%0h, expected SC (0x%0h) -- line key is not 64 B granular",
        super.tc_name, mid_addr, hnf_state, VIP_CHI_RESP_STATE_SC_E))
    end

    phase.drop_objection(this);
  endtask
endclass
