// Negative control for the two MTE tag checks.
//
// The checks added alongside this test would be worth nothing if they could not
// fail, and a tag path that has been replaying correctly for its whole life
// gives them no chance to. cfg.snf_corrupt_tag makes the completer break both
// rules, in two INDEPENDENT ways, because the two fail independently:
//
//   the TAG comes back with its low bit flipped -- a corrupt tag store.
//   the TAGOP comes back flipped too -- a completer that invented a TagOp
//   instead of replaying the one it was given.
//
// Both must be reported. A control that broke only one would leave the other
// unproven.
//
// Both breakages land on the same beat, and that is forced by the link rather
// than chosen: the only MTE-capable link here is 64 bytes and CHI's maximum
// transfer Size is 64 bytes, so every MTE transfer has exactly one beat. The
// scoreboard's third rule -- one TagOp across the beats of a transfer -- cannot
// be provoked here at all for the same reason, and is recorded as unreachable
// where it is defined rather than left to look exercised.
//
// The induced errors are demoted by a report catcher so they do not count
// against the regression verdict, and the counters are asserted directly.

class tc_chi_e_tag_negctl extends chi_e_base_test;

  typedef vip_chi_item #(CHI_E_WIDE_CFG_C) item_t;

  `uvm_component_utils(tc_chi_e_tag_negctl)

  // One beat: the wide CHI-E link is 64 bytes and CHI's maximum transfer Size is
  // also 64 bytes. See the note in tc_chi_e_tag_integrity.
  localparam int N_BEATS_C = 1;
  localparam int SETTLE_C  = 40;

  chi_tag_negctl_catcher sb_catcher;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // Break the completer's tag replay.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.snf_cfg.snf_corrupt_tag = 1'b1;
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.sb_catcher = new("tag_negctl_catcher");
  endfunction

  // ---------------------------------------------------------------------------
  // Run Phase
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    item_t::data_t write_data[$];
    item_t::tag_t  write_tag[$];
    item_t::tu_t   write_tu[$];
    int            tag_bad;
    int            tagop_bad;

    phase.raise_objection(this);

    uvm_report_cb::add(null, this.sb_catcher);
    // Both reachable tag rules are broken here on purpose, declared one by
    // one so the aggregation records them as provoked -- and so a THIRD,
    // unintended scoreboard violation would still be reported.
    super.tb_env.scoreboard.expect_failure(VIP_CHI_SB_CHK_READ_TAG_MATCHES_E);
    super.tb_env.scoreboard.expect_failure(VIP_CHI_SB_CHK_READ_TAGOP_REPLAYED_E);

    for (int i = 0; i < N_BEATS_C; i++) begin
      write_data.push_back(item_t::data_t'(64'h5A5A_0000_0000_0000 + i));
      write_tag.push_back(item_t::tag_t'(i + 1));
      write_tu.push_back(item_t::tu_t'(1));
    end

    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(E_TAG_NEGCTL_ADDR_C);
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_src_id(RNI_NODE_ID_C);
    super.rni_wr_seq.set_tgt_id(SNF_NODE_ID_C);
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
    super.rni_rd_seq.set_initial_addr(E_TAG_NEGCTL_ADDR_C);
    super.rni_rd_seq.set_size(3'd6);
    super.rni_rd_seq.set_src_id(RNI_NODE_ID_C);
    super.rni_rd_seq.set_tgt_id(SNF_NODE_ID_C);
    super.rni_rd_seq.set_get_response(1'b1);
    super.rni_rd_seq.set_verbose(1'b0);
    super.rni_rd_seq.start(super.tb_env.rni_agent.sequencer);
    void'(super.rni_rd_seq.get_responses());

    super.wait_clocks(SETTLE_C);

    tag_bad   = super.tb_env.scoreboard.get_tag_mismatch_count();
    tagop_bad = super.tb_env.scoreboard.get_tagop_replay_mismatch_count();

    if (tag_bad == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the completer returned a corrupted tag and the read-back check reported nothing - it is vacuous",
        super.tc_name))
    end

    if (tagop_bad == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the completer returned a TagOp it was never given and the replay check reported nothing - it is vacuous",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] a corrupted tag was reported %0d time(s) and a corrupted TagOp %0d time(s); both reachable rules fire",
      super.tc_name, tag_bad, tagop_bad), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
