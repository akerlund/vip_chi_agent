`ifndef VIP_CHI_HNI_AGENT
`define VIP_CHI_HNI_AGENT

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Dedicated multi-port HN-I agent.
//
// The generic vip_chi_agent is single-role / single-vif, which suits the 1x1
// HN-I proxy (built via its ROLE_P=HNI dispatch). A fan-in / fan-out HN-I
// straddles N_RN_PORTS RN-facing links and N_SN_PORTS SN-facing links, so it
// gets its own thin agent that hosts the multi-port vip_chi_driver_hni, owns the
// rst_n watcher, and republishes the interface handles down to the driver. It is
// autonomous (no sequencer); observation is left to the RN-I/SN-F agents on the
// surrounding links.
// -----------------------------------------------------------------------------
class vip_chi_hni_agent #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types #(CFG_P),
  int            N_RN_PORTS   = 1,
  int            N_SN_PORTS   = 1
  ) extends uvm_agent;

  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_HNI_E) rn_vif [N_RN_PORTS];
  virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E) sn_vif [N_SN_PORTS];

  vip_chi_cfg_agent                                                     cfg;
  vip_chi_driver_hni #(CFG_P, FLIT_TYPES_T, N_RN_PORTS, N_SN_PORTS)      hni_driver;

  `uvm_component_param_utils(vip_chi_hni_agent #(CFG_P, FLIT_TYPES_T, N_RN_PORTS, N_SN_PORTS))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Fetch the RN-facing + SN-facing vifs, build the driver, and republish the
  // handles at the driver scope.
  // ---------------------------------------------------------------------------
  function void build_phase(input uvm_phase phase);
    super.build_phase(phase);

    foreach (this.rn_vif[i]) begin
      if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_HNI_E))::get(
            this, "", $sformatf("rn_vif_%0d", i), this.rn_vif[i])) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] HN-I agent requires rn_vif_%0d to be set", get_name(), i))
      end
    end

    foreach (this.sn_vif[j]) begin
      if (!uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E))::get(
            this, "", $sformatf("sn_vif_%0d", j), this.sn_vif[j])) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] HN-I agent requires sn_vif_%0d to be set", get_name(), j))
      end
    end

    if (!uvm_config_db #(vip_chi_cfg_agent)::get(this, "", "cfg", this.cfg)) begin
      this.cfg = vip_chi_cfg_agent::type_id::create("default_cfg");
    end
    this.cfg.role = VIP_CHI_ROLE_HNI_E;

    this.hni_driver = vip_chi_driver_hni #(CFG_P, FLIT_TYPES_T, N_RN_PORTS, N_SN_PORTS)::type_id::create("hni_driver", this);
    this.hni_driver.cfg = this.cfg;

    // Optional configurable SAM. When absent the driver uses its stride default.
    void'(uvm_config_db #(vip_chi_hni_sam)::get(this, "", "sam", this.hni_driver.sam));
    // Optional QoS arbitration collection window (cycles).
    begin
      int arb_window;
      if (uvm_config_db #(int)::get(this, "", "arb_window", arb_window)) begin
        this.hni_driver.arb_window_cycles = arb_window;
      end
    end

    foreach (this.rn_vif[i]) begin
      uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_HNI_E))::set(
        this, "hni_driver", $sformatf("rn_vif_%0d", i), this.rn_vif[i]);
    end
    foreach (this.sn_vif[j]) begin
      uvm_config_db #(virtual vip_chi_if #(CFG_P, FLIT_TYPES_T, VIP_CHI_ROLE_RNI_E))::set(
        this, "hni_driver", $sformatf("sn_vif_%0d", j), this.sn_vif[j]);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // TRUE only when every RN- and SN-facing link is out of reset. The proxy
  // straddles all of them, so a reset on any single link must tear it down.
  // ---------------------------------------------------------------------------
  protected function bit all_links_out_of_reset();
    foreach (this.rn_vif[i]) begin
      if (!this.rn_vif[i].rst_n) begin
        return 1'b0;
      end
    end
    foreach (this.sn_vif[j]) begin
      if (!this.sn_vif[j].rst_n) begin
        return 1'b0;
      end
    end
    return 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // Reset watcher spanning every link: run the proxy only while ALL links are
  // out of reset, and cascade handle_reset when ANY link re-enters reset (not
  // just rn_vif[0], which would leak an in-flight proxy across a peer reset).
  // ---------------------------------------------------------------------------
  task run_phase(input uvm_phase phase);
    event link_rst_changed;

    this.hni_driver.reset_vif();

    // One persistent notifier per link pulses on any rst_n edge; the main loop
    // below re-evaluates all_links_out_of_reset() on each pulse. These live for
    // the whole run and are never disabled by the proxy tear-down below.
    foreach (this.rn_vif[i]) begin
      automatic int k = i;
      fork
        forever begin
          @(this.rn_vif[k].rst_n);
          -> link_rst_changed;
        end
      join_none
    end
    foreach (this.sn_vif[j]) begin
      automatic int k = j;
      fork
        forever begin
          @(this.sn_vif[k].rst_n);
          -> link_rst_changed;
        end
      join_none
    end

    forever begin
      while (!this.all_links_out_of_reset()) begin
        @(link_rst_changed);
      end

      fork : proxy_run
        this.hni_driver.driver_start();
      join_none

      while (this.all_links_out_of_reset()) begin
        @(link_rst_changed);
      end
      disable proxy_run;

      this.hni_driver.handle_reset();
      this.hni_driver.reset_vif();
    end
  endtask

endclass

`endif
