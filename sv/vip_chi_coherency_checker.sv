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
  typedef item_t::node_id_t     node_id_t;
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
  // The REQ opcode the completion belongs to. The Requester's final cache state
  // is a function of the request as well as the granted Resp (IHI 0050 E Table
  // 4-14), so the correlation the checker already keeps for the line has to
  // carry the opcode too -- nothing on the CompData flit says which read it
  // completes.
  protected vip_chi_req_opcode_t open_rd_op [N_NODES_C][longint];

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
  // ...and the opcode that snoop carried, because the permitted RESPONSE FORM is
  // a property of the opcode and nothing else on the DAT flit records which
  // snoop it answers. See check_snp_resp_form.
  protected vip_chi_snp_opcode_t pending_snp_opcode [N_NODES_C];
  // ...and the state the node held WHEN THE SNOOP ARRIVED. The shadow is
  // overwritten with the predicted result the moment the snoop is seen, so by the
  // time the response arrives the from-state is gone -- and the from-state is what
  // bounds which states the response may legally report (see
  // vip_chi_snp_resp_state_gains_permission).
  protected vip_chi_resp_t pending_snp_from [N_NODES_C];
  // The snoop's DoNotGoToSD bit, kept for the same reason the from-state is:
  // the rule it feeds is about the RESPONSE, and by then the flit is gone.
  protected bit            pending_snp_no_sd [N_NODES_C];

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
  // check -- otherwise a suppressed-snoop MakeUnique duplicate owner goes unseen.
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

  // Same-line hazard shadow, per node. hazard_by_line maps a cache line to the
  // TxnID currently outstanding on it, hazard_by_txn the reverse, so a REQ can
  // be tested in O(1) and a completion can retire its line without a scan.
  protected longint hazard_by_line [N_NODES_C][longint];
  protected longint hazard_by_txn  [N_NODES_C][longint];
  // Same-line hazard rule on/off. Set by the env from the requester agent's cfg
  // (see chi_coherent_tb_env); the checker holds no agent cfg of its own.
  bit hazard_check_enable = 1'b1;

  // ---------------------------------------------------------------------------
  // Catalogue rule D8, the request->snoop correspondence. To judge a snoop
  // against IHI 0050 E Table 4-5 / D Table 4-3 the checker has to know which
  // request caused it, and nothing on the SNP flit says: a snoop carries the
  // requester's SrcID in TxnID terms only for the forwarding forms, and the
  // address is the only field shared with the request in every case.
  //
  // So the correlation is by line: at the time a snoop reaches node k, find the
  // request outstanding to the same line from some node other than k. Kept
  // separately from the hazard shadow above rather than folded into it, because
  // that one is switched off by a config knob for the hazard negative control
  // and this rule must keep working while it is.
  //
  // req_op_by_line is per node, so two requesters contending for one line are
  // two entries and the ambiguous case is detectable rather than silently
  // resolved to whichever wrote last.
  // ---------------------------------------------------------------------------
  protected vip_chi_req_opcode_t req_op_by_line  [N_NODES_C][longint];
  protected longint              req_line_by_txn [N_NODES_C][longint];
  // The same correlation, carrying the two fields a forwarding snoop has to
  // name its requester by. The opcode above answers "may this snoop be sent for
  // that request"; these answer "is it addressed to it". Kept beside the opcode
  // rather than in a table of their own so one release path retires all three
  // and they cannot fall out of step.
  protected node_id_t            req_src_by_line [N_NODES_C][longint];
  protected longint              req_txn_by_line [N_NODES_C][longint];

  protected int n_line_hazard;
  protected int n_line_clear;
  // Catalogue rule D8 non-vacuity. n_snp_req_judged is how many snoops were
  // correlated to exactly one outstanding request and therefore had a Table 4-5
  // row to be judged against; n_snp_req_mismatch is how many of those carried an
  // opcode that row does not permit.
  //
  // n_snp_req_uncorrelated is the honest denominator alongside them, and it is
  // NOT a violation: the same section that gives Table 4-5 states that "it is
  // permitted for the interconnect to generate a snoop request spontaneously
  // without a corresponding request from an RN" -- a backward invalidation from
  // a snoop filter is the example it gives. A rule that fired on an
  // uncorrelated snoop would report a conformant interconnect. It is counted so
  // that a run in which the correlation silently stopped working reads as
  // "judged 0, uncorrelated 40" instead of as a clean pass.
  protected int n_snp_req_judged;
  protected int n_snp_req_mismatch;
  protected int n_snp_req_uncorrelated;

  // The positive half of the FwdNID/FwdTxnID rule. The SNP channel checker
  // judges the negative half -- both fields zero on a snoop that has no
  // requester to name -- from the flit alone, which is all a link-layer bind can
  // see. Section 2.5 also states the other direction: FwdNID "must be the Node
  // ID of the original Requester" and FwdTxnID "must be the TxnID of the
  // original Request". Neither can be judged without knowing which request
  // caused the snoop, so it is judged here, on the same correlation rule D8
  // resolves and at the same moment.
  //
  // n_snp_fwd_judged counts forwarding snoops that had exactly one candidate
  // cause and were therefore addressable; n_snp_fwd_mismatch how many of those
  // named a different transaction than the one they were sent for. A forwarding
  // snoop whose cause is ambiguous is counted by n_snp_req_uncorrelated with the
  // rest, because the two rules decline for the same reason.
  protected int n_snp_fwd_judged;
  protected int n_snp_fwd_mismatch;

  // Catalogue rule D9 -- the CompAck ordering window. One slot per node is
  // enough because an RN-F runs its coherent transactions serially, so it never
  // has two acknowledgements outstanding at once.
  //
  // req_eca_line records, at the request, which line a CompAck will eventually
  // be owed for. The window itself does NOT open there: the snoops this very
  // request causes go out before its completion, and a window opened at the
  // request would flag exactly the snoops the protocol requires. It opens at the
  // completion, which is where section 2.8.3 puts it.
  protected longint        req_eca_line [N_NODES_C][longint];
  protected bit            eca_open     [N_NODES_C];
  protected longint        eca_line     [N_NODES_C];
  protected longint        eca_txn      [N_NODES_C];
  protected int n_eca_windows;
  protected int n_eca_window_snoops;
  protected int n_eca_windows_unclosed;
  protected int n_multi_owner;
  protected int n_completions;
  protected int n_snoops;
  protected int n_coherent_data_mismatch;
  protected int n_excl_violation;
  protected int n_bad_make_unique;
  protected int n_bad_snp_resp_form;
  // Non-vacuity evidence for check_snp_resp_form. The rule can only fire when a
  // snoop that returns no data reaches a snoopee holding the line Dirty: a clean
  // holder answers on RSP whatever the opcode says, so a run without that
  // combination proves nothing about the rule. Counted from the observed snoop
  // and the shadow state, so a test can assert the provoking condition actually
  // occurred instead of reading a zero violation count out of a run that never
  // set it up -- which is the shape of the bug this check exists to catch.
  protected int n_snp_no_data_on_dirty;
  protected int n_bad_snp_resp_state;
  protected int n_bad_snp_sd_under_no_sd;
  // How many snoop responses check_snp_resp_state judged. The rule can only run
  // where a response is correlated to its snoop, so this is the honest measure of
  // whether it saw anything -- and it is the first count of DATA-LESS SnpResp
  // this checker has ever taken: before D5 it observed SnpRespData on DAT and was
  // blind to the RSP half of the response space entirely.
  protected int n_snp_resp_judged;
  // Catalogue rule D6: responses that reported a state the snoopee could not have
  // reached from what it held.
  protected int n_snp_resp_gains_permission;
  // Non-vacuity for the ADOPTION, which is the point of the change: how many
  // responses wrote their reported state into the shadow, and how many of those
  // disagreed with the state derived from the opcode. On this VIP the second is
  // expected to be 0 -- its own RN-F implements exactly the mapping snoop_result()
  // encodes -- so the count is what makes that an OBSERVATION rather than the
  // assumption it replaces. Against a DUT it is the first number to read.
  protected int n_snp_resp_adopted;
  protected int n_snp_resp_state_differs;

  // The requester axis of the same question. n_req_final_judged is how many
  // completions the Table 4-14 rule had to decide; n_req_final_retained is how
  // many of those ended in a state the granted Resp alone would NOT have given,
  // which is precisely the count that separates the rule from the shortcut it
  // replaces. It is 0 for any stimulus whose requester is Invalid when it issues
  // -- which was every transition in this regression before the sweep primed the
  // requesting node -- so it is the non-vacuity measure for this rule, not a
  // statistic.
  protected int n_req_final_judged;
  protected int n_req_final_retained;
  // Completions whose Resp encoding the dataless-completion table does not
  // permit for that request (currently MakeUnique, Table 4-19 / D Table 4-13).
  protected int n_bad_dataless_resp;
  // Catalogue rule D7: a Dirty snoopee that answered without data and without
  // keeping the dirty. The dual of n_bad_snp_resp_form, which reads the other
  // direction.
  protected int n_snp_dirty_lost;
  // Catalogue rule D10: a state-preserving snoop answered with a state other
  // than the one the snoopee held. n_snp_preserving_judged is its non-vacuity
  // evidence, and it needs one badly: the only opcode in the set is E-only and
  // is sent only under a cfg knob, so a CHI-D run and every E run without the
  // knob leave both at zero and the rule never runs at all.
  protected int n_bad_snp_state_preserved;
  protected int n_snp_preserving_judged;
  // Snoops D8 declined because Table 4-5 never generates the opcode. Kept apart
  // from n_snp_req_uncorrelated, which counts the declines caused by AMBIGUITY:
  // a run whose D8 judged-count is low reads very differently depending on which
  // of the two absorbed the traffic, and merging them would hide a home that had
  // started sending spontaneous snoops nothing was judging.
  protected int n_snp_req_spontaneous;

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

  // cg_snp_resp_legality samples, set where a snoop response is matched back to
  // the snoop it answers -- which is the only place the pairing exists. Nothing
  // on a SnpResp or SnpRespData names the snoop, so no flit-level covergroup can
  // reach this cross; that is why it lives here and not in vip_chi_coverage.
  protected item_t::snp_opcode_t sr_snp_opcode_sample;
  protected vip_chi_resp_t       sr_resp_state_sample;
  protected bit                  sr_returned_data_sample;

  // cg_req_snp_pairing samples, set where a snoop is correlated back to the
  // request that caused it. Both fields are known only at that one point: the
  // snoop flit carries no request opcode, and the request carries no snoop.
  protected item_t::req_opcode_t rs_cause_req_sample;
  protected item_t::snp_opcode_t rs_snp_opcode_sample;

  // The same cross as a set of reached pairs, keyed on the two opcodes packed
  // into one int. The covergroup's percentage is computed by the simulator and
  // pyUVM has no covergroup to compute one from, so that number is the one thing
  // about this cross the two ports cannot compare. The count of distinct pairs
  // they can, and check_counter_parity.py does.
  protected bit rs_pair_hit [int];

  // cg_req_cache_transition samples, set where a request completes. The requester
  // axis had no coverage target of any kind before 3.2 -- cg_cache_transition
  // covers the snoop axis only -- which is a large part of why the held-state
  // half of Table 4-14 could be missing without anything reporting a hole.
  protected vip_chi_resp_t       rt_from_sample;
  protected item_t::req_opcode_t rt_req_op_sample;
  protected vip_chi_resp_t       rt_granted_sample;
  protected vip_chi_resp_t       rt_to_sample;

  // ---------------------------------------------------------------------------
  // The snoop-response legality surface: snoop opcode x resulting state x whether
  // data came back.
  //
  // Chapter 4 states the snoop rules PER OPCODE -- Tables 4-9 and 4-11 list the
  // permitted responses for each one -- so a coverage model without the opcode in
  // the cross cannot express those rules at all. Before this, the snoop opcode was
  // crossed only with a direction and the response state only with pass-dirty, in
  // two covergroups sampled at two unrelated call sites, so the pairing was not
  // merely uncovered but structurally unreachable.
  //
  // The forbidden pairings are illegal_bins rather than uncovered bins, and that
  // distinction is the whole point: the defect it guards is a snoopee answering
  // SnpMakeInvalid with data, driven twice per run by a green test, recorded as
  // covered because the to-state beside it was correct. An uncovered bin is not
  // noticed; an illegal bin fails.
  // ---------------------------------------------------------------------------
  covergroup cg_snp_resp_legality;
    option.per_instance = 1;

    // The nine this home originates. SnpClean and SnpCleanFwd joined the set
    // with Table 4-5: ReadClean used to be snooped as a ReadShared, so the two
    // opcodes the spec names for it appeared nowhere -- and because the bins were
    // drawn from what the home DID send, the report read closed on a space that
    // excluded the correct answer. That is the failure mode this coverage model
    // is supposed to prevent, so the bins now come from Table 4-5's column
    // rather than from the driver.
    //
    // The other three modeled snoops (SnpCleanShared, SnpOnceFwd,
    // SnpNotSharedDirtyFwd) are left unbinned rather than listed-and-unreachable,
    // the same convention cg_cache_transition uses below: no request in the
    // RN-F's opcode set asks for them.
    cp_snp: coverpoint this.sr_snp_opcode_sample {
      bins snp_shared        = {VIP_CHI_SNP_SHARED_C};
      bins snp_clean         = {VIP_CHI_SNP_CLEAN_C};
      bins snp_once          = {VIP_CHI_SNP_ONCE_C};
      bins snp_unique        = {VIP_CHI_SNP_UNIQUE_C};
      bins snp_clean_invalid = {VIP_CHI_SNP_CLEAN_INVALID_C};
      bins snp_make_invalid  = {VIP_CHI_SNP_MAKE_INVALID_C};
      bins snp_shared_fwd    = {VIP_CHI_SNP_SHARED_FWD_C};
      bins snp_clean_fwd     = {VIP_CHI_SNP_CLEAN_FWD_C};
      bins snp_unique_fwd    = {VIP_CHI_SNP_UNIQUE_FWD_C};
    }

    // The general cache-state encodings, which is the right set for the
    // with-data half of the cross below and only that half. A data-less snoop
    // response is in Table 4-9's space instead: there UD shares UC's encoding
    // and SD is 0b011, which the cache-state field reserves and no bin here
    // names. Nothing lands outside a bin today -- the never-SD reduction keeps a
    // snoopee out of SD, and vip_chi_snp_resp_dataless_state folds a data-less
    // UD onto uc -- but a model that adds SD needs a bin for 0b011 crossed with
    // no_data, not a second meaning for this one.
    cp_state: coverpoint this.sr_resp_state_sample {
      bins inv = {VIP_CHI_RESP_STATE_I_E};
      bins sc  = {VIP_CHI_RESP_STATE_SC_E};
      bins uc  = {VIP_CHI_RESP_STATE_UC_E};
      bins ud  = {VIP_CHI_RESP_STATE_UP_PD_DIRTY_E};
      bins sd  = {VIP_CHI_RESP_STATE_SD_PD_DIRTY_E};
    }

    cp_data: coverpoint this.sr_returned_data_sample {
      bins no_data   = {1'b0};
      bins with_data = {1'b1};
    }

    cx_snp_state_data: cross cp_snp, cp_state, cp_data {
      // An invalidating snoop must leave the snoopee Invalid. Every response
      // Table 4-9 permits to these four carries the Invalid state; a snoopee
      // still holding the line has not given up ownership, and the requester
      // about to take it Unique is then not the only owner.
      illegal_bins invalidating_must_end_invalid =
        (binsof(cp_snp.snp_unique)        ||
         binsof(cp_snp.snp_clean_invalid) ||
         binsof(cp_snp.snp_make_invalid)  ||
         binsof(cp_snp.snp_unique_fwd)) && !binsof(cp_state.inv);

      // A shared snoop exists to create a sharer, so the snoopee may not keep
      // Unique. Restricted to the two shared forms this home originates -- see
      // vip_chi_snp_opcode_forbids_retaining_unique for why the rest are left out.
      illegal_bins shared_must_not_keep_unique =
        (binsof(cp_snp.snp_shared) || binsof(cp_snp.snp_shared_fwd)) &&
        (binsof(cp_state.uc) || binsof(cp_state.ud));

      // SnpMakeInvalid is defined by discarding its dirty copy: no SnpRespData
      // form appears among its permitted responses.
      illegal_bins make_invalid_returns_no_data =
        binsof(cp_snp.snp_make_invalid) && binsof(cp_data.with_data);
    }
  endgroup

  // ---------------------------------------------------------------------------
  // The request x snoop surface: which snoop the Home sent for the request that
  // caused it -- IHI 0050 E Table 4-5 (D Table 4-3) and the bullets under it.
  //
  // Table 4-5 is indexed by request opcode. A coverage model that carries the
  // two opcodes in separate covergroups, sampled at separate call sites, cannot
  // express a single row of it, so every rule of that shape is uncovered however
  // many tests run. The two are brought together here because this is the only
  // place both are known: the snoop flit carries no request opcode, and the
  // request has long completed its REQ-channel sampling by the time the snoop
  // goes out. cg_snp_resp_legality does the same for the neighbouring
  // snoop x response axis.
  //
  // Sampled only where the correlation is REAL -- one outstanding request on the
  // line, from another node. A spontaneous snoop is permitted and has no cause,
  // and recording it against whichever request happened to be open would fill
  // the cross with pairings the Home never chose.
  // ---------------------------------------------------------------------------
  covergroup cg_req_snp_pairing;
    option.per_instance = 1;

    // The snoop-generating requests, from Table 4-5's index column rather than
    // from what this Home happens to issue -- a bin set drawn from the driver
    // reads closed on a space that excludes the answers the driver never gives.
    cp_req: coverpoint this.rs_cause_req_sample {
      bins read_shared       = {VIP_CHI_REQ_READ_SHARED_C};
      bins read_clean        = {VIP_CHI_REQ_READ_CLEAN_C};
      bins read_once         = {VIP_CHI_REQ_READ_ONCE_C};
      bins read_unique       = {VIP_CHI_REQ_READ_UNIQUE_C};
      bins make_read_unique  = {VIP_CHI_REQ_MAKE_READ_UNIQUE_C};
      bins clean_unique      = {VIP_CHI_REQ_CLEAN_UNIQUE_C};
      bins clean_invalid     = {VIP_CHI_REQ_CLEAN_INVALID_C};
      bins make_unique       = {VIP_CHI_REQ_MAKE_UNIQUE_C};
      bins make_invalid      = {VIP_CHI_REQ_MAKE_INVALID_C};
      bins write_unique_full = {VIP_CHI_REQ_WRITE_UNIQUE_FULL_C};
      bins write_unique_zero = {VIP_CHI_REQ_WRITE_UNIQUE_ZERO_C};
    }

    cp_snp: coverpoint this.rs_snp_opcode_sample {
      bins snp_shared        = {VIP_CHI_SNP_SHARED_C};
      bins snp_clean         = {VIP_CHI_SNP_CLEAN_C};
      bins snp_once          = {VIP_CHI_SNP_ONCE_C};
      bins snp_clean_shared  = {VIP_CHI_SNP_CLEAN_SHARED_C};
      bins snp_unique        = {VIP_CHI_SNP_UNIQUE_C};
      bins snp_clean_invalid = {VIP_CHI_SNP_CLEAN_INVALID_C};
      bins snp_make_invalid  = {VIP_CHI_SNP_MAKE_INVALID_C};
      bins snp_shared_fwd    = {VIP_CHI_SNP_SHARED_FWD_C};
      bins snp_clean_fwd     = {VIP_CHI_SNP_CLEAN_FWD_C};
      bins snp_once_fwd      = {VIP_CHI_SNP_ONCE_FWD_C};
      bins snp_unique_fwd    = {VIP_CHI_SNP_UNIQUE_FWD_C};
    }

    cx_req_snp: cross cp_req, cp_snp {
      // A request that must leave no other holder, answered with a snoop that
      // lets the snoopee keep a copy. Whatever the snoopee then reports, a
      // sharer survives a request whose whole purpose was to remove it, and no
      // single flit looks wrong.
      illegal_bins unique_request_leaves_a_copy =
        (binsof(cp_req.read_unique)       ||
         binsof(cp_req.make_read_unique)  ||
         binsof(cp_req.clean_unique)      ||
         binsof(cp_req.clean_invalid)     ||
         binsof(cp_req.make_unique)       ||
         binsof(cp_req.make_invalid)      ||
         binsof(cp_req.write_unique_full) ||
         binsof(cp_req.write_unique_zero)) &&
        (binsof(cp_snp.snp_shared)       ||
         binsof(cp_snp.snp_clean)        ||
         binsof(cp_snp.snp_once)         ||
         binsof(cp_snp.snp_clean_shared) ||
         binsof(cp_snp.snp_shared_fwd)   ||
         binsof(cp_snp.snp_clean_fwd)    ||
         binsof(cp_snp.snp_once_fwd));

      // The other direction: a read that asks for no more than a shared copy,
      // answered with a snoop that invalidates every other holder. It is not
      // merely wasteful -- the sharers lose a line nothing asked them to give
      // up, and a Dirty one is made to write back on a request that never
      // needed the data moved.
      illegal_bins non_unique_read_invalidates =
        (binsof(cp_req.read_shared) ||
         binsof(cp_req.read_clean)  ||
         binsof(cp_req.read_once))  &&
        (binsof(cp_snp.snp_unique)       ||
         binsof(cp_snp.snp_unique_fwd)   ||
         binsof(cp_snp.snp_make_invalid) ||
         binsof(cp_snp.snp_clean_invalid));
    }
  endgroup

  // Declared by a negative control that deliberately produces a snoop response
  // the cross above calls illegal. It suppresses the SAMPLE for that pairing and
  // nothing else -- the rules still report, which is what the control asserts.
  //
  // On the scoreboard the analogous declaration is expect_failure(), which
  // changes severity for the CSV export and leaves the report alone. Here the
  // opposite is needed, and for a mechanical reason rather than a stylistic one:
  // an illegal covergroup bin is not part of the UVM report path at all, so no
  // catcher and no severity can reach it, and the hit ends the simulation.
  bit expect_illegal_snp_resp = 1'b0;

  // The illegal_bins above, as a predicate. Entered twice, which is a real cost
  // -- SystemVerilog gives no way to ask a covergroup whether a sample would
  // land in an illegal bin, and a hit is unrecoverable, so the question has to
  // be answerable BEFORE sampling. The two are compared by
  // scripts/check_snp_resp_illegal_bins.py so an edit to one that misses the
  // other is a gate failure rather than a silently unsuppressable control.
  protected function bit snp_resp_hits_illegal_bin(
    input vip_chi_snp_opcode_t op,
    input vip_chi_resp_t       state,
    input bit                  with_data
  );
    // invalidating_must_end_invalid
    if ((op inside {VIP_CHI_SNP_UNIQUE_C, VIP_CHI_SNP_CLEAN_INVALID_C,
                    VIP_CHI_SNP_MAKE_INVALID_C, VIP_CHI_SNP_UNIQUE_FWD_C}) &&
        (state != VIP_CHI_RESP_STATE_I_E)) begin
      return 1'b1;
    end

    // shared_must_not_keep_unique
    if ((op inside {VIP_CHI_SNP_SHARED_C, VIP_CHI_SNP_SHARED_FWD_C}) &&
        ((state == VIP_CHI_RESP_STATE_UC_E) ||
         (state == VIP_CHI_RESP_STATE_UP_PD_DIRTY_E))) begin
      return 1'b1;
    end

    // make_invalid_returns_no_data
    if ((op == VIP_CHI_SNP_MAKE_INVALID_C) && with_data) begin
      return 1'b1;
    end

    return 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // The requester-side transition surface: held state x request x granted state
  // x final state -- IHI 0050 E Table 4-14 (D Table 4-12) indexed exactly as the
  // table itself is.
  //
  // The interesting axis is cp_from, and it is the one that was missing. Every
  // requester transition in this regression began at Invalid, so "final = granted
  // Resp" and "final = join(held, granted)" agreed on 100% of the stimulus and
  // the difference between a correct model and a wrong one was invisible. A
  // coverage report that does not name the initial state cannot show that.
  //
  // cp_to carries the guard rather than cp_from, because the join's output is
  // where an error would surface: a completion may not leave the Requester
  // holding LESS than it held, so a final state of I is impossible for every
  // request binned here (all of them allocate or upgrade). That is the requester
  // dual of cg_cache_transition's never_upgrades.
  // ---------------------------------------------------------------------------
  covergroup cg_req_cache_transition;
    option.per_instance = 1;

    // The five states this VIP models. SD is reachable on this axis in a way it
    // is not on the snoop axis -- a CompData_SD_PD grants it directly (Table 4-14,
    // ReadShared) -- so it is binned here rather than ignored.
    cp_from: coverpoint this.rt_from_sample {
      bins i   = {VIP_CHI_RESP_STATE_I_E};
      bins sc  = {VIP_CHI_RESP_STATE_SC_E};
      bins uc  = {VIP_CHI_RESP_STATE_UC_E};
      bins sd  = {VIP_CHI_RESP_STATE_SD_PD_DIRTY_E};
      bins ud  = {VIP_CHI_RESP_STATE_UP_PD_DIRTY_E};
    }

    // The requests whose final state Table 4-14 / Table 4-19 makes a function of
    // the held state. The non-allocating reads are absent on purpose: 4.7.1
    // requires the Requester to IGNORE the granted state for those, so they have
    // no row here to cover.
    cp_req: coverpoint this.rt_req_op_sample {
      bins read_shared      = {VIP_CHI_REQ_READ_SHARED_C};
      bins read_clean       = {VIP_CHI_REQ_READ_CLEAN_C};
      bins read_unique      = {VIP_CHI_REQ_READ_UNIQUE_C};
      bins make_read_unique = {VIP_CHI_REQ_MAKE_READ_UNIQUE_C};
      bins make_unique      = {VIP_CHI_REQ_MAKE_UNIQUE_C};
    }

    // The states a completion can grant. Comp_I is not a grant any binned request
    // can receive, so it is left unbinned rather than listed and never hit.
    cp_granted: coverpoint this.rt_granted_sample {
      bins sc  = {VIP_CHI_RESP_STATE_SC_E};
      bins uc  = {VIP_CHI_RESP_STATE_UC_E};
      bins sd  = {VIP_CHI_RESP_STATE_SD_PD_DIRTY_E};
      bins ud  = {VIP_CHI_RESP_STATE_UP_PD_DIRTY_E};
    }

    cp_to: coverpoint this.rt_to_sample {
      bins sc  = {VIP_CHI_RESP_STATE_SC_E};
      bins uc  = {VIP_CHI_RESP_STATE_UC_E};
      bins sd  = {VIP_CHI_RESP_STATE_SD_PD_DIRTY_E};
      bins ud  = {VIP_CHI_RESP_STATE_UP_PD_DIRTY_E};
      // Every request binned above either allocates the line or upgrades one the
      // Requester already holds; none of them can end Invalid. Reaching I here
      // means the join lost a permission both of its operands carried, which is a
      // broken next-state function rather than a legal outcome.
      illegal_bins never_loses_the_line = {VIP_CHI_RESP_STATE_I_E};
    }

    // The table's own shape: (initial, request, response) -> final. Crossing
    // from x granted is what makes the retention rows visible as coverage; the
    // request has to be in the cross because MakeUnique's final state does not
    // follow from the other two.
    cx_from_req_granted: cross cp_from, cp_req, cp_granted;
  endgroup

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

    // Only the state-changing snoops this HN-F originates are binned. SnpClean
    // joined them with Table 4-5 -- it is what a ReadClean is now snooped with,
    // and it downgrades a Unique holder exactly as SnpShared does, so it is a
    // transition in its own right and not a synonym.
    //
    // SnpCleanShared is still never originated (no request in the RN-F's opcode
    // set asks for it), and SnpOnce / the fwd variants are snapshots or carry the
    // same result via a separate DCT path -- none is a distinct state transition,
    // so they are left unbinned (SV ignores coverpoint values outside the listed
    // bins) rather than diluting the report with permanently-unreachable bins.
    cp_snp: coverpoint this.ct_snp_opcode_sample {
      bins snp_shared        = {VIP_CHI_SNP_SHARED_C};
      bins snp_clean         = {VIP_CHI_SNP_CLEAN_C};
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
      // A snoop can never UPGRADE a holder, and none of the four binned
      // opcodes leaves it Unique: the three invalidating ones end at I, and
      // SnpShared exists to create a sharer. Either outcome landing here is a
      // miswire, so it is flagged rather than silently vanishing as an unbinned
      // value (which would leave the denominator looking fully closed while
      // masking the bug).
      illegal_bins never_upgrades = {VIP_CHI_RESP_STATE_UC_E,
                                     VIP_CHI_RESP_STATE_UP_PD_DIRTY_E};
      // SharedDirty is NOT a miswire and was wrongly grouped with the two above:
      // a UD holder answering SnpShared may keep the dirty data and report SD
      // instead of passing it on, which Chapter 4 permits. Now that the to-state
      // is taken from the response rather than derived, an illegal_bin here would
      // fail the simulation on legal peer traffic -- so it is ignored, not
      // flagged.
      //
      // Ignored rather than binned because it is unreachable in THIS VIP for a
      // structural reason that is itself an open finding: the home cannot forbid
      // SD (the DoNotGoToSD field is absent from the snoop flit in both ports),
      // and its own RN-F never retains dirty on a shared snoop. Binning it would
      // hold the covergroup permanently short of closure and train the reader to
      // ignore the gap. When the field lands, this ignore comes out and the bin
      // goes in.
      ignore_bins shared_dirty_unreachable_here = {VIP_CHI_RESP_STATE_SD_PD_DIRTY_E};
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
      // SnpShared and SnpClean both retain a held line Shared (-> SC) and never
      // invalidate it. The two are grouped because the spec's difference between
      // them -- whether the snoopee may keep the line Shared DIRTY -- is not a
      // difference this RN-F can express: it has no path to SD, so both end SC.
      ignore_bins downgrade_snp_keeps_sc =
        binsof(cp_snp.snp_shared) && binsof(cp_to.inv) ||
        binsof(cp_snp.snp_clean)  && binsof(cp_to.inv);
      // Neither a ReadShared nor a ReadClean snoops an already-Shared holder, so
      // neither downgrading snoop is ever sent to a from-SC.
      ignore_bins downgrade_snp_only_to_unique_holder =
        binsof(cp_snp.snp_shared) && binsof(cp_from.sc) ||
        binsof(cp_snp.snp_clean)  && binsof(cp_from.sc);
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
    this.cg_req_cache_transition = new();
    this.cg_snp_resp_legality = new();
    this.cg_req_snp_pairing = new();
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
      this.open_rd_op[n].delete();
      this.open_wb_line[n].delete();
      this.open_rd_excl[n].delete();
      this.open_sc_excl[n].delete();
      this.open_sc_line[n].delete();
      this.open_mu_line[n].delete();
      this.excl_ll_valid[n].delete();
      this.excl_clear_cause[n].delete();
      this.hazard_by_line[n].delete();
      this.hazard_by_txn[n].delete();
      this.req_op_by_line[n].delete();
      this.req_line_by_txn[n].delete();
      this.req_src_by_line[n].delete();
      this.req_txn_by_line[n].delete();
      this.req_eca_line[n].delete();
      this.eca_open[n] = 1'b0;
      this.eca_line[n] = 0;
      this.eca_txn[n]  = 0;
      this.pending_snp_valid[n] = 1'b0;
      this.pending_snp_from[n]  = VIP_CHI_RESP_STATE_I_E;
      this.pending_snp_no_sd[n] = 1'b0;
    end
    this.n_line_hazard = 0;
    this.n_line_clear  = 0;
    this.n_snp_req_judged       = 0;
    this.n_snp_req_mismatch     = 0;
    this.n_snp_req_uncorrelated = 0;
    this.n_snp_fwd_judged       = 0;
    this.n_snp_fwd_mismatch     = 0;
    this.n_eca_windows          = 0;
    this.n_eca_window_snoops    = 0;
    this.n_eca_windows_unclosed = 0;
    this.line_state.delete();
    this.line_data.delete();
    this.dn_rd_line.delete();
    this.n_multi_owner = 0;
    this.n_completions = 0;
    this.n_snoops      = 0;
    this.n_coherent_data_mismatch = 0;
    this.n_excl_violation         = 0;
    this.n_bad_make_unique        = 0;
    this.n_bad_snp_resp_form      = 0;
    this.n_snp_no_data_on_dirty   = 0;
    this.n_bad_snp_resp_state     = 0;
    this.n_bad_snp_sd_under_no_sd = 0;
    this.n_snp_resp_judged        = 0;
    // These three were left out when D5/D6 landed, and the omission is exactly
    // what a post-reset run reports as a divergence: Python clears them, SV did
    // not, so a snoop response judged BEFORE the reset kept its adopt tally while
    // the judged tally beside it went back to zero -- a summary reading
    // "judged=0 adopted=1", which is a state no single run can reach. Found by
    // scripts/check_counter_parity.py on its first execution.
    this.n_snp_resp_gains_permission = 0;
    this.n_snp_resp_adopted          = 0;
    this.n_snp_resp_state_differs    = 0;
    this.n_req_final_judged       = 0;
    this.n_req_final_retained     = 0;
    this.n_bad_dataless_resp      = 0;
    this.n_snp_dirty_lost         = 0;
    this.n_bad_snp_state_preserved = 0;
    this.n_snp_preserving_judged   = 0;
    this.n_snp_req_spontaneous     = 0;
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

  protected function bit state_is_dirty(input vip_chi_resp_t s);
    return (s == VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) ||
           (s == VIP_CHI_RESP_STATE_SD_PD_DIRTY_E);
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
    // Load-bearing here in a way it is not for the other opcodes. Everywhere
    // else this is only a PREDICTION, overwritten by the state the response
    // actually reports; for a preserving snoop the adoption is skipped -- the
    // answer is in Table 4-9's lossy encoding -- so this value is the one the
    // shadow keeps. Reaching it through the default arm below would work today
    // and would stop working the moment a preserving opcode belonged in one of
    // the two named arms.
    if (vip_chi_snp_opcode_preserves_state(vip_chi_snp_opcode_t'(snp_opcode))) begin
      return current;
    end
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
      VIP_CHI_SNP_CLEAN_C,
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
  // Same-line hazard shadow.
  //
  // The invariant: a requester must not have two requests outstanding to the
  // same cache line at once. The completer resolves a line's transactions in the
  // order it chooses and its snoops carry no requester-side sequence, so a
  // requester that overlaps two requests on one line has no way to say which
  // result belongs to which -- and neither has anything watching the link.
  //
  // Scoped per NODE on purpose. Two different requesters holding the same line
  // outstanding is not a hazard, it is the ordinary contention every coherent
  // test in this bench creates deliberately; the home exists to arbitrate it.
  //
  // A line is claimed at the REQ and released at the completion response. The
  // release is the response rather than the last data beat because the response
  // is what every request kind has -- reads, writes, CMOs and the data-less
  // acquires alike -- and a shadow that only understood the kinds with a data
  // phase would leak entries and then blame the next request to that line.
  // ---------------------------------------------------------------------------
  protected function void hazard_claim(input int     node,
                                       input longint line,
                                       input longint txn_id,
                                       input longint opcode);
    longint prior;
    if (!this.hazard_check_enable) begin
      return;
    end
    if (this.hazard_by_line[node].exists(line)) begin
      prior = this.hazard_by_line[node][line];
      if (prior != txn_id) begin
        this.n_line_hazard++;
        `uvm_error("VIP_CHI_COH", $sformatf(
          "COHERENCY VIOLATION: node %0d issued txn 0x%0h (opcode=0x%0h) to line 0x%0h while its own txn 0x%0h to that line was still outstanding",
          node, txn_id, opcode, line, prior))
      end
      // Same TxnID on the same line: a RetryAck'd request being re-issued, not a
      // second request. Re-claiming it would report the requester for obeying
      // the retry protocol.
      return;
    end
    this.hazard_by_line[node][line]  = txn_id;
    this.hazard_by_txn[node][txn_id] = line;
  endfunction

  protected function void hazard_release(input int node, input longint txn_id);
    longint line;
    if (!this.hazard_check_enable) begin
      return;
    end
    if (!this.hazard_by_txn[node].exists(txn_id)) begin
      return;
    end
    line = this.hazard_by_txn[node][txn_id];
    this.hazard_by_txn[node].delete(txn_id);
    if (this.hazard_by_line[node].exists(line) &&
        (this.hazard_by_line[node][line] == txn_id)) begin
      this.hazard_by_line[node].delete(line);
    end
    // Count the clean open/close pair: without it a log cannot distinguish a run
    // in which the rule held from one in which it never evaluated.
    this.n_line_clear++;
  endfunction

  // TRUE for the RSP opcodes that end a requester's claim on a cache line.
  // DBIDResp and ReadReceipt are deliberately excluded: they grant a buffer and
  // confirm ordering respectively, and the transaction is still live after
  // either. RetryAck is included because the completer refused the request
  // outright -- it holds no line, and the re-issue claims one again.
  protected function bit hazard_release_rsp(input item_t::rsp_opcode_t opc);
    return (opc == item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) ||
           (opc == item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) ||
           (opc == item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C)) ||
           (opc == item_t::rsp_opcode_t'(VIP_CHI_RSP_RETRY_ACK_C));
  endfunction

  // ---------------------------------------------------------------------------
  // Request tracking for catalogue rule D8. Deliberately a separate pair from
  // hazard_claim/hazard_release: same call sites, same lifetime, but ungated, so
  // turning the hazard rule off for its negative control does not also turn off
  // the request->snoop correspondence.
  // ---------------------------------------------------------------------------
  protected function void req_track_claim(input int                  node,
                                          input longint              line,
                                          input longint              txn_id,
                                          input node_id_t            src_id,
                                          input vip_chi_req_opcode_t opcode);
    this.req_op_by_line[node][line]   = opcode;
    this.req_line_by_txn[node][txn_id] = line;
    // SrcID is taken from the flit rather than from the node index: the index is
    // this checker's own numbering of the ports it is wired to, and the rule is
    // about the identifier the requester put on the wire.
    this.req_src_by_line[node][line]  = src_id;
    this.req_txn_by_line[node][line]  = txn_id;
  endfunction

  protected function void req_track_release(input int node, input longint txn_id);
    longint line;
    if (!this.req_line_by_txn[node].exists(txn_id)) begin
      return;
    end
    line = this.req_line_by_txn[node][txn_id];
    this.req_line_by_txn[node].delete(txn_id);
    this.req_op_by_line[node].delete(line);
    this.req_src_by_line[node].delete(line);
    this.req_txn_by_line[node].delete(line);
  endfunction

  // ---------------------------------------------------------------------------
  // Catalogue rule D8: a snoop's opcode must be one IHI 0050 E Table 4-5 / D
  // Table 4-3 permits for the request that caused it.
  //
  // Nothing in this VIP checked the snoop against its cause before. Every rule
  // on the SNP channel judged the flit's own contents -- its opcode is a modeled
  // one, its fields are in range, the response to it is a permitted form -- and
  // the pairing of a request with the snoop the home chose for it was left to
  // the home's own code to get right. It got one row wrong for both issues, and
  // the covergroup could not show the gap either, because the bins were drawn
  // from the set of opcodes this home originates: the two it should have been
  // sending were not binned, so the report was closed on a space that excluded
  // the correct answer.
  //
  // The correlation is by cache line and excludes the snooped node itself: a
  // requester is never snooped for its own request. Two nodes with a request
  // outstanding to the same line is ordinary contention, not an error, but it
  // leaves the cause ambiguous -- the rule declines to judge rather than guess,
  // and the decline is counted.
  // ---------------------------------------------------------------------------
  protected function void check_snoop_matches_request(input int                  node,
                                                      input longint              line,
                                                      input vip_chi_snp_opcode_t snp_op,
                                                      input node_id_t            fwd_nid,
                                                      input txn_id_t             fwd_txn_id);
    int                  cause_node;
    int                  cause_count;
    vip_chi_req_opcode_t cause_op;
    node_id_t            cause_src;
    longint              cause_txn;

    // A snoop Table 4-5 never generates is declined before the correlation, and
    // not because of a timing accident. Correlation is by line and by what is
    // outstanding, so a spontaneous snoop sent while some request happens to be
    // open on that line correlates perfectly and still has no cause: the home
    // chose to send it, not the request. Judging it against the request's row
    // asks the table a question it has no cell for, and the answer comes back
    // "not permitted" for every request there is.
    if (!vip_chi_snp_opcode_generated_by_request(snp_op)) begin
      this.n_snp_req_spontaneous++;
      return;
    end

    cause_count = 0;
    cause_node  = -1;
    cause_op    = vip_chi_req_opcode_t'(0);
    cause_src   = node_id_t'(0);
    cause_txn   = 0;
    for (int k = 0; k < N_NODES_C; k++) begin
      if (k == node) begin
        continue;
      end
      if (this.req_op_by_line[k].exists(line)) begin
        cause_node = k;
        cause_op   = this.req_op_by_line[k][line];
        cause_src  = this.req_src_by_line[k][line];
        cause_txn  = this.req_txn_by_line[k][line];
        cause_count++;
      end
    end

    // No cause, or more than one candidate: not judgeable. See the comment on
    // n_snp_req_uncorrelated -- a spontaneous snoop is explicitly permitted, so
    // silence here is the correct answer and not a missed check.
    if (cause_count != 1) begin
      this.n_snp_req_uncorrelated++;
      return;
    end

    this.n_snp_req_judged++;

    // The cross, recorded for every correlated pair including the ones the rule
    // below rejects: a cross that only ever saw conformant traffic would say
    // nothing about what was exercised. The two illegal classes it declares are
    // a strict subset of what vip_chi_snoop_permitted_for_req rejects -- checked
    // by scripts/check_req_snp_illegal_bins.py -- so a run that trips one has
    // already been reported by this rule.
    this.rs_cause_req_sample = item_t::req_opcode_t'(cause_op);
    this.rs_snp_opcode_sample = item_t::snp_opcode_t'(snp_op);
    this.cg_req_snp_pairing.sample();
    this.rs_pair_hit[(int'(cause_op) << 8) | int'(snp_op)] = 1'b1;

    this.check_snoop_fwd_names_requester(node, line, snp_op, fwd_nid, fwd_txn_id,
                                         cause_node, cause_src, cause_txn);

    if (!vip_chi_req_generates_snoop(cause_op)) begin
      this.n_snp_req_mismatch++;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: snoop opcode 0x%0h sent to node %0d for line 0x%0h, but the request outstanding on that line from node %0d (opcode 0x%0h) generates no snoop (Table 4-5 lists n/a in every snoop column)",
        snp_op, node, line, cause_node, cause_op))
      return;
    end
    if (!vip_chi_snoop_permitted_for_req(cause_op, snp_op)) begin
      this.n_snp_req_mismatch++;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: snoop opcode 0x%0h sent to node %0d for line 0x%0h is not permitted for the request that caused it (node %0d, opcode 0x%0h) -- IHI 0050 E Table 4-5 / D Table 4-3 and the bullets under it",
        snp_op, node, line, cause_node, cause_op))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // A forwarding snoop must name the requester it is forwarding to.
  //
  // IHI 0050 E 2.5 states both halves of the FwdNID/FwdTxnID rule. The SNP
  // channel bind judges the half a link-layer checker can see -- the fields are
  // inapplicable and must be zero on every snoop that is not one of the six
  // forwarding forms -- and passed ANY value on the six that are. The positive
  // half is here because it needs the cause: FwdNID must be the Node ID of the
  // original Requester, FwdTxnID the TxnID of the original Request.
  //
  // Both fields are judged even though only one of them can fail on this bench.
  // Every RN-F here drives SrcID zero, so the FwdNID comparison is 0 == 0 and
  // holds whatever the home puts in the field; it is the FwdTxnID half that
  // carries the weight until a test gives the two requesters distinct Node IDs.
  // Written as one rule rather than two because the specification writes it as
  // one and a home that mis-addresses a forward gets both fields from the same
  // place -- and reported field by field, so the message says which half broke.
  // ---------------------------------------------------------------------------
  protected function void check_snoop_fwd_names_requester(input int                  node,
                                                          input longint              line,
                                                          input vip_chi_snp_opcode_t snp_op,
                                                          input node_id_t            fwd_nid,
                                                          input txn_id_t             fwd_txn_id,
                                                          input int                  cause_node,
                                                          input node_id_t            cause_src,
                                                          input longint              cause_txn);
    if (!vip_chi_snp_opcode_is_forwarding(snp_op)) begin
      return;
    end

    this.n_snp_fwd_judged++;

    if (fwd_nid !== cause_src) begin
      this.n_snp_fwd_mismatch++;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: forwarding snoop opcode 0x%0h sent to node %0d for line 0x%0h carries FwdNID 0x%0h, but the request that caused it (node %0d, TxnID 0x%0h) came from SrcID 0x%0h -- IHI 0050 E 2.5 requires FwdNID to be the Node ID of the original Requester",
        snp_op, node, line, fwd_nid, cause_node, cause_txn, cause_src))
    end

    if (longint'(fwd_txn_id) !== cause_txn) begin
      this.n_snp_fwd_mismatch++;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: forwarding snoop opcode 0x%0h sent to node %0d for line 0x%0h carries FwdTxnID 0x%0h, but the request that caused it (node %0d, SrcID 0x%0h) is TxnID 0x%0h -- IHI 0050 E 2.5 requires FwdTxnID to be the TxnID of the original Request",
        snp_op, node, line, fwd_txn_id, cause_node, cause_src, cause_txn))
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
    // Every request kind claims the line, including the ones the ownership
    // shadow below does not model: the hazard rule is about a requester
    // overlapping itself, which does not depend on what the request does.
    this.hazard_claim(node, line, longint'(item.txn_id), longint'(wop));
    this.req_track_claim(node, line, longint'(item.txn_id), item.src_id, wop);
    // Rule D9's arming step. ReadOnce is excluded here rather than at the
    // judgement, because section 2.8.3 names it as the request for which the
    // home need not wait -- the exception belongs to the transaction.
    if (item.exp_comp_ack && (wop != VIP_CHI_REQ_READ_ONCE_E)) begin
      this.req_eca_line[node][longint'(item.txn_id)] = line;
    end
    if (this.is_coherent_read(item, uniq)) begin
      this.open_rd_line[node][longint'(item.txn_id)] = line;
      this.open_rd_uniq[node][longint'(item.txn_id)] = uniq;
      this.open_rd_op[node][longint'(item.txn_id)]   = wop;
      // Remember whether this read is an exclusive load, resolved at CompData.
      this.open_rd_excl[node][longint'(item.txn_id)] = item.excl;
    end
    // A coherent writeback carries CopyBackWrData whose TxnID is the granted DBID
    // (= this REQ's TxnID): remember the line so that data establishes the shadow.
    // It is also a store -> it breaks every reservation on the line.
    //
    // The DAT arm that closes this keys on the CopyBackWrData encoding alone, so
    // the two agree only if this arm claims the opcodes that produce it. Asked of
    // the classifier for that reason: an unclaimed CopyBack leaves its data out
    // of the shadow, and a shadow missing a write reports an agreement it never
    // checked.
    //
    // WriteEvictOrEvict is the one CopyBack excluded, and the exclusion is about
    // this entry's LIFETIME rather than about the opcode. The completer chooses
    // whether that transaction has a data phase at all, and only the DAT arm
    // deletes the entry -- so on the no-data leg an entry recorded here is never
    // claimed, and TxnIDs are reused. The stale line would then take the next
    // CopyBackWrData that happened to reuse the ID.
    else if (vip_chi_types_pkg::vip_chi_req_opcode_write_data_is_copyback(wop) &&
             (wop != VIP_CHI_REQ_WRITE_EVICT_OR_EVICT_E)) begin
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
    // ownership and run the single-writer check.
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

  // ---------------------------------------------------------------------------
  // Resolve the Requester's cache state when its own request completes.
  //
  // The dual of check_snp_resp_state, on the other axis. A snoop asks a node to
  // GIVE UP permissions and the checker bounds the answer from above; a
  // completion GRANTS permissions and the checker must not let the grant revoke
  // what the node already held. IHI 0050 E Tables 4-14, 4-17, 4-18 and 4-19; D
  // Tables 4-12 and 4-13.
  //
  // The held state is read from the shadow HERE, at the completion, not stashed
  // at the request. Tables 4-17 and 4-18 index the final state on the state "at
  // time of response" precisely because a snoop can take the line away while the
  // request is outstanding, and obs_snp has already written that loss into the
  // shadow by the time this runs.
  // ---------------------------------------------------------------------------
  protected function void resolve_req_final_state(input int                  node,
                                                  input longint              line,
                                                  input vip_chi_req_opcode_t opcode,
                                                  input vip_chi_resp_t       granted);
    vip_chi_resp_t held;
    vip_chi_resp_t final_state;
    vip_chi_resp_t from_invalid;

    held         = this.line_state.exists(line) ? vip_chi_resp_t'(this.line_state[line][node])
                                                : VIP_CHI_RESP_STATE_I_E;
    final_state  = vip_chi_req_final_state(opcode, held, granted);
    // What this same completion would have produced for a Requester holding
    // nothing. Comparing against THAT rather than against the granted Resp is
    // what isolates the held-state contribution: MakeUnique ends UD whatever it
    // held, so measuring "final != granted" would count every MakeUnique as
    // evidence for a rule it does not exercise.
    from_invalid = vip_chi_req_final_state(opcode, VIP_CHI_RESP_STATE_I_E, granted);

    this.n_req_final_judged++;
    if (final_state != from_invalid) begin
      // The held state changed the answer. Every such completion is one the
      // pre-3.2 shadow got wrong, so this count is the rule's non-vacuity
      // evidence: zero means the stimulus never presented a non-Invalid
      // requester and the rule was never actually exercised.
      this.n_req_final_retained++;
      `uvm_info("VIP_CHI_COH", $sformatf(
        "COHERENCY REQ RETAIN: node %0d line 0x%0h opcode 0x%0h held 0x%0h granted 0x%0h -> final 0x%0h",
        node, line, opcode, held, granted, final_state), UVM_HIGH)
    end

    this.rt_from_sample    = held;
    this.rt_req_op_sample  = item_t::req_opcode_t'(opcode);
    this.rt_granted_sample = granted;
    this.rt_to_sample      = final_state;
    this.cg_req_cache_transition.sample();

    this.set_node_state(line, node, final_state);
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

    // A read's CompData is its completion, so it releases the line.
    if (op == VIP_CHI_DAT_COMP_DATA_E) begin
      this.hazard_release(node, longint'(item.txn_id));
      this.req_track_release(node, longint'(item.txn_id));
    end

    // Rule D9: on a CopyBack there is no CompAck flit to wait for, and section
    // 2.8.3 says so in as many words -- "For CopyBack transactions, WriteData
    // acts as an implicit CompAck and an HN-F must wait for WriteData before
    // sending a snoop to the same address." Same window, same guarantee, closed
    // by a DAT flit instead of an RSP one.
    //
    // WriteEvictOrEvict is the only opcode this reaches today: Table 2-9 marks
    // it required, and its data leg answers CompDBIDResp with CopyBackWrData and
    // nothing else. Closing the window on the explicit CompAck alone left that
    // leg's window open forever -- visible as compack_windows_unclosed=1 in
    // tc_chi_{d,e}_write_evict_or_evict, which is what found this.
    if (op == VIP_CHI_DAT_COPY_BACK_WR_DATA_E) begin
      this.close_comp_ack_window(node, longint'(item.txn_id));
    end

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
        // The response FORM is a property of the snoop opcode, and this is the
        // only place the two are correlated: nothing on a DAT flit says which
        // snoop it answers, so a rule written on encodings alone cannot see
        // this. SnpRespData_I_PD is a legal row of Table 4-11 -- what is
        // prohibited is sending it IN ANSWER TO a snoop that returns no data.
        this.check_snp_resp_form(node, this.pending_snp_line[node], op);
        this.check_snp_resp_state(
          node, this.pending_snp_line[node],
          (item.dat_resp.size() > 0) ? item.dat_resp[item.dat_resp.size() - 1]
                                     : VIP_CHI_RESP_STATE_I_E,
          1'b1);
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
    this.resolve_req_final_state(
      node, line,
      this.open_rd_op[node].exists(longint'(item.txn_id)) ?
        this.open_rd_op[node][longint'(item.txn_id)] : vip_chi_req_opcode_t'(0),
      granted);
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
    this.open_rd_op[node].delete(longint'(item.txn_id));
    this.open_rd_excl[node].delete(longint'(item.txn_id));
    this.n_completions++;
    this.open_comp_ack_window(node, longint'(item.txn_id));
    this.check_multi_owner(line);
    // A read of a line with known (written/forwarded) data must return it.
    this.check_line_data(line, item);
  endfunction

  // ---------------------------------------------------------------------------
  // Catalogue rule D9 -- SNOOP_OUTSIDE_COMPACK_WINDOW.
  //
  // IHI 0050 E section 2.8.3 (D section 2.8.3), rule 2 of the completion
  // sequence: "An HN-F, except in the case of ReadOnce*, waits for CompAck
  // before sending a subsequent snoop to the same address." The same paragraph
  // states the guarantee from the requester's side, which is the form this rule
  // judges because it is the form that is visible on one node's wires:
  //
  //   "When an RN-F has a transaction in progress that uses CompAck, except for
  //    ReadNoSnp and ReadOnce*, then it is guaranteed not to receive a Snoop
  //    request to the same address between the point that it receives Comp and
  //    the point that it sends CompAck."
  //
  // This is the ordering guarantee CompAck exists to provide, and it is what
  // makes the acknowledgement worth sending at all. Without it the requester can
  // be snooped for a line it has been granted but not yet taken responsibility
  // for, and the completion and the snoop can be observed by the two ends in
  // opposite orders -- the precise outcome section 2.8.3 opens by ruling out.
  //
  // The window is deliberately checked across ALL nodes, not just the snooped
  // one. The home-side wording forbids the snoop outright ("a subsequent snoop
  // to the same address"), whoever it is addressed to, and a snoop sent to a
  // third node in that window is the same ordering hazard seen from a different
  // seat.
  //
  // ReadOnce is excluded when the window is opened rather than when it is
  // judged, because the exception is a property of the request, not of the
  // snoop: section 2.8.3 names ReadOnce* as the transaction for which the home
  // need not wait.
  // ---------------------------------------------------------------------------
  protected function void open_comp_ack_window(input int node, input longint txn_id);
    if (!this.req_eca_line[node].exists(txn_id)) begin
      return;
    end
    // A window still open here means the previous acknowledgement was never
    // observed. Counted rather than reported: it is a gap in what this checker
    // saw, not a protocol violation, and a summary that says so is what tells a
    // reader whether the zero beside it means "clean" or "never looked".
    if (this.eca_open[node]) begin
      this.n_eca_windows_unclosed++;
    end
    this.eca_open[node] = 1'b1;
    this.eca_line[node] = this.req_eca_line[node][txn_id];
    this.eca_txn[node]  = txn_id;
    this.req_eca_line[node].delete(txn_id);
    this.n_eca_windows++;
  endfunction

  protected function void close_comp_ack_window(input int node, input longint txn_id);
    if (this.eca_open[node] && (this.eca_txn[node] == txn_id)) begin
      this.eca_open[node] = 1'b0;
    end
  endfunction

  protected function void check_snoop_outside_comp_ack_window(input int     snooped,
                                                              input longint line);
    for (int k = 0; k < N_NODES_C; k++) begin
      if (!this.eca_open[k] || (this.eca_line[k] != line)) begin
        continue;
      end
      this.n_eca_window_snoops++;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: snoop to line 0x%0h (node %0d) arrived inside node %0d's CompAck window for TxnID 0x%0h -- section 2.8.3 requires the home to wait for CompAck before snooping the same address",
        line, snooped, k, this.eca_txn[k]))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // A data-bearing snoop response answering a snoop that must not return data.
  // IHI 0050 Chapter 4 defines SnpMakeInvalid by exactly this property -- the
  // snoopee invalidates and DISCARDS its Dirty copy -- and Tables 4-9 / 4-11
  // list no SnpRespData form among its permitted responses.
  //
  // Judged here rather than in an SVA bind because it needs the request and the
  // response paired: the snoop is on SNP and the offending flit is on DAT, with
  // no address and no field tying it back. Derived from observed traffic only,
  // so it catches a DUT snoopee as readily as this VIP's own.
  // ---------------------------------------------------------------------------
  protected function void check_snp_resp_form(input int                 node,
                                              input longint             line,
                                              input vip_chi_dat_opcode_t op);
    if (!vip_chi_snp_opcode_returns_no_data(this.pending_snp_opcode[node])) begin
      return;
    end
    this.n_bad_snp_resp_form++;
    `uvm_error("VIP_CHI_COH", $sformatf(
      "COHERENCY VIOLATION: node %0d answered snoop opcode 0x%0h on line 0x%0h with DAT opcode 0x%0h; that snoop returns no data",
      node, this.pending_snp_opcode[node], line, op))
  endfunction

  // ---------------------------------------------------------------------------
  // Catalogue rule D5: the state a snoop response reports must be one Chapter 4
  // permits for that snoop opcode. The channel half of this pairing is
  // check_snp_resp_form above; this is the Resp-encoding half, and together they
  // are the assertion twin of cg_snp_resp_legality.
  //
  // Two rules, both read off Tables 4-9 / 4-11 and both restricted to what this
  // home originates:
  //
  //   * an invalidating snoop must leave the snoopee Invalid. Otherwise the
  //     requester that is about to be granted Unique is not the only owner, and
  //     the single-writer invariant is broken without any flit looking wrong.
  //   * a shared snoop must not leave the snoopee Unique, for the same reason
  //     one step earlier: the grant that follows creates a second holder.
  //
  // Judged from observed traffic and correlated through pending_snp_opcode, so it
  // applies to a DUT snoopee exactly as it does to this VIP's own.
  // ---------------------------------------------------------------------------
  protected function void check_snp_resp_state(input int            node,
                                               input longint        line,
                                               input vip_chi_resp_t state,
                                               input bit            with_data);
    vip_chi_snp_opcode_t op;
    vip_chi_resp_t       from_state;
    vip_chi_resp_t       predicted;
    bit                  legal;
    op         = this.pending_snp_opcode[node];
    from_state = this.pending_snp_from[node];
    predicted  = this.line_state.exists(line) ? vip_chi_resp_t'(this.line_state[line][node])
                                              : VIP_CHI_RESP_STATE_I_E;
    legal      = 1'b1;

    // Coverage of the LEGAL pairings, which is what the cross is for: its
    // illegal_bins are there to catch a pairing nobody meant to produce.
    //
    // A negative control means to produce one, and an illegal bin cannot be
    // demoted the way a UVM report can -- VCS treats the hit as a verification
    // error and ABORTS the run, before the UVM report summary is ever printed.
    // So a control that injects an illegal snoop response could not pass:
    // sv_regression.sh looks for "UVM_ERROR :    0" in a log that stops before
    // that line exists, and reports FAIL with no UVM error anywhere in it.
    // tc_chi_coh_{d,e}_do_not_go_to_sd_negctl failed exactly that way, in both
    // issues, on the first sweep that ever ran them.
    //
    // Skipped only for the pairing the test declared it is injecting, and only
    // while expect_illegal_snp_resp is set: the legal pairings in the same run
    // are still recorded, and the RULES below still fire. Suppressing the rule
    // would delete the evidence the control exists to gather; suppressing the
    // bin deletes nothing, because a deliberate hit is not a measurement.
    this.sr_snp_opcode_sample    = item_t::snp_opcode_t'(op);
    this.sr_resp_state_sample    = state;
    this.sr_returned_data_sample = with_data;

    if (!(this.expect_illegal_snp_resp && this.snp_resp_hits_illegal_bin(
            op, state, with_data))) begin
      this.cg_snp_resp_legality.sample();
    end

    if (vip_chi_snp_opcode_invalidates(op) && (state != VIP_CHI_RESP_STATE_I_E)) begin
      this.n_bad_snp_resp_state++;
      legal = 1'b0;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: node %0d answered invalidating snoop opcode 0x%0h on line 0x%0h reporting state 0x%0h, but every response Chapter 4 permits to it is Invalid",
        node, op, line, state))
    end
    else if (vip_chi_snp_opcode_forbids_retaining_unique(op) &&
             ((state == VIP_CHI_RESP_STATE_UC_E) ||
              (state == VIP_CHI_RESP_STATE_UP_PD_DIRTY_E))) begin
      this.n_bad_snp_resp_state++;
      legal = 1'b0;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: node %0d answered shared snoop opcode 0x%0h on line 0x%0h still holding Unique (state 0x%0h); the grant that follows would create a second owner",
        node, op, line, state))
    end

    // -------------------------------------------------------------------------
    // DoNotGoToSD, judged from the RESPONSE rather than from the flit.
    //
    // "Snoopee receiving a Snoop request with the DoNotGoToSD bit set, except
    // when the Snoop is SnpOnceFwd, must not transition to SD." The SNP-channel
    // rule CHI_SNP_DO_NOT_GO_TO_SD_LEGAL judges whether the bit was SET where
    // the specification requires it; this judges whether the snoopee OBEYED it,
    // which is a different claim and the one that matters to a third-party DUT.
    //
    // Neither D5 nor D6 catches it. D5 bounds the reported state by the opcode,
    // and SD is not Unique, so a shared snoop answered SD passes it. D6 bounds
    // the state by what the snoopee held, and an SD holder answering SD passes
    // that too. The bit is a third bound and it needed its own arm.
    //
    // -------------------------------------------------------------------------
    if ((state == VIP_CHI_RESP_STATE_SD_PD_DIRTY_E) &&
        this.pending_snp_no_sd[node] &&
        (op != VIP_CHI_SNP_ONCE_FWD_C)) begin
      this.n_bad_snp_sd_under_no_sd++;
      legal = 1'b0;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: node %0d answered snoop opcode 0x%0h on line 0x%0h reporting SD, but that snoop carried DoNotGoToSD = 1 and is not SnpOnceFwd; the snoopee must not transition to SD",
        node, op, line))
    end

    // -------------------------------------------------------------------------
    // Catalogue rule D6: the reported state must not hold a permission the
    // snoopee did not have when the snoop arrived.
    //
    // D5 above bounds the response by what was ASKED; this bounds it by what was
    // HELD, and neither implies the other -- an SC holder answering SnpOnce with
    // UC passes every opcode-keyed rule and is still impossible. A snoop is a
    // request to give up permissions, never a grant of them; the only path that
    // raises a cache state is a response to that node's own request, on a
    // transaction this snoop knows nothing about.
    //
    // It is a gate and not merely a report, because the reported state is now
    // ADOPTED into the shadow directory below. Without it a peer reporting
    // nonsense would steer every later coherency check through the nonsense.
    // -------------------------------------------------------------------------
    if (vip_chi_snp_resp_state_gains_permission(from_state, state)) begin
      this.n_snp_resp_gains_permission++;
      legal = 1'b0;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: node %0d held state 0x%0h on line 0x%0h and answered snoop opcode 0x%0h reporting state 0x%0h; a snoop cannot grant a permission the snoopee did not already hold",
        node, from_state, line, op, state))
    end

    // -------------------------------------------------------------------------
    // Catalogue rule D7: a snoopee holding Dirty must hand the dirty data over
    // unless it is keeping it.
    //
    // IHI 0050 E Tables 4-30 to 4-34 (Snoopee state transitions) enumerate this
    // row by row: every row whose INITIAL state is UD, UDP or SD and whose final
    // state does not hold the dirty requires a SnpRespData_*_PD response. The
    // only rows where a Dirty snoopee answers without data are the ones where it
    // stays Dirty -- UD -> UD, UD -> SD, SD -> SD.
    //
    // Answering SnpResp_SC from UD instead loses the only modified copy in the
    // system: the snoopee has dropped its claim to the line, the Home believes
    // memory is current, and the next reader is served stale data with every
    // check agreeing. Nothing else here catches it -- the reported STATE is
    // legal (D5 and D6 both pass SC from UD), and the existing response-form
    // rule reads the other direction, flagging data returned where none was
    // wanted. This is the missing direction: data NOT returned where it was owed.
    //
    // SnpMakeInvalid is excluded because discarding is precisely what it asks
    // for, which is the rule check_snp_resp_form polices.
    // -------------------------------------------------------------------------
    if (vip_chi_state_holds_dirty(from_state)   &&
        !vip_chi_state_holds_dirty(state)       &&
        !vip_chi_snp_opcode_returns_no_data(op) &&
        !with_data) begin
      this.n_snp_dirty_lost++;
      `uvm_error("VIP_CHI_COH", $sformatf(
        "COHERENCY VIOLATION: node %0d held state 0x%0h (Dirty) on line 0x%0h and answered snoop opcode 0x%0h with state 0x%0h and NO data; the dirty copy is neither retained nor passed on",
        node, from_state, line, op, state))
    end

    // -------------------------------------------------------------------------
    // Catalogue rule D10: a snoop the specification forbids to change the
    // snoopee's state must be answered with the state the snoopee held.
    //
    // IHI 0050 E 4.5, SnpQuery: "The SnpQuery snoop must not change the state of
    // the cache line at the Snoopee." Table 4-26 gives every initial state
    // itself as the expected final state, with no permitted alternative.
    //
    // Every other rule here bounds the answer from ABOVE -- D5 by what the
    // opcode asked for, D6 by what the snoopee held, D7 by whether the dirty
    // survived somewhere. A snoopee that answers a SnpQuery by dropping a clean
    // line to Invalid passes all three: it asked for nothing, so nothing was
    // refused; it claims less than it held, so no permission was invented;
    // nothing dirty was lost. The line is simply gone, and the home has been
    // handed a precise answer that is precisely wrong -- which is worse than a
    // stale filter, because the home asked in order to STOP trusting the stale
    // one.
    //
    // Compared through vip_chi_snp_resp_dataless_state and not directly. The
    // held state comes from the shadow in the cache-state encoding; the answer
    // is on RSP in Table 4-9's, where UD and UC share a row. A UD holder
    // answering a SnpQuery correctly reports 0b010, and a raw comparison would
    // call that a violation on every dirty line.
    // -------------------------------------------------------------------------
    if (vip_chi_snp_opcode_preserves_state(op) && !with_data) begin
      this.n_snp_preserving_judged++;
      if (state != vip_chi_snp_resp_dataless_state(from_state)) begin
        this.n_bad_snp_state_preserved++;
        legal = 1'b0;
        `uvm_error("VIP_CHI_COH", $sformatf(
          "COHERENCY VIOLATION: node %0d held state 0x%0h on line 0x%0h and answered snoop opcode 0x%0h reporting state 0x%0h; that snoop must not change the state, so the only answer it permits is 0x%0h",
          node, from_state, line, op, state,
          vip_chi_snp_resp_dataless_state(from_state)))
      end
    end

    // Non-vacuity: how many responses this rule actually had to judge. A zero
    // violation count says nothing on its own -- see n_snp_no_data_on_dirty.
    this.n_snp_resp_judged++;

    // -------------------------------------------------------------------------
    // Take the snoopee's next state FROM THE RESPONSE.
    //
    // The snoop opcode CONSTRAINS the resulting state but does not determine it:
    // a UD holder answering SnpShared may pass the dirty data on and report SC,
    // or keep it and report SD, and which one happened is knowable only here.
    // Deriving it from the opcode alone -- what snoop_result() does, and what
    // this checker did everywhere before D6 -- records what a snoop WOULD do to
    // this VIP's own RN-F, which against any other peer is an assumption
    // presented as an observation. One desynchronized entry then misdirects the
    // single-writer check, the occupancy count and the data-integrity shadow, and
    // every message they produce points at the peer.
    //
    // snoop_result() keeps its job as the PREDICTION: the shadow needs a value
    // between the snoop and its response, and obs_snp still writes one. This
    // reconciles it. An illegal response is not adopted -- D5 and D6 have already
    // reported it, and steering the model with a value known to be wrong would
    // turn one reported violation into a run of unexplained ones.
    // -------------------------------------------------------------------------
    //
    // A state-preserving snoop is the exception, and it is an exception about
    // the ENCODING rather than about the response. Adopting there would DESTROY
    // information: Table 4-9 gives UD and UC one row, so a correct answer from a
    // dirty holder reads as UC, and writing that back tells the shadow the line
    // is clean -- the one thing the query was never able to say. The snoop
    // changed nothing, so the entry already held is both current and strictly
    // more precise than the answer. A lossy report cannot refine a model that
    // distinguishes more states than the report can name.
    if (legal && !vip_chi_snp_opcode_preserves_state(op)) begin
      if (state != predicted) begin
        this.n_snp_resp_state_differs++;
      end
      this.set_node_state(line, node, state);
      this.n_snp_resp_adopted++;
      // The transition covergroup records the OBSERVED outcome, so it is sampled
      // here rather than at the snoop. Sampled on the prediction it was a pure
      // function of its own inputs, which is why cp_to's illegal_bins could never
      // fire: snoop_result() provably returns only I or SC. Against observed
      // traffic the guard is live.
      this.ct_from_sample       = from_state;
      this.ct_snp_opcode_sample = item_t::snp_opcode_t'(op);
      this.ct_to_sample         = state;
      if (this.snoop_samples_cache_transition(item_t::snp_opcode_t'(op))) begin
        this.cg_cache_transition.sample();
      end
      this.sample_occupancy(line);
    end
  endfunction

  protected function void obs_snp(input int node, input item_t item);
    longint        line;
    vip_chi_resp_t cur;
    vip_chi_resp_t predicted;
    if (!this.enable || !item.is_snoop) begin
      return;
    end
    line = this.line_of(longint'(item.snp_addr));
    cur  = this.line_state.exists(line) ? vip_chi_resp_t'(this.line_state[line][node])
                                        : VIP_CHI_RESP_STATE_I_E;
    // The PREDICTED result, applied to the shadow so the window between a snoop
    // and its response is not modeled as if the snoop had not happened. It is
    // reconciled against the state the response actually reports in
    // check_snp_resp_state, which is where cg_cache_transition is now sampled --
    // the covergroup records the observed outcome, not this guess.
    predicted = this.snoop_result(item.snp_opcode, cur);
    this.set_node_state(line, node, predicted);
    // An invalidating snoop (result Invalid) to this node breaks its exclusive
    // reservation on the line -- the same clear path (b) the HN-F wires at its
    // snoop sites, derived here independently from the observed snoop. Keyed off
    // the snoop and not the response on purpose: it is the snoop that breaks the
    // reservation, whatever the snoopee goes on to report.
    if (predicted == VIP_CHI_RESP_STATE_I_E) begin
      if (this.excl_ll_valid[node].exists(line) && this.excl_ll_valid[node][line]) begin
        this.excl_clear_cause[node][line] = EXCL_CLEAR_SNOOP;
        this.excl_ll_valid[node][line]    = 1'b0;
      end
    end
    // Remember the snooped line so a dirty node's SnpRespData (which carries no
    // address) can be attributed back to it. The HN-F engine is serial, so at
    // most one snoop is outstanding per node.
    if (vip_chi_snp_opcode_returns_no_data(vip_chi_snp_opcode_t'(item.snp_opcode))
        && this.state_is_dirty(cur)) begin
      this.n_snp_no_data_on_dirty++;
    end
    // Rule D8 runs before the shadow bookkeeping below so it judges the snoop as
    // it arrives, on the request set outstanding at that moment.
    this.check_snoop_matches_request(node, line, vip_chi_snp_opcode_t'(item.snp_opcode),
                                     item.fwd_nid, item.fwd_txn_id);
    // D9 alongside D8, and for the same reason: both judge the snoop as it
    // arrives, against state that the bookkeeping below is about to change.
    this.check_snoop_outside_comp_ack_window(node, line);
    this.pending_snp_line[node]   = line;
    this.pending_snp_valid[node]  = 1'b1;
    this.pending_snp_opcode[node] = vip_chi_snp_opcode_t'(item.snp_opcode);
    // The from-state, kept because the shadow above no longer holds it and D6
    // needs it to bound what the response may legally report.
    this.pending_snp_from[node]   = cur;
    this.pending_snp_no_sd[node]  = item.do_not_go_to_sd;
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
    // A data-less snoop response. This checker watched SnpRespData on DAT and
    // nothing on RSP, so until D5 it could not see the response form a clean
    // snoopee actually sends -- which is most of them. Handled first and returned
    // from: a SnpResp carries the SNOOP's TxnID, so letting it fall through to
    // the completion correlation below would look it up against request tables it
    // was never entered in.
    if ((item.rsp_opcode === item_t::rsp_opcode_t'(VIP_CHI_RSP_SNP_RESP_C)) ||
        (item.rsp_opcode === item_t::rsp_opcode_t'(VIP_CHI_RSP_SNP_RESP_FWDED_C))) begin
      if (this.pending_snp_valid[node]) begin
        this.check_snp_resp_state(node, this.pending_snp_line[node],
                                  item.rsp_resp, 1'b0);
        this.pending_snp_valid[node] = 1'b0;
      end
      return;
    end

    // A CompAck closes rule D9's window and is not a completion of anything --
    // handled first and returned from, exactly like SnpResp above, so it cannot
    // fall through into the correlation tables it was never entered in.
    if (item.rsp_opcode === item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_ACK_C)) begin
      this.close_comp_ack_window(node, longint'(item.txn_id));
      return;
    end

    // A data-less completion (CleanUnique, MakeUnique, WriteUnique) opens the
    // window that CompData opens for a read. NOT hazard_release_rsp: that set
    // includes RetryAck, which releases the line without completing anything.
    // Opening a window on a bounced request would leave one hanging that no
    // CompAck can ever close -- the re-issue completes under the same TxnID and
    // opens its own -- and every snoop to that line in between would be reported
    // against a transaction the completer had refused outright.
    if ((item.rsp_opcode === item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) ||
        (item.rsp_opcode === item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_DBID_RESP_C)) ||
        (item.rsp_opcode === item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_PERSIST_C))) begin
      this.open_comp_ack_window(node, longint'(item.txn_id));
    end

    // Release the line on a genuine completion (see hazard_release_rsp).
    if (this.hazard_release_rsp(item.rsp_opcode)) begin
      this.hazard_release(node, longint'(item.txn_id));
      this.req_track_release(node, longint'(item.txn_id));
    end
    // MakeUnique completion (RSP-only Comp): mark the requester the Unique owner
    // and run the single-writer check -- the ownership shadow is otherwise updated
    // only by CompData (obs_dat), so without this a MakeUnique never registers as
    // an owner and a suppressed-snoop duplicate-owner bug would pass.
    if (this.open_mu_line[node].exists(longint'(item.txn_id))) begin
      line = this.open_mu_line[node][longint'(item.txn_id)];
      // Validate the OBSERVED completion rather than inventing a state: a
      // MakeUnique must complete with a data-less Comp, and a completer that
      // returns any other opcode is a protocol error.
      if (item.rsp_opcode !== item_t::rsp_opcode_t'(VIP_CHI_RSP_COMP_C)) begin
        this.n_bad_make_unique++;
        `uvm_error("VIP_CHI_COH", $sformatf(
          "COHERENCY VIOLATION: MakeUnique on line 0x%0h (node %0d) completed opcode=0x%0h resp=0x%0h, expected a data-less Comp",
          line, node, item.rsp_opcode, item.rsp_resp))
      end
      // The GRANTED state on that Comp is Comp_UC. MakeUnique's final state is
      // Unique-Dirty from every permitted initial state, but the Requester
      // becomes Dirty by its own act of overwriting the whole line -- no dirty
      // data is being handed to it -- and the response says so: Table 4-19 (D
      // Table 4-13) lists Comp_UC as the completion for MakeUnique, and Comp_UD_PD
      // means "responsibility for a Dirty cache line is being passed", which is a
      // different transaction. Issue D does not define the UD_PD encoding for a
      // data-less completion at all (Table 4-5 lists only Comp_I, Comp_UC and
      // Comp_SC), so requiring it here rejected the one legal answer and demanded
      // one a CHI-D completer may not send.
      if (item.rsp_resp !== VIP_CHI_RESP_STATE_UC_E) begin
        this.n_bad_dataless_resp++;
        `uvm_error("VIP_CHI_COH", $sformatf(
          "COHERENCY VIOLATION: MakeUnique on line 0x%0h (node %0d) completed resp=0x%0h; Table 4-19 permits only Comp_UC (0x%0h) for this request",
          line, node, item.rsp_resp, VIP_CHI_RESP_STATE_UC_E))
      end
      // The final state still comes from the shared table function, which is what
      // turns that Comp_UC into the Unique-Dirty the Requester ends up holding.
      this.resolve_req_final_state(node, line, VIP_CHI_REQ_MAKE_UNIQUE_E, item.rsp_resp);
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
  function int get_bad_snp_resp_form_count(); return this.n_bad_snp_resp_form; endfunction
  function int get_snp_no_data_on_dirty_count(); return this.n_snp_no_data_on_dirty; endfunction
  function int get_bad_snp_resp_state_count(); return this.n_bad_snp_resp_state; endfunction
  function int get_bad_snp_sd_under_no_sd_count(); return this.n_bad_snp_sd_under_no_sd; endfunction
  function int get_snp_resp_judged_count(); return this.n_snp_resp_judged; endfunction
  function int get_snp_resp_gains_permission_count(); return this.n_snp_resp_gains_permission; endfunction
  function int get_snp_resp_adopted_count(); return this.n_snp_resp_adopted; endfunction
  function int get_snp_resp_state_differs_count(); return this.n_snp_resp_state_differs; endfunction
  function int get_req_final_judged_count();   return this.n_req_final_judged;   endfunction
  function int get_req_final_retained_count(); return this.n_req_final_retained; endfunction
  function int get_bad_dataless_resp_count();  return this.n_bad_dataless_resp;  endfunction
  function int get_snp_dirty_lost_count();     return this.n_snp_dirty_lost;     endfunction
  function int get_snp_req_spontaneous_count();      return this.n_snp_req_spontaneous;      endfunction
  function int get_bad_snp_state_preserved_count(); return this.n_bad_snp_state_preserved; endfunction
  function int get_snp_preserving_judged_count();   return this.n_snp_preserving_judged;   endfunction
  function int get_snp_req_judged_count();       return this.n_snp_req_judged;       endfunction
  function int get_snp_req_mismatch_count();     return this.n_snp_req_mismatch;     endfunction
  function int get_snp_req_uncorrelated_count(); return this.n_snp_req_uncorrelated; endfunction
  function int get_snp_fwd_judged_count();       return this.n_snp_fwd_judged;       endfunction
  function int get_snp_fwd_mismatch_count();     return this.n_snp_fwd_mismatch;     endfunction
  function int get_comp_ack_window_count();          return this.n_eca_windows;          endfunction
  function int get_comp_ack_window_snoop_count();    return this.n_eca_window_snoops;    endfunction
  function int get_comp_ack_window_unclosed_count(); return this.n_eca_windows_unclosed; endfunction
  function real get_snp_resp_legality_coverage(); return this.cg_snp_resp_legality.get_coverage(); endfunction
  function real get_req_snp_pairing_coverage(); return this.cg_req_snp_pairing.get_coverage(); endfunction
  function int get_req_snp_pairs_count(); return this.rs_pair_hit.size(); endfunction
  function int get_line_hazard_count(); return this.n_line_hazard; endfunction
  // Clean claim/release pairs. A test asserts on this to show the hazard rule
  // actually evaluated, rather than reading a zero violation count from a run
  // where no request ever claimed a line.
  function int get_line_clear_count(); return this.n_line_clear; endfunction

  // Functional coverage of the (from-state x snoop-opcode -> to-state) cache
  // transition covergroup, sampled on every observed snoop. Lets a constrained-
  // random sweep self-verify that it closed more of the reachable cross than the
  // deterministic scenario tests hit individually.
  //
  // Denominator-neutral on purpose. The number of reachable bins is a property
  // of the bin declarations above and moves whenever a snoop opcode or a state
  // joins or leaves them, so a count written here is a second copy that rots --
  // and the covergroup already computes the ratio this returns.
  function real get_cache_transition_coverage(); return this.cg_cache_transition.get_coverage(); endfunction

  // ---------------------------------------------------------------------------
  // Summary.
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY CHECKER SUMMARY: completions=%0d snoops=%0d multi_owner_violations=%0d data_mismatches=%0d excl_violations=%0d bad_make_unique=%0d",
      this.n_completions, this.n_snoops, this.n_multi_owner, this.n_coherent_data_mismatch, this.n_excl_violation, this.n_bad_make_unique), UVM_LOW)
    // Its own line, short enough never to be wrapped by the report server: the
    // tally has to stay greppable across a whole regression for the check to be
    // provably non-vacuous. Same reason for the snoop-response-form line below.
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY SNP RESP FORM SUMMARY: no_data_snoops_on_dirty=%0d bad_snp_resp_form=%0d",
      this.n_snp_no_data_on_dirty, this.n_bad_snp_resp_form), UVM_LOW)
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY SNP RESP STATE SUMMARY: snp_resp_judged=%0d bad_snp_resp_state=%0d snp_dirty_lost=%0d",
      this.n_snp_resp_judged, this.n_bad_snp_resp_state, this.n_snp_dirty_lost), UVM_LOW)
    // Its own line, for the reason the comment below repeats: the report server
    // wraps long lines and a wrapped field=value pair cannot be swept with grep.
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY DO NOT GO TO SD SUMMARY: bad_snp_sd_under_no_sd=%0d",
      this.n_bad_snp_sd_under_no_sd), UVM_LOW)
    // Its own line for the same reason as the others: a wrapped field=value pair
    // cannot be swept for with grep across a regression.
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY SNP PRESERVE SUMMARY: snp_preserving_judged=%0d bad_snp_state_preserved=%0d",
      this.n_snp_preserving_judged, this.n_bad_snp_state_preserved), UVM_LOW)
    // Its own line for the same reason as the two above: the report server wraps
    // long lines, and a wrapped field=value pair cannot be swept for with grep.
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY SNP RESP ADOPT SUMMARY: snp_resp_adopted=%0d snp_resp_state_differs=%0d snp_resp_gains_permission=%0d",
      this.n_snp_resp_adopted, this.n_snp_resp_state_differs, this.n_snp_resp_gains_permission), UVM_LOW)
    // Its own line for the same reason as the three above: the report server
    // wraps long lines, and a wrapped field=value pair cannot be swept for with
    // grep across a regression.
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY REQ FINAL STATE SUMMARY: req_final_judged=%0d req_final_retained=%0d bad_dataless_resp=%0d",
      this.n_req_final_judged, this.n_req_final_retained, this.n_bad_dataless_resp), UVM_LOW)
    // Its own line for the same reason as the four above.
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY COMPACK WINDOW SUMMARY: compack_windows=%0d compack_window_snoops=%0d compack_windows_unclosed=%0d",
      this.n_eca_windows, this.n_eca_window_snoops, this.n_eca_windows_unclosed), UVM_LOW)
    `uvm_info(get_name(), $sformatf(
      "COHERENCY SNP REQ MATCH SUMMARY: snp_req_judged=%0d snp_req_mismatch=%0d snp_req_uncorrelated=%0d snp_req_spontaneous=%0d",
      this.n_snp_req_judged, this.n_snp_req_mismatch, this.n_snp_req_uncorrelated,
      this.n_snp_req_spontaneous), UVM_LOW)
    // Its own line: the report server wraps a long one, and a wrapped
    // `field=value` is invisible to the sweeps that grep for these.
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY SNP FWD NAMES SUMMARY: snp_fwd_judged=%0d snp_fwd_mismatch=%0d",
      this.n_snp_fwd_judged, this.n_snp_fwd_mismatch), UVM_LOW)
    // Its own line: the report server wraps a long one, and a wrapped
    // `field=value` is invisible to the sweeps that grep for these.
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY REQ SNP PAIRING SUMMARY: req_snp_pairs=%0d req_snp_pairing_coverage=%0.1f",
      this.rs_pair_hit.size(), this.cg_req_snp_pairing.get_coverage()), UVM_LOW)
    `uvm_info("VIP_CHI_COH", $sformatf(
      "COHERENCY HAZARD SUMMARY: line_hazards=%0d line_claims_cleared=%0d",
      this.n_line_hazard, this.n_line_clear), UVM_LOW)
  endfunction

endclass

`endif
