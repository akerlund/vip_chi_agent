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
// The negative control for the zero-write completion FORM: the completer answers
// WriteNoSnpZero with a bare Comp, and the requester must refuse it.
//
// IHI 0050 answers WriteNoSnpZero with DBIDResp and a Comp, or with a combined
// CompDBIDResp. A bare Comp is neither. The request carries no write data, so the
// granted buffer is never used and the DBID looks pointless -- which is exactly
// why a completer leaves it out, and why a requester that had never been told
// otherwise accepts it. The completion form is normative regardless of whether
// the requester uses what it is granted.
//
// Why the guard needed a control. The refusal is unreachable from conformant
// traffic, so its silence in every other run says nothing: a guard nothing can
// provoke is indistinguishable from one that was deleted.
// cfg.snf_write_zero_bare_comp_negctl provokes it.
//
// The refusal is a `uvm_fatal in this port, demoted and COUNTED through
// chi_sb_rule_negctl_catcher, which takes its pattern from the test rather than
// carrying a flag per control. The pyUVM twin arrives at the same place through
// reject() and an expect_rejection scope.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_write_zero_form_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_write_zero_form_negctl)

  vip_chi_write_zero_seq #(CHI_E_WIDE_CFG_C) write_zero_seq;
  chi_sb_rule_negctl_catcher                 form_catcher;

  localparam int SIZE_C   = 6;
  localparam int SETTLE_C = 20;

  localparam string REFUSAL_PATTERN_C =
    "*Zero-write first response opcode*was neither DBIDResp nor CompDBIDResp*";

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Start of simulation
  // ---------------------------------------------------------------------------
  function void start_of_simulation_phase(input uvm_phase phase);

    super.start_of_simulation_phase(phase);

    this.write_zero_seq =
      vip_chi_write_zero_seq #(CHI_E_WIDE_CFG_C)::type_id::create("write_zero_seq");
    this.form_catcher = new("write_zero_form_catcher");
    this.form_catcher.add_expected(REFUSAL_PATTERN_C);
  endfunction

  // ---------------------------------------------------------------------------
  // The control itself: the completer answers with a bare Comp.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    this.snf_cfg.snf_write_zero_bare_comp_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    super.drain_observation_fifos();

    uvm_report_cb::add(null, this.form_catcher);

    this.write_zero_seq.reset();
    this.write_zero_seq.set_requests(1);
    this.write_zero_seq.set_initial_addr(E_WRITE_ZERO_FORM_NEGCTL_ADDR_C);
    this.write_zero_seq.set_size(SIZE_C);
    this.write_zero_seq.set_get_response(1'b1);
    this.write_zero_seq.set_verbose(1'b0);
    this.write_zero_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    uvm_report_cb::delete(null, this.form_catcher);

    // Exactly one refusal, and on the FIRST response rather than the second: a
    // bare Comp is wrong as an opening move, and a requester that waited for a
    // grant before objecting would hang instead of refusing.
    if (this.form_catcher.caught(REFUSAL_PATTERN_C) != 1) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the requester refused a bare Comp %0d time(s), expected exactly 1. Zero means it accepted a completion form the specification does not list; more than one means the request was retried behind the refusal",
      get_name(), this.form_catcher.caught(REFUSAL_PATTERN_C)))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a bare Comp answering WriteNoSnpZero was refused as the first response",
    get_name()), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
