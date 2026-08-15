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

`ifndef VIP_CHI_AGENT
`define VIP_CHI_AGENT

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_agent #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  vip_chi_role_t ROLE_P       = VIP_CHI_ROLE_MONITOR_E
  ) extends uvm_agent;

  typedef vip_chi_item #(CFG_P) item_t;

  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P) vif;

  // Second, SN-facing interface used only by the HN-I proxy role. It is an
  // RN-I-polarity link (the HN-I is the requester toward the SN), published by
  // the TB at the agent path under the "sn_vif" key.
  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E) sn_vif;

  vip_chi_cfg_agent                                 cfg;
  vip_chi_monitor    #(CFG_P, FLIT_TYPES_T, ROLE_P) monitor;
  vip_chi_driver_rni #(CFG_P, FLIT_TYPES_T)         rni_driver;
  vip_chi_driver_rnf #(CFG_P, FLIT_TYPES_T)         rnf_driver;
  vip_chi_driver_snf #(CFG_P, FLIT_TYPES_T)         snf_driver;
  vip_chi_driver_hni #(CFG_P, FLIT_TYPES_T)         hni_driver;
  vip_chi_sequencer  #(CFG_P)                       sequencer;

  uvm_analysis_port #(item_t) req_port;
  uvm_analysis_port #(item_t) rsp_port;
  uvm_analysis_port #(item_t) dat_port;
  uvm_analysis_port #(item_t) snp_port;

  `uvm_component_param_utils(vip_chi_agent #(CFG_P, FLIT_TYPES_T, ROLE_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
    this.req_port = new("req_port", this);
    this.rsp_port = new("rsp_port", this);
    this.dat_port = new("dat_port", this);
    this.snp_port = new("snp_port", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Build the monitor always and the role-specific active path when enabled.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P))::get(this, "", "vif", this.vif)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Virtual interface must be set for %s.vif",
        get_name(), get_full_name()))
    end

    if (!uvm_config_db #(vip_chi_cfg_agent)::get(this, "", "cfg", this.cfg)) begin
      this.cfg = vip_chi_cfg_agent::type_id::create("default_cfg");
      this.cfg.role = ROLE_P;
    end

    // ROLE_P is authoritative and always wins, so a disagreeing cfg.role has
    // never made the run wrong -- it just vanished. Say so: a cfg built for a
    // different role usually carries other settings meant for that role too,
    // and those do NOT get corrected.
    if (this.cfg.role != ROLE_P) begin
      `uvm_warning(get_name(), $sformatf(
        "[%s] cfg.role is %0d but the agent is elaborated with ROLE_P=%0d; ROLE_P wins. Only the role field is corrected -- any other role-specific knob on this cfg is applied as-is",
        get_name(), this.cfg.role, ROLE_P))
    end

    this.cfg.role = ROLE_P;
    this.check_cfg_p();
    this.check_cfg();

    if ((this.cfg.is_active == UVM_ACTIVE) && (ROLE_P == VIP_CHI_ROLE_MONITOR_E)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Active agent requires a driving role, not MONITOR",
        get_name()))
    end

    this.monitor     = this.create_monitor();
    this.monitor.vif = this.vif;
    this.monitor.cfg = this.cfg;
    this.monitor.collect_beat_timestamps = this.cfg.collect_beat_timestamps;
    this.monitor.max_read_xact_latency   = this.cfg.max_read_xact_latency;
    this.monitor.max_write_xact_latency  = this.cfg.max_write_xact_latency;
    this.monitor.max_snp_xact_latency    = this.cfg.max_snp_xact_latency;
    this.monitor.record_transactions     = this.cfg.record_transactions;

    if (this.cfg.is_active == UVM_ACTIVE) begin
      if (ROLE_P == VIP_CHI_ROLE_RNI_E) begin
        this.rni_driver = this.create_rni_driver();
        uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P))::set(this, "rni_driver", "vif", this.vif);
        this.rni_driver.cfg = this.cfg;
      end
      else if (ROLE_P == VIP_CHI_ROLE_RNF_E) begin
        this.rnf_driver = this.create_rnf_driver();
        uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P))::set(this, "rnf_driver", "vif", this.vif);
        this.rnf_driver.cfg = this.cfg;
      end
      else if (ROLE_P == VIP_CHI_ROLE_SNF_E) begin
        this.snf_driver = this.create_snf_driver();
        uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P))::set(this, "snf_driver", "vif", this.vif);
        this.snf_driver.cfg = this.cfg;
      end
      else if (ROLE_P == VIP_CHI_ROLE_HNI_E) begin
        if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E))::get(this, "", "sn_vif", this.sn_vif)) begin
          `uvm_fatal(get_name(), $sformatf(
            "FATAL [%s] HN-I agent requires the SN-facing sn_vif to be set",
            get_name()))
        end
        this.hni_driver = this.create_hni_driver();
        uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, ROLE_P))::set(this, "hni_driver", "rn_vif_0", this.vif);
        uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E))::set(this, "hni_driver", "sn_vif_0", this.sn_vif);
        this.hni_driver.cfg = this.cfg;
      end
      else begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] ROLE_P=%0d is not supported by the current active driver cut",
          get_name(), ROLE_P))
      end

      // The HN-I proxy is autonomous and has no sequencer-driven stimulus.
      if (ROLE_P != VIP_CHI_ROLE_HNI_E) begin
        this.sequencer = vip_chi_sequencer #(CFG_P)::type_id::create("sequencer", this);
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Factory hook for issue- or role-specific monitor subclasses.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_monitor #(CFG_P, FLIT_TYPES_T, ROLE_P) create_monitor();
    return vip_chi_monitor #(CFG_P, FLIT_TYPES_T, ROLE_P)::type_id::create("monitor", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Factory hook for issue- or role-specific RN-I driver subclasses.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_driver_rni #(CFG_P, FLIT_TYPES_T) create_rni_driver();
    return vip_chi_driver_rni #(CFG_P, FLIT_TYPES_T)::type_id::create("rni_driver", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Factory hook for issue- or role-specific coherent RN-F driver subclasses.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_driver_rnf #(CFG_P, FLIT_TYPES_T) create_rnf_driver();
    return vip_chi_driver_rnf #(CFG_P, FLIT_TYPES_T)::type_id::create("rnf_driver", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Factory hook for issue- or role-specific SN-F driver subclasses.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_driver_snf #(CFG_P, FLIT_TYPES_T) create_snf_driver();
    return vip_chi_driver_snf #(CFG_P, FLIT_TYPES_T)::type_id::create("snf_driver", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Factory hook for the HN-I proxy driver.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_driver_hni #(CFG_P, FLIT_TYPES_T) create_hni_driver();
    return vip_chi_driver_hni #(CFG_P, FLIT_TYPES_T)::type_id::create("hni_driver", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Wire the active driver to the sequencer and expose monitor analysis ports.
  // ---------------------------------------------------------------------------
  function void connect_phase(input uvm_phase phase);
    super.connect_phase(phase);

    this.monitor.req_port.connect(this.req_port);
    this.monitor.rsp_port.connect(this.rsp_port);
    this.monitor.dat_port.connect(this.dat_port);
    this.monitor.snp_port.connect(this.snp_port);

    if (this.rni_driver != null) begin
      this.rni_driver.seq_item_port.connect(this.sequencer.seq_item_export);
    end

    if (this.rnf_driver != null) begin
      this.rnf_driver.seq_item_port.connect(this.sequencer.seq_item_export);
    end

    if (this.snf_driver != null) begin
      this.snf_driver.seq_item_port.connect(this.sequencer.seq_item_export);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Single rst_n watcher. Owns monitor/driver lifetime and the coordinated
  // handle_reset cascade so the children do not race each other on mid-run
  // resets.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);

    if (this.rni_driver != null) begin
      this.rni_driver.reset_vif();
    end

    if (this.rnf_driver != null) begin
      this.rnf_driver.reset_vif();
    end

    if (this.snf_driver != null) begin
      this.snf_driver.reset_vif();
    end

    if (this.hni_driver != null) begin
      this.hni_driver.reset_vif();
    end

    forever begin

      fork
        begin
          @(posedge this.vif.rst_n);

          fork
            this.monitor.monitor_start();
            begin
              if (this.rni_driver != null) begin
                this.rni_driver.driver_start();
              end
            end
            begin
              if (this.rnf_driver != null) begin
                this.rnf_driver.driver_start();
              end
            end
            begin
              if (this.snf_driver != null) begin
                this.snf_driver.driver_start();
              end
            end
            begin
              if (this.hni_driver != null) begin
                this.hni_driver.driver_start();
              end
            end
          join
        end
      join_none

      @(negedge this.vif.rst_n);
      disable fork;

      this.handle_reset(phase);

      if (this.rni_driver != null) begin
        this.rni_driver.reset_vif();
      end

      if (this.rnf_driver != null) begin
        this.rnf_driver.reset_vif();
      end

      if (this.snf_driver != null) begin
        this.snf_driver.reset_vif();
      end

      if (this.hni_driver != null) begin
        this.hni_driver.reset_vif();
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Clear component-local state and restart sequences after reset.
  // ---------------------------------------------------------------------------
  virtual function void handle_reset(input uvm_phase phase);

    this.monitor.handle_reset();

    if (this.rni_driver != null) begin
      this.rni_driver.handle_reset();
    end

    if (this.rnf_driver != null) begin
      this.rnf_driver.handle_reset();
    end

    if (this.snf_driver != null) begin
      this.snf_driver.handle_reset();
    end

    if (this.hni_driver != null) begin
      this.hni_driver.handle_reset();
    end

    if ((this.cfg.is_active == UVM_ACTIVE) && (this.sequencer != null)) begin
      this.sequencer.handle_reset(phase);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the RUNTIME config object. cfg.is_valid() owns every rule the cfg
  // can judge on its own; the two rules that need CFG_P are checked here,
  // because a TxnID pool is a property of the elaborated width, not of the cfg.
  // ---------------------------------------------------------------------------
  protected function void check_cfg();
    int txn_id_count;
    int txn_id_width;

    void'(this.cfg.is_valid(.silent(1'b0)));

    // A requester allocates one TxnID per in-flight transaction, so it cannot
    // have more outstanding than the ID space holds -- past that the allocator
    // has nothing left to hand out and the request thread stalls with no
    // diagnostic. Only the requester roles allocate, so only they are bound.
    if ((ROLE_P == VIP_CHI_ROLE_RNI_E) || (ROLE_P == VIP_CHI_ROLE_RNF_E)) begin
      txn_id_width = $bits(item_t::txn_id_t);
      txn_id_count = 2 ** txn_id_width;

      if (this.cfg.max_outstanding_read > txn_id_count) begin
        `uvm_error(get_name(), $sformatf(
          "[%s] cfg.max_outstanding_read (%0d) exceeds the %0d TxnIDs a %0d-bit TxnID field can hold",
          get_name(), this.cfg.max_outstanding_read, txn_id_count, txn_id_width))
      end

      if (this.cfg.max_outstanding_write > txn_id_count) begin
        `uvm_error(get_name(), $sformatf(
          "[%s] cfg.max_outstanding_write (%0d) exceeds the %0d TxnIDs a %0d-bit TxnID field can hold",
          get_name(), this.cfg.max_outstanding_write, txn_id_count, txn_id_width))
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Validate the static CFG_P envelope consumed by the interface and helpers.
  // ---------------------------------------------------------------------------
  protected function void check_cfg_p();
    int data_bytes;

    if ((CFG_P.ISSUE_P != VIP_CHI_ISSUE_D_E) &&
        (CFG_P.ISSUE_P != VIP_CHI_ISSUE_E_E)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CFG_P.ISSUE_P=%0d is not a supported CHI issue",
      get_name(), CFG_P.ISSUE_P))
    end

    if ((CFG_P.NODE_ID_WIDTH_P < 1) || (CFG_P.NODE_ID_WIDTH_P > 11)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CFG_P.NODE_ID_WIDTH_P=%0d is outside [1:11]",
      get_name(), CFG_P.NODE_ID_WIDTH_P))
    end

    if (CFG_P.ADDR_WIDTH_P < 1) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CFG_P.ADDR_WIDTH_P=%0d must be >= 1",
      get_name(), CFG_P.ADDR_WIDTH_P))
    end

    if ((CFG_P.ISSUE_P == VIP_CHI_ISSUE_D_E) && (CFG_P.ADDR_WIDTH_P > 44)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] CHI-D ADDR_WIDTH_P=%0d exceeds 44",
      get_name(), CFG_P.ADDR_WIDTH_P))
    end

    if (CFG_P.ADDR_WIDTH_P > 52) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] ADDR_WIDTH_P=%0d exceeds 52",
      get_name(), CFG_P.ADDR_WIDTH_P))
    end

    data_bytes = CFG_P.DATA_BYTES_P;
    if ((data_bytes < 1) || (data_bytes > VIP_CHI_CACHE_LINE_BYTES_C) ||
        ((data_bytes & (data_bytes - 1)) != 0)) begin
      `uvm_fatal(get_name(), $sformatf(
      "FATAL [%s] DATA_BYTES_P=%0d must be a power of two in [1:64]",
      get_name(), data_bytes))
    end
  endfunction
endclass

`endif