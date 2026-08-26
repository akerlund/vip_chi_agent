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

`ifndef VIP_CHI_HNF_AGENT_E
`define VIP_CHI_HNF_AGENT_E

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// The coherent home agent, Issue-E-exact.
//
// It exists only to name the E driver, and that is the whole job: the driver
// reads a REQ field the CHI-D flit does not have, so a CHI-D specialization of
// it fails to ELABORATE. Selecting it inside vip_chi_hnf_agent -- even under a
// test on CFG_P.ISSUE_P, which is a parameter -- would still name that
// specialization and still fail. The class boundary is the guard.
class vip_chi_hnf_agent_e #(
  vip_chi_cfg_t CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type          FLIT_TYPES_T = vip_chi_types_e #(CFG_P),
  int           N_RNF_PORTS  = 1,
  int           N_SN_PORTS   = 0
  ) extends vip_chi_hnf_agent #(CFG_P, FLIT_TYPES_T, N_RNF_PORTS, N_SN_PORTS);

  `uvm_component_param_utils(vip_chi_hnf_agent_e #(CFG_P, FLIT_TYPES_T, N_RNF_PORTS, N_SN_PORTS))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // Use the exact-CHI-E home driver so a persistent CMO's Persist response
  // carries the group the requester actually asked for.
  // ---------------------------------------------------------------------------
  protected virtual function vip_chi_driver_hnf #(CFG_P, FLIT_TYPES_T, N_RNF_PORTS, N_SN_PORTS) create_hnf_driver();
    return vip_chi_driver_hnf_e #(CFG_P, FLIT_TYPES_T, N_RNF_PORTS, N_SN_PORTS)::type_id::create("hnf_driver", this);
  endfunction
endclass

`endif
