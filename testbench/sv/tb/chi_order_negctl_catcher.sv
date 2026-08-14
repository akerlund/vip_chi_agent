class chi_order_negctl_catcher extends uvm_report_catcher;

  bit saw_order_error = 1'b0;
  int n_order_errors  = 0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name = "chi_order_negctl_catcher");

    super.new(name);
  endfunction

  // Demote the deliberately-provoked out-of-order UVM_ERROR so the negative
  // control passes: the test asserts the scoreboard DID flag the inversion
  // (proving the ordered-stream check is not a no-op) and this keeps the
  // intentional error out of the regression error count.

  // ---------------------------------------------------------------------------
  // Catch
  // ---------------------------------------------------------------------------
  virtual function action_e catch();

    if ((get_severity() == UVM_ERROR) &&
        uvm_is_match("*Ordered stream out of order*", get_message())) begin
      this.saw_order_error = 1'b1;
      this.n_order_errors++;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_SB_ORDER");
      set_message("Expected scoreboard ordered-stream error observed and demoted to INFO");
      return THROW;
    end

    return THROW;
  endfunction

endclass
