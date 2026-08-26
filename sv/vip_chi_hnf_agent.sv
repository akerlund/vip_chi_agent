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

`ifndef VIP_CHI_HNF_AGENT
`define VIP_CHI_HNF_AGENT

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Dedicated multi-port HN-F agent.
//
// The coherent home node straddles N_RNF_PORTS RN-F-facing links and terminates
// every request against its own memory + directory (no SN side). It mirrors
// vip_chi_hni_agent: a thin autonomous agent (no sequencer) that hosts the
// multi-port vip_chi_driver_hnf, owns the rst_n watcher spanning all links, and
// republishes the interface handles down to the driver. Observation is left to
// the RN-F agents on the surrounding links.
// -----------------------------------------------------------------------------
class vip_chi_hnf_agent #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  int            N_RNF_PORTS  = 1,
  int            N_SN_PORTS   = 0
  ) extends uvm_agent;

  // SN-facing array sized >= 1 to avoid a zero-size unpacked array when the
  // downstream feature is compiled out; guarded by (N_SN_PORTS > 0) everywhere.
  localparam int SN_ARR_C = (N_SN_PORTS > 0) ? N_SN_PORTS : 1;

  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_HNF_E) rn_vif [N_RNF_PORTS];

  // Downstream SN-facing links (HN-F is requester -> RN-I polarity), one per SN.
  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E) sn_vif [SN_ARR_C];

  vip_chi_cfg_agent                                                        cfg;
  vip_chi_driver_hnf #(CFG_P, FLIT_TYPES_T, N_RNF_PORTS, N_SN_PORTS)        hnf_driver;

  `uvm_component_param_utils(vip_chi_hnf_agent #(CFG_P, FLIT_TYPES_T, N_RNF_PORTS, N_SN_PORTS))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Fetch the RN-facing vifs, build the driver, and republish the handles at
  // the driver scope.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    foreach (this.rn_vif[i]) begin
      if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_HNF_E))::get(
            this, "", $sformatf("rn_vif_%0d", i), this.rn_vif[i])) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] HN-F agent requires rn_vif_%0d to be set", get_name(), i))
      end
    end

    // Downstream SN-facing vifs (real ports only).
    for (int s = 0; s < N_SN_PORTS; s++) begin
      if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E))::get(
            this, "", $sformatf("sn_vif_%0d", s), this.sn_vif[s])) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] HN-F agent requires sn_vif_%0d to be set", get_name(), s))
      end
    end

    if (!uvm_config_db #(vip_chi_cfg_agent)::get(this, "", "cfg", this.cfg)) begin
      this.cfg = vip_chi_cfg_agent::type_id::create("default_cfg");
    end
    this.cfg.role = VIP_CHI_ROLE_HNF_E;

    this.hnf_driver     = this.create_hnf_driver();
    this.hnf_driver.cfg = this.cfg;

    foreach (this.rn_vif[i]) begin
      uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_HNF_E))::set(
        this, "hnf_driver", $sformatf("rn_vif_%0d", i), this.rn_vif[i]);
    end
    for (int s = 0; s < N_SN_PORTS; s++) begin
      uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E))::set(
        this, "hnf_driver", $sformatf("sn_vif_%0d", s), this.sn_vif[s]);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Which HN-F driver this agent builds. A factory hook rather than an inline
  // create so vip_chi_hnf_agent_e can substitute the Issue-E-exact driver -- and
  // a hook rather than a runtime issue test, because the E driver names a REQ
  // field the CHI-D flit does not have and a D specialization of it would fail
  // to ELABORATE. Subclassing the agent is what keeps that specialization from
  // ever being named.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_driver_hnf #(CFG_P, FLIT_TYPES_T, N_RNF_PORTS, N_SN_PORTS) create_hnf_driver();
    return vip_chi_driver_hnf #(CFG_P, FLIT_TYPES_T, N_RNF_PORTS, N_SN_PORTS)::type_id::create("hnf_driver", this);
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE only when every RN-F-facing link is out of reset.
  // ---------------------------------------------------------------------------
  protected function bit all_links_out_of_reset();
    foreach (this.rn_vif[i]) begin
      if (!this.rn_vif[i].rst_n) begin
        return 1'b0;
      end
    end
    for (int s = 0; s < N_SN_PORTS; s++) begin
      if (!this.sn_vif[s].rst_n) begin
        return 1'b0;
      end
    end
    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Reset watcher spanning every link: run the home only while ALL links are
  // out of reset, and cascade handle_reset when ANY link re-enters reset.
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
    event link_rst_changed;

    this.hnf_driver.reset_vif();

    foreach (this.rn_vif[i]) begin
      automatic int k = i;
      fork
        forever begin
          @(this.rn_vif[k].rst_n);
          -> link_rst_changed;
        end
      join_none
    end

    for (int s = 0; s < N_SN_PORTS; s++) begin
      automatic int j = s;
      fork
        forever begin
          @(this.sn_vif[j].rst_n);
          -> link_rst_changed;
        end
      join_none
    end

    forever begin
      while (!this.all_links_out_of_reset()) begin
        @(link_rst_changed);
      end

      fork : home_run
        this.hnf_driver.driver_start();
      join_none

      while (this.all_links_out_of_reset()) begin
        @(link_rst_changed);
      end
      disable home_run;

      this.hnf_driver.handle_reset();
      this.hnf_driver.reset_vif();
    end
  endtask

endclass

`endif
