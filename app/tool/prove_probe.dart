/// Asks the live proving service to prove a batch of pool actions.
///
/// Proving changes nothing on chain. The prover executes the pool's own
/// `compile_actions` and returns a proof that it ran as claimed; state moves
/// only later, when `apply_actions` is submitted with that proof. So this is
/// safe to run against the real service as often as you like, which makes it
/// the right way to find out what the service actually wants.
///
/// The transaction being proved has an unusual shape. Its sender is the pool,
/// not the user, and the pool's `__execute__` checks that the signature
/// belongs to the `user_addr` carried in the calldata. So the user's account
/// key signs a transaction sent by somebody else.
///
/// Endpoints come from the gitignored `.strk20-env.json`.
///
///   `dart run tool/prove_probe.dart`
library;

import 'dart:convert';
import 'dart:io';

import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

Map<String, dynamic> _env() {
  for (final path in ['../.strk20-env.json', '.strk20-env.json']) {
    final file = File(path);
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  stderr.writeln('No .strk20-env.json found.');
  exit(1);
}

BigInt _felt(String hex) => BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);

/// The bounds have to be identical on both sides. The signature commits to
/// them, so a mismatch between what is signed and what is sent is a signature
/// over a different transaction.
final _l2GasLimit = Felt.fromHexString(tp.provingL2GasLimit);

Map<String, ResourceBounds> _sdkBounds() => {
      'l1_gas': ResourceBounds(maxAmount: Felt.zero, maxPricePerUnit: Felt.zero),
      'l1_data_gas':
          ResourceBounds(maxAmount: Felt.zero, maxPricePerUnit: Felt.zero),
      'l2_gas':
          ResourceBounds(maxAmount: _l2GasLimit, maxPricePerUnit: Felt.zero),
    };

Future<void> main(List<String> args) async {
  final env = _env();

  final devFile = File('../.dev-account.json');
  if (!devFile.existsSync()) {
    stderr.writeln('No .dev-account.json. Run tool/new_dev_account.dart first.');
    exit(1);
  }
  final dev = jsonDecode(devFile.readAsStringSync()) as Map<String, dynamic>;
  final keys = WalletFactory(
    accountClassHash: TipNetwork.sepolia.accountClassHash,
  ).deriveFrom(dev['mnemonic'] as String);

  final pool = _felt(env['poolAddress'] as String);
  final userAddress = keys.accountAddress.toBigInt();

  // The viewing key is what the contract calls `user_private_key`: the private
  // key whose public key the pool stores against the address.
  final viewingKey = keys.viewingKey;

  final actions = tp.buildRegister(random: _Fixed());

  final inner = tp.compileActionsCalldata(
    userAddress: userAddress,
    viewingKey: viewingKey,
    actions: actions,
  );

  final call = FunctionCall(
    contractAddress: Felt(pool),
    entryPointSelector: getSelectorByName('compile_actions'),
    calldata: inner.map(Felt.new).toList(),
  );

  // Signed by the user's account key, over a transaction whose sender is the
  // pool. That is what the pool checks.
  final signature = await StarkAccountSigner(
    signer: StarkSigner(privateKey: keys.accountPrivateKey),
  ).signTransactions(
    transactions: [call],
    contractAddress: Felt(pool),
    chainId: TipNetwork.sepolia.chainId,
    nonce: Felt(tp.proofInvocationNonce),
    resourceBounds: _sdkBounds(),
    accountDeploymentData: const [],
    paymasterData: const [],
    tip: Felt.zero,
    feeDataAvailabilityMode: 'L1',
    nonceDataAvailabilityMode: 'L1',
  );

  final invocation = tp.buildProofInvocation(
    poolAddress: pool,
    userAddress: userAddress,
    viewingKey: viewingKey,
    actions: actions,
    compileActionsSelector: getSelectorByName('compile_actions').toBigInt(),
    signature: signature.map((f) => f.toBigInt()).toList(),
  );

  stdout
    ..writeln('pool      ${env['poolAddress']}')
    ..writeln('user      ${keys.accountAddress.toHexString()}')
    ..writeln('actions   ${actions.length} (${actions.first.kind.name})')
    ..writeln('signature ${signature.length} felts')
    ..writeln('');

  final transport = tp.PlainJsonTransport(
    baseUrl: Uri.parse(env['provingUrl'] as String),
  );
  final client = tp.ProvingClient(transport: transport);

  try {
    stdout.writeln('prover spec ${await client.specVersion()}');

    final result = await client.proveTransaction(
      blockId: 'latest',
      transaction: invocation.toJson(),
    );
    stdout
      ..writeln('')
      ..writeln('proved.')
      ..writeln('  proof        ${result.proof.length} base64 chars')
      ..writeln('  proof facts  ${result.proofFacts.length}')
      ..writeln('  screening    '
          '${result.screeningSignature == null ? "none" : "signed"}');
    for (final fact in result.proofFacts.take(4)) {
      stdout.writeln('    $fact');
    }
  } on tp.ProvingException catch (error) {
    stdout
      ..writeln('')
      ..writeln('prover said no: ${error.code} ${error.message}')
      ..writeln(error.data ?? '(no detail)');
  } finally {
    client.close();
  }
}

class _Fixed implements tp.RandomSource {
  @override
  BigInt nextFelt() => BigInt.parse('1234567890abcdef', radix: 16);

  @override
  BigInt nextNoteSalt() => BigInt.from(0x424242);
}
