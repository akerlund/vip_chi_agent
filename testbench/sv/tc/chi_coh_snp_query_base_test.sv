// ===========================================================================
// chi_coh_snp_query_base_test
//
// SnpQuery (SNP 0x10, CHI-E only): the home asks a Requester what it holds
// instead of reading the answer out of its own snoop filter.
//
// IHI 0050 E 4.5: "Home can send a SnpQuery snoop without any corresponding
// request from a Requester", "The Snoop response must include the precise state
// of the cache line at the targeted Snoopee", "Snoopee must not return data with
// the Snoop response", and "The SnpQuery snoop must not change the state of the
// cache line at the Snoopee". Table 4-26 repeats the last of those row by row --
// all seven initial states have themselves as the expected final state, with no
// permitted alternative.
//
// The stimulus is chosen so the answer is one the encoding cannot say. RN-F0
// ReadUniques the line (the home records UC) and then dirties it locally, which
// is a silent transition the home never sees: the port holds UD and the filter
// holds UC. RN-F1 then reads, and the home queries RN-F0 first.
//
// Table 4-9 gives UC and UD ONE Resp encoding, because "Pass Dirty must only be
// asserted for a Snoop response with data" and Resp[2] is that bit. So the
// correct answer to this query is 0b010 from a port holding UD, the home's
// expectation from UC is the same 0b010, and the two agree -- a query cannot
// detect a silent clean-to-dirty transition, and must not claim to. A responder
// that reported its raw UD_PD instead would put a Pass Dirty bit on a data-less
// SnpResp and be flagged as a mismatch it did not commit.
//
// Asserted here, therefore, are three things at once: the query was sent and
// answered, the answer left RN-F0's state untouched (rule D10 judged it and
// found nothing), and the reconciliation agreed with the filter.
//
// Used by:
//   tc_chi_coh_e_snp_query  (wide CHI-E)
// ===========================================================================
class chi_coh_snp_query_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_E_WIDE_CFG_C,
  type          TYPES_T = chi_e_wide_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_snp_query_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C = 16;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected virtual function void configure_agent_cfgs();
    super.hnf_cfg.hnf_snp_query_enable = 1'b1;
  endfunction

  task run_phase(input uvm_phase phase);

    item_t         unique_rsp[$];
    item_t         shared_rsp[$];
    item_t::data_t dirty_pattern;
    int            judged;

    phase.raise_objection(this);

    super.wait_reset_settle();

    dirty_pattern = {($bits(dirty_pattern) / 8){8'h5A}};

    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    unique_rsp = super.hrnf0_rdunique_seq.get_responses();

    super.tb_env.hrnf0_agent.rnf_driver.make_line_dirty(
      item_t::addr_t'(WRITE_READ_ADDR_C), dirty_pattern);

    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    shared_rsp = super.hrnf1_rdshared_seq.get_responses();

    super.wait_clocks(SETTLE_C);

    if ((unique_rsp.size() != 1) || (shared_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1 responses, got %0d/%0d",
        super.tc_name, unique_rsp.size(), shared_rsp.size()))
    end

    if (super.tb_env.hnf_agent.hnf_driver.n_snp_query_sent == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home sent no SnpQuery, so nothing below judged anything",
        super.tc_name))
    end

    if (super.tb_env.hnf_agent.hnf_driver.n_snp_query_dir_mismatch != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home reported %0d SnpQuery/directory mismatch(es); a silent UC->UD transition is invisible to Table 4-9's encoding and must not be reported as one",
        super.tc_name,
        super.tb_env.hnf_agent.hnf_driver.n_snp_query_dir_mismatch))
    end

    judged = super.tb_env.coh_checker.get_snp_preserving_judged_count();
    if (judged == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] catalogue rule D10 judged no response, so the run says nothing about whether a query is allowed to move a line",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_bad_snp_state_preserved_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] D10 flagged %0d conformant SnpQuery response(s)",
        super.tc_name,
        super.tb_env.coh_checker.get_bad_snp_state_preserved_count()))
    end

    // The dirty copy survived the query. This is the property the opcode exists
    // for and the one a state-changing responder would break silently: a line
    // dropped here is dropped before the SnpShared that follows, so the dirty
    // data would never reach RN-F1 and the read would return stale memory.
    if (unique_rsp[0].data.size() != shared_rsp[0].data.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] beat-count mismatch: unique %0d vs shared %0d",
        super.tc_name, unique_rsp[0].data.size(), shared_rsp[0].data.size()))
    end

    foreach (shared_rsp[0].data[i]) begin
      if (shared_rsp[0].data[i] !== (unique_rsp[0].data[i] ^ dirty_pattern)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d carried 0x%0h, expected dirtied 0x%0h",
          super.tc_name, i, shared_rsp[0].data[i],
          (unique_rsp[0].data[i] ^ dirty_pattern)))
      end
    end

    if (shared_rsp[0].rsp_resp != VIP_CHI_RESP_STATE_SC_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadShared granted 0x%0h, expected SC (0x%0h)",
        super.tc_name, shared_rsp[0].rsp_resp, VIP_CHI_RESP_STATE_SC_E))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d SnpQuery sent, D10 judged %0d response(s) and found nothing",
      super.tc_name, super.tb_env.hnf_agent.hnf_driver.n_snp_query_sent, judged),
      UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
