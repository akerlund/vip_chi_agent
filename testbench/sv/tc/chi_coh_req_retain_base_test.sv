// ===========================================================================
// chi_coh_req_retain_base_test
//
// The Requester's final cache state is a function of what it HELD as well as
// what the completion GRANTED -- IHI 0050 E Table 4-14 (D Table 4-12). This is
// the directed positive test for the row that separates that rule from taking
// the granted Resp verbatim: a Unique-Dirty holder issuing ReadClean receives
// CompData_SC and must stay UD.
//
//   RN-F1 MakeUnique L        -> UD, beats materialized as zeros
//   make_line_dirty(L, PAT)   -> held beats = PAT (a local store, silent)
//   RN-F1 ReadClean L         -> HN-F grants CompData_SC
//                                -> state must stay UD, NOT drop to SC
//                                -> held beats must stay PAT, NOT be overwritten
//                                   by the fetched copy
//   RN-F0 ReadShared L        -> HN-F SnpShared(RN-F1)
//                                -> RN-F1, still dirty, forwards PAT
//
// The last step is what makes the data half observable. A local store leaves no
// trace on the wire, so the only way to ask "did the dirtied bytes survive the
// ReadClean" is to make someone else read the line and see which copy comes
// back. Table 4-14 footnote c is the normative half: "Data received from memory
// must be dropped if the cache state is UD or SD."
//
// Both halves fail independently, and both were wrong before this test existed:
// the state limb catches "final = granted Resp", the data limb catches the
// unconditional overwrite of the cached beats beside it. Getting the state right
// and the data wrong is the worse of the two, because every later
// data-integrity check then agrees with the loss.
//
// The line is acquired with MakeUnique rather than ReadUnique + make_line_dirty
// so the CHECKER's shadow holds Dirty too. A local store is silent to the
// checker as well as to the home, so ReadUnique priming would leave the shadow
// at UC and catalogue rule D7 would have nothing to judge at the snoop -- the
// assertion below would then pass without the rule having run. MakeUnique is the
// one path in this VIP that grants an OBSERVABLE Unique-Dirty. It also makes
// this test and its negative control differ in exactly one thing, the knob.
//
// Used by:
//   tc_chi_coh_d_req_retain    (CHI-D)
//   tc_chi_coh_e_req_retain  (wide CHI-E)
// ===========================================================================
class chi_coh_req_retain_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_req_retain_base_test #(CFG_P, TYPES_T))

  vip_chi_readclean_seq  #(CFG_P) hrnf1_rdclean_seq;
  vip_chi_makeunique_seq #(CFG_P) hrnf1_mu_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf1_rdclean_seq = vip_chi_readclean_seq #(CFG_P)::type_id::create("hrnf1_rdclean_seq");
    this.hrnf1_mu_seq      = vip_chi_makeunique_seq #(CFG_P)::type_id::create("hrnf1_mu_seq");
  endfunction

  task run_phase(input uvm_phase phase);

    item_t         mu_rsp[$];
    item_t         clean_rsp[$];
    item_t         shared_rsp[$];
    vip_chi_resp_t rnf1_state;
    vip_chi_resp_t dir_state;
    int            retained_before;
    item_t::data_t dirty_pattern;

    phase.raise_objection(this);

    super.wait_reset_settle();

    dirty_pattern = {($bits(dirty_pattern) / 8){8'h5A}};

    // 1) RN-F1 acquires the line Unique-Dirty, observably: MakeUnique transfers
    //    no data, so the driver materializes an all-zero image of the line.
    this.cfg_read_seq(this.hrnf1_mu_seq);
    this.hrnf1_mu_seq.start(super.tb_env.hrnf1_agent.sequencer);
    mu_rsp = this.hrnf1_mu_seq.get_responses();

    // 2) Model a local store on top of it. Nothing on the wire says so -- which
    //    is exactly why the checker must not try to derive the data, and why the
    //    read-back in step 4 is the only way to test it. Zeros XOR the pattern
    //    is the pattern, so the expected beats below are known exactly.
    super.tb_env.hrnf1_agent.rnf_driver.make_line_dirty(
      item_t::addr_t'(WRITE_READ_ADDR_C), dirty_pattern);

    retained_before = super.tb_env.coh_checker.get_req_final_retained_count();

    // 3) The row under test: the SAME node reads the SAME line it already holds
    //    Unique-Dirty, with a request whose grant is weaker than what it holds.
    this.cfg_read_seq(this.hrnf1_rdclean_seq);
    this.hrnf1_rdclean_seq.start(super.tb_env.hrnf1_agent.sequencer);
    clean_rsp = this.hrnf1_rdclean_seq.get_responses();

    if ((mu_rsp.size() != 1) || (clean_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, mu_rsp.size(), clean_rsp.size()))
    end

    // The grant really is the weaker one -- without this the test could pass by
    // the home happening to return UC, and the retention rule would never have
    // been asked anything.
    if (clean_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadClean granted 0x%0h, expected SC (0x%0h) -- the scenario needs a grant weaker than the held state",
        super.tc_name, clean_rsp[0].rsp_resp, VIP_CHI_RESP_STATE_SC_E))
    end

    super.wait_clocks(8);

    // 4a) The state limb. Table 4-14: UD + CompData_SC -> UD.
    rnf1_state = super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(
                   item_t::addr_t'(WRITE_READ_ADDR_C));
    if (rnf1_state != VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1 cache 0x%0h after ReadClean from Unique-Dirty, expected UD (0x%0h): the granted SC was taken verbatim and a writeback obligation was dropped",
        super.tc_name, rnf1_state, VIP_CHI_RESP_STATE_UP_PD_DIRTY_E))
    end

    // ...and the home did not DOWNGRADE its snoop filter on the back of its own
    // response. Table 4-14 footnote b: "a Home that uses a Snoop filter ... must
    // not downgrade the state of the cache line in the Snoop filter based on the
    // state in the response to the Requester." Here the home CAN track the dirty
    // -- MakeUnique granted it observably in step 1 -- so the entry must still
    // read UD after the home itself answered CompData_SC. A filter that wrote the
    // grant verbatim would believe the only modified copy in the system is clean
    // and could serve the next reader from memory without asking for it.
    dir_state = super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(
                  item_t::addr_t'(WRITE_READ_ADDR_C), 1);
    if (dir_state != VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] HN-F directory port1 0x%0h after granting SC to a Unique-Dirty holder, expected the retained UD (0x%0h)",
        super.tc_name, dir_state, VIP_CHI_RESP_STATE_UP_PD_DIRTY_E))
    end

    // ...and the checker judged this completion as one the held state decided.
    if (super.tb_env.coh_checker.get_req_final_retained_count() <= retained_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the coherency checker did not record the ReadClean as held-state-decided (count stayed at %0d) -- its shadow took the granted Resp verbatim",
        super.tc_name, retained_before))
    end

    // 4b) The data limb. RN-F0 reads the line, so the home must snoop RN-F1 --
    //     which is still dirty and must forward its MODIFIED beats. If the
    //     ReadClean had overwritten them with the fetched copy, what comes back
    //     here is the undirtied line and nothing else would ever have noticed.
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    shared_rsp = super.hrnf0_rdshared_seq.get_responses();

    if (shared_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1 ReadShared response, got %0d",
        super.tc_name, shared_rsp.size()))
    end

    // MakeUnique materialized zeros, so the dirtied line is exactly the pattern.
    foreach (shared_rsp[0].data[i]) begin
      if (shared_rsp[0].data[i] !== dirty_pattern) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d read back 0x%0h, expected the dirtied 0x%0h: the ReadClean overwrote the locally-modified beats with the fetched copy",
          super.tc_name, i, shared_rsp[0].data[i], dirty_pattern))
      end
    end

    // The forwarding snoop above is a Dirty snoopee answering a data-returning
    // snoop, which is catalogue rule D7's provoking case, and the shadow really
    // does hold Dirty here (step 1 made it observable) -- so the rule evaluated
    // rather than being skipped. Its negative control drives the same snoop with
    // the verbatim knob set and requires this count to RISE.
    if (super.tb_env.coh_checker.get_snp_dirty_lost_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d snoop response(s) dropped a dirty copy instead of passing it on",
        super.tc_name, super.tb_env.coh_checker.get_snp_dirty_lost_count()))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Checker D flagged %0d multi-owner violations on a legal retention",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
