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

`ifndef VIP_CHI_PERSIST_SEQ
`define VIP_CHI_PERSIST_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_persist_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_persist_seq #(CFG_P))

  typedef vip_chi_types #(CFG_P)::req_opcode_t req_opcode_t;

  protected bit sep_persist_enabled = 1'b0;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_persist_seq");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Clear persist-specific state while preserving the inherited defaults.
  // ---------------------------------------------------------------------------
  function void reset();
    super.reset();
    this.sep_persist_enabled = 1'b0;
  endfunction

  // ---------------------------------------------------------------------------
  // Select between CleanSharedPersist and CleanSharedPersistSep.
  // ---------------------------------------------------------------------------
  function void set_sep_persist(input bit enabled);
    this.sep_persist_enabled = enabled;
  endfunction

  // ---------------------------------------------------------------------------
  // Pin write direction, reject payload-driven modes, then forward to the
  // inherited generation loop.
  // ---------------------------------------------------------------------------
  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);

    if (this.sep_persist_enabled && (CFG_P.ISSUE_P != VIP_CHI_ISSUE_E_E)) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] CleanSharedPersistSep is only legal under CHI-E",
        get_name()))
      return;
    end

    if ((this.cfg.requests == VIP_CHI_UNLIMITED_REQUESTS_C) ||
        !this.payload_buf.exhausted() ||
        this.payload_buf.has_custom_be()) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] Persist requests do not support custom request payload configuration",
        get_name()))
      return;
    end

    super.body();
  endtask

  // ---------------------------------------------------------------------------
  // Force the request opcode to the selected persist variant.
  // ---------------------------------------------------------------------------
  virtual protected function req_opcode_t choose_opcode();
    if (this.sep_persist_enabled) begin
      if (CFG_P.ISSUE_P != VIP_CHI_ISSUE_E_E) begin
        `uvm_fatal(get_name(), $sformatf(
          "FATAL [%s] CleanSharedPersistSep is only legal under CHI-E",
          get_name()))
        return req_opcode_t'('0);
      end
      return req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_SEP_C);
    end

    return req_opcode_t'(VIP_CHI_REQ_CLEAN_SHARED_PERSIST_C);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the fixed access label used in progress logs.
  // ---------------------------------------------------------------------------
  virtual protected function string access_name();
    if (this.sep_persist_enabled) begin
      return "CleanSharedPersistSep";
    end
    return "CleanSharedPersist";
  endfunction

endclass

`endif