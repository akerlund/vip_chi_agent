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

`ifndef VIP_CHI_IF
`define VIP_CHI_IF

import vip_chi_types_pkg::*;

interface vip_chi_if #(
  parameter vip_chi_cfg_t  CFG_P  = VIP_CHI_DEFAULT_CFG_C,
  parameter type FLIT_TYPES_T = vip_chi_types #(CFG_P),
  parameter vip_chi_role_t ROLE_P = VIP_CHI_ROLE_MONITOR_E
  )(
    input clk,
    input rst_n
  );

  typedef FLIT_TYPES_T::vip_chi_req_flit_t  vip_chi_req_flit_t;
  typedef FLIT_TYPES_T::vip_chi_rsp_flit_t  vip_chi_rsp_flit_t;
  typedef FLIT_TYPES_T::vip_chi_resp_flit_t vip_chi_resp_flit_t;
  typedef FLIT_TYPES_T::vip_chi_dat_flit_t  vip_chi_dat_flit_t;
  typedef FLIT_TYPES_T::vip_chi_data_flit_t vip_chi_data_flit_t;
  typedef FLIT_TYPES_T::vip_chi_snp_flit_t  vip_chi_snp_flit_t;
  typedef vip_chi_req_flit_t  req_flit_t;
  typedef vip_chi_resp_flit_t rsp_flit_t;
  typedef vip_chi_data_flit_t dat_flit_t;
  typedef vip_chi_snp_flit_t  snp_flit_t;

  // ---------------------------------------------------------------------------
  // Link state and activation handshake.
  // ---------------------------------------------------------------------------
  logic txlinkactivereq;
  logic txlinkactiveack;
  logic rxlinkactivereq;
  logic rxlinkactiveack;
  logic txsactive;
  logic rxsactive;

  // Per-check pass/fail tallies from the vip_chi_sva and vip_chi_snp_sva binds
  // on this interface, indexed by vip_chi_check_id_t. All zero if nothing is
  // bound.
  //
  // They live HERE rather than in the checkers for two reasons. A SystemVerilog
  // package may not contain a hierarchical reference and the testcases compile
  // into one, so a test could not otherwise read them; and a value that changes
  // every cycle cannot be handed over through the config DB, which carries a
  // snapshot. A test reaches this interface through its agent's virtual handle.
  //
  // This is also what lets an SVA failure FAIL A RUN. The checkers report
  // through plain $error, which does not raise a UVM error, does not set the
  // exit status, and is not read by the regression script -- so before these
  // counters existed, every protocol assertion in the SV port was advisory:
  // it printed into a log nothing consumed. The env reads these at report_phase
  // and raises the uvm_error. Keeping the counting here rather than calling
  // uvm_report_error from the checker preserves the property that vip_chi_sva
  // and vip_chi_if are UVM-free and bindable in a non-UVM bench.
  //
  // The two binds own disjoint check IDs (the SNP checker owns only the
  // CHI_SNP_* range), so their writes never collide.
  int unsigned check_pass_count [VIP_CHI_CHK_NUM_E];
  int unsigned check_fail_count [VIP_CHI_CHK_NUM_E];

  // Per-check enable and severity, initialised by whichever checker owns each
  // ID. Published here for the same reason as the counters: a package may hold
  // no hierarchical reference, so this is the only handle a testcase has on an
  // individual check. A negative-control test turns its own rule down to
  // VIP_CHI_CHK_SEV_OFF_E -- counted, not reported -- which is what replaced the
  // one-off suppression port the LASM control originally needed.
  // check_enabled also doubles as OWNERSHIP, and readers depend on it: only the
  // checker that owns an ID ever sets its entry true, so an ID left false is
  // either switched off or belongs to a bind this interface does not carry. An
  // RN-F interface with no SNP bind therefore reports the CHI_SNP_* rules as
  // neither exercised nor missing, which is right -- listing them would put
  // seven permanent entries in every coherent run's vacuity report.
  bit                      check_enabled  [VIP_CHI_CHK_NUM_E];
  vip_chi_check_severity_t check_severity [VIP_CHI_CHK_NUM_E];

  // ---------------------------------------------------------------------------
  // Observed input race, IHI 0050 E 14.6.3 / D 13.6.3 -- for the DRIVERS on this
  // interface.
  //
  // "For all input race conditions, a component that observes the input race is
  // required to wait for both signals before changing any output signals."
  //
  // Hosted here rather than in each driver for one reason: a race is identified
  // by the STEP the two inputs took, which needs state, and the sideband tasks
  // run from several threads in a cycle. A per-call copy of "last cycle's
  // inputs" collapses the moment two callers coincide -- the same hazard that
  // cost three attempts on the activation stagger. An always_ff runs ONCE per
  // cycle whatever the drivers do, which is the property that makes it correct.
  //
  // It reads only the rx* pair, which this endpoint never drives, so the answer
  // does not depend on when in the cycle a driver asks.
  //
  // THE HOLD LASTS AT MOST ONE CYCLE, and consecutive holds are impossible: a
  // registered hold blocks the combinational term from arming again. That bound is what makes it safe for a caller to WAIT on it (see the
  // one-shot writers in the requester and the homes) rather than only to skip.
  //
  // The bound is also the right model. A race is two signals driven in one cycle
  // and observed in different ones, so the resynchronisation window is a cycle:
  // if the second signal has not arrived by then, what was observed was a peer
  // changing one signal at a time, not a race, and 14.6.3's wait does not apply.
  //
  // vip_chi_sva DELIBERATELY DOES NOT READ THIS and keeps its own copy. A
  // checker that judged the drivers against the drivers' own belief could only
  // ever report that they read the flag correctly: CHI_LASM_INPUT_RACE_HOLD
  // would pass by construction, and a negative control that cannot fail is the
  // failure mode this VIP's per-check mechanism exists to prevent. The
  // duplication IS the independence, which is why the two are written from the
  // specification separately rather than shared.
  // ---------------------------------------------------------------------------
  logic rxreq_prev;
  logic rxack_prev;
  // Combinational: the step just observed at this edge is a forbidden one.
  logic input_race_now;
  // REGISTERED, and this is the one the drivers read. The distinction is the
  // whole timing of the thing: a driver running just after edge N sees raw
  // inputs that have ALREADY advanced past the edge, so the combinational term
  // describes the step from N to N+1, while the drive it is about to issue lands
  // at N+1 and must match N+1's value. The register carries the step that armed
  // the obligation, which is what the drive being issued now has to respect.
  //
  // Reading the combinational term instead puts the hold a cycle early and
  // changes nothing -- measured: the completer still reported its violation.
  // Same lesson as the acknowledge stagger, in a new place: the non-blocking
  // assignment IS the delay, and the delayed copy is the one to consume.
  //
  // THE pyUVM TWIN CONSUMES ITS LIVE TERM, NOT A REGISTERED ONE, and that is
  // correct there rather than a divergence to reconcile. cocotb wakes a
  // coroutine on RisingEdge before non-blocking-style updates have landed, so
  // its raw reads are the PRE-edge values and the live step is already the
  // arming step. A driver here is resumed on a clocking-block event and reads
  // wires that have advanced past the edge. Measured both ways round in both
  // ports: each at the other's term leaves the completer's violation in place.
  logic input_race_hold;

  // TRUE when the peer's two outputs arrived in an order 14.6.3 forbids.
  // Two-state comparisons throughout: X -> 0 is not a deassertion, and an
  // undriven peer must not read as a race.
  function automatic bit input_race_step();
    if ((rxack_prev === 1'b0) && (rxlinkactiveack === 1'b1) &&
        (rxlinkactivereq !== 1'b1)) begin
      return 1'b1;
    end
    if ((rxack_prev === 1'b1) && (rxlinkactiveack === 1'b0) &&
        (rxlinkactivereq !== 1'b0)) begin
      return 1'b1;
    end
    if ((rxreq_prev === 1'b0) && (rxlinkactivereq === 1'b1) &&
        (rxlinkactiveack !== 1'b0)) begin
      return 1'b1;
    end
    if ((rxreq_prev === 1'b1) && (rxlinkactivereq === 1'b0) &&
        (rxlinkactiveack !== 1'b1)) begin
      return 1'b1;
    end
    return 1'b0;
  endfunction

  always_comb begin
    bit changed;
    changed = ((rxlinkactivereq === 1'b1) !== rxreq_prev) ||
              ((rxlinkactiveack === 1'b1) !== rxack_prev);
    // RESOLVE TAKES PRECEDENCE OVER ARM: an armed race is closed by the next
    // input change whatever it is, because that change IS the arrival of the
    // other signal, and only an unarmed step can open a new one. The second half
    // of a raced pair is itself out of order almost by definition, so arming on
    // it would chain one race into a permanent hold.
    input_race_now = changed && !input_race_hold && input_race_step();
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      // 14.1.3 has both peers holding the sideband idle through reset, so
      // nothing is in flight and a race carried across would freeze the
      // bring-up that follows.
      rxreq_prev      <= 1'b0;
      rxack_prev      <= 1'b0;
      input_race_hold <= 1'b0;
    end
    else begin
      rxreq_prev      <= (rxlinkactivereq === 1'b1);
      rxack_prev      <= (rxlinkactiveack === 1'b1);
      input_race_hold <= input_race_now;
    end
  end

  // ---------------------------------------------------------------------------
  // Request channel.
  // ---------------------------------------------------------------------------
  logic      txreqflitpend;
  logic      txreqflitv;
  req_flit_t txreqflit;
  logic      txreqlcrdv;

  logic      rxreqflitpend;
  logic      rxreqflitv;
  req_flit_t rxreqflit;
  logic      rxreqlcrdv;

  // ---------------------------------------------------------------------------
  // Response channel.
  // ---------------------------------------------------------------------------
  logic      txrspflitpend;
  logic      txrspflitv;
  rsp_flit_t txrspflit;
  logic      txrsplcrdv;

  logic      rxrspflitpend;
  logic      rxrspflitv;
  rsp_flit_t rxrspflit;
  logic      rxrsplcrdv;

  // ---------------------------------------------------------------------------
  // Data channel.
  // ---------------------------------------------------------------------------
  logic      txdatflitpend;
  logic      txdatflitv;
  dat_flit_t txdatflit;
  logic      txdatlcrdv;

  logic      rxdatflitpend;
  logic      rxdatflitv;
  dat_flit_t rxdatflit;
  logic      rxdatlcrdv;

  // ---------------------------------------------------------------------------
  // Snoop channel (Tier C). Flows home (HN-F) -> requester (RN-F) -- opposite
  // REQ. Only ROLE_P==HNF sources snoops (drives txsnp*); only ROLE_P==RNF
  // receives them and returns SNP receive-credit (drives txsnplcrdv). Every
  // other role keeps the channel tied idle (see the tie-off generate below), so
  // links carrying no coherent traffic present a quiescent SNP channel.
  // ---------------------------------------------------------------------------
  logic      txsnpflitpend;
  logic      txsnpflitv;
  snp_flit_t txsnpflit;
  logic      txsnplcrdv;

  logic      rxsnpflitpend;
  logic      rxsnpflitv;
  snp_flit_t rxsnpflit;
  logic      rxsnplcrdv;

  generate
    if (ROLE_P != VIP_CHI_ROLE_HNF_E) begin: g_snp_tx_idle
      assign txsnpflitpend = 1'b0;
      assign txsnpflitv    = 1'b0;
      assign txsnpflit     = '0;
    end
    if (ROLE_P != VIP_CHI_ROLE_RNF_E) begin: g_snp_crd_idle
      assign txsnplcrdv    = 1'b0;
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Passive monitor clocking block.
  // ---------------------------------------------------------------------------
  clocking monitor_cb @(posedge clk);

    default input #1step;

    input txlinkactivereq;
    input txlinkactiveack;
    input rxlinkactivereq;
    input rxlinkactiveack;
    input txsactive;
    input rxsactive;

    input txreqflitpend;
    input txreqflitv;
    input txreqflit;
    input txreqlcrdv;
    input rxreqflitpend;
    input rxreqflitv;
    input rxreqflit;
    input rxreqlcrdv;

    input txrspflitpend;
    input txrspflitv;
    input txrspflit;
    input txrsplcrdv;
    input rxrspflitpend;
    input rxrspflitv;
    input rxrspflit;
    input rxrsplcrdv;

    input txdatflitpend;
    input txdatflitv;
    input txdatflit;
    input txdatlcrdv;
    input rxdatflitpend;
    input rxdatflitv;
    input rxdatflit;
    input rxdatlcrdv;

    input txsnpflitpend;
    input txsnpflitv;
    input txsnpflit;
    input txsnplcrdv;
    input rxsnpflitpend;
    input rxsnpflitv;
    input rxsnpflit;
    input rxsnplcrdv;
  endclocking

  modport monitor (clocking monitor_cb, input clk, input rst_n);

  // ---------------------------------------------------------------------------
  // Raw-signal modports. Active drivers typically use the role-gated clocking
  // blocks below, but these modports are useful for structural hookups.
  // ---------------------------------------------------------------------------
  modport snf (
    input  clk,
    input  rst_n,
    output txlinkactivereq,
    output txlinkactiveack,
    input  rxlinkactivereq,
    input  rxlinkactiveack,
    output txsactive,
    input  rxsactive,
    input  rxreqflitpend,
    input  rxreqflitv,
    input  rxreqflit,
    output txreqlcrdv,
    output txrspflitpend,
    output txrspflitv,
    output txrspflit,
    output txrsplcrdv,
    input  rxrspflitpend,
    input  rxrspflitv,
    input  rxrspflit,
    input  rxrsplcrdv,
    output txdatflitpend,
    output txdatflitv,
    output txdatflit,
    output txdatlcrdv,
    input  rxdatflitpend,
    input  rxdatflitv,
    input  rxdatflit,
    input  rxdatlcrdv
  );

  modport rni (
    input  clk,
    input  rst_n,
    output txlinkactivereq,
    output txlinkactiveack,
    input  rxlinkactivereq,
    input  rxlinkactiveack,
    output txsactive,
    input  rxsactive,
    output txreqflitpend,
    output txreqflitv,
    output txreqflit,
    input  rxreqlcrdv,
    output txrspflitpend,
    output txrspflitv,
    output txrspflit,
    output txrsplcrdv,
    input  rxrspflitpend,
    input  rxrspflitv,
    input  rxrspflit,
    input  rxrsplcrdv,
    output txdatflitpend,
    output txdatflitv,
    output txdatflit,
    output txdatlcrdv,
    input  rxdatflitpend,
    input  rxdatflitv,
    input  rxdatflit,
    input  rxdatlcrdv
  );

  // ---------------------------------------------------------------------------
  // Role-gated driving clocking blocks. This mirrors the vip_axi4_if pattern:
  // only the active role's clocking block is elaborated, which avoids giving
  // both sides a procedural-driver context on the same signals.
  // ---------------------------------------------------------------------------
  generate

    if (ROLE_P == VIP_CHI_ROLE_SNF_E) begin: g_drv

      clocking snf_cb @(posedge clk);

        default input #1step output #0;

        output txlinkactivereq;
        output txlinkactiveack;
        input  rxlinkactivereq;
        input  rxlinkactiveack;
        output txsactive;
        input  rxsactive;

        input  rxreqflitpend;
        input  rxreqflitv;
        input  rxreqflit;
        output txreqlcrdv;

        output txrspflitpend;
        output txrspflitv;
        output txrspflit;
        output txrsplcrdv;
        input  rxrspflitpend;
        input  rxrspflitv;
        input  rxrspflit;
        input  rxrsplcrdv;

        output txdatflitpend;
        output txdatflitv;
        output txdatflit;
        output txdatlcrdv;
        input  rxdatflitpend;
        input  rxdatflitv;
        input  rxdatflit;
        input  rxdatlcrdv;
      endclocking
    end
    else if (ROLE_P == VIP_CHI_ROLE_HNI_E) begin: g_drv

      // HN-I RN-facing side. A home node sits between an RN and an SN, so on the
      // link that faces the RN it plays the completer/subordinate role: it
      // receives REQ, sources RSP/DAT completions, and grants inbound REQ/RSP/
      // DAT credits. Those directions are identical to the SN-F clocking block,
      // so this mirrors snf_cb verbatim. The SN-facing side of the same proxy
      // uses a separate ROLE_P=RNI interface (rni_cb) to act as the requester.
      clocking hni_cb @(posedge clk);

        default input #1step output #0;

        output txlinkactivereq;
        output txlinkactiveack;
        input  rxlinkactivereq;
        input  rxlinkactiveack;
        output txsactive;
        input  rxsactive;

        input  rxreqflitpend;
        input  rxreqflitv;
        input  rxreqflit;
        output txreqlcrdv;

        output txrspflitpend;
        output txrspflitv;
        output txrspflit;
        output txrsplcrdv;
        input  rxrspflitpend;
        input  rxrspflitv;
        input  rxrspflit;
        input  rxrsplcrdv;

        output txdatflitpend;
        output txdatflitv;
        output txdatflit;
        output txdatlcrdv;
        input  rxdatflitpend;
        input  rxdatflitv;
        input  rxdatflit;
        input  rxdatlcrdv;
      endclocking
    end
    else if (ROLE_P == VIP_CHI_ROLE_RNI_E) begin: g_drv

      clocking rni_cb @(posedge clk);

        default input #1step output #0;

        output txlinkactivereq;
        output txlinkactiveack;
        input  rxlinkactivereq;
        input  rxlinkactiveack;
        output txsactive;
        input  rxsactive;

        output txreqflitpend;
        output txreqflitv;
        output txreqflit;
        input  rxreqlcrdv;

        output txrspflitpend;
        output txrspflitv;
        output txrspflit;
        output txrsplcrdv;
        input  rxrspflitpend;
        input  rxrspflitv;
        input  rxrspflit;
        input  rxrsplcrdv;

        output txdatflitpend;
        output txdatflitv;
        output txdatflit;
        output txdatlcrdv;
        input  rxdatflitpend;
        input  rxdatflitv;
        input  rxdatflit;
        input  rxdatlcrdv;
      endclocking
    end
    else if (ROLE_P == VIP_CHI_ROLE_RNF_E) begin: g_drv

      // Coherent requester (RN-F). It plays the requester on REQ/RSP/DAT exactly
      // like an RN-I, so this clocking block is a SUPERSET of rni_cb and is named
      // rni_cb on purpose: the RN-F driver extends vip_chi_driver_rni, whose body
      // references g_drv.rni_cb, and that body binds unchanged here. The superset
      // adds the SNP receive channel (snoops flow home->RN-F) plus the RN-F's own
      // SNP receive-credit output. Snoop RESPONSES go back out on txrsp/txdat,
      // which rni_cb already carries -- no extra SNP-tx is needed on this side.
      clocking rni_cb @(posedge clk);

        default input #1step output #0;

        output txlinkactivereq;
        output txlinkactiveack;
        input  rxlinkactivereq;
        input  rxlinkactiveack;
        output txsactive;
        input  rxsactive;

        output txreqflitpend;
        output txreqflitv;
        output txreqflit;
        input  rxreqlcrdv;

        output txrspflitpend;
        output txrspflitv;
        output txrspflit;
        output txrsplcrdv;
        input  rxrspflitpend;
        input  rxrspflitv;
        input  rxrspflit;
        input  rxrsplcrdv;

        output txdatflitpend;
        output txdatflitv;
        output txdatflit;
        output txdatlcrdv;
        input  rxdatflitpend;
        input  rxdatflitv;
        input  rxdatflit;
        input  rxdatlcrdv;

        // Inbound snoops (home -> RN-F) + this RN-F's SNP receive-credit grant.
        input  rxsnpflitpend;
        input  rxsnpflitv;
        input  rxsnpflit;
        output txsnplcrdv;
      endclocking
    end
    else if (ROLE_P == VIP_CHI_ROLE_HNF_E) begin: g_drv

      // Coherent home node (HN-F). Toward each RN-F it is the completer, so on
      // REQ/RSP/DAT this mirrors hni_cb (receive REQ, source RSP/DAT, grant the
      // inbound REQ/RSP/DAT credits). It additionally SOURCES snoops on the SNP
      // channel (home -> RN-F) and consumes the RN-F's SNP receive-credit.
      clocking hnf_cb @(posedge clk);

        default input #1step output #0;

        output txlinkactivereq;
        output txlinkactiveack;
        input  rxlinkactivereq;
        input  rxlinkactiveack;
        output txsactive;
        input  rxsactive;

        input  rxreqflitpend;
        input  rxreqflitv;
        input  rxreqflit;
        output txreqlcrdv;

        output txrspflitpend;
        output txrspflitv;
        output txrspflit;
        output txrsplcrdv;
        input  rxrspflitpend;
        input  rxrspflitv;
        input  rxrspflit;
        input  rxrsplcrdv;

        output txdatflitpend;
        output txdatflitv;
        output txdatflit;
        output txdatlcrdv;
        input  rxdatflitpend;
        input  rxdatflitv;
        input  rxdatflit;
        input  rxdatlcrdv;

        // Outbound snoops (HN-F -> RN-F) + inbound SNP send-credit from the RN-F.
        output txsnpflitpend;
        output txsnpflitv;
        output txsnpflit;
        input  rxsnplcrdv;
      endclocking
    end
  endgenerate

endinterface

`endif