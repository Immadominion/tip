/// The submission conventions the pool enforces, encoded rather than remembered.
///
/// Each of these fails in a way that does not name its cause. A proof built at
/// the chain head reverts with "Note not mature". An empty `proofFacts` array
/// serialises an invalid v3 transaction. A missing tip surfaces as "Cannot mix
/// BigInt and other types". A retry after a failed submission loops forever on
/// a stale nonce.
///
/// They are small rules with expensive failure modes, so they live in code with
/// the reasoning attached.
library;

import '../errors.dart';

/// How far behind the chain head a proof must be based.
///
/// Two reasons, and both bite:
///
/// Notes mature ten blocks after creation, so proving any earlier can include a
/// note the pool will reject. And a proof based on the head can be invalidated
/// by an L2 reorg before the transaction lands.
const int provingBlockLag = 10;

/// How long the pool accepts a proof for, in blocks.
///
/// Ten blocks back is comfortably fresh against this ceiling, so backing off
/// costs nothing.
const int proofValidityBlocks = 450;

/// The block a proof should be generated against, given the current head.
///
/// Re-fetch this between chained transactions. Reusing a value from before an
/// awaited confirmation is how "Note not mature" reappears after it seemed
/// fixed.
int provingBlockFor(int currentBlock) {
  if (currentBlock < provingBlockLag) {
    throw ProtocolException(
      'Chain head is only $currentBlock blocks in; nothing can have matured '
      'yet. Proving requires a base at least $provingBlockLag blocks back.',
    );
  }
  return currentBlock - provingBlockLag;
}

/// Whether a proof based on [provingBlock] is still acceptable at
/// [currentBlock].
bool isProofStillValid({
  required int provingBlock,
  required int currentBlock,
}) =>
    currentBlock - provingBlock <= proofValidityBlocks;

/// The proof fields to merge into a transaction, or nothing at all.
///
/// The conditional is the whole point. Development and mock proving backends
/// return no proof facts, and passing an empty array through produces a
/// transaction the node rejects as malformed. The keys must be absent, not
/// empty.
Map<String, dynamic> proofFields({
  required List<String> proofFacts,
  required String proof,
}) =>
    proofFacts.isEmpty ? const {} : {'proof_facts': proofFacts, 'proof': proof};

/// Fee tip for a v3 transaction.
///
/// Mandatory, and zero is a valid value. Omitting it entirely is what triggers
/// the "Cannot mix BigInt and other types" failure.
const String requiredTip = '0x0';

/// Whether a failed submission has invalidated the cached pool nonce.
///
/// After any of these the cache is stale, and resubmitting without clearing it
/// produces proofs the chain keeps rejecting for the same reason.
bool requiresNonceCacheReset(String errorMessage) {
  final normalised = errorMessage.toUpperCase();
  return normalised.contains('INVALID_NONCE') ||
      normalised.contains('REPLACEMENT TRANSACTION UNDERPRICED') ||
      normalised.contains('REVERT');
}
