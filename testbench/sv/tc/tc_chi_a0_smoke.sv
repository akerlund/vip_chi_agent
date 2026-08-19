// Agent-free smoke on the A0 link: a link-activation handshake driven by hand
// and one REQ flit pushed across the chi_link_adapter, checked field-for-field
// on the far side.
//
// The point is the GEOMETRY. Every other SV link here is CHI_D_CFG_C (11-bit
// node IDs, 16-byte data) or CHI_E_WIDE_CFG_C; A0 is 7-bit node IDs over a
// 32-byte data bus, so this is the only test that carries real traffic through
// the interface and the adapter at a third flit shape. Driving the wires
// directly rather than through agents keeps the check on the interface itself.
//
// The Python twin additionally asserts that its packing codec's flit widths
// match the HDL net widths. That check has no meaning here: the SV interface
// carries the flit struct itself, so there is no second encoding that could
// disagree with it.

class tc_chi_a0_smoke extends uvm_test;

  `uvm_component_utils(tc_chi_a0_smoke)

  string tc_name;

  typedef vip_chi_types #(CHI_A0_CFG_C)::req_opcode_t req_opcode_t;
  typedef chi_a0_types_t::vip_chi_req_flit_t          req_flit_t;

  virtual vip_chi_if #(CHI_A0_CFG_C, chi_a0_types_t, VIP_CHI_ROLE_RNI_E) rn_vif;
  virtual vip_chi_if #(CHI_A0_CFG_C, chi_a0_types_t, VIP_CHI_ROLE_SNF_E) sn_vif;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent = null);

    super.new(name, parent);

    tc_name = name;
    void'($value$plusargs("UVM_TESTNAME=%s", tc_name));
  endfunction

  // ---------------------------------------------------------------------------
  // No env: this test owns the A0 link outright, so it takes both vifs directly.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);

    super.build_phase(phase);

    if (!uvm_config_db #(virtual vip_chi_if #(CHI_A0_CFG_C, chi_a0_types_t, VIP_CHI_ROLE_RNI_E))
          ::get(this, "", "a0_rni_vif", this.rn_vif)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a0_rni_vif was not published by the harness", tc_name))
    end

    if (!uvm_config_db #(virtual vip_chi_if #(CHI_A0_CFG_C, chi_a0_types_t, VIP_CHI_ROLE_SNF_E))
          ::get(this, "", "a0_snf_vif", this.sn_vif)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] a0_snf_vif was not published by the harness", tc_name))
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Bring the link up by hand, then send one REQ flit and compare it verbatim.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    req_flit_t flit;
    req_flit_t observed;
    bit        seen;

    phase.raise_objection(this);

    // Wait for reset to be released before driving anything.
    wait (this.rn_vif.rst_n === 1'b1);
    @(this.rn_vif.g_drv.rni_cb);

    // --- Link activation: RN raises the request, SN mirrors the ack ----------
    this.rn_vif.g_drv.rni_cb.txlinkactivereq <= 1'b1;
    this.rn_vif.g_drv.rni_cb.txsactive       <= 1'b1;

    seen = 1'b0;
    for (int i = 0; (i < 10) && !seen; i++) begin
      @(this.sn_vif.g_drv.snf_cb);
      seen = (this.sn_vif.g_drv.snf_cb.rxlinkactivereq === 1'b1);
    end
    if (!seen) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SN-F never saw rxlinkactivereq across the link adapter",
        tc_name))
    end

    this.sn_vif.g_drv.snf_cb.txlinkactiveack <= 1'b1;
    this.sn_vif.g_drv.snf_cb.txsactive       <= 1'b1;

    seen = 1'b0;
    for (int i = 0; (i < 10) && !seen; i++) begin
      @(this.rn_vif.g_drv.rni_cb);
      seen = (this.rn_vif.g_drv.rni_cb.rxlinkactiveack === 1'b1);
    end
    if (!seen) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] RN-I never saw rxlinkactiveack across the link adapter",
        tc_name))
    end

    // --- One REQ flit, checked verbatim on the far side ---------------------
    flit             = '0;
    flit.tgtid       = 'h5;
    flit.srcid       = 'h3;
    flit.txnid       = 'h2a;
    flit.opcode      = req_opcode_t'(VIP_CHI_REQ_READ_NO_SNP_C);
    flit.addr        = 'h0123_4567_89ab;
    flit.size        = 3'd6;
    flit.ns          = 1'b1;
    flit.order       = VIP_CHI_ORDER_REQ_ORDER_E;
    flit.qos         = 4'ha;
    flit.returnnid   = 'h7;
    flit.returntxnid = 'h15;

    @(this.rn_vif.g_drv.rni_cb);
    this.rn_vif.g_drv.rni_cb.txreqflit     <= flit;
    this.rn_vif.g_drv.rni_cb.txreqflitpend <= 1'b1;
    this.rn_vif.g_drv.rni_cb.txreqflitv    <= 1'b1;

    @(this.sn_vif.g_drv.snf_cb);
    if (this.sn_vif.g_drv.snf_cb.rxreqflitv !== 1'b1) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] SN-F did not see rxreqflitv", tc_name))
    end
    observed = this.sn_vif.g_drv.snf_cb.rxreqflit;

    if (observed !== flit) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] REQ flit did not cross the adapter verbatim:\n  sent     0x%0h\n  observed 0x%0h",
        tc_name, flit, observed))
    end

    @(this.rn_vif.g_drv.rni_cb);
    this.rn_vif.g_drv.rni_cb.txreqflitpend <= 1'b0;
    this.rn_vif.g_drv.rni_cb.txreqflitv    <= 1'b0;

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] A0 link activated and carried one REQ flit verbatim",
      tc_name), UVM_LOW)

    phase.drop_objection(this);
  endtask

  // ---------------------------------------------------------------------------
  // This test owns the A0 link outright -- no env -- so it is also the only place
  // that can export its two binds' tallies. Box 0.3 bound the link; exporting
  // from here is what makes the bind visible to the vacuity aggregation, and
  // without it the bind would be exactly the defect that box exists to fix: a
  // checker that runs and reports nowhere.
  //
  // The A0 link raises a REQ flit by hand and never completes it, so most of the
  // registry is legitimately unexercised here. That is a statement about this
  // testcase, and it is the aggregation's job to say so across the sweep -- which
  // it can only do if these rows exist.
  // ---------------------------------------------------------------------------
  function void report_phase(input uvm_phase phase);

    super.report_phase(phase);

    chi_check_export_csv("a0_rni_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.rn_vif.check_enabled, this.rn_vif.check_severity,
      this.rn_vif.check_pass_count, this.rn_vif.check_fail_count);
    chi_check_export_csv("a0_snf_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.sn_vif.check_enabled, this.sn_vif.check_severity,
      this.sn_vif.check_pass_count, this.sn_vif.check_fail_count);

    chi_check_report_tallies("a0_rni_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.rn_vif.check_enabled, this.rn_vif.check_severity,
      this.rn_vif.check_pass_count, this.rn_vif.check_fail_count);
    chi_check_report_tallies("a0_snf_sva", CHI_CHECK_SCOPE_MAIN_E,
      this.sn_vif.check_enabled, this.sn_vif.check_severity,
      this.sn_vif.check_pass_count, this.sn_vif.check_fail_count);
  endfunction

endclass
