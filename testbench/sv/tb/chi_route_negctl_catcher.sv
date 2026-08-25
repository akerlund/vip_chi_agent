// A requester refusing a response it was not owed.
//
// Three negative controls provoke the same shape: the completer sends a
// response the requester is not expecting -- at the wrong address ( ,
// both limbs) or satisfying no outstanding obligation -- and the
// requester, which knows what it asked for, refuses it with a `uvm_fatal. The
// refusal is the correct behaviour and the point of the control, so it is
// demoted here and counted, exactly as chi_scoreboard_negctl_catcher does for
// the deliberately-injected orphan.
//
// Without this the SV port cannot write the control at all, and what it gets
// instead is worse than nothing: a testcase named _negctl whose body is the
// positive test's, asserting that the rule stays SILENT. That is what stood
// here before, and it read as evidence for the opposite of its own name.
//
// Two patterns rather than one catch-all, and counted separately, so a control
// cannot pass on the wrong refusal -- the DWT control provoking the Persist
// path would otherwise look identical to it provoking its own.
class chi_route_negctl_catcher extends uvm_report_catcher;

  bit saw_persist_route_refusal = 1'b0;
  bit saw_grant_txn_refusal     = 1'b0;
  bit saw_obligation_refusal    = 1'b0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name = "chi_route_negctl_catcher");

    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Catch
  // ---------------------------------------------------------------------------
  virtual function action_e catch();

    if (get_severity() != UVM_FATAL) begin
      return THROW;
    end

    // The standalone Persist arrived from the right node at the wrong target.
    if (uvm_is_match("*Standalone Persist route*", get_message())) begin
      this.saw_persist_route_refusal = 1'b1;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_ROUTE_REFUSAL");
      set_message("Expected Persist route refusal observed and demoted to INFO");
      return THROW;
    end

    // The write grant arrived under the requester's own TxnID when DoDWT had
    // moved it to ReturnTxnID, so the requester did not recognise it.
    if (uvm_is_match("*Write completion txn_id*does not match request txn_id*",
                     get_message())) begin
      this.saw_grant_txn_refusal = 1'b1;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_ROUTE_REFUSAL");
      set_message("Expected write-grant TxnID refusal observed and demoted to INFO");
      return THROW;
    end

    // A combined Write + CMO response that retires nothing still outstanding.
    if (uvm_is_match("*satisfying no outstanding obligation*", get_message())) begin
      this.saw_obligation_refusal = 1'b1;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_ROUTE_REFUSAL");
      set_message("Expected combined-write obligation refusal observed and demoted to INFO");
      return THROW;
    end

    return THROW;
  endfunction

endclass
