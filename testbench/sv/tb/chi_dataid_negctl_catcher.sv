class chi_dataid_negctl_catcher extends uvm_report_catcher;

  bit saw_duplicate_error = 1'b0;
  bit saw_missing_error   = 1'b0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name = "chi_dataid_negctl_catcher");

    super.new(name);
  endfunction

  // Demote the two UVM_ERRORs the deliberately malformed DAT burst is expected
  // to raise, so the negative control passes: the test asserts the monitor DID
  // report both faults (proving the DataID placement checks are not vacuous) and
  // this keeps the intentional errors out of the regression error count.

  // ---------------------------------------------------------------------------
  // Catch
  // ---------------------------------------------------------------------------
  virtual function action_e catch();

    if (get_severity() != UVM_ERROR) begin
      return THROW;
    end

    if (uvm_is_match("*duplicate DAT DataID*", get_message())) begin
      this.saw_duplicate_error = 1'b1;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_DATAID_DUPLICATE");
      set_message("Expected duplicate-DataID error observed and demoted to INFO");
      return THROW;
    end

    if (uvm_is_match("*closed with no beat carrying DataID*", get_message())) begin
      this.saw_missing_error = 1'b1;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_DATAID_MISSING");
      set_message("Expected missing-DataID error observed and demoted to INFO");
      return THROW;
    end

    return THROW;
  endfunction

endclass
