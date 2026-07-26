class chi_scoreboard_negctl_catcher extends uvm_report_catcher;

  bit saw_orphan_error = 1'b0;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name = "chi_scoreboard_negctl_catcher");

    super.new(name);
  endfunction

  // Demote the deliberately-injected scoreboard orphan UVM_ERROR so the negative
  // control passes: the test asserts the scoreboard DID flag the orphan (proving
  // Checker A is not a no-op) and this keeps the intentional error out of the
  // regression error count.

  // ---------------------------------------------------------------------------
  // Catch
  // ---------------------------------------------------------------------------
  virtual function action_e catch();

    if ((get_severity() == UVM_ERROR) &&
        uvm_is_match("*Orphan RSP (no open ctx)*", get_message())) begin
      this.saw_orphan_error = 1'b1;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_SB_ORPHAN");
      set_message("Expected scoreboard orphan-RSP error observed and demoted to INFO");
      return THROW;
    end

    return THROW;
  endfunction

endclass
