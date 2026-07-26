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

`ifndef VIP_CHI_COHERENCY_CHECKER
`define VIP_CHI_COHERENCY_CHECKER

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Checker D -- coherency invariants, self-derived from observed traffic.
//
// A standalone checker (a sibling of vip_chi_scoreboard, not folded into it, so
// the delicate A/B/C machinery is untouched). It subscribes to the coherent
// RN-F streams and maintains a per-line, per-node ownership shadow built ONLY
// from what it sees on the wire -- never from the HN-F directory it is meant to
// police:
//   * a coherent-read REQ opens a pending read (TxnID -> line, unique?),
//   * the matching CompData resolves it: the granting state becomes that node's
//     held state for the line,
//   * an observed snoop transitions the snooped node's state (invalidate ->
//     Invalid, shared-class -> Shared).
//
// Core invariant (n_multi_owner): a line may have at most ONE node in a Unique
// state at any time. A second Unique holder with no intervening invalidate is a
// coherency violation. The negative control tc_chi_coherency_negctl forces
// exactly that (HN-F snoop suppression) and fails unless this fires -- so the
// check is provably not vacuous.
//
// N_NODES_C is fixed at 2 to match the coherent bench (two RN-F), mirroring the
// scoreboard's hrni0/hrni1 dual-stream shape.
// -----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_rnf0_req_cc)
`uvm_analysis_imp_decl(_rnf0_rsp_cc)
`uvm_analysis_imp_decl(_rnf0_dat_cc)
`uvm_analysis_imp_decl(_rnf0_snp_cc)
`uvm_analysis_imp_decl(_rnf1_req_cc)
`uvm_analysis_imp_decl(_rnf1_rsp_cc)
`uvm_analysis_imp_decl(_rnf1_dat_cc)
`uvm_analysis_imp_decl(_rnf1_snp_cc)
`uvm_analysis_imp_decl(_snf_req_cc)
`uvm_analysis_imp_decl(_snf_dat_cc)

class vip_chi_coherency_checker #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends uvm_component;

  typedef vip_chi_item #(CFG_P) item_t;
  typedef item_t::txn_id_t      txn_id_t;
  typedef item_t::data_t        data_t;

  localparam int N_NODES_C = 2;

  bit enable = 1'b1;

  uvm_analysis_imp_rnf0_req_cc #(item_t, vip_chi_coherency_checker #(CFG_P)) rnf0_req_cc;
  uvm_analysis_imp_rnf0_rsp_cc #(item_t, vip_chi_coherency_checker #(CFG_P)) rnf0_rsp_cc;
  uvm_analysis_imp_rnf0_dat_cc #(item_t, vip_chi_coherency_checker #(CFG_P)) rnf0_dat_cc;
  uvm_analysis_imp_rnf0_snp_cc #(item_t, vip_chi_coherency_checker #(CFG_P)) rnf0_snp_cc;
  uvm_analysis_imp_rnf1_req_cc #(item_t, vip_chi_coherency_checker #(CFG_P)) rnf1_req_cc;
  uvm_analysis_imp_rnf1_rsp_cc #(item_t, vip_chi_coherency_checker #(CFG_P)) rnf1_rsp_cc;
  uvm_analysis_imp_rnf1_dat_cc #(item_t, vip_chi_coherency_checker #(CFG_P)) rnf1_dat_cc;
  uvm_analysis_imp_rnf1_snp_cc #(item_t, vip_chi_coherency_checker #(CFG_P)) rnf1_snp_cc;
  // Downstream SN-F streams: its ReadNoSnp REQ (addr) + CompData (value) let the
  // checker seed the authoritative line-data shadow from what the SN-F actually
  // returned, so a downstream-fetched RN-F CompData is integrity-checked end to end.
  uvm_analysis_imp_snf_req_cc #(item_t, vip_chi_coherency_checker #(CFG_P)) snf_req_cc;
  uvm_analysis_imp_snf_dat_cc #(item_t, vip_chi_coherency_checker #(CFG_P)) snf_dat_cc;

  // Per-node open coherent reads (parallel maps keyed [node][TxnID], no struct).
  protected longint open_rd_line [N_NODES_C][longint];
  protected bit     open_rd_uniq [N_NODES_C][longint];

  // Per-line, per-node held state (packed 3 bits/node; '0 == all Invalid).
  protected logic [N_NODES_C-1:0][2:0] line_state [longint];

  // Data-integrity shadow: the authoritative beats for a line, established ONLY
  // by an observed write-to-home (CopyBackWrData) or dirty forward (SnpRespData).
  // A coherent read's CompData for a line whose data is known must match it. A
  // line whose data was never observed being written (e.g. a home-synthesized
  // read) is absent here and left unchecked -- predictable-only, like Checker C.
  protected data_t line_data [longint][];
  // Correlate a writeback's later CopyBackWrData back to its line (keyed by the
  // DBID, which equals the writeback REQ TxnID) and a snoop's later SnpRespData
  // back to its line (the HN-F engine is serial, so at most one snoop per node
  // is outstanding -- track the most recent line snooped on each node).
  protected longint open_wb_line   [N_NODES_C][longint];
  protected longint pending_snp_line [N_NODES_C];
  protected bit     pending_snp_valid [N_NODES_C];

  // Downstream SN-F read correlation: a ReadNoSnp REQ (addr) -> its line, keyed by
  // the downstream TxnID, so the SN-F's later CompData establishes the line-data
  // shadow (the authoritative value the two-level hierarchy fetched).
  protected longint dn_rd_line [longint];

  // Exclusive (LL/SC) monitor shadow, self-derived from observed traffic ONLY
  // (never the HN-F's own monitor -- the checker must be able to catch the home
  // lying). excl_ll_valid[node][line] becomes 1 when an exclusive load on that
  // node completed with ExclOkay, and stays 1 until an intervening conflict is
  // observed: an invalidating snoop to the node, or a store to the line by any
  // node. The exclusive store (CleanUnique+excl) it gates consumes it. Absent /
  // 0 means "no continuously-valid reservation". open_rd_excl / open_sc_line
  // correlate an in-flight exclusive REQ (by TxnID) to its later completion (the
  // LL result rides CompData on DAT; the SC result rides Comp on RSP).
  protected bit     excl_ll_valid [N_NODES_C][longint];
  protected bit     open_rd_excl  [N_NODES_C][longint];
  protected bit     open_sc_excl  [N_NODES_C][longint];
  protected longint open_sc_line  [N_NODES_C][longint];
  // MakeUnique completes on an RSP-only Comp (no CompData), so its unique grant is
  // resolved on the RSP stream, not obs_dat. Remember the line per (node,TxnID) at
  // the REQ so obs_rsp can mark the requester Unique and run the single-writer
  // check -- otherwise a suppressed-snoop MakeUnique duplicate owner goes unseen. [F1]
  protected longint open_mu_line  [N_NODES_C][longint];

  // Why a reservation was last broken, recorded on the 1->0 transition (root
  // cause: the FIRST clear wins, so a remote store that both snoops and stores is
  // attributed to the store). Read at the SC resolution point to drive coverage.
  typedef enum bit [1:0] {
    EXCL_CLEAR_NONE  = 2'd0,  // reservation never broken (a winning SC)
    EXCL_CLEAR_STORE = 2'd1,  // broken by a store/invalidate REQ to the line
    EXCL_CLEAR_SNOOP = 2'd2   // broken by an invalidating snoop to the node
  } excl_clear_cause_e;
  protected excl_clear_cause_e excl_clear_cause [N_NODES_C][longint];

  protected int n_multi_owner;
  protected int n_completions;
  protected int n_snoops;
  protected int n_coherent_data_mismatch;
  protected int n_excl_violation;
  protected int n_bad_make_unique;

  // cg_excl samples (SC outcome x clear-cause), set at the obs_rsp resolution.
  protected bit                excl_result_sample;  // 1 = ExclOkay (won), 0 = fail
  protected excl_clear_cause_e excl_cause_sample;

  // Coherent coverage (Tier C). These groups need the from/to line state, so
  // they live here on the self-derived shadow rather than in vip_chi_coverage
  // (which is flit-level and holds no per-line state). Sampled at the exact
  // transition points -- a snoop-induced state change, and the sharer count
  // after every state update.
  protected vip_chi_resp_t       ct_from_sample;
  protected item_t::snp_opcode_t ct_snp_opcode_sample;
  protected vip_chi_resp_t       ct_to_sample;
  protected int unsigned         occ_sharers_sample;

  covergroup cg_cache_transition;
    option.per_instance = 1;

    // A snoop only ever targets a HELD line -- the HN-F never snoops an Invalid
    // holder -- and this model never produces the Shared-Dirty (SD) state (a grant
    // is SC/UC/UD and snoop_result() only ever yields SC or I). So the snooped
    // from-state is always one of {SC, UC, UD}; I and SD are left unbinned.
    cp_from: coverpoint this.ct_from_sample {
      bins sc  = {VIP_CHI_RESP_STATE_SC_E};
      bins uc  = {VIP_CHI_RESP_STATE_UC_E};
      bins ud  = {VIP_CHI_RESP_STATE_UP_PD_DIRTY_E};
    }

    // Only the state-changing snoops this HN-F actually originates are binned.
    // SnpClean / SnpCleanShared are never originated (see the HN-F snoop sites),
    // and SnpOnce / the fwd variants are snapshots or carry the same result via a
    // separate DCT path -- none is a distinct state transition, so they are left
    // unbinned (SV ignores coverpoint values outside the listed bins) rather than
    // diluting the report with permanently-unreachable bins.
    cp_snp: coverpoint this.ct_snp_opcode_sample {
      bins snp_shared        = {VIP_CHI_SNP_SHARED_C};
      bins snp_unique        = {VIP_CHI_SNP_UNIQUE_C};
      bins snp_clean_invalid = {VIP_CHI_SNP_CLEAN_INVALID_C};
      bins snp_make_invalid  = {VIP_CHI_SNP_MAKE_INVALID_C};
    }

    // The binned (state-changing) snoops resolve a held line to exactly SC
    // (downgrade) or I (invalidate) -- snoop_result() never yields a Unique/Dirty
    // to-state. Snapshot snoops such as SnpOnce leave the holder unchanged; obs_snp
    // updates the shadow state for them, but does not sample this transition
    // covergroup because they are not state transitions. So the reachable to-states
    // for sampled transitions are {SC, I}.
    cp_to: coverpoint this.ct_to_sample {
      bins inv = {VIP_CHI_RESP_STATE_I_E};
      bins sc  = {VIP_CHI_RESP_STATE_SC_E};
      // [F3] snoop_result() only ever downgrades (-> SC) or invalidates (-> I); a
      // snoop can NEVER upgrade a holder. Guard the reduced bin set: if a future
      // miswire ever produces a Unique/Dirty to-state it lands here and is flagged,
      // instead of silently vanishing as an unbinned value (which would leave the
      // 11-bin denominator looking fully closed while masking the bug).
      illegal_bins never_upgrades = {VIP_CHI_RESP_STATE_UC_E,
                                     VIP_CHI_RESP_STATE_UP_PD_DIRTY_E,
                                     VIP_CHI_RESP_STATE_SD_PD_DIRTY_E};
    }

    // The snoop-induced transition is a pure function of (from-state, snoop) --
    // see snoop_result(): SnpShared downgrades a Unique holder to SC, and the
    // invalidating snoops (SnpUnique/CleanInvalid/MakeInvalid) drop a held line to
    // I. A ReadShared does not snoop an already-Shared holder (no downgrade
    // needed), so SnpShared is only ever sent to a UC/UD holder. That leaves
    // exactly 11 reachable (from,snoop,to) tuples: {UC,UD}xSnpShared->SC, and
    // {SC,UC,UD}x{SnpUnique,SnpCleanInvalid,SnpMakeInvalid}->I. Everything else is
    // ignored (this FSM cannot produce it) or illegal (a mis-wire), so the report
    // reflects the real transition space rather than a diluted fraction.
    cx_from_snp_to: cross cp_from, cp_snp, cp_to {
      // SnpShared retains a held line Shared (-> SC), never invalidates it.
      ignore_bins shared_snp_keeps_sc =
        binsof(cp_snp.snp_shared) && binsof(cp_to.inv);
      // A ReadShared never snoops an already-Shared holder, so SnpShared is only
      // ever sent to a Unique (UC/UD) holder -- never a from-SC.
      ignore_bins shared_snp_only_to_unique_holder =
        binsof(cp_snp.snp_shared) && binsof(cp_from.sc);
      // Invalidating snoops drop a held line to I, never leave it SC.
      ignore_bins inval_snp_reaches_i =
        binsof(cp_snp) intersect {VIP_CHI_SNP_UNIQUE_C,
                                  VIP_CHI_SNP_CLEAN_INVALID_C,
                                  VIP_CHI_SNP_MAKE_INVALID_C}
        && binsof(cp_to.sc);
    }
  endgroup

  covergroup cg_directory_occupancy;
    option.per_instance = 1;

    cp_sharers: coverpoint this.occ_sharers_sample {
      bins none = {0};
      bins one  = {1};
      bins two  = {2};
      // A line can be held by at most N_NODES_C nodes; a higher count means the
      // shadow double-counted an owner -- flag it rather than silently drop it.
      illegal_bins over_subscribed = {[N_NODES_C+1:$]};
    }
  endgroup

  // Exclusive (LL/SC) outcome coverage. State-dependent (the clear-cause needs
  // the per-(node,line) shadow), so it lives here on Checker D's shadow rather
  // than in the flit-level vip_chi_coverage. Sampled once per exclusive SC at the
  // obs_rsp resolution point, alongside the invariant check.
  covergroup cg_excl;
    option.per_instance = 1;

    cp_result: coverpoint this.excl_result_sample {
      bins fail    = {1'b0};  // NormalOkay: the SC lost
      bins success = {1'b1};  // ExclOkay:   the SC won
    }

    cp_cause: coverpoint this.excl_cause_sample {
      bins none     = {EXCL_CLEAR_NONE};
      bins by_store = {EXCL_CLEAR_STORE};
      bins by_snoop = {EXCL_CLEAR_SNOOP};
    }

    cx_result_cause: cross cp_result, cp_cause {
      // Legal space: a won SC always had an intact reservation (cause NONE); a
      // lost SC was broken by a store or a snoop, never NONE. The remaining
      // combinations are only producible by the forced-success negative control
      // (success with a cleared monitor) -- not real coverage, so ignore them.
      ignore_bins won_but_cleared =
        binsof(cp_result.success) &&
        binsof(cp_cause) intersect {EXCL_CLEAR_STORE, EXCL_CLEAR_SNOOP};
      ignore_bins lost_but_intact =
        binsof(cp_result.fail) && binsof(cp_cause.none);
    }
  endgroup

  // Two-level hierarchy: the downstream request kinds the HN-F issues to the SN-F
  // -- a directory/mem-miss fetch (ReadNoSnp) and a writeback flush
  // (WriteNoSnpFull). Sampled from the observed SN-F REQ stream.
  protected vip_chi_req_opcode_t dn_req_op_sample;
  covergroup cg_hnf_downstream;
    option.per_instance = 1;
    cp_dn_op: coverpoint this.dn_req_op_sample {
      bins miss_fetch      = {VIP_CHI_REQ_READ_NO_SNP_E};
      bins writeback_flush = {VIP_CHI_REQ_WRITE_NO_SNP_FULL_E};
    }
  endgroup

  `uvm_component_param_utils(vip_chi_coherency_checker #(CFG_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.rnf0_req_cc = new("rnf0_req_cc", this);
    this.rnf0_rsp_cc = new("rnf0_rsp_cc", this);
    this.rnf0_dat_cc = new("rnf0_dat_cc", this);
    this.rnf0_snp_cc = new("rnf0_snp_cc", this);
    this.rnf1_req_cc = new("rnf1_req_cc", this);
    this.rnf1_rsp_cc = new("rnf1_rsp_cc", this);
    this.rnf1_dat_cc = new("rnf1_dat_cc", this);
    this.rnf1_snp_cc = new("rnf1_snp_cc", this);
    this.snf_req_cc  = new("snf_req_cc", this);
    this.snf_dat_cc  = new("snf_dat_cc", this);
    this.cg_cache_transition = new();
    this.cg_directory_occupancy = new();
    this.cg_excl = new();
    this.cg_hnf_downstream = new();
  endfunction

  // ---------------------------------------------------------------------------
  // Clear the shadow after a reset pulse.
  // ---------------------------------------------------------------------------
  function void handle_reset();
    foreach (this.open_rd_line[n]) begin
      this.open_rd_line[n].delete();
      this.open_rd_uniq[n].delete();
      this.open_wb_line[n].delete();
      this.open_rd_excl[n].delete();
      this.open_sc_excl[n].delete();
      this.open_sc_line[n].delete();
      this.open_mu_line[n].delete();
      this.excl_ll_valid[n].delete();
      this.excl_clear_cause[n].delete();
      this.pending_snp_valid[n] = 1'b0;
    end
    this.line_state.delete();
    this.line_data.delete();
    this.dn_rd_line.delete();
    this.n_multi_owner = 0;
    this.n_completions = 0;
    this.n_snoops      = 0;
    this.n_coherent_data_mismatch = 0;
    this.n_excl_violation         = 0;
    this.n_bad_make_unique        = 0;
  endfunction

  // ---------------------------------------------------------------------------
  // Line-align (byte address -> line key). Keyed on the 64 B cache line
  // (VIP_CHI_CACHE_LINE_BYTES_C), not the data-bus width, so the ownership
  // shadow agrees with the RN-F/HN-F line keys for a multi-beat line on a narrow
  // bus (P1).
  // ---------------------------------------------------------------------------
  protected function longint line_of(input longint addr);
    return addr & ~longint'(VIP_CHI_CACHE_LINE_BYTES_C - 1);
  endfunction

  // ---------------------------------------------------------------------------
  // Coherent-read classification, in the wide opcode domain (CHI-D's narrow
  // req opcode would alias if compared down-cast).
  // ---------------------------------------------------------------------------
  protected function bit is_coherent_read(input item_t item, output bit is_unique);
    vip_chi_req_opcode_t op;
    op = vip_chi_req_opcode_t'(item.opcode);
    // MakeReadUnique acquires Unique + data, so it is a unique coherent read for
    // the single-writer and data-integrity invariants.
    is_unique = (op == VIP_CHI_REQ_READ_UNIQUE_E) ||
                (op == VIP_CHI_REQ_MAKE_READ_UNIQUE_E);
    return (op inside {VIP_CHI_REQ_READ_SHARED_E,
                       VIP_CHI_REQ_READ_CLEAN_E,
                       VIP_CHI_REQ_READ_UNIQUE_E,
                       VIP_CHI_REQ_MAKE_READ_UNIQUE_E});
  endfunction

  protected function bit state_is_unique(input vip_chi_resp_t s);
    return (s == VIP_CHI_RESP_STATE_UC_E) || (s == VIP_CHI_RESP_STATE_UP_PD_DIRTY_E);
  endfunction

  // ---------------------------------------------------------------------------
  // Set one node's held state for a line.
  // ---------------------------------------------------------------------------
  protected function void set_node_state(input longint line, input int node, input vip_chi_resp_t st);
    logic [N_NODES_C-1:0][2:0] e;
    e = this.line_state.exists(line) ? this.line_state[line] : '0;
    e[node] = st;
    this.line_state[line] = e;
  endfunction

  // ---------------------------------------------------------------------------
  // The single-writer invariant: at most one Unique owner per line.
  // ---------------------------------------------------------------------------
  protected function void check_multi_owner(input longint line);
    logic [N_NODES_C-1:0][2:0] e;
    int cnt;

    if (!this.line_state.exists(line)) begin
      return;
    end
    e   = this.line_state[line];
    cnt = 0;
    for (int k = 0; k < N_NODES_C; k++) begin
      if (this.state_is_unique(vip_chi_resp_t'(e[k]))) begin
        cnt++;
      end
    end

    if (cnt > 1) begin
      this.n_multi_owner++;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: line 0x%0h has %0d Unique owners simultaneously",
        line, cnt))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Sharer count for a line: nodes holding it in any non-Invalid state.
  // ---------------------------------------------------------------------------
  protected function int unsigned sharer_count(input longint line);
    logic [N_NODES_C-1:0][2:0] e;
    int unsigned cnt;
    if (!this.line_state.exists(line)) begin
      return 0;
    end
    e   = this.line_state[line];
    cnt = 0;
    for (int k = 0; k < N_NODES_C; k++) begin
      if (vip_chi_resp_t'(e[k]) != VIP_CHI_RESP_STATE_I_E) begin
        cnt++;
      end
    end
    return cnt;
  endfunction

  protected function void sample_occupancy(input longint line);
    if (!this.enable) begin
      return;
    end
    this.occ_sharers_sample = this.sharer_count(line);
    this.cg_directory_occupancy.sample();
  endfunction

  // ---------------------------------------------------------------------------
  // Resulting state of a snooped node for the clean snoop opcodes.
  // ---------------------------------------------------------------------------
  protected function vip_chi_resp_t snoop_result(
    input item_t::snp_opcode_t snp_opcode,
    input vip_chi_resp_t       current
  );
    case (snp_opcode)
      VIP_CHI_SNP_SHARED_C, VIP_CHI_SNP_CLEAN_C, VIP_CHI_SNP_CLEAN_SHARED_C,
      // Forwarding shared-family snoops downgrade the snoopee to SC, same as their
      // non-fwd counterparts (the fwd changes where the data goes, not the state).
      VIP_CHI_SNP_SHARED_FWD_C, VIP_CHI_SNP_CLEAN_FWD_C,
      VIP_CHI_SNP_NOT_SHARED_DIRTY_FWD_C:
        return (current == VIP_CHI_RESP_STATE_I_E) ? VIP_CHI_RESP_STATE_I_E
                                                   : VIP_CHI_RESP_STATE_SC_E;
      VIP_CHI_SNP_UNIQUE_C, VIP_CHI_SNP_CLEAN_INVALID_C, VIP_CHI_SNP_MAKE_INVALID_C,
      // A forwarding unique snoop invalidates the snoopee (it hands ownership on).
      VIP_CHI_SNP_UNIQUE_FWD_C:
        return VIP_CHI_RESP_STATE_I_E;
      default:
        // SnpOnce / SnpOnceFwd (snapshot) and anything else: no state change.
        return current;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE for the snoops binned by cg_cache_transition. Snapshot/data-forwarding
  // snoops are still applied to the shadow state, but are intentionally not
  // sampled as state transitions.
  // ---------------------------------------------------------------------------
  protected function bit snoop_samples_cache_transition(input item_t::snp_opcode_t snp_opcode);
    case (snp_opcode)
      VIP_CHI_SNP_SHARED_C,
      VIP_CHI_SNP_UNIQUE_C,
      VIP_CHI_SNP_CLEAN_INVALID_C,
      VIP_CHI_SNP_MAKE_INVALID_C: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Record the authoritative beats for a line (from an observed write to home).
  // ---------------------------------------------------------------------------
  protected function void record_line_data(input longint line, input item_t item);
    this.line_data[line] = new[item.data.size()];
    foreach (item.data[i]) begin
      this.line_data[line][i] = item.data[i];
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Data-integrity check: a coherent read of a line whose data is known (was
  // observed being written) must return exactly that data. Absent knowledge, the
  // line is left unchecked (home-synthesized data is not predictable).
  // ---------------------------------------------------------------------------
  protected function void check_line_data(input longint line, input item_t item);
    if (!this.line_data.exists(line)) begin
      return;
    end
    if (item.data.size() != this.line_data[line].size()) begin
      this.n_coherent_data_mismatch++;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: line 0x%0h read returned %0d beats, expected %0d",
        line, item.data.size(), this.line_data[line].size()))
      return;
    end
    foreach (item.data[i]) begin
      if (item.data[i] !== this.line_data[line][i]) begin
        this.n_coherent_data_mismatch++;
        `uvm_error("VIP_CHI_COH", $sformatf(
          "COHERENCY VIOLATION: line 0x%0h beat %0d read 0x%0h != authoritative 0x%0h",
          line, i, item.data[i], this.line_data[line][i]))
        return;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Exclusive-monitor shadow maintenance: clear reservations broken by a store.
  // clear_excl_all breaks every node's reservation on a line (a store/invalidate
  // that changes the line for everyone); clear_excl_others keeps the initiating
  // node's bit so its OWN exclusive store can still be evaluated + consumed by
  // obs_rsp before it is cleared.
  // ---------------------------------------------------------------------------
  protected function void clear_excl_all(input longint line);
    for (int k = 0; k < N_NODES_C; k++) begin
      if (this.excl_ll_valid[k].exists(line) && this.excl_ll_valid[k][line]) begin
        this.excl_clear_cause[k][line] = EXCL_CLEAR_STORE;  // root cause (first clear)
        this.excl_ll_valid[k][line]    = 1'b0;
      end
    end
  endfunction

  protected function void clear_excl_others(input longint line, input int keep_node);
    for (int k = 0; k < N_NODES_C; k++) begin
      if (k == keep_node) begin
        continue;
      end
      if (this.excl_ll_valid[k].exists(line) && this.excl_ll_valid[k][line]) begin
        this.excl_clear_cause[k][line] = EXCL_CLEAR_STORE;
        this.excl_ll_valid[k][line]    = 1'b0;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Stream observers (one per RN-F node).
  // ---------------------------------------------------------------------------
  protected function void obs_req(input int node, input item_t item);
    bit                  uniq;
    longint              line;
    vip_chi_req_opcode_t wop;
    if (!this.enable || item.is_snoop) begin
      return;
    end
    line = this.line_of(longint'(item.addr));
    wop  = vip_chi_req_opcode_t'(item.opcode);
    if (this.is_coherent_read(item, uniq)) begin
      this.open_rd_line[node][longint'(item.txn_id)] = line;
      this.open_rd_uniq[node][longint'(item.txn_id)] = uniq;
      // Remember whether this read is an exclusive load, resolved at CompData.
      this.open_rd_excl[node][longint'(item.txn_id)] = item.excl;
    end
    // A coherent writeback carries CopyBackWrData whose TxnID is the granted DBID
    // (= this REQ's TxnID): remember the line so that data establishes the shadow.
    // It is also a store -> it breaks every reservation on the line.
    else if ((wop == VIP_CHI_REQ_WRITE_BACK_FULL_E) ||
             (wop == VIP_CHI_REQ_WRITE_CLEAN_FULL_E)) begin
      this.open_wb_line[node][longint'(item.txn_id)] = line;
      this.clear_excl_all(line);
    end
    // CleanUnique is the exclusive-store (SC) opcode (and the plain ownership
    // upgrade). Record it for RSP-side resolution. An exclusive SC keeps its own
    // node's reservation for obs_rsp to evaluate but breaks the others'; a plain
    // (non-exclusive) CleanUnique is a store that breaks all.
    else if (wop == VIP_CHI_REQ_CLEAN_UNIQUE_E) begin
      this.open_sc_line[node][longint'(item.txn_id)] = line;
      this.open_sc_excl[node][longint'(item.txn_id)] = item.excl;
      if (item.excl) begin
        this.clear_excl_others(line, node);
      end
      else begin
        this.clear_excl_all(line);
      end
    end
    // MakeUnique is a no-data unique acquire (the requester will overwrite the
    // whole line). It is a store (breaks every reservation) AND grants the
    // requester Unique on an RSP-only Comp -- record the line so obs_rsp can mark
    // ownership and run the single-writer check. [F1]
    else if (wop == VIP_CHI_REQ_MAKE_UNIQUE_E) begin
      this.open_mu_line[node][longint'(item.txn_id)] = line;
      this.clear_excl_all(line);
    end
    // Other stores / invalidates break every reservation on the line.
    else if ((wop == VIP_CHI_REQ_WRITE_UNIQUE_FULL_E) ||
             (wop == VIP_CHI_REQ_WRITE_UNIQUE_PTL_E)  ||
             (wop == VIP_CHI_REQ_CLEAN_INVALID_E)     ||
             (wop == VIP_CHI_REQ_MAKE_INVALID_E)) begin
      this.clear_excl_all(line);
    end
  endfunction

  protected function void obs_dat(input int node, input item_t item);
    longint              line;
    vip_chi_resp_t       granted;
    vip_chi_dat_opcode_t op;
    bit                  ll_excl;
    bit                  ll_okay;
    if (!this.enable) begin
      return;
    end
    op = vip_chi_dat_opcode_t'(item.dat_opcode);

    // Authoritative writes to the home establish the expected line data.
    if (op == VIP_CHI_DAT_COPY_BACK_WR_DATA_E) begin
      if (this.open_wb_line[node].exists(longint'(item.txn_id))) begin
        this.record_line_data(this.open_wb_line[node][longint'(item.txn_id)], item);
        this.open_wb_line[node].delete(longint'(item.txn_id));
      end
      return;
    end
    // A plain dirty snoop response (SnpRespData) and a forwarding snoop response
    // (SnpRespDataFwded) both carry the snoopee's authoritative beats for the
    // snooped line. Establish the line-data shadow from either, so a forwarded
    // line's relayed CompData is integrity-checked against what the snoopee sent
    // (this is what the hnf_corrupt_fwd_data negative control relies on).
    if ((op == VIP_CHI_DAT_SNP_RESP_DATA_E) ||
        (op == VIP_CHI_DAT_SNP_RESP_DATA_FWDED_E)) begin
      if (this.pending_snp_valid[node]) begin
        this.record_line_data(this.pending_snp_line[node], item);
        this.pending_snp_valid[node] = 1'b0;
      end
      return;
    end

    if (op != VIP_CHI_DAT_COMP_DATA_E) begin
      return;
    end
    if (!this.open_rd_line[node].exists(longint'(item.txn_id))) begin
      return;
    end
    line    = this.open_rd_line[node][longint'(item.txn_id)];
    granted = (item.dat_resp.size() > 0) ? item.dat_resp[item.dat_resp.size() - 1]
                                         : VIP_CHI_RESP_STATE_I_E;
    this.set_node_state(line, node, granted);
    this.sample_occupancy(line);

    // Exclusive-load result: an exclusive coherent read that completes with
    // ExclOkay arms this node's reservation on the line. The result rides the
    // CompData RespErr (all beats carry it; read the last).
    ll_excl = this.open_rd_excl[node].exists(longint'(item.txn_id)) &&
              this.open_rd_excl[node][longint'(item.txn_id)];
    if (ll_excl) begin
      ll_okay = (item.dat_resp_err.size() > 0) &&
                (item.dat_resp_err[item.dat_resp_err.size() - 1] ==
                 VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E);
      if (ll_okay) begin
        this.excl_ll_valid[node][line]    = 1'b1;
        this.excl_clear_cause[node][line] = EXCL_CLEAR_NONE;  // fresh reservation epoch
      end
    end

    this.open_rd_line[node].delete(longint'(item.txn_id));
    this.open_rd_uniq[node].delete(longint'(item.txn_id));
    this.open_rd_excl[node].delete(longint'(item.txn_id));
    this.n_completions++;
    this.check_multi_owner(line);
    // A read of a line with known (written/forwarded) data must return it.
    this.check_line_data(line, item);
  endfunction

  protected function void obs_snp(input int node, input item_t item);
    longint        line;
    vip_chi_resp_t cur;
    if (!this.enable || !item.is_snoop) begin
      return;
    end
    line = this.line_of(longint'(item.snp_addr));
    cur  = this.line_state.exists(line) ? vip_chi_resp_t'(this.line_state[line][node])
                                        : VIP_CHI_RESP_STATE_I_E;
    // Coverage: sample only the binned state-changing snoops (from-state x snoop x
    // to) before applying them. Snapshot snoops (SnpOnce) preserve Unique/Dirty
    // state and are not part of cg_cache_transition.
    this.ct_from_sample       = cur;
    this.ct_snp_opcode_sample = item.snp_opcode;
    this.ct_to_sample         = this.snoop_result(item.snp_opcode, cur);
    if (this.snoop_samples_cache_transition(item.snp_opcode)) begin
      this.cg_cache_transition.sample();
    end
    this.set_node_state(line, node, this.ct_to_sample);
    this.sample_occupancy(line);
    // An invalidating snoop (result Invalid) to this node breaks its exclusive
    // reservation on the line -- the same clear path (b) the HN-F wires at its
    // snoop sites, derived here independently from the observed snoop.
    if (this.ct_to_sample == VIP_CHI_RESP_STATE_I_E) begin
      if (this.excl_ll_valid[node].exists(line) && this.excl_ll_valid[node][line]) begin
        this.excl_clear_cause[node][line] = EXCL_CLEAR_SNOOP;
        this.excl_ll_valid[node][line]    = 1'b0;
      end
    end
    // Remember the snooped line so a dirty node's SnpRespData (which carries no
    // address) can be attributed back to it. The HN-F engine is serial, so at
    // most one snoop is outstanding per node.
    this.pending_snp_line[node]  = line;
    this.pending_snp_valid[node] = 1'b1;
    this.n_snoops++;
  endfunction

  // ---------------------------------------------------------------------------
  // Exclusive-store (SC) observer, on the RSP stream. The SC is a CleanUnique
  // whose completion is a plain Comp on RSP -- a channel the checker did not
  // subscribe to before this package (the load-bearing structural add). The
  // invariant: an SC that reports success (ExclOkay) must have had a
  // continuously-valid reservation, i.e. its (node,line) flag is still set from
  // the matching exclusive load with no intervening conflict. Success without
  // that flag is an exclusive violation. The SC consumes the reservation either
  // way.
  // ---------------------------------------------------------------------------
  protected function void obs_rsp(input int node, input item_t item);
    longint line;
    bit     success;
    if (!this.enable) begin
      return;
    end
    // MakeUnique completion (RSP-only Comp): mark the requester the Unique owner
    // and run the single-writer check -- the ownership shadow is otherwise updated
    // only by CompData (obs_dat), so without this a MakeUnique never registers as
    // an owner and a suppressed-snoop duplicate-owner bug would pass. [F1]
    if (this.open_mu_line[node].exists(longint'(item.txn_id))) begin
      line = this.open_mu_line[node][longint'(item.txn_id)];
      // [F1] Validate the OBSERVED completion rather than inventing UD: a MakeUnique
      // must complete with a data-less Comp granting Unique-Dirty (IHI0050). A
      // completer that returns any other opcode/state is a protocol error -- flag it
      // and record the state actually observed, so the shadow reflects reality
      // rather than a fabricated Unique owner that would mask the broken completer.
      if ((item.rsp_opcode !== item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) ||
          (item.rsp_resp   !== VIP_CHI_RESP_STATE_UP_PD_DIRTY_E)) begin
        this.n_bad_make_unique++;
        `uvm_error("VIP_CHI_COH", $sformatf(
          "COHERENCY VIOLATION: MakeUnique on line 0x%0h (node %0d) completed opcode=0x%0h resp=0x%0h, expected Comp / Unique-Dirty",
          line, node, item.rsp_opcode, item.rsp_resp))
      end
      this.set_node_state(line, node, item.rsp_resp);
      this.sample_occupancy(line);
      this.n_completions++;
      this.check_multi_owner(line);
      this.open_mu_line[node].delete(longint'(item.txn_id));
      return;
    end
    // Only an exclusive-store completion is of interest; correlate by TxnID to a
    // CleanUnique REQ recorded in obs_req.
    if (!this.open_sc_line[node].exists(longint'(item.txn_id))) begin
      return;
    end
    line    = this.open_sc_line[node][longint'(item.txn_id)];
    success = (item.rsp_resp_err == VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E);

    // Coverage: only exclusive SCs (a plain CleanUnique is a normal upgrade, not
    // a store-conditional). Sample the outcome crossed with why the reservation
    // was broken (NONE for a win, STORE/SNOOP for a loss).
    if (this.open_sc_excl[node].exists(longint'(item.txn_id)) &&
        this.open_sc_excl[node][longint'(item.txn_id)] && this.enable) begin
      this.excl_result_sample = success;
      this.excl_cause_sample  = this.excl_clear_cause[node].exists(line) ?
                                this.excl_clear_cause[node][line] : EXCL_CLEAR_NONE;
      this.cg_excl.sample();
    end

    if (success &&
        !(this.excl_ll_valid[node].exists(line) && this.excl_ll_valid[node][line])) begin
      this.n_excl_violation++;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "EXCLUSIVE VIOLATION: node %0d SC on line 0x%0h reported ExclOkay with no continuously-valid monitor (no matching uninterrupted exclusive load)",
        node, line))
    end

    // The SC consumes/clears the reservation regardless of outcome.
    if (this.excl_ll_valid[node].exists(line)) begin
      this.excl_ll_valid[node][line] = 1'b0;
    end
    this.open_sc_line[node].delete(longint'(item.txn_id));
    this.open_sc_excl[node].delete(longint'(item.txn_id));
  endfunction

  // ---------------------------------------------------------------------------
  // Analysis-imp write callbacks.
  // ---------------------------------------------------------------------------
  function void write_rnf0_req_cc(input item_t item); this.obs_req(0, item); endfunction
  function void write_rnf0_rsp_cc(input item_t item); this.obs_rsp(0, item); endfunction
  function void write_rnf0_dat_cc(input item_t item); this.obs_dat(0, item); endfunction
  function void write_rnf0_snp_cc(input item_t item); this.obs_snp(0, item); endfunction
  function void write_rnf1_req_cc(input item_t item); this.obs_req(1, item); endfunction
  function void write_rnf1_rsp_cc(input item_t item); this.obs_rsp(1, item); endfunction
  function void write_rnf1_dat_cc(input item_t item); this.obs_dat(1, item); endfunction
  function void write_rnf1_snp_cc(input item_t item); this.obs_snp(1, item); endfunction

  // Downstream SN-F observers: correlate a ReadNoSnp REQ (addr) to its CompData
  // (value) by TxnID, and record the returned beats as the authoritative line
  // data. A subsequent RN-F CompData for that line is then integrity-checked
  // against what the SN-F actually returned (check_line_data in obs_dat).
  protected function void obs_snf_req(input item_t item);
    if (!this.enable) begin
      return;
    end
    if (vip_chi_req_opcode_t'(item.opcode) == VIP_CHI_REQ_READ_NO_SNP_E) begin
      this.dn_rd_line[longint'(item.txn_id)] = this.line_of(longint'(item.addr));
    end
    // Coverage: the downstream request kind (miss-fetch vs writeback-flush).
    if ((vip_chi_req_opcode_t'(item.opcode) == VIP_CHI_REQ_READ_NO_SNP_E) ||
        (vip_chi_req_opcode_t'(item.opcode) == VIP_CHI_REQ_WRITE_NO_SNP_FULL_E)) begin
      this.dn_req_op_sample = vip_chi_req_opcode_t'(item.opcode);
      this.cg_hnf_downstream.sample();
    end
  endfunction

  protected function void obs_snf_dat(input item_t item);
    if (!this.enable) begin
      return;
    end
    if ((vip_chi_dat_opcode_t'(item.dat_opcode) == VIP_CHI_DAT_COMP_DATA_E) &&
        this.dn_rd_line.exists(longint'(item.txn_id))) begin
      this.record_line_data(this.dn_rd_line[longint'(item.txn_id)], item);
      this.dn_rd_line.delete(longint'(item.txn_id));
    end
  endfunction

  function void write_snf_req_cc(input item_t item); this.obs_snf_req(item); endfunction
  function void write_snf_dat_cc(input item_t item); this.obs_snf_dat(item); endfunction

  // ---------------------------------------------------------------------------
  // Accessors for tests / negative control.
  // ---------------------------------------------------------------------------
  function int get_multi_owner_count(); return this.n_multi_owner; endfunction
  function int get_completion_count();  return this.n_completions; endfunction
  function int get_snoop_count();       return this.n_snoops;      endfunction
  function int get_coherent_data_mismatch_count(); return this.n_coherent_data_mismatch; endfunction
  function int get_excl_violation_count(); return this.n_excl_violation; endfunction
  function int get_bad_make_unique_count(); return this.n_bad_make_unique; endfunction

  // Functional coverage of the (from-state x snoop-opcode -> to-state) cache
  // transition covergroup, sampled on every observed snoop. Lets a constrained-
  // random sweep self-verify that it closed many more of the 30 reachable bins
  // than the deterministic scenario tests hit individually.
  function real get_cache_transition_coverage(); return this.cg_cache_transition.get_coverage(); endfunction

  // ---------------------------------------------------------------------------
  // Summary.
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY CHECKER SUMMARY: completions=%0d snoops=%0d multi_owner_violations=%0d data_mismatches=%0d excl_violations=%0d bad_make_unique=%0d",
      this.n_completions, this.n_snoops, this.n_multi_owner, this.n_coherent_data_mismatch, this.n_excl_violation, this.n_bad_make_unique), UVM_LOW)
  endfunction

endclass

`endif
