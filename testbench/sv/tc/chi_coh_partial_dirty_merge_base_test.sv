// ===========================================================================
// chi_coh_partial_dirty_merge_base_test
//
// The MERGE half of IHI 0050 E Table 4-14 footnote c: "Data received from memory
// must be dropped if the cache state is UD or SD, or merged if the cache state
// is UDP."
//
// UDP is a state the WIRE cannot express. Table 4-6 gives UD and UDP the same
// Resp encoding, UD_PD, so nothing on the link says which bytes of a dirty line
// are dirty -- and until the requester kept a per-beat dirty byte mask, the VIP
// could not represent the difference either. Every dirty line was fully dirty,
// so the footnote's drop half was the whole of it and the merge case could not
// arise.
//
// The scenario is the one place a UDP line comes from cleanly, and each step is
// load-bearing:
//
//   MakeUnique grants Unique-Dirty with NO data transfer. The line is now owned
//   and its contents are whatever the requester makes them -- this model
//   materializes zeros -- so no byte of it is real memory content.
//
//   A PARTIAL local store dirties some of those bytes. Now the line is genuinely
//   UDP: the stored bytes are the newest copy in the system, and the rest are
//   filler this cache was never given.
//
//   A read then fetches the line from memory. This is the moment the footnote is
//   about, and all three outcomes are wrong except one.
//
// What the two assertions below separate:
//
//   TAKE  -- the fetch over the top -- loses the store. The dirty bytes would
//            read back as memory.
//   DROP  -- keep everything held -- loses the clean bytes, which were never
//            real. They would read back as the MakeUnique zeros.
//   MERGE -- dirty bytes from the store, everything else from the fetch.
//
// DROP is not a hypothetical: it is exactly what this VIP did before the mask
// existed, because the held state was UD_PD and that was the whole question. So
// the clean-byte assertion is the mutation proof as well as the requirement.
//
// The precondition is asserted rather than assumed: if memory happened to hold
// zeros under the clean bytes, MERGE and DROP would agree and the test would
// pass without testing anything.
//
// Used by:
//   tc_chi_coh_d_partial_dirty_merge  (CHI-D)
//   tc_chi_coh_e_partial_dirty_merge  (wide CHI-E)
// ===========================================================================
class chi_coh_partial_dirty_merge_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_partial_dirty_merge_base_test #(CFG_P, TYPES_T))

  vip_chi_readclean_seq  #(CFG_P)  hrnf1_rdclean_seq;
  vip_chi_makeunique_seq #(CFG_P)  hrnf1_mu_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf1_rdclean_seq = vip_chi_readclean_seq #(CFG_P)::type_id::create("hrnf1_rdclean_seq");
    this.hrnf1_mu_seq      = vip_chi_makeunique_seq #(CFG_P)::type_id::create("hrnf1_mu_seq");
  endfunction

  task run_phase(input uvm_phase phase);

    item_t::data_t store_pattern;
    item_t::data_t dirty_bits;
    item_t::be_t   dirty_be;
    item_t::data_t held  [];
    item_t::be_t   mask  [];
    item_t::data_t after [];
    item_t::be_t   mask_after [];
    item_t         read_rsp [$];
    bit            saw_partial;
    bit            saw_clean_content;
    int            n_dirty;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // Every other byte, so both halves of every beat have something to say.
    dirty_be   = '0;
    dirty_bits = '0;
    n_dirty    = 0;
    for (int b = 0; b < CFG_P.DATA_BYTES_P; b += 2) begin
      dirty_be[b]              = 1'b1;
      dirty_bits[(8 * b) +: 8] = 8'hFF;
      n_dirty++;
    end
    store_pattern = {($bits(store_pattern) / 8){8'h5A}};

    this.cfg_read_seq(this.hrnf1_mu_seq);
    this.hrnf1_mu_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(this.hrnf1_mu_seq.get_responses());

    super.tb_env.hrnf1_agent.rnf_driver.make_line_dirty_partial(
      item_t::addr_t'(WRITE_READ_ADDR_C), store_pattern, dirty_be);

    super.tb_env.hrnf1_agent.rnf_driver.get_cache_line(
      item_t::addr_t'(WRITE_READ_ADDR_C), held, mask);

    saw_partial = 1'b0;
    foreach (mask[i]) begin
      if (mask[i] !== item_t::be_t'('1)) begin
        saw_partial = 1'b1;
      end
    end
    if ((mask.size() == 0) || !saw_partial) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the partial store did not leave a partial dirty mask, so the line is not UDP and the merge case is not the one being exercised",
        super.tc_name))
    end

    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(
          item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a local store must leave the line Unique-Dirty",
        super.tc_name))
    end

    this.cfg_read_seq(this.hrnf1_rdclean_seq);
    this.hrnf1_rdclean_seq.start(super.tb_env.hrnf1_agent.sequencer);
    read_rsp = this.hrnf1_rdclean_seq.get_responses();
    if (read_rsp.size() != 1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1's read never completed (got %0d response(s))",
        super.tc_name, read_rsp.size()))
    end

    super.wait_clocks(8);

    super.tb_env.hrnf1_agent.rnf_driver.get_cache_line(
      item_t::addr_t'(WRITE_READ_ADDR_C), after, mask_after);

    if (after.size() != read_rsp[0].data.size()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the line holds %0d beat(s) against %0d fetched",
        super.tc_name, after.size(), read_rsp[0].data.size()))
    end

    // Without this the test would pass on a memory image of zeros, where merging
    // and dropping cannot be told apart.
    saw_clean_content = 1'b0;
    foreach (read_rsp[0].data[i]) begin
      if ((read_rsp[0].data[i] & ~dirty_bits) != '0) begin
        saw_clean_content = 1'b1;
      end
    end
    if (!saw_clean_content) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] memory holds zeros under every clean byte of this line, so a merge and a drop produce the same image and this test proves nothing",
        super.tc_name))
    end

    foreach (after[i]) begin
      if ((after[i] & dirty_bits) !== (store_pattern & dirty_bits)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d: the locally stored bytes read back as 0x%0h, expected 0x%0h; the fetch was taken over the top of the store and the newest copy in the system is gone",
          super.tc_name, i, after[i] & dirty_bits, store_pattern & dirty_bits))
      end

      if ((after[i] & ~dirty_bits) !== (read_rsp[0].data[i] & ~dirty_bits)) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] beat %0d: the clean bytes read back as 0x%0h, expected the fetched 0x%0h; the fetch was dropped whole, which keeps bytes this cache was never given",
          super.tc_name, i, after[i] & ~dirty_bits,
          read_rsp[0].data[i] & ~dirty_bits))
      end
    end

    // The line is still Unique and still dirty in those bytes: only the clean
    // ones changed hands, and the requester still owes the dirty ones on.
    if (super.tb_env.hrnf1_agent.rnf_driver.get_cache_state(
          item_t::addr_t'(WRITE_READ_ADDR_C)) != VIP_CHI_RESP_STATE_UP_PD_DIRTY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the merge left the line no longer Unique-Dirty", super.tc_name))
    end

    if (mask_after != mask) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the merge changed the dirty mask; a merge moves bytes, not ownership",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "Test (%s) PASS: a UDP line took a fill and kept its %0d stored byte(s) per beat while the remainder came from memory",
      super.tc_name, n_dirty), UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
