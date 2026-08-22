/// Creates a Sepolia development account.
///
/// Writes the seed phrase to `.dev-account.json` at the repo root, which is
/// gitignored, and prints only the public half. The private key is never echoed
/// to the terminal, so it does not end up in shell history or scrollback.
///
/// Usage, from the `app` directory:
///   dart run tool/new_dev_account.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:starknet/starknet.dart';
import 'package:tip/src/wallet/wallet.dart';

/// The account class this wallet deploys. Verified declared on Sepolia.
final _classHash = Felt.fromHexString(
  '0x061dac032f228abef9c6626f995015233097ae253a7f72d68552db02f2971b8f',
);

void main() {
  final file = File('../.dev-account.json');
  if (file.existsSync()) {
    stderr.writeln(
      'Refusing to overwrite ${file.path}. Delete it first if you really want '
      'a new account: the existing one may hold testnet funds.',
    );
    exitCode = 1;
    return;
  }

  final mnemonic = WalletFactory.generateMnemonic();
  final keys = WalletFactory(accountClassHash: _classHash).deriveFrom(mnemonic);

  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'network': 'SN_SEPOLIA',
      'mnemonic': mnemonic,
      'account_address': keys.accountAddress.toHexString(),
      'account_class_hash': _classHash.toHexString(),
      'note': 'Development account. Never use this seed on mainnet.',
    }),
  );
  // Owner read/write only.
  Process.runSync('chmod', ['600', file.path]);

  stdout
    ..writeln('Sepolia dev account created.')
    ..writeln('')
    ..writeln('  Address:    ${keys.accountAddress.toHexString()}')
    ..writeln('  Public key: ${keys.accountPublicKey.toHexString()}')
    ..writeln('  Class hash: ${_classHash.toHexString()}')
    ..writeln('')
    ..writeln('Seed phrase written to .dev-account.json (gitignored, 0600).')
    ..writeln('Fund the address above, then the account can be deployed.');
}
