// ===========================================================================
// chi_coh_read_clean_snoop_base_test
//
// The snoop a Home sends must be one IHI 0050 E Table 4-5 / D Table 4-3 permits
// for the request that caused it. This is the directed positive test for the
// ReadClean row, on both of its paths.
//
// The table gives ReadClean SnpCleanFwd as the expected snoop and SnpClean as
// the alternative. The bullet list under the table then widens the row twice,
// and asymmetrically -- which is the reason this test drives both paths:
//
//   "Use SnpNotSharedDirty or SnpShared or SnpClean for ReadNotSharedDirty,
//    ReadShared and ReadClean transactions."
//   "Use SnpNotSharedDirtyFwd or SnpCleanFwd for ReadNotSharedDirty and
//    ReadClean transactions."
//
// SnpShared is permitted for a ReadClean. SnpSharedFwd is not, and no other
// bullet reaches it. The asymmetry is not editorial: a forwarding snoop hands
// the line straight to the requester in a state the SNOOPEE picks, and Table
// 4-34 permits a UD or SD snoopee answering SnpSharedFwd to forward
// CompData_SD_PD. Table 4-14's ReadClean rows permit final SC or UC and nothing
// else. So SnpSharedFwd for a ReadClean can put the requester in a state its own
// request forbids, with no individual flit being illegal.
//
//   DCT off:
//     RN-F0 ReadUnique L   -> RN-F0 UC, sole holder
//     RN-F1 ReadClean  L   -> HN-F must snoop RN-F0 with SnpClean (0x02)
//   DCT on:
//     RN-F0 ReadUnique L   -> invalidates RN-F1 (forwarding unique snoop)
//     RN-F1 ReadClean  L   -> single holder, so the home takes the DCT path and
//                             must snoop RN-F0 with SnpCleanFwd (0x12)
//
// Before Table 4-5 was modeled the home chose its snoop from a single is_unique
// bit, so both of those were SnpShared / SnpSharedFwd -- ReadClean was snooped
// as though it were a ReadShared. The regression could not see it: no test drove
// ReadClean on the DCT path at all, and the transition covergroup's snoop bins
// were drawn from the set of opcodes the home DID send, so the two opcodes that
// should have been there were not even counted as missing.
//
// Used by:
//   tc_chi_coh_d_read_clean_snoop    (CHI-D)
//   tc_chi_coh_e_read_clean_snoop  (wide CHI-E)
// ===========================================================================
class chi_coh_read_clean_snoop_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_read_clean_snoop_base_test #(CFG_P, TYPES_T))

  vip_chi_readclean_seq #(CFG_P) hrnf1_rdclean_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf1_rdclean_seq = vip_chi_readclean_seq #(CFG_P)::type_id::create("hrnf1_rdclean_seq");
  endfunction

  // Drain and return the single snoop RN-F0 observed, fataling if the count is
  // not exactly one -- an extra snoop would make the opcode assertion below
  // ambiguous about which one it read.
  protected function item_t::snp_opcode_t sole_snoop_opcode(input string what);
    item_t snp_item;
    item_t extra;
    if (!super.tb_env.hrnf0_snp_fifo.try_get(snp_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 observed no snoop for the %s", super.tc_name, what))
    end
    if (super.tb_env.hrnf0_snp_fifo.try_get(extra)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 observed more than one snoop for the %s (second opcode 0x%0h)",
        super.tc_name, what, extra.snp_opcode))
    end
    return snp_item.snp_opcode;
  endfunction

  task run_phase(input uvm_phase phase);

    item_t::snp_opcode_t got;
    item_t               drain;
    int                  judged_before;

    phase.raise_objection(this);

    super.wait_reset_settle();

    judged_before = super.tb_env.coh_checker.get_snp_req_judged_count();

    // ---- Path 1: no DCT. RN-F0 takes the line Unique, RN-F1 ReadCleans it. ----
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    // RN-F0 was Invalid, so its ReadUnique snooped nobody; drain anything the
    // fifo picked up so the ReadClean's snoop is the only entry in it.
    while (super.tb_env.hrnf0_snp_fifo.try_get(drain)) begin
    end

    this.cfg_read_seq(this.hrnf1_rdclean_seq);
    this.hrnf1_rdclean_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(this.hrnf1_rdclean_seq.get_responses());

    super.wait_clocks(8);

    got = this.sole_snoop_opcode("non-forwarded ReadClean");
    if (got != item_t::snp_opcode_t'(VIP_CHI_SNP_CLEAN_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] ReadClean snooped with 0x%0h, expected SnpClean (0x%0h) -- Table 4-5 gives ReadClean SnpClean, not the SnpShared (0x%0h) an is_unique bit produces",
        super.tc_name, got, VIP_CHI_SNP_CLEAN_C, VIP_CHI_SNP_SHARED_C))
    end

    // ---- Path 2: DCT. The home forwards from the single holder. ----
    super.hnf_cfg.hnf_enable_snoop_fwd = 1'b1;

    // RN-F0 re-acquires Unique (this invalidates RN-F1, leaving RN-F0 the sole
    // holder again so the next ReadClean qualifies for the forwarding path).
    this.cfg_read_seq(super.hrnf0_rdunique_seq);
    super.hrnf0_rdunique_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdunique_seq.get_responses());

    while (super.tb_env.hrnf0_snp_fifo.try_get(drain)) begin
    end

    this.cfg_read_seq(this.hrnf1_rdclean_seq);
    this.hrnf1_rdclean_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(this.hrnf1_rdclean_seq.get_responses());

    super.wait_clocks(8);

    got = this.sole_snoop_opcode("forwarded ReadClean");
    if (got != item_t::snp_opcode_t'(VIP_CHI_SNP_CLEAN_FWD_C)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] forwarded ReadClean snooped with 0x%0h, expected SnpCleanFwd (0x%0h) -- SnpSharedFwd (0x%0h) is permitted for ReadShared and for nothing else",
        super.tc_name, got, VIP_CHI_SNP_CLEAN_FWD_C, VIP_CHI_SNP_SHARED_FWD_C))
    end

    // Catalogue rule D8 must have had something to judge. Without this the two
    // opcode assertions above could both pass while the checker's correlation
    // silently found no cause for any snoop and judged nothing at all.
    if (super.tb_env.coh_checker.get_snp_req_judged_count() <= judged_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] catalogue rule D8 judged no snoop against its request (judged %0d, was %0d) -- the request/snoop correlation is not working",
        super.tc_name,
        super.tb_env.coh_checker.get_snp_req_judged_count(), judged_before))
    end

    if (super.tb_env.coh_checker.get_snp_req_mismatch_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] catalogue rule D8 reported %0d snoop/request mismatches on conformant stimulus",
        super.tc_name, super.tb_env.coh_checker.get_snp_req_mismatch_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
