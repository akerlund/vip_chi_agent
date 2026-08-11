class chi_pcrd_leak_negctl_catcher extends uvm_report_catcher;

  bit saw_leak_error = 1'b0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name = "chi_pcrd_leak_negctl_catcher");

    super.new(name);
  endfunction

  // Demote the end-of-test P-credit leak UVM_ERROR this negative control induces
  // on purpose: the test asserts the RN-I DID report the leak (proving the
  // accounting is not vacuous) and this keeps the intentional error out of the
  // regression error count.

  // ---------------------------------------------------------------------------
  // Catch
  // ---------------------------------------------------------------------------
  virtual function action_e catch();

    if ((get_severity() == UVM_ERROR) &&
        uvm_is_match("*were granted and never consumed*", get_message())) begin
      this.saw_leak_error = 1'b1;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_PCRD_LEAK");
      set_message("Expected P-credit leak error observed and demoted to INFO");
      return THROW;
    end

    return THROW;
  endfunction

endclass
