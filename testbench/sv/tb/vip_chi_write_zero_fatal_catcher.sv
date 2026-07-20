class vip_chi_write_zero_fatal_catcher extends uvm_report_catcher;

  bit saw_write_zero_issue_fatal = 1'b0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_write_zero_fatal_catcher");

    super.new(name);
  endfunction

  // Demote the expected CHI-D WriteNoSnpZero fatal so regression summaries do
  // not report a caught UVM_FATAL for this intentional legality check.

  // ---------------------------------------------------------------------------
  // Catch
  // ---------------------------------------------------------------------------
  virtual function action_e catch();

    if ((get_severity() == UVM_FATAL) &&
        uvm_is_match("*WriteNoSnpZero is only legal under CHI-E*", get_message())) begin
      this.saw_write_zero_issue_fatal = 1'b1;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_WRITE_ZERO_FATAL");
      set_message("Expected CHI-D WriteNoSnpZero legality fatal observed and demoted to INFO");
      return THROW;
    end

    return THROW;
  endfunction

endclass