// ===========================================================================
// chi_coh_evict_allocate_negctl_base_test
//
// Negative control for CHI_REQ_ALLOCATE_LEGAL, and the proof that the rule is
// not redundant with the two that already read MemAttr.
//
// IHI 0050 E section 2.9.3 / D section 2.9.3 puts Evict on the Allocate field's
// inapplicable-and-must-be-zero list, and Table A-3's Allocate column gives it a
// literal zero. Nothing else in the checker can see it: Table 2-12's Snoopable
// rows leave Allocate free, so an Evict carrying it is a legal tuple with an
// inapplicable field set.
//
// That is what this control turns into evidence. The Evict is issued with
// MemAttr = {Allocate 1, Cacheable 1, Device 0, EWA 1}, which is Table 2-12
// row-legal against the SnpAttr = 1 the opcode requires -- so
// CHI_REQ_ATTR_COMBINATION_LEGAL and CHI_REQ_SNP_ATTR_LEGAL must both stay
// SILENT while this rule reports. Asserting their silence is the whole point: it
// is what separates a rule with its own content from an id that can only fail
// behind another.
//
// The Evict is still required to COMPLETE, and the directory still required to
// clear. A control that leaves the transaction broken has proved the stimulus
// rather than the rule.
//
// Used by:
//   tc_chi_coh_e_evict_allocate_negctl  (wide CHI-E)
//   tc_chi_coh_d_evict_allocate_negctl  (CHI-D)
// ===========================================================================
class chi_coh_evict_allocate_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_evict_allocate_negctl_base_test #(CFG_P, TYPES_T))

  // {Allocate, Cacheable, Device, EWA} in Table 13-21 bit order. Allocate is the
  // inapplicable bit; the other three carry the values the opcode requires, so
  // the tuple this drives is one Table 2-12 lists.
  localparam logic [3:0] MEM_ATTR_C = 4'b1101;

  vip_chi_evict_seq #(CFG_P) hrnf1_ev_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf1_ev_seq = vip_chi_evict_seq #(CFG_P)::type_id::create("hrnf1_ev_seq");
  endfunction

  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t       ev_rsp[$];
    int unsigned reported;
    int unsigned tuple_fails;
    int unsigned snp_attr_fails;

    phase.raise_objection(this);

    // Suppress the report, keep the count, at both ends of the link the Evict
    // crosses: the requester drives the flit and the home receives it, and a
    // field-applicability rule has to hold at both vantages.
    super.tb_env.hrnf1_agent.vif.check_severity[VIP_CHI_CHK_REQ_ALLOCATE_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.hnf_agent.rn_vif[1].check_severity[VIP_CHI_CHK_REQ_ALLOCATE_LEGAL_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    super.wait_reset_settle();

    // RN-F1 has to hold the line before it can evict it.
    this.cfg_read_seq(super.hrnf1_rdshared_seq);
    super.hrnf1_rdshared_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdshared_seq.get_responses());

    this.cfg_read_seq(this.hrnf1_ev_seq);
    this.hrnf1_ev_seq.set_mem_attr(MEM_ATTR_C);
    this.hrnf1_ev_seq.start(super.tb_env.hrnf1_agent.sequencer);
    ev_rsp = this.hrnf1_ev_seq.get_responses();

    super.wait_clocks(8);

    if (ev_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the Evict never completed (got %0d response(s)), so the control proved the stimulus and not the rule",
        super.tc_name, ev_rsp.size()))
    end

    reported =
      super.tb_env.hrnf1_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ALLOCATE_LEGAL_E];
    if (reported == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CHI_REQ_ALLOCATE_LEGAL did not report an Evict carrying Allocate at the requester vantage",
        super.tc_name))
    end

    if (super.tb_env.hnf_agent.rn_vif[1].check_fail_count[VIP_CHI_CHK_REQ_ALLOCATE_LEGAL_E] == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home received the same flit and did not report it, so the rule is wired at one vantage only",
        super.tc_name))
    end

    // The non-redundancy claim, asserted rather than argued.
    tuple_fails =
      super.tb_env.hrnf1_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_ATTR_COMBINATION_LEGAL_E];
    snp_attr_fails =
      super.tb_env.hrnf1_agent.vif.check_fail_count[VIP_CHI_CHK_REQ_SNP_ATTR_LEGAL_E];
    if ((tuple_fails != 0) || (snp_attr_fails != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the tuple rule reported %0d and the SnpAttr rule %0d: this MemAttr is Table 2-12 legal for a Snoopable request, and if either of those fires the new rule has not been shown to have content of its own",
        super.tc_name, tuple_fails, snp_attr_fails))
    end

    if (super.tb_env.hnf_agent.hnf_driver.get_directory_port_state(
          item_t::addr_t'(WRITE_READ_ADDR_C), 1) != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the home's directory port1 is not Invalid after the Evict",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "Test (%s) PASS: CHI_REQ_ALLOCATE_LEGAL reported an Evict carrying Allocate %0d time(s) at the requester and at the home, the tuple and SnpAttr rules stayed silent, and the Evict completed",
      super.tc_name, reported), UVM_LOW)

    phase.drop_objection(this);

  endtask
endclass
