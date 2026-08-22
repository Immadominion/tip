/// Wire types for the STRK20 discovery service API.
///
/// These mirror the JSON contract served by `crates/discovery-service` in
/// starkware-libs/starknet-privacy. Field names are kept in the service's
/// snake_case on the wire and converted at the boundary.
library;

import '../errors.dart';

BigInt _felt(String hex) {
  final cleaned = hex.startsWith('0x') ? hex.substring(2) : hex;
  final parsed = BigInt.tryParse(cleaned, radix: 16);
  if (parsed == null) {
    throw ProtocolException('Expected a hex felt, got "$hex"');
  }
  return parsed;
}

String feltToHex(BigInt value) => '0x${value.toRadixString(16)}';

T _require<T>(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! T) {
    throw ProtocolException(
      'Expected "$key" to be $T in discovery response, got ${value.runtimeType}',
    );
  }
  return value;
}

/// Pagination state for the notes within one subchannel.
class SubchannelCursor {
  const SubchannelCursor({
    this.noteDiscoveryComplete,
    this.lastNoteIndex,
    this.totalNotes,
  });

  factory SubchannelCursor.fromJson(Map<String, dynamic> json) =>
      SubchannelCursor(
        noteDiscoveryComplete: json['note_discovery_complete'] as bool?,
        lastNoteIndex: json['last_note_index'] as int?,
        totalNotes: json['total_n_notes'] as int?,
      );

  final bool? noteDiscoveryComplete;
  final int? lastNoteIndex;
  final int? totalNotes;

  Map<String, dynamic> toJson() => {
        if (noteDiscoveryComplete != null)
          'note_discovery_complete': noteDiscoveryComplete,
        if (lastNoteIndex != null) 'last_note_index': lastNoteIndex,
        if (totalNotes != null) 'total_n_notes': totalNotes,
      };
}

/// Pagination state for the subchannels within one channel.
class ChannelCursor {
  const ChannelCursor({
    this.channelKey,
    this.subchannelDiscoveryComplete,
    this.lastSubchannelIndex,
    this.subchannels = const {},
  });

  factory ChannelCursor.fromJson(Map<String, dynamic> json) {
    final raw = json['subchannels'] as Map<String, dynamic>? ?? const {};
    return ChannelCursor(
      channelKey: json['channel_key'] as String?,
      subchannelDiscoveryComplete:
          json['subchannel_discovery_complete'] as bool?,
      lastSubchannelIndex: json['last_subchannel_index'] as int?,
      subchannels: raw.map(
        (key, value) => MapEntry(
          key,
          SubchannelCursor.fromJson(value as Map<String, dynamic>),
        ),
      ),
    );
  }

  final String? channelKey;
  final bool? subchannelDiscoveryComplete;
  final int? lastSubchannelIndex;
  final Map<String, SubchannelCursor> subchannels;

  Map<String, dynamic> toJson() => {
        if (channelKey != null) 'channel_key': channelKey,
        if (subchannelDiscoveryComplete != null)
          'subchannel_discovery_complete': subchannelDiscoveryComplete,
        if (lastSubchannelIndex != null)
          'last_subchannel_index': lastSubchannelIndex,
        if (subchannels.isNotEmpty)
          'subchannels':
              subchannels.map((key, value) => MapEntry(key, value.toJson())),
      };
}

/// Top-level pagination state for a sync request.
///
/// The service caps how much on-chain state it will traverse per request, so a
/// full sync is a loop: pass the cursor back until [isComplete].
class DiscoveryCursor {
  const DiscoveryCursor({
    this.channelDiscoveryComplete,
    this.totalChannels,
    this.lastChannelIndex,
    this.channels = const {},
  });

  /// An empty cursor, for the first request of a sync.
  factory DiscoveryCursor.initial() => const DiscoveryCursor();

  factory DiscoveryCursor.fromJson(Map<String, dynamic> json) {
    final raw = json['channels'] as Map<String, dynamic>? ?? const {};
    return DiscoveryCursor(
      channelDiscoveryComplete: json['channel_discovery_complete'] as bool?,
      totalChannels: json['total_n_channels'] as int?,
      lastChannelIndex: json['last_channel_index'] as int?,
      channels: raw.map(
        (key, value) => MapEntry(
          key,
          ChannelCursor.fromJson(value as Map<String, dynamic>),
        ),
      ),
    );
  }

  final bool? channelDiscoveryComplete;
  final int? totalChannels;
  final int? lastChannelIndex;
  final Map<String, ChannelCursor> channels;

  /// Whether every channel, subchannel, and note has been walked.
  ///
  /// Discovery is only finished when channel discovery is complete *and* every
  /// channel's subchannel discovery is complete *and* every subchannel's note
  /// discovery is complete. Stopping at the top-level flag alone would silently
  /// truncate a sync and lose notes.
  bool get isComplete {
    if (channelDiscoveryComplete != true) return false;
    for (final channel in channels.values) {
      if (channel.subchannelDiscoveryComplete != true) return false;
      for (final subchannel in channel.subchannels.values) {
        if (subchannel.noteDiscoveryComplete != true) return false;
      }
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        if (channelDiscoveryComplete != null)
          'channel_discovery_complete': channelDiscoveryComplete,
        if (totalChannels != null) 'total_n_channels': totalChannels,
        if (lastChannelIndex != null) 'last_channel_index': lastChannelIndex,
        if (channels.isNotEmpty)
          'channels':
              channels.map((key, value) => MapEntry(key, value.toJson())),
      };
}

/// A channel someone opened to pay us.
class IncomingChannel {
  const IncomingChannel({required this.channelKey, required this.senderAddr});

  factory IncomingChannel.fromJson(Map<String, dynamic> json) =>
      IncomingChannel(
        channelKey: _felt(_require<String>(json, 'channel_key')),
        senderAddr: _felt(_require<String>(json, 'sender_addr')),
      );

  final BigInt channelKey;
  final BigInt senderAddr;
}

/// A per-token subchannel inside an incoming channel.
class IncomingSubchannel {
  const IncomingSubchannel({required this.senderAddr, required this.token});

  factory IncomingSubchannel.fromJson(Map<String, dynamic> json) =>
      IncomingSubchannel(
        senderAddr: _felt(_require<String>(json, 'sender_addr')),
        token: _felt(_require<String>(json, 'token')),
      );

  final BigInt senderAddr;
  final BigInt token;
}

/// A note payable to us, already decrypted by the discovery service using the
/// viewing key we supplied.
class IncomingNote {
  const IncomingNote({
    required this.senderAddr,
    required this.token,
    required this.index,
    required this.noteId,
    required this.amount,
    required this.salt,
    required this.blockNumber,
  });

  factory IncomingNote.fromJson(Map<String, dynamic> json) => IncomingNote(
        senderAddr: _felt(_require<String>(json, 'sender_addr')),
        token: _felt(_require<String>(json, 'token')),
        index: _require<int>(json, 'index'),
        noteId: _felt(_require<String>(json, 'note_id')),
        amount: _felt(_require<String>(json, 'amount')),
        salt: _felt(_require<String>(json, 'salt')),
        blockNumber: _require<int>(json, 'block_number'),
      );

  final BigInt senderAddr;
  final BigInt token;
  final int index;
  final BigInt noteId;
  final BigInt amount;
  final BigInt salt;
  final int blockNumber;
}

/// A channel we opened to pay someone.
class OutgoingChannel {
  const OutgoingChannel({
    required this.recipientAddr,
    required this.recipientPublicKey,
    required this.channelKey,
    this.precomputed,
  });

  factory OutgoingChannel.fromJson(Map<String, dynamic> json) =>
      OutgoingChannel(
        recipientAddr: _felt(_require<String>(json, 'recipient_addr')),
        recipientPublicKey:
            _felt(_require<String>(json, 'recipient_public_key')),
        channelKey: _felt(_require<String>(json, 'channel_key')),
        precomputed: json['precomputed'] as bool?,
      );

  final BigInt recipientAddr;
  final BigInt recipientPublicKey;
  final BigInt channelKey;
  final bool? precomputed;
}

/// A per-token subchannel inside an outgoing channel.
class OutgoingSubchannel {
  const OutgoingSubchannel({
    required this.recipientAddr,
    required this.token,
    this.lastNoteIndex,
  });

  factory OutgoingSubchannel.fromJson(Map<String, dynamic> json) =>
      OutgoingSubchannel(
        recipientAddr: _felt(_require<String>(json, 'recipient_addr')),
        token: _felt(_require<String>(json, 'token')),
        lastNoteIndex: json['last_note_index'] as int?,
      );

  final BigInt recipientAddr;
  final BigInt token;
  final int? lastNoteIndex;
}

/// One page of incoming discovery results.
class IncomingSyncPage {
  const IncomingSyncPage({
    required this.blockRef,
    required this.channels,
    required this.subchannels,
    required this.notes,
    required this.cursor,
  });

  factory IncomingSyncPage.fromJson(Map<String, dynamic> json) =>
      IncomingSyncPage(
        blockRef: json['block_ref'],
        channels: (json['channels'] as List<dynamic>? ?? const [])
            .map((e) => IncomingChannel.fromJson(e as Map<String, dynamic>))
            .toList(),
        subchannels: (json['subchannels'] as List<dynamic>? ?? const [])
            .map((e) => IncomingSubchannel.fromJson(e as Map<String, dynamic>))
            .toList(),
        notes: (json['notes'] as List<dynamic>? ?? const [])
            .map((e) => IncomingNote.fromJson(e as Map<String, dynamic>))
            .toList(),
        cursor: DiscoveryCursor.fromJson(
          json['cursor'] as Map<String, dynamic>? ?? const {},
        ),
      );

  /// The block the service read state at. Pin subsequent pages to it so a sync
  /// sees a consistent snapshot.
  final Object? blockRef;
  final List<IncomingChannel> channels;
  final List<IncomingSubchannel> subchannels;
  final List<IncomingNote> notes;
  final DiscoveryCursor cursor;
}

/// One page of outgoing discovery results.
class OutgoingSyncPage {
  const OutgoingSyncPage({
    required this.blockRef,
    required this.channels,
    required this.subchannels,
    required this.cursor,
  });

  factory OutgoingSyncPage.fromJson(Map<String, dynamic> json) =>
      OutgoingSyncPage(
        blockRef: json['block_ref'],
        channels: (json['channels'] as List<dynamic>? ?? const [])
            .map((e) => OutgoingChannel.fromJson(e as Map<String, dynamic>))
            .toList(),
        subchannels: (json['subchannels'] as List<dynamic>? ?? const [])
            .map((e) => OutgoingSubchannel.fromJson(e as Map<String, dynamic>))
            .toList(),
        cursor: DiscoveryCursor.fromJson(
          json['cursor'] as Map<String, dynamic>? ?? const {},
        ),
      );

  final Object? blockRef;
  final List<OutgoingChannel> channels;
  final List<OutgoingSubchannel> subchannels;
  final DiscoveryCursor cursor;
}

/// What still needs setting up before a private transfer can go through.
class SetupRequirement {
  const SetupRequirement({
    required this.blockRef,
    required this.senderRegistered,
    required this.channelExists,
    required this.subchannelExists,
  });

  factory SetupRequirement.fromJson(Map<String, dynamic> json) =>
      SetupRequirement(
        blockRef: json['block_ref'],
        senderRegistered: _require<bool>(json, 'sender_registered'),
        channelExists: _require<bool>(json, 'channel_exists'),
        subchannelExists: _require<bool>(json, 'subchannel_exists'),
      );

  final Object? blockRef;
  final bool senderRegistered;
  final bool channelExists;
  final bool subchannelExists;

  /// Whether everything is already in place and a transfer needs no setup
  /// actions bundled ahead of it.
  bool get isReady => senderRegistered && channelExists && subchannelExists;
}

/// Health of the discovery service and how far its view lags the chain head.
class DiscoveryHealth {
  const DiscoveryHealth({required this.status, this.lagSeconds});

  factory DiscoveryHealth.fromJson(Map<String, dynamic> json) =>
      DiscoveryHealth(
        status: _require<String>(json, 'status'),
        lagSeconds: (json['lag_secs'] as num?)?.toInt(),
      );

  final String status;
  final int? lagSeconds;
}
