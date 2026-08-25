////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Akerlund
// https://github.com/akerlund/vip_chi_agent
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
////////////////////////////////////////////////////////////////////////////////
//
// The negative control for the separated-persist completion FORM: the completer
// sends a standalone Persist first and CompPersist after it, and the requester
// must refuse the sequence.
//
// A requester must accept either of two forms, and only those two:
//
//   * Comp then Persist -- Point of Coherency reached, then Point of
//     Persistence. Two milestones, two responses.
//   * CompPersist alone -- the completer combined them.
//
// Persist-then-CompPersist is neither: no bare Comp ever arrives, and persistence
// is signalled twice, once alone and again inside the combined response. It is
// also the shape this VIP's own completer used to produce, which is why its
// requester used to demand it -- the two agreed with each other and were wrong
// together, which is the failure mode a control on ONE side cannot find.
//
// cfg.snf_persist_before_comp_negctl reproduces that shape in full, TxnID
// included, and the TxnID is why this test asserts more than one rule. A
// standalone Persist is not tied to a transaction, so carrying the request's
// TxnID is a second defect in the same flit, and CHI_RSP_FIELD_ZERO judges it
// independently of the requester's opinion. Asserting both is what distinguishes
// a completer put back on the old shape from one that merely sent an unexpected
// opcode.
//
// The refusal is a `uvm_fatal in this port, demoted and COUNTED through
// chi_sb_rule_negctl_catcher. The field rule is demoted the other way -- severity
// OFF on the interface, count kept -- because an SVA failure is not in the UVM
// report path at all.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_persist_sep_form_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_persist_sep_form_negctl)

  vip_chi_persist_seq #(CHI_E_WIDE_CFG_C)   persist_seq;
  chi_sb_rule_negctl_catcher                form_catcher;

  localparam int SIZE_C   = 6;
  localparam int SETTLE_C = 20;

  localparam string REFUSAL_PATTERN_C =
    "*PersistSep first completion opcode*was neither Comp nor CompPersist*";

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Start of simulation
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.persist_seq =
      vip_chi_persist_seq #(CHI_E_WIDE_CFG_C)::type_id::create("persist_seq");
    this.form_catcher = new("persist_sep_form_catcher");
    this.form_catcher.add_expected(REFUSAL_PATTERN_C);
  endfunction

  // ---------------------------------------------------------------------------
  // The control itself: Persist first, then CompPersist.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    this.snf_cfg.snf_persist_before_comp_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int rni_before;
    int snf_before;
    int rni_after;
    int snf_after;
    int out_before;
    int out_after;

    phase.raise_objection(this);

    // Suppress the field rule's report, keep its count. Both ends, because the
    // flit is seen at both and both are about to be made to fail.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_RSP_FIELD_ZERO_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_RSP_FIELD_ZERO_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // The collateral, and it is inherent rather than sloppy: a refused
    // completion is never retired, so the transaction stays outstanding for the
    // rest of the run while the requester's activity window closes over it. Any
    // control that makes a requester ABANDON a transaction produces this, and
    // suppressing it without saying so would hide the consequence of the
    // injection. Counted below rather than merely permitted.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    super.drain_observation_fifos();

    uvm_report_cb::add(null, this.form_catcher);

    rni_before = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_FIELD_ZERO_E];
    snf_before = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_FIELD_ZERO_E];
    out_before = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E] +
                 super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E];

    // A STANDALONE CleanSharedPersistSep, not the combined Write + CMO. Only the
    // standalone form is collected by collect_persist_sep_completion, which is
    // the guard under test; a combined request completes through the obligation
    // loop and would never reach it.
    //
    // TWO requests, and the reason is the TxnID. The requester's first wait is
    // TxnID-matched, so the injected Persist must carry the request's TxnID to
    // reach the opcode check at all -- which means whether it ALSO breaks the
    // field rule depends on whether that TxnID happens to be zero. Two
    // consecutive requests cannot both draw zero, so the field arm is reached
    // whatever the allocator starts from.
    this.persist_seq.reset();
    this.persist_seq.set_sep_persist(1'b1);
    this.persist_seq.set_requests(2);
    this.persist_seq.set_initial_addr(E_PERSIST_SEP_FORM_NEGCTL_ADDR_C);
    this.persist_seq.set_size(SIZE_C);
    this.persist_seq.set_get_response(1'b1);
    this.persist_seq.set_verbose(1'b0);
    this.persist_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    uvm_report_cb::delete(null, this.form_catcher);

    // Exactly one refusal, and on the FIRST completion: Persist is wrong as an
    // opening move whatever follows it, so a requester that waited to see the
    // CompPersist before objecting would be judging the pair rather than the form.
    if (this.form_catcher.caught(REFUSAL_PATTERN_C) != 2) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the requester refused Persist-then-CompPersist %0d time(s), expected exactly 2 -- one per request. Fewer means it accepted a completion sequence that is neither of the two legal forms",
      get_name(), this.form_catcher.caught(REFUSAL_PATTERN_C)))
    end

    rni_after = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_FIELD_ZERO_E];
    snf_after = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_FIELD_ZERO_E];

    if ((rni_after + snf_after) <= (rni_before + snf_before)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] %s did not report on a standalone Persist carrying the request's TxnID. Either the control is sending TxnID 0 after all -- in which case it is not the shape this test claims to drive -- or the field rule stopped reading Persist",
      get_name(), vip_chi_check_name(VIP_CHI_CHK_RSP_FIELD_ZERO_E)))
    end

    out_after = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E] +
                super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E];

    if (out_after <= out_before) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] %s did not report, but two transactions were abandoned by the refusals above. Either they were retired after all -- in which case the refusal did not abandon them -- or the rule stopped reading the outstanding count",
      get_name(), vip_chi_check_name(VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E)))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] Persist-then-CompPersist was refused %0d time(s), and the standalone Persist's non-zero TxnID was reported %0d time(s)",
    get_name(), this.form_catcher.caught(REFUSAL_PATTERN_C),
    (rni_after + snf_after) - (rni_before + snf_before)), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
