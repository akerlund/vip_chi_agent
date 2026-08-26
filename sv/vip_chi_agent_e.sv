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

`ifndef VIP_CHI_AGENT_E
`define VIP_CHI_AGENT_E

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_agent_e #(
  vip_chi_cfg_t  CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type           FLIT_TYPES_T = vip_chi_types_e #(CFG_P),
  vip_chi_role_t ROLE_P       = VIP_CHI_ROLE_MONITOR_E
  ) extends vip_chi_agent #(CFG_P, FLIT_TYPES_T, ROLE_P);

  `uvm_component_param_utils(vip_chi_agent_e #(CFG_P, FLIT_TYPES_T, ROLE_P))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Use the exact-CHI-E monitor so REQ-only E fields are published back out of
  // monitor analysis ports.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_monitor #(CFG_P, FLIT_TYPES_T, ROLE_P) create_monitor();
    return vip_chi_monitor_e #(CFG_P, FLIT_TYPES_T, ROLE_P)::type_id::create("monitor", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Use the exact-CHI-E RN-I driver so REQ-only E fields reach the wire.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_driver_rni #(CFG_P, FLIT_TYPES_T) create_rni_driver();
    return vip_chi_driver_rni_e #(CFG_P, FLIT_TYPES_T)::type_id::create("rni_driver", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Use the exact-CHI-E RN-F driver so REQ-only E fields reach the wire from a
  // COHERENT requester too. Without it the coherent link is E in every respect
  // but the one that matters to a persistent CMO: GroupIDExt stays zero, so
  // 13.10.8's PGroupID reports group zero whatever the requester asked for.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_driver_rnf #(CFG_P, FLIT_TYPES_T) create_rnf_driver();
    return vip_chi_driver_rnf_e #(CFG_P, FLIT_TYPES_T)::type_id::create("rnf_driver", this);
  endfunction

  // ---------------------------------------------------------------------------
  // Use the exact-CHI-E SN-F driver so DAT-side E tagging reaches the wire on
  // responder-driven completions.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_driver_snf #(CFG_P, FLIT_TYPES_T) create_snf_driver();
    return vip_chi_driver_snf_e #(CFG_P, FLIT_TYPES_T)::type_id::create("snf_driver", this);
  endfunction
endclass

`endif