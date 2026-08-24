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
//
// The negative control for the raw path's TXSACTIVE window (F-CORR-021).
//
// cfg.raw_req_txsactive_flit_scoped_negctl reverts the raw-injection path to the
// window it used to have -- scoped to the injected flit, with nothing holding
// the sideband up while the transaction that flit started is still outstanding.
// IHI 0050 E section 14.7.2 / D section 13.7.2 requires TXSACTIVE to cover every
// outstanding transaction, so CHI_TXSACTIVE_COVERS_OUTSTANDING must report it.
//
// The control is the DEFECT, not an invented one. That is what makes it worth a
// testcase rather than a mutation: the fix is a behaviour that has to keep
// working as opcodes are classified, and only a control re-proves it on every
// run. tc_chi_e_write_unique_zero_negctl is the positive half -- it injects the
// same opcode with no compensating hold on the requester and must stay silent.
//
// The rule is turned down to VIP_CHI_CHK_SEV_OFF_E rather than disabled. OFF
// still evaluates and still counts, and only suppresses the report, which is
// exactly what a negative control needs.
//
////////////////////////////////////////////////////////////////////////////////

class tc_chi_e_raw_txsactive_negctl extends tc_chi_e_write_unique_zero_negctl;

  `uvm_component_utils(tc_chi_e_raw_txsactive_negctl)

  localparam int NEGCTL_SETTLE_C = 40;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

  endfunction

  // ---------------------------------------------------------------------------
  // The requester reverts to the flit-scoped window. The completer's hold stays
  // as the parent sets it: it is a property of a test that drives both ends, not
  // of the defect under control here, and removing it would make the SN-F report
  // a violation of its own and muddle the count below.
  // ---------------------------------------------------------------------------
  protected virtual function void configure_agent_cfgs();

    super.configure_agent_cfgs();

    super.rni_cfg.raw_req_txsactive_flit_scoped_negctl = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Run
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    int unsigned covers_before;
    int unsigned covers_fails;
    int unsigned bounded_fails;

    phase.raise_objection(this);

    // Compliant traffic first, so the link is in RUN and the silence asserted
    // here is a statement about the injection rather than about an idle link.
    super.rni_wr_seq.reset();
    super.rni_wr_seq.set_requests(1);
    super.rni_wr_seq.set_initial_addr(item_t::addr_t'(E_WUZ_NEGCTL_ADDR_C));
    super.rni_wr_seq.set_size(3'd6);
    super.rni_wr_seq.set_get_response(1'b1);
    super.rni_wr_seq.set_verbose(1'b0);
    super.rni_wr_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(4);

    covers_before = super.tb_env.rni_agent.vif.check_fail_count[
      VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E];

    if (covers_before != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_TXSACTIVE_COVERS_OUTSTANDING already reported %0d time(s) on compliant traffic; the count below would prove nothing",
      get_name(), covers_before))
    end

    super.tb_env.rni_agent.vif.check_severity[
      VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E] = VIP_CHI_CHK_SEV_OFF_E;

    // One WriteUniqueZero, injected raw, completed by this test. Between the two
    // the transaction is outstanding and the sideband is down.
    this.rni_raw_seq.reset();
    this.rni_raw_seq.add_raw_req(this.write_unique_zero(E_WUZ_NEGCTL_TXN_ID_PASS_C));
    this.rni_raw_seq.start(super.tb_env.rni_agent.sequencer);

    super.wait_clocks(4);

    this.snf_raw_seq.reset();
    this.snf_raw_seq.add_raw_rsp(this.comp_dbid_resp(E_WUZ_NEGCTL_TXN_ID_PASS_C));
    this.snf_raw_seq.start(super.tb_env.snf_agent.sequencer);

    super.wait_clocks(NEGCTL_SETTLE_C);

    covers_fails = super.tb_env.rni_agent.vif.check_fail_count[
      VIP_CHI_CHK_TXSACTIVE_COVERS_OUTSTANDING_E];
    // The neighbour that must NOT move. A window closed too early is
    // UNDER-assertion; the bound on over-assertion has nothing to say about it,
    // and a control that tripped both would not tell the two rules apart.
    bounded_fails = super.tb_env.rni_agent.vif.check_fail_count[
      VIP_CHI_CHK_TXSACTIVE_DEASSERT_BOUNDED_E];

    if (covers_fails == 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_TXSACTIVE_COVERS_OUTSTANDING did not report a raw WriteUniqueZero whose TXSACTIVE window was scoped to its flit; either the control is not reaching the driver or the rule has stopped watching the requester's own window",
      get_name()))
    end

    if (bounded_fails != 0) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI_TXSACTIVE_DEASSERT_BOUNDED reported %0d time(s) as well; a window closed too early is under-assertion and must not move the over-assertion bound, so this control is no longer isolating one rule",
      get_name(), bounded_fails))
    end

    `uvm_info(get_name(), $sformatf(
    "PASS [%s] a flit-scoped raw window was reported %0d time(s) by CHI_TXSACTIVE_COVERS_OUTSTANDING, with CHI_TXSACTIVE_DEASSERT_BOUNDED silent",
    get_name(), covers_fails), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass
