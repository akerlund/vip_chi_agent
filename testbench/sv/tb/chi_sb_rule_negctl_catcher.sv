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
// Demote the scoreboard UVM_ERROR that a negative control provoked on purpose,
// and record that it was really emitted.
//
// The scoreboard reports unconditionally: chk_bad raises a uvm_error whatever
// expect_failure() set the severity to, because there the report IS the verdict
// and suppressing it would delete the evidence a negative control depends on.
// expect_failure declares INTENT for the CSV export and nothing more. So a
// scoreboard negative control needs two things, not one: expect_failure so the
// cross-run aggregation does not read the run as a regression, and a catcher so
// the deliberate error does not count against a regression script that gates on
// "UVM_ERROR : 0".
//
// chi_scoreboard_negctl_catcher does exactly this for one hard-coded message.
// This one takes the pattern from the test, so a control does not need a catcher
// class of its own -- add_expected() once, then assert saw_expected() at the end
// the same way.
//
////////////////////////////////////////////////////////////////////////////////

class chi_sb_rule_negctl_catcher extends uvm_report_catcher;

  // Glob patterns (uvm_is_match syntax) whose UVM_ERRORs are expected.
  protected string patterns[$];

  // How many errors each pattern actually caught. Kept per pattern rather than
  // as one total so a test registering two provocations can tell which of them
  // fired -- a single count could be one pattern firing twice.
  protected int    n_caught[string];

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name = "chi_sb_rule_negctl_catcher");

    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Declare one message shape as deliberately provoked.
  // ---------------------------------------------------------------------------
  function void add_expected(input string pattern);

    this.patterns.push_back(pattern);
    this.n_caught[pattern] = 0;
  endfunction

  // ---------------------------------------------------------------------------
  // How many errors matched one registered pattern. Zero means the control never
  // reached the checker, which a negative control must fail on: a rule that was
  // never provoked is not a rule that was proved.
  // ---------------------------------------------------------------------------
  function int caught(input string pattern);

    return this.n_caught.exists(pattern) ? this.n_caught[pattern] : 0;
  endfunction

  // ---------------------------------------------------------------------------
  // Catch
  // ---------------------------------------------------------------------------
  // UVM_FATAL as well as UVM_ERROR, because the two kinds of refusal this is
  // aimed at report at different severities and a control cannot choose which.
  // A scoreboard or checker rule raises a `uvm_error; a DRIVER refusing a
  // response it was never owed raises a `uvm_fatal, because outside a control
  // there is nothing sensible for it to do next. Demoting only the error would
  // leave every driver-refusal control unwritable in this port -- which is the
  // asymmetry with the pyUVM port's reject() that the mechanism exists to close.
  //
  // Only patterns a test registered are touched, so an unexpected fatal still
  // ends the run.
  virtual function action_e catch();

    if ((get_severity() == UVM_ERROR) || (get_severity() == UVM_FATAL)) begin
      foreach (this.patterns[i]) begin
        if (uvm_is_match(this.patterns[i], get_message())) begin
          this.n_caught[this.patterns[i]]++;
          set_severity(UVM_INFO);
          set_id("VIP_CHI_EXPECTED_NEGCTL_REPORT");
          return THROW;
        end
      end
    end

    return THROW;
  endfunction

endclass
