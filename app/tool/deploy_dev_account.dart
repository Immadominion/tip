/// Deploys the Sepolia development account created by `new_dev_account.dart`.
///
/// The account pays its own deployment fee, so the address must already hold
/// STRK. Reads the seed from the gitignored `.dev-account.json` and never
/// prints it.
///
/// Usage, from the `app` directory:
///   dart run tool/deploy_dev_account.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart';
import 'package:tip/src/wallet/wallet.dart';

const _rpc = 'https://api.cartridge.gg/x/starknet/sepolia';

Future<void> main() async {
  final file = File('../.dev-account.json');
  if (!file.existsSync()) {
    stderr.writeln(
      'No .dev-account.json. Run tool/new_dev_account.dart first.',
    );
    exitCode = 1;
    return;
  }

  final config = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final classHash = Felt.fromHexString(config['account_class_hash'] as String);
  final keys = WalletFactory(
    accountClassHash: classHash,
  ).deriveFrom(config['mnemonic'] as String);

  final address = keys.accountAddress;
  stdout.writeln('Account: ${address.toHexString()}');

  final provider = JsonRpcProvider(nodeUri: Uri.parse(_rpc));

  // Deploying twice would fail anyway, but checking first gives a clear
  // message instead of a decoded revert.
  final existing = await provider.getClassHashAt(
    contractAddress: address,
    blockId: BlockId.latest,
  );
  final alreadyDeployed = existing.when(
    result: (_) => true,
    error: (_) => false,
  );
  if (alreadyDeployed) {
    stdout.writeln('Already deployed. Nothing to do.');
    return;
  }

  stdout.writeln('Deploying...');

  // The constructor takes the public key, and the salt is the public key too,
  // which is what makes the address derivable before deployment.
  final response = await Account.deployAccount(
    accountSigner: StarkAccountSigner(
      signer: StarkSigner(privateKey: keys.accountPrivateKey),
    ),
    provider: provider,
    constructorCalldata: [keys.accountPublicKey],
    classHash: classHash,
    contractAddressSalt: keys.accountPublicKey,
    // The address must be passed explicitly. Leaving every resource bound at
    // its default makes the SDK estimate the fee itself, and that estimate
    // runs against this address; without it the estimate is made for address
    // zero and validation fails.
    contractAddress: address,
  );

  response.when(
    result: (result) {
      // Felt.toString() renders decimal. Explorers and every other Starknet
      // tool expect hex, so ask for it explicitly rather than printing a link
      // that silently 404s.
      final tx = result.transactionHash.toHexString();
      final deployed = result.contractAddress.toHexString();
      stdout
        ..writeln('')
        ..writeln('Submitted.')
        ..writeln('  tx:      $tx')
        ..writeln('  address: $deployed')
        ..writeln('')
        ..writeln('https://sepolia.voyager.online/tx/$tx');
    },
    error: (error) {
      stderr.writeln('Deploy failed: ${error.code} ${error.message}');
      exitCode = 1;
    },
  );
}
