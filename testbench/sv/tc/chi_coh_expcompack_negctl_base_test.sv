// ===========================================================================
// chi_coh_expcompack_negctl_base_test
//
// Negative control for CHI_EXPCOMPACK_REQUIRED_BUT_ZERO.
//
// IHI 0050 E Table 2-9 / D Table 2-8 mark six RN-F request types "Yes" in the
// CompAck column, and section 2.8.3 states it without a table: "An RN-F must
// include a CompAck response in all Read transactions except ReadNoSnp and
// ReadOnce*." A ReadShared with ExpCompAck = 0 is therefore a non-conformant
// request -- and it is the request this VIP issued, on every coherent read, for
// the whole life of the model, because the item's legality constraint forced the
// bit to zero on every read direction.
//
// The converse has been checked since the first cut: COMPACK_WITHOUT_EXPCOMPACK
// catches a CompAck for a request that never asked for one. Nobody wrote the
// other direction, and the reason is instructive -- the constraint made it
// unreachable, so a rule against it would have been dead code in every run.
//
// cfg.rn_drop_required_exp_comp_ack clears the bit on the ITEM, not just on the
// outgoing flit. That keeps the requester self-consistent: it sends a zero and
// then does not send a CompAck, so exactly one rule can fire. Clearing only the
// flit field would leave the driver acking a request the wire says wanted no
// ack, which trips COMPACK_WITHOUT_EXPCOMPACK as well -- and a control that
// breaks two rules at once cannot show which of them is being exercised.
//
// Only the requester vantage is asserted, and that is a fact about this
// testbench rather than about the rule. The coherent link carries the main bind
// at the RN-F ends only -- the home's ports carry the SNP bind alone -- so there
// is no completer-side counter here to read. The rule is written from both
// vantages anyway, for the reason CHI_RSP_FIELD_ZERO is: against a real DUT the
// bind may sit at only one end of the link, and which end is not this rule's
// choice.
//
// Used by:
//   tc_chi_coh_d_expcompack_negctl  (CHI-D)
//   tc_chi_coh_e_expcompack_negctl  (wide CHI-E)
// ===========================================================================
class chi_coh_expcompack_negctl_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_expcompack_negctl_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C = 20;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  protected virtual function void configure_agent_cfgs();
    super.hrnf0_cfg.rn_drop_required_exp_comp_ack = 1'b1;
  endfunction

  task run_phase(input uvm_phase phase);

    int unsigned rnf_fails;

    phase.raise_objection(this);

    // Suppress the report, keep the count -- at BOTH ends of the link. The
    // deliberate ExpCompAck = 0 travels from the RN-F to the HN-F, so it is
    // judged twice under one ID: once where it is sent and once where it
    // arrives. Standing it down only at the sender left the receiving vantage
    // reporting a violation this test asked for, the moment gave the
    // HN-F endpoint a main-range bind.
    super.tb_env.hrnf0_agent.vif.check_severity[VIP_CHI_CHK_EXPCOMPACK_REQUIRED_BUT_ZERO_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    foreach (super.tb_env.hnf_agent.rn_vif[i]) begin
      super.tb_env.hnf_agent.rn_vif[i].check_severity[VIP_CHI_CHK_EXPCOMPACK_REQUIRED_BUT_ZERO_E] =
        VIP_CHI_CHK_SEV_OFF_E;
    end

    super.wait_reset_settle();

    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdshared_seq.get_responses());

    super.wait_clocks(SETTLE_C);

    rnf_fails =
      super.tb_env.hrnf0_agent.vif.check_fail_count[VIP_CHI_CHK_EXPCOMPACK_REQUIRED_BUT_ZERO_E];

    if (rnf_fails == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s did not report a ReadShared issued with ExpCompAck = 0 -- Table 2-9 marks it required",
        super.tc_name,
        vip_chi_check_name(VIP_CHI_CHK_EXPCOMPACK_REQUIRED_BUT_ZERO_E)))
    end

    // The requester stayed consistent with the zero it sent, so the CompAck
    // rules must be silent. This is what separates "the bit was wrong" from "the
    // whole handshake fell apart", and it is the half that keeps this control
    // pointed at one rule.
    if (super.tb_env.hrnf0_agent.vif.check_fail_count[VIP_CHI_CHK_COMPACK_WITHOUT_EXPCOMPACK_E] != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s also reported: the requester acked a request whose wire bit it had cleared, so this control is exercising two rules at once",
        super.tc_name,
        vip_chi_check_name(VIP_CHI_CHK_COMPACK_WITHOUT_EXPCOMPACK_E)))
    end

    if (super.tb_env.coh_checker.get_comp_ack_window_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a CompAck window opened for a request that carried no ExpCompAck; rule D9 is arming off something other than the wire bit",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %s reported %0d time(s) at the requester, and no CompAck rule fired alongside it",
      super.tc_name,
      vip_chi_check_name(VIP_CHI_CHK_EXPCOMPACK_REQUIRED_BUT_ZERO_E),
      rnf_fails), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
