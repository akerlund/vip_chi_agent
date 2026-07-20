`ifndef VIP_CHI_ADDR_ITERATOR
`define VIP_CHI_ADDR_ITERATOR

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

class vip_chi_addr_iterator #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends uvm_object;

  `uvm_object_param_utils(vip_chi_addr_iterator #(CFG_P))

  typedef vip_chi_types #(CFG_P)::addr_t addr_t;

  protected addr_t current_addr = '0;
  protected addr_t addrs        [$];
  protected bit    enabled      = 1'b1;
  protected longint fixed_inc   = 0;

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_addr_iterator");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Set the address used by the next generated request.
  // ---------------------------------------------------------------------------
  function void set_initial_addr(input addr_t addr);
    this.current_addr = addr;
  endfunction

  // ---------------------------------------------------------------------------
  // Load an explicit request-address list.
  // ---------------------------------------------------------------------------
  function void load_list(input addr_t list []);

    this.addrs.delete();
    foreach (list[i]) begin
      this.addrs.push_back(list[i]);
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Return the number of queued explicit addresses still available.
  // ---------------------------------------------------------------------------
  function int list_size();
    return this.addrs.size();
  endfunction

  // ---------------------------------------------------------------------------
  // Consume and return the first explicit address in the list.
  // ---------------------------------------------------------------------------
  function addr_t pop_list_front();
    return this.addrs.pop_front();
  endfunction

  // ---------------------------------------------------------------------------
  // Set a fixed increment between successive generated addresses.
  // ---------------------------------------------------------------------------
  function void set_increment(input longint increment);
    this.fixed_inc = increment;
  endfunction

  // ---------------------------------------------------------------------------
  // Enable or disable address advancement between generated requests.
  // ---------------------------------------------------------------------------
  function void set_enabled(input bit en);
    this.enabled = en;
  endfunction

  // ---------------------------------------------------------------------------
  // Return the address that the next generated request will use.
  // ---------------------------------------------------------------------------
  function addr_t current();
    return this.current_addr;
  endfunction

  // ---------------------------------------------------------------------------
  // Advance the iterator after one request has been generated.
  // ---------------------------------------------------------------------------
  function addr_t advance(input logic [VIP_CHI_REQ_SIZE_WIDTH_C - 1 : 0] size);

    if (this.addrs.size() != 0) begin
      this.current_addr = this.addrs.pop_front();
      return this.current_addr;
    end

    if (!this.enabled) begin
      return this.current_addr;
    end

    if (this.fixed_inc != 0) begin
      this.current_addr = this.current_addr + this.fixed_inc;
      return this.current_addr;
    end

    this.current_addr = this.current_addr +
      addr_t'(vip_chi_types_pkg::chi_size_bytes(size));
    return this.current_addr;
  endfunction

  // ---------------------------------------------------------------------------
  // Restore the iterator to its default idle state.
  // ---------------------------------------------------------------------------
  function void reset();
    this.current_addr = '0;
    this.addrs.delete();
    this.enabled    = 1'b1;
    this.fixed_inc  = 0;
  endfunction

endclass

`endif