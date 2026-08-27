/// Runs a real discovery sync over Oblivious HTTP.
///
/// Every live call this project has made so far went over the plain transport,
/// which means the viewing key was readable by whoever terminates TLS. That is
/// the single largest gap between what the architecture claims and what has
/// actually been running.
///
/// This proves the encrypted path works against the live service, and prints
/// the key configuration so it can be pinned. Pinning matters: without it the
/// config is fetched over the same TLS the encryption is meant to be
/// independent of, and anything terminating that TLS can substitute its own
/// key and read everything after it.
///
///   `dart run tool/ohttp_probe.dart ADDRESS VIEWING_KEY`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tip_privacy/tip_privacy.dart';

Map<String, dynamic> _env() {
  for (final path in ['../../.strk20-env.json', '../.strk20-env.json', '.strk20-env.json']) {
    final file = File(path);
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  stderr.writeln('No .strk20-env.json found.');
  exit(1);
}

BigInt _felt(String hex) => BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/ohttp_probe.dart ADDRESS VIEWING_KEY');
    exit(64);
  }

  final env = _env();
  final gateway = Uri.parse(env['discoveryUrl'] as String);

  // Fetch the config first, so it can be shown and pinned.
  final keysResponse = await http.get(gateway.replace(path: '/ohttp-keys'));
  if (keysResponse.statusCode != 200) {
    stderr.writeln('No ohttp-keys: HTTP ${keysResponse.statusCode}');
    exit(1);
  }
  final raw = Uint8List.fromList(keysResponse.bodyBytes);
  final configs = OhttpKeyConfig.parseList(raw);

  stdout.writeln('ohttp-keys  ${raw.length} bytes, ${configs.length} config(s)');
  for (final config in configs) {
    stdout
      ..writeln('  key id    ${config.keyId}')
      ..writeln('  kem       0x${config.kemId.toRadixString(16).padLeft(4, "0")}')
      ..writeln('  kdf/aead  '
          '${config.symmetricAlgorithms.map((a) => "0x${a.kdfId.toRadixString(16)}/0x${a.aeadId.toRadixString(16)}").join(", ")}');
  }
  stdout.writeln('  pin       ${base64.encode(raw)}');
  stdout.writeln('');

  // Now the round trip, with the config pinned so this exercises the mode a
  // real wallet should use.
  final transport = OhttpTransport(
    gatewayUrl: gateway,
    pinnedKeyConfig: raw,
  );
  final client = DiscoveryClient(
    transport: transport,
    poolContractAddress: _felt(env['poolAddress'] as String),
  );

  try {
    final health = await client.health();
    stdout.writeln('health over ohttp: ${health.status}, lag ${health.lagSeconds}s');

    final incoming = await client.syncIncoming(
      address: _felt(args[0]),
      viewingKey: _felt(args[1]),
    );

    var total = BigInt.zero;
    for (final note in incoming.notes) {
      total += note.amount;
    }

    stdout
      ..writeln('')
      ..writeln('sync over ohttp')
      ..writeln('  channels  ${incoming.channels.length}')
      ..writeln('  notes     ${incoming.notes.length}')
      ..writeln('  total     ${total / BigInt.from(10).pow(18)}');
  } finally {
    client.close();
  }
}
