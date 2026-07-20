`ifndef VIP_CHI_EXCL_LOAD_SEQ
`define VIP_CHI_EXCL_LOAD_SEQ

import uvm_pkg::*;
`include "uvm_macros.svh"
import vip_chi_types_pkg::*;

// -----------------------------------------------------------------------------
// Exclusive load (LL): a ReadClean with the exclusive attribute set. It fetches
// the line into a clean shared/unique state exactly like a normal ReadClean AND
// arms the home's per-(line, port) exclusive monitor. The completion carries
// RespErr = ExclOkay to tell the RN-F its reservation was taken. Pair with
// vip_chi_excl_store_seq (CleanUnique+excl) to form an LL/SC exclusive sequence.
// -----------------------------------------------------------------------------
class vip_chi_excl_load_seq #(
  vip_chi_cfg_t CFG_P = VIP_CHI_DEFAULT_CFG_C
  ) extends vip_chi_coherent_base_seq #(CFG_P);

  `uvm_object_param_utils(vip_chi_excl_load_seq #(CFG_P))

  function new(input string name = "vip_chi_excl_load_seq");
    super.new(name);
  endfunction

  task body();
    super.set_direction(VIP_CHI_DIR_READ_E);
    super.set_coherent_opcode(req_opcode_t'(VIP_CHI_REQ_READ_CLEAN_C));
    // Set excl AFTER any reset() the test issued in cfg (reset clears excl_val).
    super.set_excl(1'b1);
    super.body();
  endtask

endclass

`endif
