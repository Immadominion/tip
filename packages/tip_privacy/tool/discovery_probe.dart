/// Runs the discovery client against the live StarkWare testnet service.
///
/// Unit tests prove the client parses what I told it to expect. This proves it
/// parses what the service actually sends, which is the only version that
/// counts.
///
/// Reads its endpoints from `.strk20-env.json` at the repo root. That file is
/// gitignored on purpose: the environment was shared in confidence and the
/// URLs in it are not ours to publish.
///
///   `dart run tool/discovery_probe.dart ADDRESS VIEWING_KEY`
library;

import 'dart:convert';
import 'dart:io';

import 'package:tip_privacy/tip_privacy.dart';

Map<String, dynamic> _env() {
  for (final path in ['../../.strk20-env.json', '../.strk20-env.json', '.strk20-env.json']) {
    final file = File(path);
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  stderr.writeln('No .strk20-env.json found. It holds the testnet endpoints.');
  exit(1);
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/discovery_probe.dart <address> <viewing-key>');
    exit(64);
  }

  final env = _env();
  final transport = PlainJsonTransport(
    baseUrl: Uri.parse(env['discoveryUrl'] as String),
  );
  final pool = BigInt.parse(
    (env['poolAddress'] as String).replaceFirst('0x', ''),
    radix: 16,
  );
  final client = DiscoveryClient(
    transport: transport,
    poolContractAddress: pool,
  );

  try {
    final health = await client.health();
    stdout.writeln('health   ${health.status}, lag ${health.lagSeconds}s');

    final address = BigInt.parse(args[0].replaceFirst('0x', ''), radix: 16);
    final viewingKey = BigInt.parse(args[1].replaceFirst('0x', ''), radix: 16);

    final incoming = await client.syncIncoming(
      address: address,
      viewingKey: viewingKey,
    );

    stdout
      ..writeln('')
      ..writeln('incoming at block ${incoming.blockRef}')
      ..writeln('  channels     ${incoming.channels.length}')
      ..writeln('  subchannels  ${incoming.subchannels.length}')
      ..writeln('  notes        ${incoming.notes.length}');

    // What a wallet actually wants: the balance, per token, from live notes.
    // The service decrypts amounts because it was given the viewing key, which
    // is exactly what the OHTTP layer exists to stop it seeing.
    final byToken = <BigInt, BigInt>{};
    final countByToken = <BigInt, int>{};
    for (final note in incoming.notes) {
      byToken[note.token] = (byToken[note.token] ?? BigInt.zero) + note.amount;
      countByToken[note.token] = (countByToken[note.token] ?? 0) + 1;
    }

    stdout.writeln('');
    stdout.writeln('shielded balance, before spending is accounted for');
    for (final entry in byToken.entries) {
      final whole = entry.value / BigInt.from(10).pow(18);
      stdout.writeln(
        '  0x${entry.key.toRadixString(16).substring(0, 8)}...  '
        '${whole.toStringAsFixed(6)}  '
        'across ${countByToken[entry.key]} notes',
      );
    }

    final newest = incoming.notes.map((n) => n.blockNumber).fold(0, (a, b) => a > b ? a : b);
    stdout.writeln('  newest note at block $newest');

    final outgoing = await client.syncOutgoing(
      address: address,
      viewingKey: viewingKey,
    );
    stdout
      ..writeln('')
      ..writeln('outgoing at block ${outgoing.blockRef}')
      ..writeln('  channels     ${outgoing.channels.length}');
  } finally {
    client.close();
  }
}
