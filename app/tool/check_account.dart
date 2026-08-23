/// Reads an account through the app's own chain client.
///
/// Unit tests can only check that this layer parses what I told it to expect.
/// This checks it against what the chain actually sends back.
///
///   dart run tool/check_account.dart <address> [mainnet|sepolia]
library;

import 'dart:io';

import 'package:starknet/starknet.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/network.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/check_account.dart <address> [mainnet|sepolia]');
    exit(64);
  }

  final address = Felt.fromHexString(args.first);
  final network = args.length > 1 && args[1] == 'mainnet'
      ? TipNetwork.mainnet
      : TipNetwork.sepolia;
  final client = ChainClient(network: network);

  stdout.writeln('${network.label}  ${address.toHexString()}');

  stdout.writeln('  chain id matches: ${await client.chainIdMatches()}');

  final deployed = await client.isDeployed(address);
  stdout.writeln('  deployed:         $deployed');
  stdout.writeln('  nonce:            ${(await client.nonceOf(address)).toBigInt()}');

  final snapshot = await client.balances(address);
  for (final amount in snapshot.amounts) {
    final failure = snapshot.failures[amount.token];
    stdout.writeln(
      '  ${amount.token.symbol.padRight(6)} ${failure == null ? amount.format() : 'unreadable: $failure'}',
    );
  }

  stdout.writeln('  ${network.addressUrl(address)}');
}
