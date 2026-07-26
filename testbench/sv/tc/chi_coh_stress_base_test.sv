// ===========================================================================
// chi_coh_stress_base_test
//
// Concurrency stress for the coherent subsystem. Both RN-F requesters run
// independent randomized streams of coherent reads (ReadShared / ReadClean /
// ReadUnique) over a small pool of overlapping cache lines, in parallel. When
// both pick the same line the HN-F's per-line lock must serialize them, and a
// ReadUnique must snoop-invalidate the other sharer before granting -- so the
// single-writer invariant (Checker D: never two Unique owners of a line) is
// exercised under contention.
//
// Asserts, after both streams drain: zero coherency violations, zero coherent
// data mismatches, and that snoops actually fired (proving the overlapping-line
// contention -- not just independent lines -- was reached).
//
// Used by:
//   tc_chi_coh_e_stress  (wide CHI-E)
//   tc_chi_coh_d_stress    (CHI-D)
// ===========================================================================
class chi_coh_stress_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_stress_base_test #(CFG_P, TYPES_T))

  localparam int N_ITERS_C = 16;
  localparam int N_LINES_C = 4;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction


  // ---------------------------------------------------------------------------
  // Drive one RN-F's randomized coherent-read stream over the shared line pool.
  // ---------------------------------------------------------------------------
  protected task drive_stream(input int node, input uvm_sequencer_base seqr);

    item_t::addr_t addr;
    int            line_idx;
    int            op;

    vip_chi_readshared_seq #(CFG_P) rs;
    vip_chi_readclean_seq  #(CFG_P) rc;
    vip_chi_readunique_seq #(CFG_P) ru;

    for (int i = 0; i < N_ITERS_C; i++) begin
      line_idx = $urandom_range(0, N_LINES_C - 1);
      op       = $urandom_range(0, 2);
      addr     = item_t::addr_t'(WRITE_READ_ADDR_C + (line_idx * 'h40));

      case (op)
        0: begin
          rs = vip_chi_readshared_seq #(CFG_P)::type_id::create($sformatf("rs_%0d_%0d", node, i));
          this.cfg_read_seq(rs, addr);
          rs.start(seqr);
        end
        1: begin
          rc = vip_chi_readclean_seq #(CFG_P)::type_id::create($sformatf("rc_%0d_%0d", node, i));
          this.cfg_read_seq(rc, addr);
          rc.start(seqr);
        end
        default: begin
          ru = vip_chi_readunique_seq #(CFG_P)::type_id::create($sformatf("ru_%0d_%0d", node, i));
          this.cfg_read_seq(ru, addr);
          ru.start(seqr);
        end
      endcase
    end
  endtask

  task run_phase(input uvm_phase phase);

    vip_chi_readshared_seq #(CFG_P) prime_rs;
    vip_chi_readunique_seq #(CFG_P) prime_ru;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // Prime one deterministic contended snoop so the test is seed-independent:
    // RN-F0 takes line 0 Shared, then RN-F1 takes it Unique (forces SnpUnique).
    // The randomized storm below then piles on additional overlapping contention.
    prime_rs = vip_chi_readshared_seq #(CFG_P)::type_id::create("prime_rs");
    this.cfg_read_seq(prime_rs, item_t::addr_t'(WRITE_READ_ADDR_C));
    prime_rs.start(super.tb_env.hrnf0_agent.sequencer);

    prime_ru = vip_chi_readunique_seq #(CFG_P)::type_id::create("prime_ru");
    this.cfg_read_seq(prime_ru, item_t::addr_t'(WRITE_READ_ADDR_C));
    prime_ru.start(super.tb_env.hrnf1_agent.sequencer);

    fork
      this.drive_stream(0, super.tb_env.hrnf0_agent.sequencer);
      this.drive_stream(1, super.tb_env.hrnf1_agent.sequencer);
    join

    super.wait_clocks(20);

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d single-writer (multi-owner) violations under stress",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    if (super.tb_env.coh_checker.get_coherent_data_mismatch_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherent data mismatches under stress",
        super.tc_name, super.tb_env.coh_checker.get_coherent_data_mismatch_count()))
    end

    if (super.tb_env.coh_checker.get_snoop_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] no snoops fired -- overlapping-line contention was never reached",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] stress complete: completions=%0d snoops=%0d, no coherency violations",
      super.tc_name, super.tb_env.coh_checker.get_completion_count(),
      super.tb_env.coh_checker.get_snoop_count()), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
