class chi_coherency_negctl_catcher extends uvm_report_catcher;

  bit saw_coherency_error = 1'b0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name = "chi_coherency_negctl_catcher");
    super.new(name);
  endfunction

  // Demote a deliberately-induced Checker-D UVM_ERROR so the negative control
  // passes: the test asserts Checker D DID flag the violation (proving the
  // invariant is not a no-op), and this keeps the intentional error out of the
  // regression error count. Covers both the multi-owner / data-integrity
  // invariants ("COHERENCY VIOLATION") and the exclusive LL/SC invariant
  // ("EXCLUSIVE VIOLATION"); the specific test disambiguates via the matching
  // per-invariant counter (get_multi_owner_count / get_excl_violation_count).
  // ---------------------------------------------------------------------------
  virtual function action_e catch();

    if ((get_severity() == UVM_ERROR) &&
        (uvm_is_match("*COHERENCY VIOLATION*", get_message()) ||
         uvm_is_match("*EXCLUSIVE VIOLATION*", get_message()))) begin
      this.saw_coherency_error = 1'b1;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_COH_VIOLATION");
      set_message("Expected Checker-D coherency/exclusive violation observed and demoted to INFO");
      return THROW;
    end

    return THROW;
  endfunction

endclass
