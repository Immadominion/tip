/// Isolates one question: does this node accept a signature produced by
/// starknet.dart at all?
///
/// The registration submission fails validation with "Account: invalid
/// signature", and there are two candidate causes. Either the proof fields
/// ride inside the transaction hash, so a signature computed without them is
/// over the wrong message, or the v3 hash this SDK computes does not match
/// what a spec 0.10 node expects.
///
/// This sends the same hand-assembled transaction with no proof fields at all.
/// If it validates, the proof fields are in the hash. If it does not, the hash
/// itself is wrong and the proof is a red herring.
///
///   `dart run tool/sig_probe.dart [--submit]`
library;

import 'dart:convert';
import 'dart:io';

import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/wallet/wallet.dart';

Future<Map<String, dynamic>> _rpc(Uri node, String method, Object params) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(node);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(
      {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params},
    ));
    final response = await request.close();
    return jsonDecode(await response.transform(utf8.decoder).join())
        as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

Future<void> main(List<String> args) async {
  final env = jsonDecode(File('../.strk20-env.json').readAsStringSync())
      as Map<String, dynamic>;
  final node = Uri.parse(env['rpcUrl'] as String);
  final pool = Felt.fromHexString(env['poolAddress'] as String);
  final strk = Felt.fromHexString(env['feeTokenAddress'] as String);

  final keys = WalletFactory(
    accountClassHash: TipNetwork.sepolia.accountClassHash,
  ).deriveFrom(
    (jsonDecode(File('../.dev-account.json').readAsStringSync())
        as Map<String, dynamic>)['mnemonic'] as String,
  );

  final calls = [
    FunctionCall(
      contractAddress: strk,
      entryPointSelector: getSelectorByName('approve'),
      calldata: [pool, Felt.fromInt(1), Felt.zero],
    ),
  ];

  final nonce = Felt.fromHexString(
    (await _rpc(node, 'starknet_getNonce', ['latest', keys.accountAddress.toHexString()]))['result']
        as String,
  );
  final header = (await _rpc(node, 'starknet_getBlockWithTxHashes', ['latest']))['result']
      as Map<String, dynamic>;
  Felt price(String key) => Felt.fromHexString(
        ((header[key] as Map<String, dynamic>?)?['price_in_fri'] as String?) ?? '0x1',
      );

  final bounds = <String, ResourceBounds>{
    'l1_gas': ResourceBounds(
      maxAmount: Felt.fromInt(100000),
      maxPricePerUnit: price('l1_gas_price'),
    ),
    'l1_data_gas': ResourceBounds(
      maxAmount: Felt.fromInt(100000),
      maxPricePerUnit: price('l1_data_gas_price'),
    ),
    'l2_gas': ResourceBounds(
      maxAmount: Felt.fromHexString('0x5f5e100'),
      maxPricePerUnit: price('l2_gas_price'),
    ),
  };

  final signature = await StarkAccountSigner(
    signer: StarkSigner(privateKey: keys.accountPrivateKey),
  ).signTransactions(
    transactions: calls,
    contractAddress: keys.accountAddress,
    chainId: TipNetwork.sepolia.chainId,
    nonce: nonce,
    resourceBounds: bounds,
    accountDeploymentData: const [],
    paymasterData: const [],
    tip: Felt.zero,
    feeDataAvailabilityMode: 'L1',
    nonceDataAvailabilityMode: 'L1',
  );

  final calldata =
      functionCallsToCalldata(functionCalls: calls, useLegacyCalldata: false);

  final transaction = <String, dynamic>{
    'type': 'INVOKE',
    'version': '0x3',
    'sender_address': keys.accountAddress.toHexString(),
    'calldata': calldata.map((f) => f.toHexString()).toList(),
    'signature': signature.map((f) => f.toHexString()).toList(),
    'nonce': nonce.toHexString(),
    'resource_bounds': {
      for (final e in bounds.entries)
        e.key: {
          'max_amount': e.value.maxAmount.toHexString(),
          'max_price_per_unit': e.value.maxPricePerUnit.toHexString(),
        },
    },
    'tip': '0x0',
    'paymaster_data': <String>[],
    'account_deployment_data': <String>[],
    'nonce_data_availability_mode': 'L1',
    'fee_data_availability_mode': 'L1',
  };

  stdout.writeln('node    $node');
  stdout.writeln('nonce   ${nonce.toHexString()}');

  if (!args.contains('--submit')) {
    stdout.writeln('dry run only.');
    return;
  }

  final sent = await _rpc(node, 'starknet_addInvokeTransaction', [transaction]);
  stdout.writeln(jsonEncode(sent).length > 900
      ? '${jsonEncode(sent).substring(0, 900)}...'
      : jsonEncode(sent));
}
