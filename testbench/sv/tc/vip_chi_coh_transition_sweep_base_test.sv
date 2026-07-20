// ===========================================================================
// vip_chi_coh_transition_sweep_base_test
//
// Directed sweep that closes the coherency checker's cg_cache_transition
// covergroup (from-state x snoop-opcode -> to-state) -- the 11 reachable tuples
// (see the covergroup): {UC,UD}xSnpShared->SC and {SC,UC,UD}x{SnpUnique,
// SnpCleanInvalid,SnpMakeInvalid}->I. The individual scenario tests each hit only
// a few; this sweep drives every combination of a snoopee from-state {SC,UC,UD}
// against every snoop-originating requester opcode {ReadShared, ReadClean,
// ReadUnique, ReadOnce, CleanInvalid, MakeInvalid, MakeUnique}, each on a FRESH
// line so the combinations do not interfere.
//
// For each combination: RN-F0 is primed into the target from-state (a coherent
// read, plus make_line_dirty() for UD), then RN-F1 issues the opcode -- which
// makes the home snoop RN-F0 in that state, sampling one transition. Deterministic
// (no $urandom), so the sampled set is stable across seeds. The test self-checks
// the observed snoop count and the single-writer invariant always; under a
// coverage build it additionally asserts cg_cache_transition is (near) fully
// closed (get_coverage() reads 0 without a coverage build, so that check is gated
// on coverage actually being collected).
//
// Used by:
//   tc_chi_coh_d_transition_sweep    (CHI-D)
//   tc_chi_coh_e_transition_sweep  (wide CHI-E)
// ===========================================================================
class vip_chi_coh_transition_sweep_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_transition_sweep_base_test #(CFG_P, TYPES_T))

  localparam int LINE_STRIDE_C = 'h40;    // 64 B coherence granule
  localparam int N_STATES_C    = 3;       // SC, UC, UD
  localparam int N_OPS_C       = 7;
  // The sweep drives one snoop-originating op per primed from-state; every
  // combination that requires a downgrade/invalidate fires a snoop into RN-F0,
  // which samples one cg_cache_transition tuple. A conservative floor on the
  // observed snoop count guards that the stimulus actually ran (the covergroup's
  // get_coverage() only populates under a coverage build, so it is reported for
  // information but not asserted here -- bin closure is confirmed offline by a
  // coverage-enabled FuseSoC/VCS build + URG).
  localparam int MIN_SNOOPS_C  = 10;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // Run one fresh coherent op of `kind` on `node`'s sequencer at `line`.
  //   0=ReadShared 1=ReadClean 2=ReadUnique 3=ReadOnce
  //   4=CleanInvalid 5=MakeInvalid 6=MakeUnique
  protected task run_op(input int node, input item_t::addr_t line, input int kind);
    vip_chi_coherent_base_seq #(CFG_P) seq;

    case (kind)
      0: seq = vip_chi_readshared_seq   #(CFG_P)::type_id::create("sw_rs");
      1: seq = vip_chi_readclean_seq    #(CFG_P)::type_id::create("sw_rc");
      2: seq = vip_chi_readunique_seq   #(CFG_P)::type_id::create("sw_ru");
      3: seq = vip_chi_readonce_seq     #(CFG_P)::type_id::create("sw_ro");
      4: seq = vip_chi_cleaninvalid_seq #(CFG_P)::type_id::create("sw_ci");
      5: seq = vip_chi_makeinvalid_seq  #(CFG_P)::type_id::create("sw_mi");
      6: seq = vip_chi_makeunique_seq   #(CFG_P)::type_id::create("sw_mu");
      default: seq = vip_chi_readshared_seq #(CFG_P)::type_id::create("sw_rs");
    endcase

    this.cfg_read_seq(seq, line);
    if (node == 0) begin
      seq.start(super.tb_env.hrnf0_agent.sequencer);
    end
    else begin
      seq.start(super.tb_env.hrnf1_agent.sequencer);
    end
    void'(seq.get_responses());
  endtask

  task run_phase(input uvm_phase phase);

    item_t::addr_t base_addr;
    item_t::addr_t line;
    int            idx;
    int            snoops;
    real           cov;

    phase.raise_objection(this);

    super.wait_reset_settle();

    base_addr = item_t::addr_t'(WRITE_READ_ADDR_C);
    idx       = 0;

    for (int st = 0; st < N_STATES_C; st++) begin
      for (int op = 0; op < N_OPS_C; op++) begin
        line = base_addr + item_t::addr_t'(idx * LINE_STRIDE_C);
        idx++;

        // Prime RN-F0 into the target from-state on this fresh line. UD is primed
        // with MakeUnique (not ReadUnique + make_line_dirty): a local dirtying is
        // SILENT, so the coherency checker's ownership shadow -- which is what the
        // covergroup samples as the from-state -- would still read UC. MakeUnique
        // grants an observable Unique-Dirty (the checker resolves it on the RSP-only
        // Comp, F1), so the snoop that follows samples a real UD from-state.
        case (st)
          0: this.run_op(0, line, 0);   // ReadShared -> SC
          1: this.run_op(0, line, 2);   // ReadUnique -> UC
          default: this.run_op(0, line, 6);   // MakeUnique -> UD (observable)
        endcase

        // RN-F1 issues the opcode; the home snoops RN-F0 in the primed state.
        this.run_op(1, line, op);
      end
    end

    super.wait_clocks(16);

    snoops = super.tb_env.coh_checker.get_snoop_count();
    cov    = super.tb_env.coh_checker.get_cache_transition_coverage();
    `uvm_info(get_name(), $sformatf(
      "[%s] transition sweep: %0d directed combinations, %0d snoops observed; cg_cache_transition = %0.1f%% (non-zero only under a coverage build)",
      super.tc_name, idx, snoops, cov), UVM_LOW)

    if (snoops < MIN_SNOOPS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] transition sweep drove only %0d snoops (< %0d) -- the transition stimulus did not run",
        super.tc_name, snoops, MIN_SNOOPS_C))
    end

    // Under a coverage build the aligned covergroup should be (near) fully closed
    // by this sweep -- it hits all 11 reachable transitions. get_coverage() is 0
    // in a normal build, so gate the closure check on coverage actually being
    // collected (cov > 0).
    if ((cov > 0.0) && (cov < 99.0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] transition sweep left cg_cache_transition at %0.1f%% under a coverage build (expected near 100%% of the reachable transitions)",
        super.tc_name, cov))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations during the transition sweep",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
