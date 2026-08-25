// ===========================================================================
// chi_coh_transition_sweep_base_test
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
// A SECOND sweep primes the REQUESTING node and issues on the SAME line, which
// is the axis this test did not have. Priming only the snoopee leaves the
// requester Invalid for every combination, and a Requester that holds nothing
// cannot tell "final state = the granted Resp" apart from "final state = what the
// grant adds to what was held" -- the two agree on every from-Invalid row of
// Table 4-14. That is what let the held-state half of the table go missing with
// a fully green regression and a closed transition covergroup behind it
//. The rows that separate the two are the ones where the grant is
// WEAKER than what the Requester already had: a UD holder issuing ReadClean is
// granted CompData_SC and must stay UD.
//
// Used by:
//   tc_chi_coh_d_transition_sweep    (CHI-D)
//   tc_chi_coh_e_transition_sweep  (wide CHI-E)
// ===========================================================================
class chi_coh_transition_sweep_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_transition_sweep_base_test #(CFG_P, TYPES_T))

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
  // Only the UD priming leaves a Dirty holder, and two of the seven opcodes
  // (MakeInvalid, MakeUnique) make the Home send SnpMakeInvalid, so the sweep
  // provokes the no-data-snoop rule exactly twice.
  localparam int MIN_NO_DATA_SNOOPS_ON_DIRTY_C = 2;
  // The sweep drives 3 initial states x 7 opcodes and every snoop it provokes is
  // answered, so D5 has plenty to judge. Ten is a floor well under that, chosen
  // so the assertion catches the rule going dark rather than tracking an exact
  // count that stimulus changes would keep breaking.
  localparam int MIN_SNP_RESP_JUDGED_C = 10;
  // The requester-priming sweep: 3 primed states {SC, UC, UD} x 4 requests
  // {ReadShared, ReadClean, ReadUnique, MakeUnique}.
  localparam int N_REQ_STATES_C = 3;
  localparam int N_REQ_OPS_C    = 4;
  // Of those 12, the held state changes the answer in exactly 5 -- the rows where
  // the grant is weaker than what was held. Enumerated rather than approximated,
  // because this count IS the evidence that the rule was exercised:
  //   UC + ReadShared -> UC (granted SC)    UD + ReadShared -> UD (granted SC)
  //   UC + ReadClean  -> UC (granted SC)    UD + ReadClean  -> UD (granted SC)
  //                                         UD + ReadUnique -> UD (granted UC)
  // The from-SC row retains nothing (SC is the weakest state that holds
  // anything), and MakeUnique reaches UD from its opcode rather than from the
  // held state, so it is correctly not counted -- see resolve_req_final_state.
  localparam int MIN_REQ_FINAL_RETAINED_C = 5;

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

    // -------------------------------------------------------------------------
    // Requester axis. Same shape, but the node that is primed is the node that
    // then issues, and it issues on the line it already holds -- so the
    // completion arrives at a Requester in a known non-Invalid state and Table
    // 4-14 has to combine the two. The sweep above can never produce this: it
    // issues from RN-F1 on lines only RN-F0 ever touched.
    // -------------------------------------------------------------------------
    for (int st = 0; st < N_REQ_STATES_C; st++) begin
      for (int op = 0; op < N_REQ_OPS_C; op++) begin
        line = base_addr + item_t::addr_t'(idx * LINE_STRIDE_C);
        idx++;

        // Prime RN-F1 -- the requester this time -- exactly as above: UD comes
        // from MakeUnique so the state is observable rather than silently local.
        case (st)
          0: this.run_op(1, line, 0);   // ReadShared -> SC
          1: this.run_op(1, line, 2);   // ReadUnique -> UC
          default: this.run_op(1, line, 6);   // MakeUnique -> UD (observable)
        endcase

        // ...and now issue again, on the SAME line, from the SAME node.
        case (op)
          0: this.run_op(1, line, 0);   // ReadShared
          1: this.run_op(1, line, 1);   // ReadClean
          2: this.run_op(1, line, 2);   // ReadUnique
          default: this.run_op(1, line, 6);   // MakeUnique
        endcase
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

    // Two of the seven opcodes make the Home send SnpMakeInvalid to a UD holder
    // (MakeInvalid and MakeUnique), so this sweep is where a snoopee answering a
    // no-data snoop on DAT shows up. Asserted here and not only in the checker
    // because the to-state of that transition is correct either way -- which is
    // exactly why cg_cache_transition recorded the tuple as covered while the
    // response beside it was wrong.
    if (super.tb_env.coh_checker.get_bad_snp_resp_form_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d snoop responses carried data for a snoop that returns none",
        super.tc_name, super.tb_env.coh_checker.get_bad_snp_resp_form_count()))
    end

    // ...and that the rule had something to judge. A zero above means nothing on
    // its own: a clean holder answers on RSP whatever the opcode says, so only a
    // no-data snoop reaching a Dirty holder can distinguish the fixed behaviour
    // from the broken one. Without this the check goes silently vacuous the day
    // the Home stops sending SnpMakeInvalid here.
    if (super.tb_env.coh_checker.get_snp_no_data_on_dirty_count() <
        MIN_NO_DATA_SNOOPS_ON_DIRTY_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] only %0d no-data snoop(s) reached a dirty holder (< %0d) -- the response-form rule was never provoked",
        super.tc_name, super.tb_env.coh_checker.get_snp_no_data_on_dirty_count(),
        MIN_NO_DATA_SNOOPS_ON_DIRTY_C))
    end

    // Catalogue rule D5: the response STATE against the snoop opcode. Both
    // halves again -- no violation, and evidence the rule had responses to
    // judge. This sweep is where D5 gets its stimulus: every snoop opcode the
    // home originates, against a primed cache state.
    if (super.tb_env.coh_checker.get_bad_snp_resp_state_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d snoop response(s) reported a state Chapter 4 does not permit for the snoop that asked",
        super.tc_name, super.tb_env.coh_checker.get_bad_snp_resp_state_count()))
    end

    if (super.tb_env.coh_checker.get_snp_resp_judged_count() <
        MIN_SNP_RESP_JUDGED_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] D5 judged only %0d snoop response(s) (< %0d); a zero violation count above means nothing if nothing reached the rule",
        super.tc_name, super.tb_env.coh_checker.get_snp_resp_judged_count(),
        MIN_SNP_RESP_JUDGED_C))
    end

    // Catalogue rule D6, and the adoption it guards. The snooped node's next
    // state is now taken FROM the response rather than derived from the opcode,
    // so three things have to hold together.
    //
    // No response reported a state the snoopee could not have reached:
    if (super.tb_env.coh_checker.get_snp_resp_gains_permission_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d snoop response(s) reported a permission the snoopee did not hold when the snoop arrived",
        super.tc_name, super.tb_env.coh_checker.get_snp_resp_gains_permission_count()))
    end

    // ...every judged response was adopted. With D5 and D6 both clean this is an
    // identity, and that is exactly why it is worth asserting: if it ever parts,
    // a response was judged legal and still failed to reach the shadow, which is
    // the desynchronization this rule exists to prevent -- silent, and visible
    // only as later checks failing somewhere else.
    if (super.tb_env.coh_checker.get_snp_resp_adopted_count() !=
        super.tb_env.coh_checker.get_snp_resp_judged_count()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d snoop response(s) judged but only %0d adopted into the shadow, with no violation reported for the difference",
        super.tc_name, super.tb_env.coh_checker.get_snp_resp_judged_count(),
        super.tb_env.coh_checker.get_snp_resp_adopted_count()))
    end

    // ...and the adoption path actually ran. Same non-vacuity discipline as the
    // two counts above: adopted=0 would satisfy both assertions.
    if (super.tb_env.coh_checker.get_snp_resp_adopted_count() < MIN_SNP_RESP_JUDGED_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] only %0d snoop response(s) reached the shadow (< %0d); the adoption path was never exercised",
        super.tc_name, super.tb_env.coh_checker.get_snp_resp_adopted_count(),
        MIN_SNP_RESP_JUDGED_C))
    end

    // Reported, not asserted. This VIP's own RN-F implements exactly the mapping
    // snoop_result() encodes, so the expected value here is 0 -- and a 0 is only
    // meaningful because the counts above prove responses were adopted at all.
    // It is the first number to read against a DUT: non-zero says the peer
    // resolved a snoop somewhere the derived model did not predict, which is the
    // whole reason the state is taken from the response.
    `uvm_info(get_name(), $sformatf(
      "[%s] snoop responses adopted=%0d, of which %0d differed from the derived prediction",
      super.tc_name, super.tb_env.coh_checker.get_snp_resp_adopted_count(),
      super.tb_env.coh_checker.get_snp_resp_state_differs_count()), UVM_LOW)

    // Under a coverage build the legality cross should have spread across the
    // surface, not merely fired. Gated on coverage actually being collected, the
    // same way the cache-transition closure check above is.
    if ((super.tb_env.coh_checker.get_snp_resp_legality_coverage() > 0.0) &&
        (super.tb_env.coh_checker.get_snp_resp_legality_coverage() < 20.0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the snoop-response legality cross closed only %0.1f%% under a coverage build -- the sweep drives every snoop opcode the home originates, so it should reach far more of the surface",
        super.tc_name, super.tb_env.coh_checker.get_snp_resp_legality_coverage()))
    end

    // -------------------------------------------------------------------------
    // The requester axis. Same three-part discipline as D5/D6
    // above: the rule ran, it ran on the inputs that distinguish it, and nothing
    // it judged was illegal.
    //
    // req_final_retained is the load-bearing count. It rises only where the
    // Requester's held state changed the answer -- which is nothing at all unless
    // the stimulus primes the requesting node, and priming the requesting node is
    // exactly what no test in either port did before. A regression can be green
    // end to end with this at 0 and the whole held-state half of Table 4-14
    // missing, which is how the defect survived.
    // -------------------------------------------------------------------------
    if (super.tb_env.coh_checker.get_req_final_judged_count() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the requester final-state rule judged nothing -- no coherent read completed",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_req_final_retained_count() <
        MIN_REQ_FINAL_RETAINED_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] only %0d completion(s) had their final state decided by the held state (< %0d); the requester was Invalid throughout, so Table 4-14's held-state half was never exercised",
        super.tc_name, super.tb_env.coh_checker.get_req_final_retained_count(),
        MIN_REQ_FINAL_RETAINED_C))
    end

    // A data-less completion must carry a Resp encoding its request's table
    // permits. MakeUnique is the case the sweep drives: Table 4-19 (D Table 4-13)
    // gives it Comp_UC, and issue D does not define UD_PD for a data-less
    // completion at all.
    if (super.tb_env.coh_checker.get_bad_dataless_resp_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d data-less completion(s) carried a Resp encoding the request's table does not permit",
        super.tc_name, super.tb_env.coh_checker.get_bad_dataless_resp_count()))
    end

    `uvm_info(get_name(), $sformatf(
      "[%s] requester final state: judged=%0d, of which %0d were decided by the state the requester already held",
      super.tc_name, super.tb_env.coh_checker.get_req_final_judged_count(),
      super.tb_env.coh_checker.get_req_final_retained_count()), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
