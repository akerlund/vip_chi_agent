// ===========================================================================
// chi_link_adapter
//
// Connects one CHI interface endpoint to another. A CHI link is a
// point-to-point pair of unidirectional signal sets (REQ/RSP/DAT flits, the
// link-activation handshake, and per-channel L-credits). Each role-typed
// vip_chi_if drives only its own TX side, so joining two endpoints into a live
// link is purely a matter of cross-wiring one endpoint's tx* onto the other's
// rx*. This adapter is that cross-wire, packaged once so the DUT-less example
// top can express "RN-I <-> SN-F", "RN-I <-> HN-I", "HN-I <-> SN-F", etc. as a
// single instance instead of ~26 hand-repeated assignments.
//
//   rn = requester-polarity endpoint (VIP_CHI_ROLE_RNI, or an HN-I SN-facing
//        port which also uses RN-I signal directions)
//   sn = completer-polarity endpoint (VIP_CHI_ROLE_SNF, or an HN-I RN-facing
//        port which uses SN-F signal directions)
//
// REQ flows rn -> sn; the REQ credit (rxreqlcrdv) flows sn -> rn. RSP and DAT
// flow in both directions. An endpoint whose agent is not driving simply holds
// its tx* idle, so an unused link carries idle without any extra gating here.
//
// The interface ports are left unparameterized (`vip_chi_if rn`): the tx*/rx*
// signal names are identical for every ROLE_P, and the flit widths come from
// whatever instance is connected, so the same adapter serves the narrow CHI-D
// links and the wide CHI-E links.
// ===========================================================================
module chi_link_adapter (
  vip_chi_if rn,
  vip_chi_if sn
);

  always_comb begin
    // Requester TX -> completer RX (REQ + the RSP/DAT that flow rn->sn, and
    // the RSP/DAT credits rn grants for what it receives).
    sn.rxlinkactivereq = rn.txlinkactivereq;
    sn.rxlinkactiveack = rn.txlinkactiveack;
    sn.rxsactive       = rn.txsactive;
    sn.rxreqflitpend   = rn.txreqflitpend;
    sn.rxreqflitv      = rn.txreqflitv;
    sn.rxreqflit       = rn.txreqflit;
    sn.rxrspflitpend   = rn.txrspflitpend;
    sn.rxrspflitv      = rn.txrspflitv;
    sn.rxrspflit       = rn.txrspflit;
    sn.rxrsplcrdv      = rn.txrsplcrdv;
    sn.rxdatflitpend   = rn.txdatflitpend;
    sn.rxdatflitv      = rn.txdatflitv;
    sn.rxdatflit       = rn.txdatflit;
    sn.rxdatlcrdv      = rn.txdatlcrdv;
    // SNP receive-credit the requester (RN-F) grants for snoops it accepts,
    // flowing rn->sn (mirror of the REQ credit). Idle on non-coherent links.
    sn.rxsnplcrdv      = rn.txsnplcrdv;

    // Completer TX -> requester RX (RSP/DAT completions, the REQ credit sn
    // grants, and the RSP/DAT credits sn grants for what it receives).
    rn.rxlinkactivereq = sn.txlinkactivereq;
    rn.rxlinkactiveack = sn.txlinkactiveack;
    rn.rxsactive       = sn.txsactive;
    rn.rxreqlcrdv      = sn.txreqlcrdv;
    rn.rxrspflitpend   = sn.txrspflitpend;
    rn.rxrspflitv      = sn.txrspflitv;
    rn.rxrspflit       = sn.txrspflit;
    rn.rxrsplcrdv      = sn.txrsplcrdv;
    rn.rxdatflitpend   = sn.txdatflitpend;
    rn.rxdatflitv      = sn.txdatflitv;
    rn.rxdatflit       = sn.txdatflit;
    rn.rxdatlcrdv      = sn.txdatlcrdv;
    // Snoops the home (HN-F) sources, flowing sn->rn (opposite REQ). Idle on
    // non-coherent links (the completer endpoint ties txsnp* to 0).
    rn.rxsnpflitpend   = sn.txsnpflitpend;
    rn.rxsnpflitv      = sn.txsnpflitv;
    rn.rxsnpflit       = sn.txsnpflit;
  end

endmodule
