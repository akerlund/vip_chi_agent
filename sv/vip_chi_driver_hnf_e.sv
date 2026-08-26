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

`ifndef VIP_CHI_DRIVER_HNF_E
`define VIP_CHI_DRIVER_HNF_E

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// The coherent home, Issue-E-exact: the same HN-F, reading the REQ fields the
// Issue E flit has and the Issue D flit does not.
//
// One override, and it is the completer half of what vip_chi_driver_rnf_e drives.
// 13.10.8 builds PGroupID out of {GroupIDExt[2:0], LPID[4:0]}, so the requester
// putting GroupIDExt on the wire and the home reading it back are one feature:
// either end alone reports group zero, and reports it with every check agreeing.
class vip_chi_driver_hnf_e #(
  vip_chi_cfg_t CFG_P        = VIP_CHI_DEFAULT_CFG_C,
  type          FLIT_TYPES_T = vip_chi_types_e #(CFG_P),
  int           N_RNF_PORTS  = 1,
  int           N_SN_PORTS   = 0
  ) extends vip_chi_driver_hnf #(CFG_P, FLIT_TYPES_T, N_RNF_PORTS, N_SN_PORTS);

  typedef FLIT_TYPES_T::vip_chi_req_flit_t req_flit_t;

  `uvm_component_param_utils(vip_chi_driver_hnf_e #(CFG_P, FLIT_TYPES_T, N_RNF_PORTS, N_SN_PORTS))

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name, input uvm_component parent);
    super.new(name, parent);
  endfunction

  // ---------------------------------------------------------------------------
  // The exact CHI-E REQ GroupIDExt, which the base cannot name.
  // ---------------------------------------------------------------------------
  virtual protected function logic [2 : 0] req_group_id_ext(input req_flit_t req);
    return 3'(req.groupidext);
  endfunction
endclass

`endif
