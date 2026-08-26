// ===========================================================================
// chi_coh_combined_write_cmo_base_test
//
// The COHERENT half of the combined Write + CMO family: one request carrying a
// write to a Home and a cache-maintenance operation on the same address, applied
// in that order.
//
// The WriteNoSnp half of this family reaches a memory node and was built first.
// These reach the HN-F, so the write half runs on the coherent completer path --
// service_writeback for the CopyBacks, service_write_unique for the rest -- and
// the CMO acts on the state that write leaves behind.
//
// What is asserted, per form:
//
//   * the second completion arrives. CompCMO is what says the CMO half happened;
//     without it a completer that ignored the CMO entirely would produce a run
//     indistinguishable from a correct one, because the write completes exactly
//     as an ordinary write does. The requester's combined_completion_log is read
//     rather than the wire, because the log is what the requester ACCEPTED -- a
//     response left in the stream would be a wrong-opcode error on the next
//     transaction rather than a missing entry here.
//   * a persistent form draws a Persist after it, and a non-persistent one draws
//     none. Both directions, so the check cannot pass by always expecting one.
//   * the requester's cache state ends where the WRITE half puts it, which is
//     the thing that distinguishes the three write classes: a CopyBack ends
//     Invalid, a WriteClean keeps a clean copy, a WriteUnique is non-allocating.
//   * no coherency violation, and -- for CleanInvalid -- the other holder really
//     lost its copy, which is the one CMO of the three with work left to do
//     after the write half has run.
//
// Used by:
//   tc_chi_coh_e_combined_write_cmo   (wide CHI-E)
//
// CHI-E only: every combined form sits in the Opcode[6] = 1 half of Table 13-14
// and does not fit CHI-D's 6-bit REQ opcode field, so there is no CHI-D twin.
// ===========================================================================
class chi_coh_combined_write_cmo_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_E_WIDE_CFG_C,
  type          TYPES_T = chi_e_wide_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_combined_write_cmo_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C = 12;

  vip_chi_write_cmo_seq #(CFG_P) cmo_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);
    this.cmo_seq = vip_chi_write_cmo_seq #(CFG_P)::type_id::create("hrnf0_cmo_seq");
  endfunction

  // -------------------------------------------------------------------------
  // One combined write from RN-F0. The requester's accepted-completion log is
  // cleared first so what comes back belongs to this request alone.
  // -------------------------------------------------------------------------
  protected task combined_write(input vip_chi_combined_write_e write_class,
                                input vip_chi_combined_cmo_e   cmo,
                                input bit                      partial = 1'b0);
    super.tb_env.hrnf0_agent.rnf_driver.combined_completion_log.delete();

    this.cfg_read_seq(this.cmo_seq);
    this.cmo_seq.set_write_class(write_class);
    this.cmo_seq.set_cmo(cmo);
    this.cmo_seq.set_partial(partial);
    this.cmo_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(this.cmo_seq.get_responses());

    super.wait_clocks(SETTLE_C);
  endtask

  // RN-F0 takes the line Unique-Dirty, so a CopyBack has something to write.
  protected task own_the_line();
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());
    super.wait_clocks(4);
  endtask

  // -------------------------------------------------------------------------
  // The two obligations, read off what the requester accepted.
  // -------------------------------------------------------------------------
  protected function void check_completions(input vip_chi_combined_cmo_e cmo,
                                           input string                 what);
    bit saw_cmo;
    bit saw_persist;
    int n;

    saw_cmo     = 1'b0;
    saw_persist = 1'b0;
    n = super.tb_env.hrnf0_agent.rnf_driver.combined_completion_log.size();
    for (int i = 0; i < n; i++) begin
      if (super.tb_env.hrnf0_agent.rnf_driver.combined_completion_log[i] ==
          item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_CMO_C)) begin
        saw_cmo = 1'b1;
      end
      if (super.tb_env.hrnf0_agent.rnf_driver.combined_completion_log[i] ==
          item_t::rsp_opcode_t'(VIP_CHI_RSP_PERSIST_C)) begin
        saw_persist = 1'b1;
      end
    end

    if (!saw_cmo) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s: no CompCMO among the %0d completion(s) the requester accepted. Section 2.8 owes one, and without it a completer that ignored the CMO half looks correct from here",
        super.tc_name, what, n))
    end
    if ((cmo == VIP_CHI_CMO_CLEAN_SH_PER_SEP_E) && !saw_persist) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s: a persistent CMO drew no Persist among %0d completion(s)",
        super.tc_name, what, n))
    end
    if ((cmo != VIP_CHI_CMO_CLEAN_SH_PER_SEP_E) && saw_persist) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s: a non-persistent CMO drew a Persist; the two must be distinguishable",
        super.tc_name, what))
    end
  endfunction

  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    super.wait_reset_settle();

    // --- CopyBack + CleanShared: the requester gives the line up -------------
    this.own_the_line();
    this.combined_write(VIP_CHI_CWRITE_BACK_FULL_E, VIP_CHI_CMO_CLEAN_SH_E);
    this.check_completions(VIP_CHI_CMO_CLEAN_SH_E, "WriteBackFullCleanSh");
    if (super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(
          item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 still holds the line after a WriteBackFull + CMO",
        super.tc_name))
    end

    // --- CopyBack + CleanSharedPersistSep: the Persist half ------------------
    this.own_the_line();
    this.combined_write(VIP_CHI_CWRITE_BACK_FULL_E, VIP_CHI_CMO_CLEAN_SH_PER_SEP_E);
    this.check_completions(VIP_CHI_CMO_CLEAN_SH_PER_SEP_E,
                           "WriteBackFullCleanShPerSep");

    // --- CopyBack + CleanInvalid: the one CMO with work left to do -----------
    // RN-F1 takes a shared copy first, so the CleanInvalid half has a holder to
    // invalidate. Without it the phase would pass against a home that skipped
    // the CMO entirely.
    this.own_the_line();
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());
    super.wait_clocks(4);
    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(
          item_t::addr_t'(WRITE_READ_ADDR_C)) == VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 holds nothing before the CleanInvalid phase, so it proves nothing",
        super.tc_name))
    end

    this.combined_write(VIP_CHI_CWRITE_BACK_FULL_E, VIP_CHI_CMO_CLEAN_INV_E);
    this.check_completions(VIP_CHI_CMO_CLEAN_INV_E, "WriteBackFullCleanInv");
    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(
          item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 kept its copy through a combined CleanInvalid: the CMO half did not run, and the write half alone would leave it exactly here",
        super.tc_name))
    end

    // --- WriteClean + CleanShared: the requester KEEPS a clean copy ----------
    this.own_the_line();
    this.combined_write(VIP_CHI_CWRITE_CLEAN_FULL_E, VIP_CHI_CMO_CLEAN_SH_E);
    this.check_completions(VIP_CHI_CMO_CLEAN_SH_E, "WriteCleanFullCleanSh");

    // --- WriteUnique, full and partial --------------------------------------
    this.combined_write(VIP_CHI_CWRITE_UNIQUE_E, VIP_CHI_CMO_CLEAN_SH_E);
    this.check_completions(VIP_CHI_CMO_CLEAN_SH_E, "WriteUniqueFullCleanSh");

    this.combined_write(VIP_CHI_CWRITE_UNIQUE_E, VIP_CHI_CMO_CLEAN_SH_PER_SEP_E,
                        1'b1);
    this.check_completions(VIP_CHI_CMO_CLEAN_SH_PER_SEP_E,
                           "WriteUniquePtlCleanShPerSep");

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] combined Write + CMO produced %0d multi-owner violation(s)",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end
    if (super.tb_env.coh_checker.get_coherent_data_mismatch_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] combined Write + CMO produced %0d data mismatch(es)",
        super.tc_name, super.tb_env.coh_checker.get_coherent_data_mismatch_count()))
    end

    `uvm_info(get_name(), $sformatf(
      "PASS [%s] six coherent combined forms, each answered with CompCMO",
      super.tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
