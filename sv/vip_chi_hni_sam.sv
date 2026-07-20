`ifndef VIP_CHI_HNI_SAM
`define VIP_CHI_HNI_SAM

import uvm_pkg::*;
`include "uvm_macros.svh"

// -----------------------------------------------------------------------------
// HN-I System Address Map (SAM).
//
// Configurable address-range -> SN-target-port table for the HN-I proxy's
// request routing. This is the production form of the SN decode: instead of the
// driver's default single-bit address stride, a test/integration can hand the
// HN-I a SAM with explicit [base:limit] ranges. `lookup` returns the SN port of
// the first matching range, or `default_port` when no range matches.
//
// Ranges are inclusive on both ends and are compared as unsigned addresses.
// -----------------------------------------------------------------------------
typedef struct {
  longint unsigned base;
  longint unsigned limit;
  int              sn_port;
} vip_chi_hni_sam_entry_t;

class vip_chi_hni_sam extends uvm_object;

  vip_chi_hni_sam_entry_t entries [$];
  int                     default_port = 0;

  `uvm_object_utils(vip_chi_hni_sam)

  // ---------------------------------------------------------------------------
  // Constructor.
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_hni_sam");
    super.new(name);
  endfunction

  // ---------------------------------------------------------------------------
  // Append one inclusive [base:limit] -> sn_port range.
  // ---------------------------------------------------------------------------
  function void add_range(
    input longint unsigned base,
    input longint unsigned limit,
    input int              sn_port
  );
    vip_chi_hni_sam_entry_t e;

    // Validate before appending (7.4). A reversed [base:limit] can never match in
    // lookup(); an overlap makes routing insertion-order-dependent (lookup returns
    // the FIRST matching range), which is almost always a config mistake.
    if (base > limit) begin
      `uvm_fatal(get_name(), $sformatf(
        "FATAL [%s] add_range base 0x%0h > limit 0x%0h (reversed range)",
        get_name(), base, limit))
    end
    foreach (this.entries[i]) begin
      if ((base <= this.entries[i].limit) && (this.entries[i].base <= limit)) begin
        `uvm_warning(get_name(), $sformatf(
          "[%s] add_range [0x%0h:0x%0h]->%0d overlaps existing [0x%0h:0x%0h]->%0d; lookup() resolves by insertion order",
          get_name(), base, limit, sn_port,
          this.entries[i].base, this.entries[i].limit, this.entries[i].sn_port))
      end
    end

    e.base    = base;
    e.limit   = limit;
    e.sn_port = sn_port;
    this.entries.push_back(e);
  endfunction

  // ---------------------------------------------------------------------------
  // Return the SN port owning `addr` (first matching range), else default_port.
  // ---------------------------------------------------------------------------
  function int lookup(input longint unsigned addr);
    foreach (this.entries[i]) begin
      if ((addr >= this.entries[i].base) && (addr <= this.entries[i].limit)) begin
        return this.entries[i].sn_port;
      end
    end
    return this.default_port;
  endfunction

endclass

`endif
