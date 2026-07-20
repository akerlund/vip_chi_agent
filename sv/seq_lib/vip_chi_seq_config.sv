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