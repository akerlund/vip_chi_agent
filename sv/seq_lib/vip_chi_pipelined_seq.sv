`ifndef VIP_CHI_PIPELINED_SEQ
`define VIP_CHI_PIPELINED_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_pipelined_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_pipelined_seq #(CFG_P))

  typedef vip_chi_item #(CFG_P) item_t;

  int max_outstanding = 8;

  // Caller-supplied item queue. The first cut bypasses the base generator and
  // simply forwards pre-built items to the driver in order.
  item_t items [$];

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_pipelined_seq");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Reset the inherited base-sequence state and clear any queued items.
  // ---------------------------------------------------------------------------
  function void reset();
    super.reset();
    this.items.delete();
    this.max_outstanding = 8;
  endfunction

  // ---------------------------------------------------------------------------
  // Append one fully-configured item to the pipelined send queue.
  // ---------------------------------------------------------------------------
  function void add_item(input item_t item);

    if (item == null) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] add_item() received a null item handle",
        get_name()))
    end

    this.items.push_back(item);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the queued item count for smoke checks.
  // ---------------------------------------------------------------------------
  function int item_count();
    return this.items.size();
  endfunction

  // ---------------------------------------------------------------------------
  // Return the collected response count for smoke checks.
  // ---------------------------------------------------------------------------
  function int response_count();
    return this.responses.size();
  endfunction

  // ---------------------------------------------------------------------------
  // Send the caller-supplied item queue in order. The driver is responsible
  // for channel-level pipelining; this sequence only avoids re-generating
  // items through the base randomization loop.
  // ---------------------------------------------------------------------------
  task body();
    item_t rsp;

    if (this.max_outstanding <= 0) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] max_outstanding must be > 0",
        get_name()))
    end

    if (this.items.size() == 0) begin
      `uvm_warning(get_name(), $sformatf(
        "WARNING [%s] No items queued in vip_chi_pipelined_seq",
        get_name()))
      return;
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Starting pipelined CHI sequence with %0d items (max_outstanding=%0d)",
      get_name(), this.items.size(), this.max_outstanding), UVM_LOW)

    foreach (this.items[i]) begin
      start_item(this.items[i]);
      finish_item(this.items[i]);

      if (this.item_cfg.get_response) begin
        get_response(rsp);
        this.responses.push_back(rsp);
      end
    end

    `uvm_info(get_name(), $sformatf(
      "INFO [%s] Completed pipelined CHI sequence with %0d items",
      get_name(), this.items.size()), UVM_LOW)
  endtask

endclass

`endif