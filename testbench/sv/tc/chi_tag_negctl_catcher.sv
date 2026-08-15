// Demotes the two deliberately-injected MTE tag errors so the negative control
// keeps them out of the regression error count.
//
// A dedicated catcher rather than a pattern added to the scoreboard-orphan one,
// because the two controls break different checks and a catcher that demoted
// both would let either test pass on the other's error. It matches only the two
// messages this control injects, so a THIRD unexpected scoreboard error inside
// the same run still fails the test -- which is the point of demoting per
// message rather than waiving the component.
class chi_tag_negctl_catcher extends uvm_report_catcher;

  bit saw_tag_error;
  bit saw_tagop_error;

  function new(input string name = "chi_tag_negctl_catcher");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Catch
  // ---------------------------------------------------------------------------
  virtual function action_e catch();

    if (get_severity() != UVM_ERROR) begin
      return THROW;
    end

    if (uvm_is_match("*Tag mismatch*", get_message())) begin
      this.saw_tag_error = 1'b1;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_TAG_MISMATCH");
      set_message("Expected MTE tag mismatch observed and demoted to INFO");
      return THROW;
    end

    if (uvm_is_match("*TagOp replay mismatch*", get_message())) begin
      this.saw_tagop_error = 1'b1;
      set_severity(UVM_INFO);
      set_id("VIP_CHI_EXPECTED_TAGOP_MISMATCH");
      set_message("Expected MTE TagOp replay mismatch observed and demoted to INFO");
      return THROW;
    end

    return THROW;
  endfunction

endclass
