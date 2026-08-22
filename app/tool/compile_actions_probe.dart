/// Calls `compile_actions` on the live Sepolia pool with actions encoded by
/// this project's own Cairo Serde implementation.
///
/// This is the check that unit tests cannot make. The encoding was written by
/// reading `actions.cairo`, and it is tested against my own reading of it. Only
/// the contract can say whether that reading was right: if the calldata is
/// wrong the call reverts, and if it is right the pool hands back the server
/// actions it would execute.
library;

import 'dart:convert';
import 'dart:io';

import 'package:starknet/starknet.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip_privacy/tip_privacy.dart';

const _rpc = 'https://api.cartridge.gg/x/starknet/sepolia';
const _pool =
    '0x0254a6b2997ef52e9f830ce1f543f6b29768295e8d17e2267d672c552cfe0d91';

Future<Map<String, dynamic>> _rpcCall(String method, Object params) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(_rpc));
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': params,
      }),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

Future<List<String>?> _call(String entryPoint, List<String> calldata) async {
  final result = await _rpcCall('starknet_call', {
    'request': {
      'contract_address': _pool,
      'entry_point_selector': getSelectorByName(entryPoint).toHexString(),
      'calldata': calldata,
    },
    'block_id': 'latest',
  });
  if (result.containsKey('error')) {
    final error = result['error'] as Map<String, dynamic>;
    stdout.writeln('  reverted: ${error['message']}');
    final data = error['data'];
    if (data != null) stdout.writeln('  data: $data');
    return null;
  }
  return (result['result'] as List).cast<String>();
}

Future<void> main() async {
  final config =
      jsonDecode(File('../.dev-account.json').readAsStringSync()) as Map;
  final keys = WalletFactory(
    accountClassHash: Felt.fromHexString(
      config['account_class_hash'] as String,
    ),
  ).deriveFrom(config['mnemonic'] as String);

  stdout.writeln('Pool:    $_pool');
  stdout.writeln('Account: ${keys.accountAddress.toHexString()}');

  stdout.writeln('\n--- pool state ---');
  for (final view in [
    'get_version',
    'get_fee_amount',
    'get_auditor_public_key',
  ]) {
    final out = await _call(view, const []);
    if (out != null) stdout.writeln('  $view: ${out.join(', ')}');
  }

  // Has this account already registered a viewing key?
  final registered = await _call('get_public_key', [
    keys.accountAddress.toHexString(),
  ]);
  final isRegistered =
      registered != null &&
      registered.isNotEmpty &&
      BigInt.parse(registered.first.replaceFirst('0x', ''), radix: 16) !=
          BigInt.zero;
  stdout.writeln('  registered: $isRegistered');

  // The real test: encode SetViewingKey with our own Serde and let the
  // contract judge it.
  stdout.writeln('\n--- compile_actions(SetViewingKey) ---');
  final actions = <ClientAction>[SetViewingKey(random: BigInt.from(0xabc123))];
  final encoded = encodeActions(actions);
  stdout.writeln(
    '  our calldata for the actions span: '
    '${encoded.map((f) => '0x${f.toRadixString(16)}').join(' ')}',
  );

  final out = await _call('compile_actions', [
    keys.accountAddress.toHexString(),
    '0x${keys.viewingKey.toRadixString(16)}',
    ...encoded.map((f) => '0x${f.toRadixString(16)}'),
  ]);

  if (out != null) {
    stdout
      ..writeln('  ACCEPTED. ${out.length} felts of server actions returned:')
      ..writeln('  ${out.join(' ')}');
  }
}
