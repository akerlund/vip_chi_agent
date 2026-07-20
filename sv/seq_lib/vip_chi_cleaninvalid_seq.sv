`ifndef VIP_CHI_CLEANINVALID_SEQ
`define VIP_CHI_CLEANINVALID_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Coherent CleanInvalid CMO: push any dirty copy to the point of coherence and
// invalidate ALL copies of the line (including the requester's, if held). The
// home snoops every other holder with SnpCleanInvalid (dirty holders forward
// their data, merged to memory) and returns an RSP-only Comp (no data).
// Completion-only, like Evict.
// -----------------------------------------------------------------------------
class vip_chi_cleaninvalid_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_cleaninvalid_seq #(CFG_P))

  function new(input string name = "vip_chi_cleaninvalid_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_WRITE_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_CLEAN_INVALID_C));
    super.body();
  endtask

endclass

`endif
