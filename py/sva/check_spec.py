################################################################################
#
# Copyright (C) 2026 Fredrik Akerlund
# https://github.com/akerlund/vip_chi_agent
#
# See the SystemVerilog originals for the full MIT notice.
#
################################################################################
#
# The specification clause each check enforces, one entry per check ID.
#
# The citation belongs to the RULE, not to the place the rule happens to be
# evaluated. It used to be an argument at every `_chk` call site, which meant a
# rule judged from two vantages carried the string twice and could carry it
# differently, and a rule whose clause was wrong had to be corrected once per
# site. Here there is one string per rule and the report reads it.
#
# The SystemVerilog twin is `vip_chi_check_spec()` in `sv/vip_chi_types_pkg.sv`,
# which carries the same string for the same ID. `scripts/check_citation_parity.py`
# holds them equal and fails if a rule in the registry has no citation.
#
# ---------------------------------------------------------------------------
# How a citation is written
# ---------------------------------------------------------------------------
# The two issues renumber from chapter 12 onward -- the Link Layer is E chapter
# 14 and D chapter 13 -- so a bare section number is ambiguous exactly where the
# link rules live. Every entry therefore names its issue:
#
#   "E section 14.6.1 / D section 13.6.1"  both numbers known
#   "E section 13.10.3"                    verified against issue E only, which
#                                          is the case for the field-description
#                                          chapter and for the chapter-2 tables,
#                                          whose numbering was not confirmed
#                                          against D
#
# An EMPTY string means the check has no clause behind it and is not claiming
# one. Both ports omit the citation from the report rather than printing an
# empty reference. This is not a gap to be filled later: the X/Z rules below
# guard against a testbench defect, and the specification has nothing to say
# about a signal holding X.
#
################################################################################

# Keyed by the canonical rule name -- `vip_chi_check_name()` in the SV registry,
# and the first argument of `_chk` here.
CHECK_SPEC_C = {

  # ---------------------------------------------------------------------------
  # Link layer. E chapter 14 / D chapter 13.
  # ---------------------------------------------------------------------------
  # Flit and credit gating: the two link state machines are defined by the
  # direction of the channels they govern, and only RUN permits a flit.
  "CHI_REQ_FLITV_REQUIRES_LINK":       "E section 14.6.1 / D section 13.6.1",
  "CHI_RSP_FLITV_REQUIRES_LINK":       "E section 14.6.1 / D section 13.6.1",
  "CHI_DAT_FLITV_REQUIRES_LINK":       "E section 14.6.1 / D section 13.6.1",
  "CHI_REQ_LCRDV_REQUIRES_LINK":       "E section 14.6.1 / D section 13.6.1",
  "CHI_RSP_LCRDV_REQUIRES_LINK":       "E section 14.6.1 / D section 13.6.1",
  "CHI_DAT_LCRDV_REQUIRES_LINK":       "E section 14.6.1 / D section 13.6.1",
  "CHI_SNP_FLITV_REQUIRES_LINK":       "E section 14.6.1 / D section 13.6.1",
  "CHI_SNP_LCRDV_REQUIRES_LINK":       "E section 14.6.1 / D section 13.6.1",
  "CHI_LCRD_QUIESCENT_IN_STOP":        "E section 14.6.1 / D section 13.6.1",

  # FLITPEND, one cycle ahead of the flit it announces.
  "CHI_REQ_VALID_REQUIRES_PEND":       "E section 14.4 / D section 13.4",
  "CHI_RSP_VALID_REQUIRES_PEND":       "E section 14.4 / D section 13.4",
  "CHI_DAT_VALID_REQUIRES_PEND":       "E section 14.4 / D section 13.4",
  "CHI_SNP_VALID_REQUIRES_PEND":       "E section 14.4 / D section 13.4",

  # Initialization: what must be held low through reset, and that the link comes
  # back up afterwards.
  "CHI_REQ_IDLE_IN_RESET":             "E section 14.1.3 / D section 13.1.3",
  "CHI_RSP_IDLE_IN_RESET":             "E section 14.1.3 / D section 13.1.3",
  "CHI_DAT_IDLE_IN_RESET":             "E section 14.1.3 / D section 13.1.3",
  "CHI_SNP_IDLE_IN_RESET":             "E section 14.1.3 / D section 13.1.3",
  "CHI_LINK_SIDEBAND_IDLE_IN_RESET":   "E section 14.1.3 / D section 13.1.3",
  "CHI_LINK_RESTARTS_AFTER_RESET":     "E section 14.1.3 / D section 13.1.3",

  # L-Credit flow control -- the credit shadow, not the activation sequence.
  "CHI_LCRD_OVERFLOW":                 "E section 14.2.1 / D section 13.2.1",
  "CHI_LCRD_UNDERFLOW":                "E section 14.2.1 / D section 13.2.1",
  "CHI_LCRD_USED_IN_GRANT_CYCLE":      "E section 14.2.1 Note / D section 13.2.1 Note",
  "CHI_SNP_LCRD_OVERFLOW":             "E section 14.2.1 / D section 13.2.1",
  "CHI_SNP_LCRD_UNDERFLOW":            "E section 14.2.1 / D section 13.2.1",

  # The Link Activation State Machine: the legal transition set, and the two
  # handshakes that must not stall forever.
  "CHI_LASM_LEGAL_TRANSITION":         "E section 14.6.2 / D section 13.6.2",
  "CHI_LASM_ACTIVATE_OBSERVED":        "E section 14.5.1 Table 14-2 / D section 13.5.1",
  "CHI_LASM_ACTIVATION_TIMEOUT":       "E section 14.6.2 / D section 13.6.2",
  "CHI_LASM_DEACTIVATION_TIMEOUT":     "E section 14.6.2 / D section 13.6.2",

  # Asynchronous race condition. The first constrains a component's own two
  # outputs, the second what it may drive while observing a race on its inputs.
  "CHI_LASM_OUTPUT_RACE":              "E section 14.6.3 / D section 13.6.3",
  "CHI_LASM_INPUT_RACE_HOLD":          "E section 14.6.3 / D section 13.6.3",

  # SACTIVE. Both rules are in 14.7.2, which is where the TXSACTIVE rules are
  # written -- 14.7.1 is an Introduction and carries none of them. "TXSACTIVE
  # must remain asserted until after the last flit relating to all transactions
  # is sent or received" is the coverage rule; the bullet permitting deassertion
  # during a link deactivation sequence is what the deassertion bound reads
  # against.
  "CHI_TXSACTIVE_COVERS_OUTSTANDING":  "E section 14.7.2 / D section 13.7.2",
  "CHI_TXSACTIVE_DEASSERT_BOUNDED":    "E section 14.7.2 / D section 13.7.2",
  "CHI_LINK_DEACTIVATE_WHEN_IDLE":     "E section 14.7.4 / D section 13.7.4",

  # X/Z hygiene. SV-only -- Verilator is 2-state, so the Python port cannot hold
  # X and a mirror there could never fire. No clause: the specification does not
  # legislate about a net holding X, and claiming one would be an invention.
  "CHI_REQ_KNOWN_WHEN_VALID":          "",
  "CHI_RSP_KNOWN_WHEN_VALID":          "",
  "CHI_DAT_KNOWN_WHEN_VALID":          "",
  "CHI_SNP_KNOWN_WHEN_VALID":          "",

  # ---------------------------------------------------------------------------
  # Transaction structure. Chapter 2 in both issues.
  # ---------------------------------------------------------------------------
  "CHI_COMPLETION_FOLLOWS_REQ":        "E section 2.3 / D section 2.3",

  # 2.5 Details of transaction identifier fields. TxnID uniqueness lives here,
  # and so does the constancy of a TxnID across the beats of one burst.
  "CHI_TXNID_REUSE_REQUESTER":         "E section 2.5 / D section 2.5",
  "CHI_TXNID_REUSE_COMPLETER":         "E section 2.5 / D section 2.5",
  "CHI_TX_DAT_TXNID_STABLE":           "E section 2.5 / D section 2.5",
  "CHI_RX_DAT_TXNID_STABLE":           "E section 2.5 / D section 2.5",

  # 2.6 Transaction identifier field flows, one subsection per class.
  "CHI_TX_READ_COMPLETION_DAT_OPCODE": "E section 2.6.1 / D section 2.6.1",
  "CHI_RX_READ_COMPLETION_DAT_OPCODE": "E section 2.6.1 / D section 2.6.1",
  "CHI_WRITE_DAT_BEFORE_DBID":         "E section 2.6.3 / D section 2.6.3",
  "CHI_WRITE_DAT_TXNID_MATCHES_DBID":  "E section 2.6.3 / D section 2.6.3",
  "CHI_RSP_RETRY_ACK_TXN_ID":          "E section 2.6.5 / D section 2.6.5",
  # Same section as the TxnID rules above, and for the same reason: it is a
  # statement about which identifier a message must carry.
  "CHI_COMP_DBID_MATCHES_GRANT":       "E section 2.5 / D section 2.5",
  "CHI_COMPLETER_DBID_UNIQUE":         "E section 2.5 / D section 2.5",

  # 2.8 Ordering. CompAck has its own subsection, carrying both the sequencing
  # rule and the rule that ExpCompAck is what asks for one. The ordered-read
  # receipt is in 2.8.5 -- not 2.7, which is the Logical Processor Identifier.
  "CHI_COMPACK_BEFORE_COMPLETION":     "E section 2.8.3 / D section 2.8.3",
  "CHI_COMPACK_WITHOUT_EXPCOMPACK":    "E section 2.8.3 / D section 2.8.3",
  "CHI_EXPCOMPACK_REQUIRED_BUT_ZERO":  "E section 2.8.3 / D section 2.8.3",
  "CHI_ORDERED_READ_RECEIPT_BEFORE_DAT": "E section 2.8.5 / D section 2.8.5",

  # 2.9 Address, Control, and Data -- the request ATTRIBUTES, not the data.
  "CHI_REQ_ATTR_COMBINATION_LEGAL":    "E section 2.9.4 Table 2-12",
  "CHI_REQ_LIKELY_SHARED_LEGAL":       "E section 2.9.5 / D section 2.9.5",

  # 2.10 Data transfer. Beat placement and count are packetization (2.10.4);
  # the atomic size table is 2.10.5.
  "CHI_TX_DAT_FIRST_BEAT_DATAID_ZERO": "E section 2.10.4 / D section 2.10.4",
  "CHI_RX_DAT_FIRST_BEAT_DATAID_ZERO": "E section 2.10.4 / D section 2.10.4",
  "CHI_TX_DAT_DATAID_SEQUENTIAL":      "E section 2.10.4 / D section 2.10.4",
  "CHI_RX_DAT_DATAID_SEQUENTIAL":      "E section 2.10.4 / D section 2.10.4",
  "CHI_TX_WRITE_DAT_BEAT_COUNT":       "E section 2.10.4 / D section 2.10.4",
  "CHI_RX_WRITE_DAT_BEAT_COUNT":       "E section 2.10.4 / D section 2.10.4",
  "CHI_TX_READ_COMPLETION_DAT_BEAT_COUNT": "E section 2.10.4 / D section 2.10.4",
  "CHI_RX_READ_COMPLETION_DAT_BEAT_COUNT": "E section 2.10.4 / D section 2.10.4",
  "CHI_ATOMIC_SIZE_LEGAL":             "E section 2.10.5 Table 2-17",

  # 2.11 Request Retry. NOT 2.9.4, which is Transaction attribute combinations
  # -- both retry rules were filed there and neither is written there.
  "CHI_REQ_ALLOW_RETRY_PCRD_ZERO":     "E section 2.11.2 / D section 2.11.2",
  "CHI_REQ_RETRY_SPENDS_GRANTED_CREDIT": "E section 2.11.2 / D section 2.11.2",

  # Outside chapter 2. Chapter 4 renumbers between the issues -- E 4.2.5 is
  # Atomic transactions, D 4.2.5 is Other transactions -- so the atomic rule is
  # cited against E alone. 4.9 and 6.3 carry the same number in both.
  "CHI_ATOMIC_RETURN_USES_DAT_COMPLETION": "E section 4.2.5",
  "CHI_SNP_RET_TO_SRC_LEGAL":          "E section 4.9 / D section 4.9",
  "CHI_REQ_EXCL_LEGAL":                "E section 6.3 / D section 6.3",

  # ---------------------------------------------------------------------------
  # Field legality. Issue E numbering only -- these were read from E, and the
  # field-description chapter is one of the renumbered ones, so quoting a D
  # number here would be a guess.
  # ---------------------------------------------------------------------------
  "CHI_DAT_HOME_NID_LEGAL":            "E section 13.10.3",
  "CHI_REQ_RETURN_PATH_LEGAL":         "E section 13.10.4 / E section 13.10.15",
  "CHI_SNP_FWD_FIELDS_ZERO":           "E section 13.10.5 / E section 13.10.16",
  "CHI_SNP_DO_NOT_GO_TO_SD_LEGAL":     "E section 13.10.35",
  "CHI_REQ_ORDER_LEGAL":               "E Table 13-25 / E Table 2-12 footnote a",
  "CHI_REQ_TAGOP_LEGAL":               "E Table 12-2",
  "CHI_EXPCOMPACK_PROHIBITED_BUT_SET": "E Table 2-9",
  "CHI_REQ_SNP_ATTR_LEGAL":            "E Table 2-14",
  "CHI_REQ_PCRD_RETURN_FIELDS_ZERO":   "E Table A-2 / E Table A-3",
  "CHI_REQ_SIZE_LEGAL":                "E Table A-3 / D Table A-3",
  "CHI_REQ_ENDIAN_LEGAL":              "E Table A-3 / D Table A-3",
  "CHI_RSP_FIELD_ZERO":                "E Table A-4 / D Table A-4",
  "CHI_RSP_COMP_RESP_LEGAL":           "E Table 4-7 / D Table 4-5",
  "CHI_REQ_ALLOCATE_LEGAL":            "E Table A-3 / D Table A-3, with E section 2.9.3 / D section 2.9.3",
  "CHI_DAT_CBUSY_LEGAL":               "E Table A-5",
}


def check_spec(rule: str) -> str:
  """The clause for a rule, or the empty string when it claims none.

  An UNKNOWN rule also returns empty rather than raising: a check name is a
  plain string here, and a checker that has just been given a new rule should
  report the violation it found rather than die on a missing citation. The
  parity script is what makes the omission visible, at author time.
  """
  return CHECK_SPEC_C.get(rule, "")
