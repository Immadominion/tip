/// One thing the wallet did.
///
/// Starknet's RPC has no way to ask "what transactions involved this address",
/// so a wallet either pays an indexer or remembers its own. This remembers its
/// own. That means the list is honest about its limits: it holds what this
/// wallet did, not everything that ever touched the address.
///
/// The token's symbol and decimals are copied into the entry rather than
/// looked up later. A registry can change, and an old entry reformatted
/// against new decimals would silently display the wrong amount.
library;

import 'dart:convert';

import '../chain/amount.dart';
import '../chain/token.dart';

enum ActivityKind { send, deploy }

enum ActivityStatus { pending, succeeded, reverted, unknown }

class ActivityEntry {
  const ActivityEntry({
    required this.txHash,
    required this.kind,
    required this.submittedAt,
    required this.status,
    this.tokenSymbol,
    this.tokenDecimals,
    this.rawAmount,
    this.counterparty,
    this.failureReason,
  });

  factory ActivityEntry.send({
    required String txHash,
    required TokenAmount amount,
    required String counterparty,
    required DateTime submittedAt,
  }) =>
      ActivityEntry(
        txHash: txHash,
        kind: ActivityKind.send,
        submittedAt: submittedAt,
        status: ActivityStatus.pending,
        tokenSymbol: amount.token.symbol,
        tokenDecimals: amount.token.decimals,
        rawAmount: amount.raw.toString(),
        counterparty: counterparty,
      );

  factory ActivityEntry.deploy({
    required String txHash,
    required DateTime submittedAt,
  }) =>
      ActivityEntry(
        txHash: txHash,
        kind: ActivityKind.deploy,
        submittedAt: submittedAt,
        status: ActivityStatus.pending,
      );

  final String txHash;
  final ActivityKind kind;
  final DateTime submittedAt;
  final ActivityStatus status;

  final String? tokenSymbol;
  final int? tokenDecimals;

  /// The amount in smallest units, as a string. A decimal amount cannot round
  /// trip through a double, and JSON has nothing else to offer.
  final String? rawAmount;

  final String? counterparty;
  final String? failureReason;

  bool get isPending =>
      status == ActivityStatus.pending || status == ActivityStatus.unknown;

  /// The amount, formatted. Null for entries that do not move a token.
  String? get amountLabel {
    final raw = rawAmount;
    final symbol = tokenSymbol;
    final decimals = tokenDecimals;
    if (raw == null || symbol == null || decimals == null) return null;

    final token = TipToken(
      // The address is not stored and is not needed to format. A placeholder
      // keeps TokenAmount's own token equality out of the way.
      address: placeholderTokenAddress,
      symbol: symbol,
      name: symbol,
      decimals: decimals,
    );
    return TokenAmount(BigInt.parse(raw), token).formatWithSymbol();
  }

  ActivityEntry copyWith({
    ActivityStatus? status,
    String? failureReason,
  }) =>
      ActivityEntry(
        txHash: txHash,
        kind: kind,
        submittedAt: submittedAt,
        status: status ?? this.status,
        tokenSymbol: tokenSymbol,
        tokenDecimals: tokenDecimals,
        rawAmount: rawAmount,
        counterparty: counterparty,
        failureReason: failureReason ?? this.failureReason,
      );

  Map<String, Object?> toJson() => {
        'tx': txHash,
        'kind': kind.name,
        'at': submittedAt.toUtc().toIso8601String(),
        'status': status.name,
        if (tokenSymbol != null) 'symbol': tokenSymbol,
        if (tokenDecimals != null) 'decimals': tokenDecimals,
        if (rawAmount != null) 'amount': rawAmount,
        if (counterparty != null) 'to': counterparty,
        if (failureReason != null) 'reason': failureReason,
      };

  /// Reads an entry back, or null if it is not one.
  ///
  /// Null rather than throwing: one corrupt entry should cost the user that
  /// entry, not their whole history.
  static ActivityEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final tx = json['tx'];
    final at = json['at'];
    if (tx is! String || at is! String) return null;

    final submittedAt = DateTime.tryParse(at);
    if (submittedAt == null) return null;

    return ActivityEntry(
      txHash: tx,
      kind: _enumByName(ActivityKind.values, json['kind']) ?? ActivityKind.send,
      submittedAt: submittedAt.toLocal(),
      status: _enumByName(ActivityStatus.values, json['status']) ??
          ActivityStatus.unknown,
      tokenSymbol: json['symbol'] as String?,
      tokenDecimals: json['decimals'] as int?,
      rawAmount: json['amount'] as String?,
      counterparty: json['to'] as String?,
      failureReason: json['reason'] as String?,
    );
  }

  static String encodeAll(List<ActivityEntry> entries) =>
      jsonEncode([for (final entry in entries) entry.toJson()]);

  static List<ActivityEntry> decodeAll(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (ActivityEntry.fromJson(item) case final entry?) entry,
      ];
    } on FormatException {
      return const [];
    }
  }
}

T? _enumByName<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}
