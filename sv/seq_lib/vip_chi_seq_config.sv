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

`ifndef VIP_CHI_SEQ_CONFIG
`define VIP_CHI_SEQ_CONFIG

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_seq_config extends uvm_object;

  `uvm_object_utils(vip_chi_seq_config)

  // ---------------------------------------------------------------------------
  // Sequence control.
  // ---------------------------------------------------------------------------
  int unsigned requests = 1;

  // ---------------------------------------------------------------------------
  // Inter-request delay control.
  // ---------------------------------------------------------------------------
  bit      request_delay_enabled = 1'b0;
  int      request_delay_min     = 0;
  int      request_delay_max     = 0;
  realtime clock_period          = 0.0;

  // ---------------------------------------------------------------------------
  // Logging.
  // ---------------------------------------------------------------------------
  bit verbose         = 1'b1;
  int log_denominator = 100;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_seq_config");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Restore default loop, delay, and logging knobs.
  // ---------------------------------------------------------------------------
  function void reset();

    this.requests              = 1;
    this.request_delay_enabled = 1'b0;
    this.request_delay_min     = 0;
    this.request_delay_max     = 0;
    this.clock_period          = 0.0;
    this.verbose               = 1'b1;
    this.log_denominator       = 100;
  endfunction

  // ---------------------------------------------------------------------------
  // Emit a periodic progress print for long-running generated traffic.
  // ---------------------------------------------------------------------------
  function void log_status(
    input int    request_idx,
    input string access_type,
    input string caller_name
  );

    if (this.verbose &&
        ((request_idx % this.log_denominator) == 0 ||
         ((this.requests != VIP_CHI_UNLIMITED_REQUESTS_C) &&
          (request_idx == (int'(this.requests) - 1))))) begin
      if (this.requests == VIP_CHI_UNLIMITED_REQUESTS_C) begin
        `uvm_info(caller_name, $sformatf(
          "INFO [%s] %s (%0d)",
          caller_name, access_type, request_idx + 1), UVM_LOW)
      end
      else begin
        `uvm_info(caller_name, $sformatf(
          "INFO [%s] %s (%0d/%0d)",
          caller_name, access_type, request_idx + 1, this.requests), UVM_LOW)
      end
    end
  endfunction

endclass

`endif