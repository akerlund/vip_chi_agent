class chi_latency_negctl_catcher extends uvm_report_catcher;

  bit saw_latency_error = 1'b0;
  int n_latency_errors  = 0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name = "chi_latency_negctl_catcher");

    super.new(name);
  endfunction

  // Demote the deliberately-provoked latency-bound UVM_ERROR so the test passes:
  // it asserts the monitor DID flag the over-budget transaction (proving the
  // bound is not a no-op) and this keeps the intentional error out of the
  // regression error count.

  // ---------------------------------------------------------------------------
  // Catch
  // ---------------------------------------------------------------------------
  virtual function action_e catch();

    if ((get_severity() == UVM_ERROR) &&
        uvm_is_match("*exceeding the configured bound*", get_message())) begin
      this.saw_latency_error = 1'b1;
      this.n_latency_errors++;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_LATENCY_BOUND");
      set_message("Expected latency-bound error observed and demoted to INFO");
      return THROW;
    end

    return THROW;
  endfunction

endclass
