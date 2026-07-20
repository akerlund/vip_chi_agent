class vip_chi_prefetch_tgt_seq extends vip_chi_base_seq #(CHI_D_CFG_C);

  `uvm_object_utils(vip_chi_prefetch_tgt_seq)

  typedef vip_chi_types #(CHI_D_CFG_C)::req_opcode_t req_opcode_t;

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------
  function new(input string name = "vip_chi_prefetch_tgt_seq");

    super.new(name);

  endfunction

  // ---------------------------------------------------------------------------
  // Force the request direction to READ before using the shared base flow.
  // ---------------------------------------------------------------------------
  task body();

    super.set_direction(VIP_CHI_DIR_READ_E);

    super.body();
  endtask

  // ---------------------------------------------------------------------------
  // Force the request opcode to PrefetchTgt.
  // ---------------------------------------------------------------------------
  virtual protected function req_opcode_t choose_opcode();

    return req_opcode_t'(VIP_CHI_REQ_PREFETCH_TGT_C);

  endfunction

  // ---------------------------------------------------------------------------
  // Return the fixed access label used in progress logs.
  // ---------------------------------------------------------------------------
  virtual protected function string access_name();

    return "PrefetchTgt";
  endfunction
endclass