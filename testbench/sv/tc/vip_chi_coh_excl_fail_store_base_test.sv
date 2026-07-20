// ===========================================================================
// vip_chi_coh_excl_fail_store_base_test
//
// Exclusive store FAILS because a remote store cleared the monitor (clear path
// (a): a conflicting store to the line by another RN). RN-F0 takes an exclusive
// load, then RN-F1 WriteUniques the line -- a genuine store that both
// snoop-invalidates RN-F0 and clears every port's monitor for the line at the
// home. RN-F0's later exclusive store must therefore LOSE:
//   RN-F0 LL (ReadClean+excl) L  -> SC, monitor[L][0]=1, Comp/ExclOkay
//   RN-F1 WriteUnique L          -> SnpCleanInvalid(RN-F0) + monitor cleared
//   RN-F0 SC (CleanUnique+excl) L -> monitor clear -> Comp/NormalOkay (FAIL)
// Asserts: the LL won ExclOkay, the SC reports NormalOkay (lost), RN-F0's cache
// stays Invalid (it was snoop-invalidated and the lost SC does not re-take it),
// and Checker D is silent (a legitimate, coherent SC failure).
//
// Used by:
//   tc_chi_coh_e_excl_fail_store  (wide CHI-E)
//   tc_chi_coh_d_excl_fail_store    (CHI-D)
// ===========================================================================
class vip_chi_coh_excl_fail_store_base_test #(
  vip_chi_cfg_t CFG_P   = CHI_D_CFG_C,
  type          TYPES_T = chi_d_types_t
) extends vip_chi_coherent_base_test #(CFG_P, TYPES_T);

  typedef vip_chi_item #(CFG_P) item_t;

  `uvm_component_param_utils(vip_chi_coh_excl_fail_store_base_test #(CFG_P, TYPES_T))

  vip_chi_excl_load_seq   #(CFG_P) hrnf0_ll_seq;
  vip_chi_excl_store_seq  #(CFG_P) hrnf0_sc_seq;
  vip_chi_writeunique_seq #(CFG_P) hrnf1_wu_seq;

  function new(input string name, input uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void start_of_simulation_phase(input uvm_phase phase);
    super.start_of_simulation_phase(phase);
    this.hrnf0_ll_seq = vip_chi_excl_load_seq   #(CFG_P)::type_id::create("hrnf0_ll_seq");
    this.hrnf0_sc_seq = vip_chi_excl_store_seq  #(CFG_P)::type_id::create("hrnf0_sc_seq");
    this.hrnf1_wu_seq = vip_chi_writeunique_seq #(CFG_P)::type_id::create("hrnf1_wu_seq");
  endfunction


  task run_phase(input uvm_phase phase);

    item_t         ll_rsp[$];
    item_t         wu_rsp[$];
    item_t         sc_rsp[$];
    vip_chi_resp_t rnf0_state;

    phase.raise_objection(this);

    super.wait_reset_settle();

    // RN-F0 exclusive load -> monitor armed, ExclOkay.
    this.cfg_read_seq(this.hrnf0_ll_seq);
    this.hrnf0_ll_seq.start(super.tb_env.hrnf0_agent.sequencer);
    ll_rsp = this.hrnf0_ll_seq.get_responses();

    // RN-F1 remote store -> snoop-invalidates RN-F0 and clears the monitor.
    this.cfg_read_seq(this.hrnf1_wu_seq);
    this.hrnf1_wu_seq.start(super.tb_env.hrnf1_agent.sequencer);
    wu_rsp = this.hrnf1_wu_seq.get_responses();

    // RN-F0 exclusive store -> must lose (NormalOkay).
    this.cfg_read_seq(this.hrnf0_sc_seq);
    this.hrnf0_sc_seq.start(super.tb_env.hrnf0_agent.sequencer);
    sc_rsp = this.hrnf0_sc_seq.get_responses();

    super.wait_clocks(8);

    if ((ll_rsp.size() != 1) || (wu_rsp.size() != 1) || (sc_rsp.size() != 1)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] expected 1+1+1 responses, got %0d/%0d/%0d",
        super.tc_name, ll_rsp.size(), wu_rsp.size(), sc_rsp.size()))
    end

    if (ll_rsp[0].rsp_resp_err != VIP_CHI_RESP_ERR_EXCLUSIVE_OKAY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] LL completion resperr 0x%0h, expected ExclOkay",
        super.tc_name, ll_rsp[0].rsp_resp_err))
    end

    // The store lost: the intervening WriteUnique cleared the monitor.
    if (sc_rsp[0].rsp_resp_err != VIP_CHI_RESP_ERR_NORMAL_OKAY_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SC completion resperr 0x%0h, expected NormalOkay (store should have LOST)",
        super.tc_name, sc_rsp[0].rsp_resp_err))
    end

    // RN-F0 was snoop-invalidated by the WriteUnique; the lost SC must not re-take it.
    rnf0_state = super.tb_env.hrnf0_agent.rnf_driver.get_cache_state(item_t::addr_t'(WRITE_READ_ADDR_C));
    if (rnf0_state != VIP_CHI_RESP_STATE_I_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-F0 cache 0x%0h after a LOST SC, expected I (unchanged from invalidation)",
        super.tc_name, rnf0_state))
    end

    if (super.tb_env.coh_checker.get_multi_owner_count() != 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] %0d coherency violations on a legitimate SC failure",
        super.tc_name, super.tb_env.coh_checker.get_multi_owner_count()))
    end

    phase.drop_objection(this);
  endtask
endclass
