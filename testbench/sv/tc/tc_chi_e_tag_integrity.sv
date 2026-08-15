// MTE tag read-back integrity, checked rather than merely modelled.
//
// The exact-CHI-E completer has kept a per-beat tag store and replayed it since
// it was written, and nothing ever checked what came back. A model nothing
// checks is the same defect as a check nothing exercises, seen from the other
// side: it can be wrong for a whole regression without one test noticing.
//
// A multi-beat tagged write, then a read of the same line. The scoreboard
// predicts tag and TagUpdate per beat alongside the data it already predicted,
// and the read-back must match.
//
// The assertion that matters is NOT "no mismatches" -- a scoreboard that
// compared nothing would satisfy that too, which is the whole lesson of the
// vacuity work. It is "tags were COMPARED, and none mismatched". Zero out of
// zero is not a pass.

class tc_chi_e_tag_integrity extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_tag_integrity)

  // ONE beat, and that is a property of the link rather than a choice: the wide
  // CHI-E link is 64 bytes and CHI's maximum transfer Size is also 64 bytes, so
  // every MTE transfer here is a single beat. Asking for four and asserting on
  // four is how the first cut of this test failed.
  localparam int N_BEATS_C  = 1;
  localparam int SETTLE_C   = 40;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::data_t write_data[$];
    item_t::tag_t  write_tag[$];
    item_t::tu_t   write_tu[$];
    int            checked;
    int            tag_bad;
    int            tagop_bad;

    phase.raise_objection(this);

    for (int i = 0; i < N_BEATS_C; i++) begin
      write_data.push_back(item_t::data_t'(64'hA5A5_0000_0000_0000 + i));
      write_tag.push_back(item_t::tag_t'(i + 1));
      write_tu.push_back(item_t::tu_t'(1));
    end

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_TAG_INTEGRITY_ADDR_C);
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_src_id(RNI_NODE_ID_C);
    super.rni_wr_seq.set_tgt_id(SNF_NODE_ID_C);
    super.rni_wr_seq.set_allow_retry(1'b0);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.set_data(write_data);
    super.rni_wr_seq.set_dat_tagop(E_MTE_WRITE_TAGOP_C);
    super.rni_wr_seq.set_tag(write_tag);
    super.rni_wr_seq.set_tu(write_tu);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);
    void'(super.rni_wr_seq.get_responses());

    super.rni_rd_seq.reset();
    super.rni_rd_seq.set_requests(1);
    super.rni_rd_seq.set_initial_addr(E_TAG_INTEGRITY_ADDR_C);
    super.rni_rd_seq.set_size(3'd6);
    super.rni_rd_seq.set_src_id(RNI_NODE_ID_C);
    super.rni_rd_seq.set_tgt_id(SNF_NODE_ID_C);
    super.rni_rd_seq.set_allow_retry(1'b0);
    super.rni_rd_seq.set_get_response(1'b1);
    super.rni_rd_seq.set_verbose(1'b0);
    super.rni_rd_seq.start(super.tb_env.rni_agent.sequencer);
    void'(super.rni_rd_seq.get_responses());

    super.wait_clocks(SETTLE_C);

    checked   = super.tb_env.scoreboard.get_tag_checked_count();
    tag_bad   = super.tb_env.scoreboard.get_tag_mismatch_count();
    tagop_bad = super.tb_env.scoreboard.get_tagop_replay_mismatch_count();

    // The half a clean run cannot show you: the scoreboard must actually have
    // compared tags. Without this the two assertions below hold on a scoreboard
    // that never predicted a single one.
    if (checked < N_BEATS_C) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the scoreboard compared %0d tag(s) against a %0d-beat tagged write; the tag path is not being checked at all",
        super.tc_name, checked, N_BEATS_C))
    end

    if (tag_bad != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d tag mismatch(es) on a read-back of tags this test wrote",
        super.tc_name, tag_bad))
    end

    // The REPLAY rule, which needs only one beat and is therefore the reachable
    // one here. The across-beats rule cannot fire on a single-beat link; see the
    // note on it in vip_chi_scoreboard.
    if (tagop_bad != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d TagOp replay mismatch(es) on a read-back of a TagOp this test wrote",
        super.tc_name, tagop_bad))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d tag(s) compared on read-back, all matching, and the TagOp replayed as written",
      super.tc_name, checked), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
