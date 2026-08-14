// ===========================================================================
// chi_coh_line_hazard_base_test
//
// Same-cache-line hazard rule, both halves in one test.
//
// Positive half: two coherent reads to the SAME line, issued back to back but
// each allowed to complete before the next is sent. This is the ordinary,
// entirely legal pattern the rule must not object to, and it is what proves the
// rule is discriminating rather than simply allergic to repeated addresses.
//
// Negative half: two overlapping same-line requests, published straight into the
// checker's REQ observation port.
//
// That is deliberate, and it is worth being explicit about why it is not driven
// on the wire like the other coherency negative controls. This VIP's own RN-F
// cannot commit this violation: its coherent issue path is serial, and its
// multi-outstanding pipeline refuses coherent opcodes outright ("mixed pipeline
// supports ReadNoSnp / WriteNoSnp / atomics / persist only"). So there is no
// requester configuration that produces an overlapping coherent pair, and the
// alternative would be adding a driver knob whose only purpose is to make this
// VIP violate a rule it is otherwise structurally incapable of violating.
//
// The checker is a pure observer of the link, so handing it the two observations
// exercises exactly the code path that a real DUT overlapping two requests would
// exercise. What the negative control proves is that the RULE fires -- which is
// the thing that could rot -- rather than that this VIP can be made to misbehave.
//
// Used by:
//   tc_chi_coh_d_line_hazard  (CHI-D)
//   tc_chi_coh_e_line_hazard  (wide CHI-E)
// ===========================================================================
class chi_coh_line_hazard_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_line_hazard_base_test #(CFG_P, TYPES_T))

  localparam longint HAZARD_ADDR_C = WRITE_READ_ADDR_C + 'h200;

  chi_coherency_negctl_catcher hazard_catcher;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Create the report catcher once topology is ready.
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.hazard_catcher = new("line_hazard_catcher");
  endfunction

  // ---------------------------------------------------------------------------
  // Build the REQ observation a monitor would publish for a coherent read.
  // ---------------------------------------------------------------------------
  protected function item_t observed_req(input longint addr, input longint txn_id);

    item_t item;

    item          = item_t::type_id::create("hazard_req");
    item.role     = VIP_CHI_ROLE_RNF_E;
    item.is_snoop = 1'b0;
    item.opcode   = item_t::req_opcode_t'(VIP_CHI_REQ_READ_SHARED_E);
    item.addr     = item_t::addr_t'(addr);
    item.txn_id   = item_t::txn_id_t'(txn_id);
    item.excl     = 1'b0;
    return item;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    vip_chi_readshared_seq #(CFG_P) rs;
    int serial_clears;
    int hazards_after_overlap;
    int hazards_after_reissue;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // -- Positive half: same line twice, but strictly one at a time. ----------
    for (int i = 0; i < 2; i++) begin
      rs = vip_chi_readshared_seq #(CFG_P)::type_id::create($sformatf("serial_rs_%0d", i));
      this.cfg_read_seq(rs, item_t::addr_t'(HAZARD_ADDR_C));
      rs.start(super.tb_env.hrnf0_agent.sequencer);
    end

    super.wait_clocks(20);

    if (super.tb_env.coh_checker.get_line_hazard_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d hazard(s) reported for two NON-overlapping reads to one line - the rule is firing on address reuse rather than on overlap",
        super.tc_name, super.tb_env.coh_checker.get_line_hazard_count()))
    end

    serial_clears = super.tb_env.coh_checker.get_line_clear_count();
    if (serial_clears < 2) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] only %0d line claim(s) were opened and closed for two reads - the hazard shadow did not see this traffic",
        super.tc_name, serial_clears))
    end

    // -- Negative half: two overlapping same-line requests (see header). ------
    uvm_report_cb::add(null, this.hazard_catcher);

    // Distinct TxnIDs, one line, neither completed in between. Same TxnID would
    // be a retry re-issue, which the rule correctly does NOT flag -- the check
    // below covers that.
    super.tb_env.coh_checker.rnf0_req_cc.write(this.observed_req(HAZARD_ADDR_C, 'h51));
    super.tb_env.coh_checker.rnf0_req_cc.write(this.observed_req(HAZARD_ADDR_C, 'h52));
    hazards_after_overlap = super.tb_env.coh_checker.get_line_hazard_count();

    // A RetryAck'd request re-issued on the same TxnID must not be mistaken for
    // a second request: obeying the retry protocol is not a hazard.
    super.tb_env.coh_checker.rnf0_req_cc.write(this.observed_req(HAZARD_ADDR_C + 'h40, 'h53));
    super.tb_env.coh_checker.rnf0_req_cc.write(this.observed_req(HAZARD_ADDR_C + 'h40, 'h53));
    hazards_after_reissue = super.tb_env.coh_checker.get_line_hazard_count();

    super.wait_clocks(20);

    uvm_report_cb::delete(null, this.hazard_catcher);

    if (hazards_after_overlap != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the overlapping same-line pair produced %0d hazard report(s), expected exactly 1",
        super.tc_name, hazards_after_overlap))
    end

    if (hazards_after_reissue != hazards_after_overlap) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a re-issue on the SAME TxnID was reported as a hazard (%0d extra) - the rule cannot tell a retry re-issue from a second request",
        super.tc_name, hazards_after_reissue - hazards_after_overlap))
    end

    if (!this.hazard_catcher.saw_coherency_error) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the hazard rule bumped its counter without reporting - a silent check cannot be acted on",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d non-overlapping claims accepted, overlapping same-line pair flagged once, same-TxnID re-issue not flagged",
      super.tc_name, serial_clears), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
