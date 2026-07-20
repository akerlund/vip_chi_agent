// ===========================================================================
// vip_chi_coh_cache_evict_base_test
//
// Bounded RN-F cache with SILENT eviction. RN-F0's cache is bounded to 2 lines
// (cfg.rnf_cache_max_lines). RN-F0 then ReadShares THREE distinct clean lines.
// Allocating the third forces the RN-F to silently evict a clean victim -- the
// lowest-address held line -- with no bus transaction (spec-legal silent
// eviction of a clean line; the home keeps a stale directory entry it would
// resolve on a later snoop).
//
// Asserts: after the third read the evicted (lowest-address) line reads Invalid
// while the two most-recent lines are held Shared, and Checker D stays silent
// (a silent clean drop never violates the single-writer invariant). Non-vacuous:
// with an unbounded cache (rnf_cache_max_lines = 0) all three lines stay Shared,
// so the "line A is Invalid" assertion fails without the eviction.
//
// Writeback-on-eviction of a DIRTY victim is out of scope (needs autonomous REQ
// origination) -- see docs/FUTURE_WORK.md; this scenario only holds clean lines.
//
// Used by:
//   tc_chi_coh_d_cache_evict    (CHI-D)
//   tc_chi_coh_e_cache_evict  (wide CHI-E)
// ===========================================================================
class vip_chi_coh_cache_evict_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_cache_evict_base_test #(CFG_P, TYPES_T))

  localparam int MAX_LINES_C   = 2;
  localparam int LINE_STRIDE_C = 'h40;   // 64 B coherence granule

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Bound RN-F0's cache so a third allocation forces a silent eviction.
  protected virtual function void configure_agent_cfgs();
    super.hrnf0_cfg.rnf_cache_max_lines = MAX_LINES_C;
  endfunction

  protected task read_shared_line(input item_t::addr_t line);
    this.cfg_read_seq(super.hrnf0_rdshared_seq, line);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdshared_seq.get_responses());
  endtask

  task run_phase(input uvm_phase phase);

    item_t::addr_t line_a;
    item_t::addr_t line_b;
    item_t::addr_t line_c;

    phase.raise_objection(this);

    super.wait_reset_settle();

    line_a = item_t::addr_t'(WRITE_READ_ADDR_C);
    line_b = line_a + item_t::addr_t'(LINE_STRIDE_C);
    line_c = line_a + item_t::addr_t'(2 * LINE_STRIDE_C);

    // Fill the 2-line cache, then allocate a third -> evict the lowest-address
    // clean line (A).
    this.read_shared_line(line_a);
    this.read_shared_line(line_b);
    this.read_shared_line(line_c);

    super.wait_clocks(8);

    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(line_a) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] line A (0x%0h) was not silently evicted from the bounded RN-F cache (state 0x%0h)",
        super.tc_name, line_a, super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(line_a)))
    end
    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(line_b) != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] line B (0x%0h) not held Shared after eviction (state 0x%0h)",
        super.tc_name, line_b, super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(line_b)))
    end
    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(line_c) != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] line C (0x%0h) not held Shared after eviction (state 0x%0h)",
        super.tc_name, line_c, super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(line_c)))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations on a bounded-cache silent eviction",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
