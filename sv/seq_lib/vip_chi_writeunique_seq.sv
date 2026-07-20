`ifndef VIP_CHI_WRITEUNIQUE_SEQ
`define VIP_CHI_WRITEUNIQUE_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Coherent WriteUniqueFull/Ptl: a non-allocating coherent write to a line the
// requester does NOT hold. The home snoop-invalidates every other holder, grants
// a DBID (CompDBIDResp), collects the NonCopyBackWrData burst into memory, and
// leaves the requester Invalid (no ownership).
// -----------------------------------------------------------------------------
class vip_chi_writeunique_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_writeunique_seq #(CFG_P))

  protected bit partial_enabled = 1'b0;

  function new(input string name = "vip_chi_writeunique_seq");
    super.new(name);
  endfunction

  function void reset();
    super.reset();
    this.partial_enabled = 1'b0;
  endfunction

  function void set_partial(input bit enabled = 1'b1);
    this.partial_enabled = enabled;
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);
    super.set_coherent_opcode(this.partial_enabled
                            ? req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_PTL_C)
                            : req_opcode_t'(VIP_CHI_REQ_WRITE_UNIQUE_FULL_C));
    super.body();
  endtask

endclass

`endif
