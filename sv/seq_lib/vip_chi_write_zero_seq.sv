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

`ifndef VIP_CHI_WRITE_ZERO_SEQ
`define VIP_CHI_WRITE_ZERO_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_write_zero_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_write_zero_seq #(CFG_P))

  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_write_zero_seq");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Pin the direction, reject unsupported payload-driven modes, and then
  // forward to the inherited generation loop.
  // ---------------------------------------------------------------------------
  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);

    if (CFG_P.ISSUE_P != VIP_CHI_ISSUE_E_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteNoSnpZero is only legal under CHI-E",
        get_name()))
      return;
    end

    if ((this.cfg.requests == VIP_CHI_UNLIMITED_REQUESTS_C) ||
        !this.payload_buf.exhausted() ||
        this.payload_buf.has_custom_be()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteNoSnpZero does not support custom request payload configuration",
        get_name()))
      return;
    end

    super.set_data_type(VIP_CHI_DATA_ZEROS_E);
    super.body();
  endtask

  // ---------------------------------------------------------------------------
  // Force the request opcode to WriteNoSnpZero.
  // ---------------------------------------------------------------------------
  virtual protected function req_opcode_t choose_opcode();

    if (CFG_P.ISSUE_P != VIP_CHI_ISSUE_E_E) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] WriteNoSnpZero is only legal under CHI-E",
        get_name()))
      return req_opcode_t'('0);
    end

    return req_opcode_t'(VIP_CHI_REQ_WRITE_NO_SNP_ZERO_C);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the fixed access label used in progress logs.
  // ---------------------------------------------------------------------------
  virtual protected function string access_name();
    return "WriteNoSnpZero";
  endfunction

  // ---------------------------------------------------------------------------
  // Expose the fixed opcode choice for smoke checks.
  // ---------------------------------------------------------------------------
  function req_opcode_t get_opcode();
    return this.choose_opcode();
  endfunction

  // ---------------------------------------------------------------------------
  // Expose the fixed access label for smoke checks.
  // ---------------------------------------------------------------------------
  function string get_access_name();
    return this.access_name();
  endfunction

endclass

`endif