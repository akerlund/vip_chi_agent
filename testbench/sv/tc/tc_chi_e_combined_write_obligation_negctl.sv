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
// The negative control for the combined-write obligation set.
//
// Replacing a fixed completion sequence with an obligation set buys tolerance of
// ORDER. It must not buy tolerance of anything at all, and the difference is not
// self-evident from reading the loop: the same code that accepts CompCMO before
// Comp would accept a second CompCMO, or a ReadReceipt, if the final else were
// ever softened.
//
// cfg.snf_combined_cmo_duplicate_negctl makes the completer send CompCMO twice.
// The duplicate is chosen deliberately over an obviously wrong opcode: it is a
// response this transaction really is entitled to, arriving at a moment when it
// satisfies nothing outstanding. An implementation that keyed on "is this a
// legal opcode for this request" rather than on "is this obligation still owed"
// would pass a control built from a ReadReceipt and fail this one.
//
// The refusal is a `uvm_fatal in this port, demoted and counted by
// chi_route_negctl_catcher, so the run stays green and the refusal is asserted
// rather than assumed.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_combined_write_obligation_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_combined_write_obligation_negctl)

  vip_chi_write_cmo_seq #(CHI_E_WIDE_CFG_C) write_cmo_seq;
  chi_route_negctl_catcher                  route_catcher;

  localparam int SIZE_C   = 6;
  localparam int SETTLE_C = 20;

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

    this.write_cmo_seq =
      vip_chi_write_cmo_seq #(CHI_E_WIDE_CFG_C)::type_id::create("write_cmo_seq");
    this.route_catcher = new("combined_write_obligation_catcher");
  endfunction

  // ---------------------------------------------------------------------------
  // The control itself: the completer sends a second CompCMO.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    this.snf_cfg.snf_combined_cmo_duplicate_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    phase.raise_objection(this);

    super.drain_observation_fifos();

    // Demote the requester's refusal of the duplicate, and record it.
    uvm_report_cb::add(null, this.route_catcher);

    this.write_cmo_seq.reset();
    this.write_cmo_seq.set_partial(1'b0);
    this.write_cmo_seq.set_cmo(VIP_CHI_CMO_CLEAN_SH_PER_SEP_E);
    this.write_cmo_seq.set_requests(1);
    this.write_cmo_seq.set_initial_addr(E_COMBINED_WRITE_OBLIGATION_NEGCTL_ADDR_C);
    this.write_cmo_seq.set_size(SIZE_C);
    this.write_cmo_seq.set_get_response(1'b1);
    this.write_cmo_seq.set_verbose(1'b0);
    this.write_cmo_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(SETTLE_C);

    uvm_report_cb::delete(null, this.route_catcher);

    if (!this.route_catcher.saw_obligation_refusal) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the requester accepted a second CompCMO. Collecting completions as an obligation set must not become collecting anything at all -- a response that retires nothing still outstanding has to be refused",
      get_name()))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a second CompCMO satisfying no outstanding obligation was refused",
    get_name()), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
