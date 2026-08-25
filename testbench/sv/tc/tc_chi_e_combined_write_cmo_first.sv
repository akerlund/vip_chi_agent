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
// CompCMO driven before the write's Comp.
//
// IHI 0050 E section 2.8 places exactly one ordering rule on CompCMO -- it "must
// only be sent after the associated request is received" -- and none at all
// relative to the write's own completion. Both orders are conformant.
//
// The requester used to encode one of them as the only one: it consumed the
// write completion first and only then looked for CompCMO, so a completer that
// led with the CMO half had that flit collected by the write-completion path and
// died on "was not Comp". The fix is not to accept the other order as a second
// script but to stop scripting: the remaining completions are collected as an
// obligation SET, and each flit retires whichever obligation it satisfies.
//
// cfg.snf_cmo_before_write_comp is not a negative control. It selects a legal
// alternative, which is why it does not appear in the config's has_negctl chain
// -- nothing here is expected to be reported by anything.
//
// What is asserted:
//   * the transaction completes, which under the old fixed sequence it could
//     not have;
//   * the requester's completion log opens with CompCMO, without which the
//     testcase would pass against a knob that did nothing;
//   * the scoreboard reports no error, so accepting the order is not achieved
//     by the checker having stopped looking.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_combined_write_cmo_first extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_combined_write_cmo_first)

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
  // The order under test: the CMO half ahead of the write's Comp.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();
    this.snf_cfg.snf_cmo_before_write_comp = 1'b1;
    // The write's Comp must be a separate flit for there to be an order to put
    // the CMO in front of: a combined CompDBIDResp carries the completion with
    // the grant, before the write data has even been sent.
    this.snf_cfg.split_write_rsp = 1'b1;
  endfunction


  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t wr_rsp[$];

    phase.raise_objection(this);

    super.drain_observation_fifos();

    this.write_cmo_seq.reset();
    this.write_cmo_seq.set_partial(1'b0);
    this.write_cmo_seq.set_cmo(VIP_CHI_CMO_CLEAN_SH_PER_SEP_E);
    this.write_cmo_seq.set_requests(1);
    this.write_cmo_seq.set_initial_addr(E_COMBINED_WRITE_CMO_FIRST_ADDR_C);
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

    // The CMO half really did arrive first. Without this the test passes against
    // a knob that does nothing, because the write-first order completes too.
    if (super.tb_env.rni_agent.rni_driver.combined_completion_log.size() == 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the combined Write + PCMO retired no obligations at all",
      get_name()))
    end

    if (super.tb_env.rni_agent.rni_driver.combined_completion_log[0] !=
        VIP_CHI_RSP_COMP_CMO_C) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the combined Write + PCMO retired its first obligation on RSP opcode 0x%0h; CompCMO was expected first, so the completer did not take the order this testcase exists to exercise",
      get_name(), super.tb_env.rni_agent.rni_driver.combined_completion_log[0]))
    end

    if (super.tb_env.scoreboard.total_errors() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] the scoreboard reported %0d error(s) against a completer that sent CompCMO before the write's Comp. Section 2.8 does not order those two responses",
      get_name(), super.tb_env.scoreboard.total_errors()))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a combined Write + PCMO whose CompCMO preceded the write's Comp completed normally",
    get_name()), UVM_LOW)


    phase.drop_objection(this);
  endtask

endclass
