////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2026 Fredrik Akerlund
// https://github.com/akerlund/vip_chi_agent
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Description: Both sides of a CLOSED list. IHI 0050 E 14.1.3 / D 13.1.3:
//
//   "During reset the following interface signals must be deasserted by the
//    component:  TX***LCRDV.  TX***FLITV.  TXLINKACTIVEREQ and
//    RXLINKACTIVEACK. [...] All other signals can be any value."
//
// Four items, then a sentence that closes the set. A closed list needs two
// controls or it is not verified at all: one that drives what the closing
// sentence permits and requires SILENCE, and one that drives what the list
// names and requires a REPORT. The four rules had passes in the hundreds and
// ZERO fails across the whole regression before this testcase -- never once
// asked to fail, and two of the things they rejected were legal.
//
//   phase 1  traffic, so link_ever_active latches at both binds and the reset
//            rules are armed. An unarmed rule reports nothing, and nothing is
//            indistinguishable from a pass.
//   phase 2  reset with FLITPEND on every transmitted channel and TXSACTIVE
//            held HIGH. Both sit outside the list and both are permitted high
//            by name -- 14.4 / D 13.4 permits a transmitter "to keep the signal
//            permanently asserted", and 14.7.2 / D 13.7.2 permits an
//            interconnect interface to drive TXSACTIVE straight from its
//            RXSACTIVE input, which the closing sentence leaves free during
//            reset. Nothing may be reported, and every rule must still have
//            EVALUATED: a rule that stood itself down would also be silent.
//   phase 3  reset with txrsplcrdv held HIGH. TX***LCRDV is the first item on
//            the list, so this must be reported, at both vantages.
//
// The RSP credit is the violation because it is the one signal every role here
// drives -- a requester credits the responses it receives and a completer
// credits the ones it receives -- so one knob arms both ends.
//
// It has COLLATERAL, and that is a fact about the protocol rather than a flaw in
// the control. A credit driven through reset is still a credit when reset
// releases. A driver that owns its outputs through a clocking block cannot change
// them between the last reset edge and the first edge after it: the value sampled
// at the second was decided at the first, before the driver could know the
// release was coming. So the parked credit is judged for one cycle with the link
// still in STOP, and CHI_RSP_LCRDV_REQUIRES_LINK and CHI_LCRD_QUIESCENT_IN_STOP
// both report it -- and they are RIGHT to. The first version of this testcase
// assumed those two were gated on rst_n and therefore blind to it; they are not.
//
// Both are REQUIRED to fire, at both vantages. That is what makes phase 3 the
// only place in either sweep where CHI_LCRD_QUIESCENT_IN_STOP can fail: a credit
// banked into the pool the link then carries into STOP is the single situation
// that rule exists to report, and nothing else here produces one.
//
// The counts are asserted as a RANGE and not as a number. The rule is two
// properties here and six per-pool checks in the pyUVM port, so one stranded
// credit is one report at this end and three at that one, and the range is what
// both ports can satisfy without either being wrong.
//
// Every item on 14.1.3's list is a signal that MEANS something, so no member of
// it can be driven without collateral. A control for a closed list has to own
// that rather than pick the signal that hides it.
//
// The reset-window count is a range for a second reason. The property needs rst_n
// low in this cycle AND the previous one, so it cannot evaluate on the first low
// cycle, giving at most RESET_CYCLES_C - 1 evaluations; the lower bound is one
// because the driver's reset hook runs an implementation-defined number of cycles
// into the window.
//
// The SNP twin of these rules lives only on the coherent *_snp_sva binds, so its
// control needs the HN-F/RN-F drivers rather than these two. The host already
// exists -- tc_chi_coh_{d,e}_reset_mid_snoop are the only two runs that exercise
// CHI_SNP_IDLE_IN_RESET at all -- so the work is the knobs, not the testbench.
// Open, not overlooked.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_reset_idle_scope extends chi_base_test;

  `uvm_component_utils(tc_chi_reset_idle_scope)

  localparam bit [2:0] SIZE_C     = 3'd6;   // 64 B = 4 beats on the CHI-D cut
  localparam int       SETTLE_C   = 40;
  // Long enough that phase 3 has several evaluations to report and phase 2 has
  // several to pass, and short enough not to stretch the run.
  localparam int       RESET_CYCLES_C = 8;
  localparam int       MAX_FAILS_C    = RESET_CYCLES_C - 1;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // One conformant write, so both binds latch link_ever_active.
  // ---------------------------------------------------------------------------
  protected task one_write();

    super.rni0_wr_seq.reset();
    super.rni0_wr_seq.set_requests(1);
    super.rni0_wr_seq.set_initial_addr(RESET_IDLE_ADDR_C);
    super.rni0_wr_seq.set_size(SIZE_C);
    super.rni0_wr_seq.set_get_response(1'b1);
    super.rni0_wr_seq.set_verbose(1'b0);
    super.rni0_wr_seq.start(super.v_sqr.rni_sequencer);

  endtask

  // ---------------------------------------------------------------------------
  // Ride out one armed reset pulse and let the link come back up.
  // ---------------------------------------------------------------------------
  protected task one_reset_pulse();

    super.tb_cfg.request_reset_pulse(RESET_CYCLES_C);
    @(negedge super.tb_env.rni_agent.vif.rst_n);
    @(posedge super.tb_env.rni_agent.vif.rst_n);
    super.wait_clocks(SETTLE_C);

  endtask

  // ---------------------------------------------------------------------------
  // Nothing may be reported, at either end.
  // ---------------------------------------------------------------------------
  protected function void require_silent(input vip_chi_check_id_t id,
                                        input string             why);

    int unsigned rni_fails;
    int unsigned snf_fails;

    rni_fails = super.tb_env.rni_agent.vif.check_fail_count[id];
    snf_fails = super.tb_env.snf_agent.vif.check_fail_count[id];

    if ((rni_fails != 0) || (snf_fails != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported rni_e=%0d snf_e=%0d time(s) on %s, which the specification permits",
        super.tc_name, vip_chi_check_name(id), rni_fails, snf_fails, why))
    end

  endfunction

  // ---------------------------------------------------------------------------
  // The rule must have EVALUATED, at both ends. Silence from a rule that stood
  // itself down is not evidence that the traffic was accepted.
  // ---------------------------------------------------------------------------
  protected function void require_evaluated(input vip_chi_check_id_t id,
                                           input int unsigned       rni_before,
                                           input int unsigned       snf_before);

    int unsigned rni_after;
    int unsigned snf_after;

    rni_after = super.tb_env.rni_agent.vif.check_pass_count[id];
    snf_after = super.tb_env.snf_agent.vif.check_pass_count[id];

    if ((rni_after <= rni_before) || (snf_after <= snf_before)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s recorded no new evaluation across the reset window: rni_e %0d -> %0d, snf_e %0d -> %0d. Its silence says nothing",
        super.tc_name, vip_chi_check_name(id),
        rni_before, rni_after, snf_before, snf_after))
    end

  endfunction

  // ---------------------------------------------------------------------------
  // Exactly the rule the stimulus targets, at both ends, within the window the
  // pulse length allows.
  // ---------------------------------------------------------------------------
  protected function void require_reported(input vip_chi_check_id_t id,
                                           input string             what);

    int unsigned rni_fails;
    int unsigned snf_fails;

    rni_fails = super.tb_env.rni_agent.vif.check_fail_count[id];
    snf_fails = super.tb_env.snf_agent.vif.check_fail_count[id];

    if ((rni_fails < 1) || (rni_fails > MAX_FAILS_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the RN-I against %s, expected 1..%0d; zero means the rule no longer sees it at all, above the bound means it is firing outside the window",
        super.tc_name, vip_chi_check_name(id), rni_fails, what, MAX_FAILS_C))
    end

    if ((snf_fails < 1) || (snf_fails > MAX_FAILS_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported %0d time(s) at the SN-F against %s, expected 1..%0d; the completer vantage is not judging its own outputs",
        super.tc_name, vip_chi_check_name(id), snf_fails, what, MAX_FAILS_C))
    end

  endfunction

  // ---------------------------------------------------------------------------
  // Collateral: bounded ABOVE only, for the reason given in the header. Zero is
  // a legitimate answer -- it means the credit did not outlive the release here.
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // A named ceiling, for the one report that is a known defect rather than a
  // consequence of the stimulus.
  // ---------------------------------------------------------------------------
  protected function void require_at_most(input vip_chi_check_id_t id,
                                         input int unsigned       ceiling);

    int unsigned rni_fails;
    int unsigned snf_fails;

    rni_fails = super.tb_env.rni_agent.vif.check_fail_count[id];
    snf_fails = super.tb_env.snf_agent.vif.check_fail_count[id];

    if ((rni_fails > ceiling) || (snf_fails > ceiling)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %s reported rni_e=%0d snf_e=%0d time(s), above the %0d this testcase accounts for. The activation handshake has broken further than the one collapsed step already recorded against it",
        super.tc_name, vip_chi_check_name(id), rni_fails, snf_fails, ceiling))
    end

  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned rni_pass_sideband;
    int unsigned snf_pass_sideband;
    int unsigned rni_pass_req;
    int unsigned snf_pass_req;
    int unsigned rni_pass_rsp;
    int unsigned snf_pass_rsp;
    int unsigned rni_pass_dat;
    int unsigned snf_pass_dat;

    phase.raise_objection(this);

    @(posedge super.tb_env.rni_agent.vif.rst_n);
    super.wait_clocks(4);

    // -- Phase 1: arm the rules. ----------------------------------------------
    this.one_write();
    super.wait_clocks(SETTLE_C);

    rni_pass_sideband = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_LINK_SIDEBAND_IDLE_IN_RESET_E];
    snf_pass_sideband = super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_LINK_SIDEBAND_IDLE_IN_RESET_E];
    rni_pass_req      = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_REQ_IDLE_IN_RESET_E];
    snf_pass_req      = super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_REQ_IDLE_IN_RESET_E];
    rni_pass_rsp      = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_RSP_IDLE_IN_RESET_E];
    snf_pass_rsp      = super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_RSP_IDLE_IN_RESET_E];
    rni_pass_dat      = super.tb_env.rni_agent.vif.check_pass_count[VIP_CHI_CHK_DAT_IDLE_IN_RESET_E];
    snf_pass_dat      = super.tb_env.snf_agent.vif.check_pass_count[VIP_CHI_CHK_DAT_IDLE_IN_RESET_E];

    // -- Phase 2: what the closing sentence permits. --------------------------
    //
    // Set on the cfg objects the drivers already hold, not through the config
    // db, because the window this arms is the NEXT reset and the drivers are
    // built.
    super.rni_cfg.reset_permitted_high = 1'b1;
    super.snf_cfg.reset_permitted_high = 1'b1;

    this.one_reset_pulse();

    super.rni_cfg.reset_permitted_high = 1'b0;
    super.snf_cfg.reset_permitted_high = 1'b0;

    this.require_silent(VIP_CHI_CHK_LINK_SIDEBAND_IDLE_IN_RESET_E,
                        "TXSACTIVE held high through reset");
    this.require_silent(VIP_CHI_CHK_REQ_IDLE_IN_RESET_E,
                        "TXREQFLITPEND held high through reset");
    this.require_silent(VIP_CHI_CHK_RSP_IDLE_IN_RESET_E,
                        "TXRSPFLITPEND held high through reset");
    this.require_silent(VIP_CHI_CHK_DAT_IDLE_IN_RESET_E,
                        "TXDATFLITPEND held high through reset");

    this.require_evaluated(VIP_CHI_CHK_LINK_SIDEBAND_IDLE_IN_RESET_E,
                           rni_pass_sideband, snf_pass_sideband);
    this.require_evaluated(VIP_CHI_CHK_REQ_IDLE_IN_RESET_E,
                           rni_pass_req, snf_pass_req);
    this.require_evaluated(VIP_CHI_CHK_RSP_IDLE_IN_RESET_E,
                           rni_pass_rsp, snf_pass_rsp);
    this.require_evaluated(VIP_CHI_CHK_DAT_IDLE_IN_RESET_E,
                           rni_pass_dat, snf_pass_dat);

    // -- Phase 3: what the list names. ---------------------------------------
    //
    // Suppress the report, keep the count, at both ends: both are about to be
    // made to fail by the same credit.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_RSP_IDLE_IN_RESET_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_RSP_IDLE_IN_RESET_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    // And the rules the same credit reaches once reset releases, asserted below
    // rather than ignored. The third is the defect named in the header, not
    // collateral.
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_RSP_LCRDV_REQUIRES_LINK_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_RSP_LCRDV_REQUIRES_LINK_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.rni_agent.vif.check_severity[VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E] =
      VIP_CHI_CHK_SEV_OFF_E;
    super.tb_env.snf_agent.vif.check_severity[VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E] =
      VIP_CHI_CHK_SEV_OFF_E;

    // The link has to carry traffic again before the second pulse: the write in
    // phase 1 is what armed the rules, and a reset takes link_ever_active's
    // subject down with it. This also proves the link survived phase 2.
    this.one_write();
    super.wait_clocks(SETTLE_C);

    super.rni_cfg.reset_idle_violation = 1'b1;
    super.snf_cfg.reset_idle_violation = 1'b1;

    this.one_reset_pulse();

    super.rni_cfg.reset_idle_violation = 1'b0;
    super.snf_cfg.reset_idle_violation = 1'b0;

    this.require_reported(VIP_CHI_CHK_RSP_IDLE_IN_RESET_E,
                          "a credit driven through reset");

    // The two rules the same credit reaches after release. Required, not merely
    // bounded: the clocking block carries the parked value into the first judged
    // cycle whatever the driver does with it afterwards, so a silent rule here
    // means the rule stopped looking.
    this.require_reported(VIP_CHI_CHK_RSP_LCRDV_REQUIRES_LINK_E,
                          "a credit still asserted with the link in STOP");
    this.require_reported(VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E,
                          "a credit banked in the pool the link carried into STOP");
    // The activation handshake must be clean through this window. It used to be
    // bounded at one instead: the completer derived its acknowledge from its own
    // link request, and want_link raises that request whenever link_drained() is
    // false -- one credit held through reset is enough -- so the acknowledge
    // could already be up when the peer first asked and the link stepped
    // STOP -> RUN. The acknowledge now answers the peer's observed request, so
    // ACTIVATE is structural and the bound is zero.
    this.require_at_most(VIP_CHI_CHK_LASM_LEGAL_TRANSITION_E, 0);
    this.require_at_most(VIP_CHI_CHK_LASM_ACTIVATE_OBSERVED_E, 0);

    // The other three saw a conformant reset window in phase 3 and must still
    // be silent. A rule that reports the RSP credit on the DAT channel would be
    // reading the wrong wire and phase 3 alone could not tell.
    this.require_silent(VIP_CHI_CHK_LINK_SIDEBAND_IDLE_IN_RESET_E,
                        "a reset window whose only offending signal was the RSP credit");
    this.require_silent(VIP_CHI_CHK_REQ_IDLE_IN_RESET_E,
                        "a reset window whose only offending signal was the RSP credit");
    this.require_silent(VIP_CHI_CHK_DAT_IDLE_IN_RESET_E,
                        "a reset window whose only offending signal was the RSP credit");

    // The link must still work after both pulses. A control that leaves the
    // interface broken has not proved the rule, only the stimulus.
    super.rni0_rd_seq.reset();
    super.rni0_rd_seq.set_requests(1);
    super.rni0_rd_seq.set_initial_addr(RESET_IDLE_ADDR_C);
    super.rni0_rd_seq.set_size(SIZE_C);
    super.rni0_rd_seq.set_get_response(1'b1);
    super.rni0_rd_seq.set_verbose(1'b0);
    super.rni0_rd_seq.start(super.v_sqr.rni_sequencer);

    super.wait_clocks(SETTLE_C);

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] the closing sentence of 14.1.3 was driven and reported nowhere (all four rules re-evaluated), the list's TX***LCRDV was driven and reported %0d/%0d time(s) at the RN-I/SN-F, its two post-release rules %0d/%0d and %0d/%0d, and the link carried a read afterwards",
      super.tc_name,
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_IDLE_IN_RESET_E],
      super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_IDLE_IN_RESET_E],
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_LCRDV_REQUIRES_LINK_E],
      super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_RSP_LCRDV_REQUIRES_LINK_E],
      super.tb_env.rni_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E],
      super.tb_env.snf_agent.vif.check_fail_count[VIP_CHI_CHK_LCRD_QUIESCENT_IN_STOP_E]), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
