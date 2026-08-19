// ===========================================================================
// chi_coh_comp_ack_read_base_test
//
// The read half of CompAck, and the ordering guarantee it buys.
//
// IHI 0050 E Table 2-9 / D Table 2-8 mark ReadClean, ReadShared, ReadUnique and
// MakeReadUnique "Yes" in the RN-F column, and section 2.8.3 says the same thing
// in prose: "An RN-F must include a CompAck response in all Read transactions
// except ReadNoSnp and ReadOnce*." Until Table 2-9 was implemented, this VIP's
// item constraint forced ExpCompAck to zero on EVERY read, so no coherent read
// it ever issued was conformant, and the acknowledgement -- along with the
// ordering guarantee that is its entire purpose -- was absent from the model.
//
// Two things are asserted, and the second is the one worth having:
//
//   1. The read opened and closed a CompAck window. Opened means the request
//      carried ExpCompAck and its CompData arrived; closed means the CompAck
//      itself was seen on the wire. A count of windows with none unclosed is the
//      evidence that both flits happened, in that order.
//
//   2. A LATER read of the same line, from the other RN-F, snooped this one --
//      and that snoop landed outside the window. This is section 2.8.3 rule 2:
//      "An HN-F, except in the case of ReadOnce*, waits for CompAck before
//      sending a subsequent snoop to the same address", judged from the wire by
//      catalogue rule D9.
//
// The second assertion needs the first: if no window ever opened, "no snoop
// inside a window" is true of a run in which nothing was ever checked. The
// snoop count is asserted to have moved for the same reason.
//
// Used by:
//   tc_chi_coh_d_comp_ack_read  (CHI-D)
//   tc_chi_coh_e_comp_ack_read  (wide CHI-E)
// ===========================================================================
class chi_coh_comp_ack_read_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(chi_coh_comp_ack_read_base_test #(CFG_P, TYPES_T))

  localparam int SETTLE_C = 20;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(input uvm_phase phase);

    item_t drain;
    item_t snp_item;
    int    windows_after_first;
    int    snoops_before;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // ---- RN-F0 takes the line Shared. Table 2-9: CompAck required. ----
    this.cfg_read_seq(super.hrnf0_rdshared_seq);
    super.hrnf0_rdshared_seq.start(super.tb_env.hrnf0_agent.sequencer);
    void'(super.hrnf0_rdshared_seq.get_responses());

    super.wait_clocks(SETTLE_C);

    windows_after_first = super.tb_env.coh_checker.get_comp_ack_window_count();

    if (windows_after_first == 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the ReadShared opened no CompAck window: either ExpCompAck was not set on a request Table 2-9 marks required, or its completion was never observed",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_comp_ack_window_unclosed_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a CompAck window was still open when the next one opened -- the RN-F did not send the CompAck section 2.8.3 requires after CompData",
        super.tc_name))
    end

    while (super.tb_env.hrnf0_snp_fifo.try_get(drain)) begin
    end

    // ---- RN-F1 reads the same line Unique, which forces a snoop of RN-F0. ----
    snoops_before = super.tb_env.coh_checker.get_snoop_count();

    this.cfg_read_seq(super.hrnf1_rdunique_seq);
    super.hrnf1_rdunique_seq.start(super.tb_env.hrnf1_agent.sequencer);
    void'(super.hrnf1_rdunique_seq.get_responses());

    super.wait_clocks(SETTLE_C);

    // The snoop has to have happened, or the ordering assertion below is a
    // statement about a run with no snoop in it.
    if (!super.tb_env.hrnf0_snp_fifo.try_get(snp_item)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1's ReadUnique did not snoop RN-F0, so this run says nothing about where a snoop may fall",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_snoop_count() == snoops_before) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] the coherency checker observed no snoop, so rule D9 had nothing to judge",
        super.tc_name))
    end

    if (super.tb_env.coh_checker.get_comp_ack_window_snoop_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d snoop(s) arrived inside a CompAck window; section 2.8.3 requires the home to wait for CompAck before snooping the same address",
        super.tc_name,
        super.tb_env.coh_checker.get_comp_ack_window_snoop_count()))
    end

    if (super.tb_env.coh_checker.get_comp_ack_window_count() <= windows_after_first) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F1's ReadUnique opened no CompAck window of its own; Table 2-9 marks it required too",
        super.tc_name))
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] %0d CompAck windows opened and closed, and the snoop that followed fell outside every one of them",
      super.tc_name, super.tb_env.coh_checker.get_comp_ack_window_count()), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
