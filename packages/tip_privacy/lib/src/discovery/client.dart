/// Client for the STRK20 discovery service.
///
/// Discovery is how a wallet finds money paid to it. Notes live on chain as
/// encrypted blobs with no index by recipient, so finding yours means walking
/// pool storage and trial-decrypting with your viewing key. The discovery
/// service does that walk on the client's behalf and returns only what the
/// supplied viewing key can open.
///
/// The service caps how much state it traverses per request, so a full sync is
/// a paginated loop. [syncIncoming] and [syncOutgoing] run that loop and hand
/// back the accumulated result.
library;

import '../errors.dart';
import 'models.dart';
import 'transport.dart';

/// Reads channels, subchannels, and notes from the discovery service.
class DiscoveryClient {
  DiscoveryClient({
    required this.transport,
    required this.poolContractAddress,
    this.maxPages = 100,
  });

  final DiscoveryTransport transport;

  /// The STRK20 pool this client reads from.
  final BigInt poolContractAddress;

  /// Safety bound on the pagination loop.
  ///
  /// A malformed or hostile cursor that never reports completion would
  /// otherwise spin forever. Hitting this throws rather than silently
  /// returning a partial sync, because a truncated sync looks exactly like
  /// "you have no money" to the user.
  final int maxPages;

  /// Walks every page of incoming state for [address].
  ///
  /// The [viewingKey] is sent to the service, which is the whole point of the
  /// design: the service can decrypt notes addressed to this key and nothing
  /// else. Use an OHTTP transport in production so the key is not visible to
  /// whatever terminates TLS.
  Future<IncomingSyncResult> syncIncoming({
    required BigInt address,
    required BigInt viewingKey,
    Object? blockIdentifier,
  }) async {
    final channels = <IncomingChannel>[];
    final subchannels = <IncomingSubchannel>[];
    final notes = <IncomingNote>[];

    var cursor = DiscoveryCursor.initial();
    Object? blockRef = blockIdentifier;
    var pages = 0;

    while (true) {
      if (++pages > maxPages) {
        throw DiscoveryException(
          'Incoming sync did not complete within $maxPages pages. '
          'Refusing to return a partial result.',
        );
      }

      final page = IncomingSyncPage.fromJson(
        await transport.post('/v1/sync/incoming_state', {
          'contract_address': feltToHex(poolContractAddress),
          'recipient_address': feltToHex(address),
          'viewing_key': feltToHex(viewingKey),
          'cursor': cursor.toJson(),
          if (blockRef != null) 'block_ref': blockRef,
        }),
      );

      channels.addAll(page.channels);
      subchannels.addAll(page.subchannels);
      notes.addAll(page.notes);

      // Pin every subsequent page to the block the first page was read at, so
      // the sync sees one consistent snapshot rather than a moving target.
      blockRef ??= page.blockRef;
      cursor = page.cursor;

      if (cursor.isComplete) {
        return IncomingSyncResult(
          blockRef: blockRef,
          channels: channels,
          subchannels: subchannels,
          notes: notes,
        );
      }
    }
  }

  /// Walks every page of outgoing state for [address].
  ///
  /// Pass [recipients] to narrow the walk to specific counterparties.
  Future<OutgoingSyncResult> syncOutgoing({
    required BigInt address,
    required BigInt viewingKey,
    List<BigInt>? recipients,
    Object? blockIdentifier,
  }) async {
    final channels = <OutgoingChannel>[];
    final subchannels = <OutgoingSubchannel>[];

    var cursor = DiscoveryCursor.initial();
    Object? blockRef = blockIdentifier;
    var pages = 0;

    while (true) {
      if (++pages > maxPages) {
        throw DiscoveryException(
          'Outgoing sync did not complete within $maxPages pages. '
          'Refusing to return a partial result.',
        );
      }

      final page = OutgoingSyncPage.fromJson(
        await transport.post('/v1/sync/outgoing_state', {
          'contract_address': feltToHex(poolContractAddress),
          'sender_address': feltToHex(address),
          'viewing_key': feltToHex(viewingKey),
          'cursor': cursor.toJson(),
          if (blockRef != null) 'block_ref': blockRef,
          if (recipients != null)
            'recipients': recipients.map(feltToHex).toList(),
        }),
      );

      channels.addAll(page.channels);
      subchannels.addAll(page.subchannels);

      blockRef ??= page.blockRef;
      cursor = page.cursor;

      if (cursor.isComplete) {
        return OutgoingSyncResult(
          blockRef: blockRef,
          channels: channels,
          subchannels: subchannels,
        );
      }
    }
  }

  /// Asks what setup a transfer to [recipient] in [token] still needs.
  ///
  /// Cheaper than a full sync, and the right call before building a transfer:
  /// the answer decides whether registration or channel-opening actions have to
  /// be bundled ahead of it.
  Future<SetupRequirement> preflight({
    required BigInt address,
    required BigInt viewingKey,
    required BigInt recipient,
    required BigInt token,
  }) async {
    return SetupRequirement.fromJson(
      await transport.post('/v1/sync/preflight_check', {
        'contract_address': feltToHex(poolContractAddress),
        'sender_address': feltToHex(address),
        'viewing_key': feltToHex(viewingKey),
        'recipient': feltToHex(recipient),
        'token': feltToHex(token),
      }),
    );
  }

  /// Service health, including how far behind the chain head it is.
  Future<DiscoveryHealth> health() async =>
      DiscoveryHealth.fromJson(await transport.get('/health'));

  void close() => transport.close();
}

/// Everything found for a recipient across a complete incoming sync.
class IncomingSyncResult {
  const IncomingSyncResult({
    required this.blockRef,
    required this.channels,
    required this.subchannels,
    required this.notes,
  });

  final Object? blockRef;
  final List<IncomingChannel> channels;
  final List<IncomingSubchannel> subchannels;
  final List<IncomingNote> notes;

  /// Total spendable value per token across every discovered note.
  Map<BigInt, BigInt> balanceByToken() {
    final totals = <BigInt, BigInt>{};
    for (final note in notes) {
      totals[note.token] = (totals[note.token] ?? BigInt.zero) + note.amount;
    }
    return totals;
  }
}

/// Everything found for a sender across a complete outgoing sync.
class OutgoingSyncResult {
  const OutgoingSyncResult({
    required this.blockRef,
    required this.channels,
    required this.subchannels,
  });

  final Object? blockRef;
  final List<OutgoingChannel> channels;
  final List<OutgoingSubchannel> subchannels;
}
