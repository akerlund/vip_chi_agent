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
// A combined Write + PCMO answered with CompPersist (F-INTOP-008).
//
// IHI 0050 E section 2.8, in the SN response summary: the Slave "is permitted to
// combine CompCMO with Persist as a CompPersist response if the two are sent to
// Home". So a conformant completer may answer this request with two responses
// where the default completer sends three, and a requester must accept both
// shapes.
//
// This one could not previously be RUN, let alone passed. The requester demanded
// exactly CompCMO and then exactly Persist, and fatalled on anything else -- not
// a mis-score, a stopped simulation on legal CHI. And the completer could not
// produce the encoding on this path at all, so the intolerance had nothing to
// meet it: cfg.combined_persist_rsp reached only the standalone
// CleanSharedPersistSep flow. Both halves are fixed here, which is why the test
// is evidence rather than a restatement of the driver.
//
// The combination is legal only where CompCMO's target and the Persist's
// coincide -- SrcID and ReturnNID -- so the completer emits it only when they do
// rather than obeying the knob blindly. Here the sequence leaves ReturnNID at
// the requester's own node, which is the case that makes it available.
//
// What is asserted:
//   * the transaction completes and returns exactly one response, so the
//     obligation set retired on two flits rather than hanging on a third;
//   * the requester's completion log CONTAINS CompPersist, without which this
//     testcase would pass equally well against a knob that did nothing;
//   * the scoreboard reports no error, which is the check that the CMO and
//     persist milestones were both ticked by the one response.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_combined_write_comp_persist extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_combined_write_comp_persist)

  vip_chi_write_cmo_seq #(CHI_E_WIDE_CFG_C) write_cmo_seq;

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
  endfunction

  // ---------------------------------------------------------------------------
  // The encoding under test: CompCMO and Persist combined into CompPersist.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    this.snf_cfg.combined_persist_rsp = 1'b1;
  endfunction


  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t wr_rsp[$];
    bit    saw_comp_persist;

    phase.raise_objection(this);

    super.drain_observation_fifos();

    this.write_cmo_seq.reset();
    this.write_cmo_seq.set_partial(1'b0);
    this.write_cmo_seq.set_cmo(VIP_CHI_CMO_CLEAN_SH_PER_SEP_E);
    this.write_cmo_seq.set_requests(1);
    this.write_cmo_seq.set_initial_addr(E_COMBINED_WRITE_COMP_PERSIST_ADDR_C);
    this.write_cmo_seq.set_size(SIZE_C);
    this.write_cmo_seq.set_get_response(1'b1);
    this.write_cmo_seq.set_verbose(1'b0);
    this.write_cmo_seq.start(super.tb_env.rni_agent.sequencer);

    wr_rsp = this.write_cmo_seq.get_responses();
    if (wr_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the combined Write + PCMO returned %0d responses, expected 1",
      get_name(), wr_rsp.size()))
    end

    super.wait_clocks(SETTLE_C);

    // The completer actually took the encoding, rather than sending the default
    // pair and being accepted anyway. Both complete, so completion alone would
    // not distinguish them and this test would pass against a knob that did
    // nothing.
    saw_comp_persist = 1'b0;
    foreach (super.tb_env.rni_agent.rni_driver.combined_completion_log[i]) begin
      if (super.tb_env.rni_agent.rni_driver.combined_completion_log[i] ==
          VIP_CHI_RSP_COMP_PERSIST_C) begin
        saw_comp_persist = 1'b1;
      end
    end

    if (!saw_comp_persist) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the combined Write + PCMO retired its obligations from %0d response(s), none of them a CompPersist. The requester accepting the default CompCMO + Persist pair proves nothing about the combined encoding",
      get_name(), super.tb_env.rni_agent.rni_driver.combined_completion_log.size()))
    end

    if (super.tb_env.scoreboard.total_errors() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the scoreboard reported %0d error(s) against a combined Write + PCMO answered with CompPersist. Section 2.8 permits that encoding, and the milestones it ticks are CompCMO and Persist -- not Comp and Persist, which is what the standalone form combines",
      get_name(), super.tb_env.scoreboard.total_errors()))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a combined Write + PCMO answered with CompPersist retired both the CMO and the persist obligation from one response",
    get_name()), UVM_LOW)


    phase.drop_objection(this);
  endtask

endclass
