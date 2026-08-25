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
// The two link state machines standing in DIFFERENT states in the same cycle,
// and the transition rule required to stay SILENT through it.
//
// IHI 0050 E section 14.6.1 / D 13.6.1 defines a transmit machine and a receive
// machine per interface -- section 14.5.1: "two signals are used for all the
// transmit channels and two signals are used for all the receive channels" --
// and section 14.6.2 says Figure 14-5 "is formatted so that the independent
// nature of the Tx and Rx state machines can be seen". They activate, run and
// tear down on their own schedules, so a component whose transmit link is RUN
// while its receive link is still ACTIVATE is conformant, not broken.
//
// This is the case the checker could not represent while the four sideband
// signals were OR-collapsed into one state: TxRun/RxAct and TxAct/RxRun both
// computed req=1, ack=1 and aliased onto RUN, and a peer advancing the two
// machines in one cycle could move the collapsed state two places and be
// REPORTED for a legal step. A false failure against conformant hardware.
//
// So this is a control on silence, which needs its provocation asserted or it
// proves nothing. cfg.lasm_stall_activation_cycles holds the completer's own
// request and acknowledge back for a while after the requester has asked, which
// drives the two machines apart at both endpoints: the requester sits with its
// transmit link waiting while its receive link has not been asked for yet, and
// passes through TxRun/RxAct as the stall ends. vif.lasm_divergent_cycles counts
// the cycles where they really did differ, and a run where it stayed zero would
// mean the stimulus never reached the case whatever the rule then said.
//
// The stall is well inside any bound: link_activation_timeout_cycles defaults to
// 0, which disables the timeout, so this test is about the transition rule alone
// and does not smuggle in a timing claim.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_lasm_divergent_states extends chi_base_test;

  `uvm_component_utils(tc_chi_lasm_divergent_states)

  localparam item_t::addr_t ADDR_C   = item_t::addr_t'(44'h3D50_0000);
  localparam bit [2:0]      SIZE_C   = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int            SETTLE_C = 20;
  localparam int            STALL_C  = 12;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Hold the completer's own request and acknowledge back, which is what drives
  // the two machines apart at both ends.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.snf_cfg.lasm_stall_activation_cycles = STALL_C;
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned rni_apart;
    int unsigned snf_apart;
    int unsigned rni_fails;
    int unsigned snf_fails;
    int unsigned rni_missed;
    int unsigned snf_missed;
    int unsigned rni_passes;

    phase.raise_objection(this);

    // Ordinary traffic over the link the stall delayed. It has to complete: a
    // link that never came up would also report no illegal transitions, and the
    // silence below would be silence about nothing.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    rni_apart = super.tb_env.rni_agent.vif.lasm_divergent_cycles;
    snf_apart = super.tb_env.snf_agent.vif.lasm_divergent_cycles;

    // The provocation, asserted before the silence it qualifies. Both endpoints,
    // because both own two machines and the stall separates them at each: a
    // divergence at one end only would mean one side is still deriving both
    // machines from the same pair of signals.
    if (rni_apart == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the requester's two link machines never differed, so the stall did not separate them and the transition rule was never asked the question this test exists to ask",
        super.tc_name))
    end

    if (snf_apart == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the completer's two link machines never differed, so the stall did not separate them and the transition rule was never asked the question this test exists to ask",
        super.tc_name))
    end

    rni_fails = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E];
    snf_fails = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E];

    // ...and the silence itself. Each machine walked its own axis, so neither
    // may have been reported -- a report here is the false failure against
    // conformant hardware that the OR-collapse produced.
    if ((rni_fails != 0) || (snf_fails != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the checkers reported %0d (RN-I) / %0d (SN-F) illegal LASM transition(s) while the two machines were legitimately in different states. Each machine moves on its own axis; reporting one for the other's step is a false failure against a conformant peer",
        super.tc_name, rni_fails, snf_fails))
    end

    // The companion claim, which a divergence must not break either: both
    // machines still went up THROUGH ACTIVATE.
    rni_missed = super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_ACTIVATE_OBSERVED_E];
    snf_missed = super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LASM_ACTIVATE_OBSERVED_E];

    if ((rni_missed != 0) || (snf_missed != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the checkers reported %0d (RN-I) / %0d (SN-F) activation(s) that skipped ACTIVATE while the two machines were apart",
        super.tc_name, rni_missed, snf_missed))
    end

    // The rule was live, not merely quiet: it recorded legal steps on the same
    // run.
    rni_passes = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E];

    if (rni_passes == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the transition rule recorded no legal steps at all, so its zero above is the zero of a rule that never ran",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "PASS [%s] the two machines stood apart for %0d (RN-I) / %0d (SN-F) cycle(s), no step was reported, and a read completed over the link",
      super.tc_name, rni_apart, snf_apart), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
