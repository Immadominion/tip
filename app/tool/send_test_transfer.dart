/// Sends a real transfer on Sepolia, through the app's own transfer service.
///
/// Generates a throwaway recipient, quotes the transfer, signs it, waits for
/// it to settle, then reads the recipient's balance back. Anything less than
/// the last step proves only that a transaction was accepted, not that the
/// money arrived.
///
///   dart run tool/send_test_transfer.dart [amount]
library;

import 'dart:convert';
import 'dart:io';

import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/chain/transfer_service.dart';
import 'package:tip/src/wallet/wallet.dart';

Future<void> main(List<String> args) async {
  final file = File('../.dev-account.json');
  if (!file.existsSync()) {
    stderr.writeln('No .dev-account.json. Run tool/new_dev_account.dart first.');
    exit(1);
  }

  final network = TipNetwork.sepolia;
  final client = ChainClient(network: network);
  final service = TransferService(client: client);
  final token = network.feeToken;

  final config = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final sender = WalletFactory(accountClassHash: network.accountClassHash)
      .deriveFrom(config['mnemonic'] as String);

  // A fresh wallet, so the recipient balance starts at a known zero.
  final recipient = WalletFactory(accountClassHash: network.accountClassHash)
      .deriveFrom(WalletFactory.generateMnemonic());

  final amount = TokenAmount.parse(args.isEmpty ? '0.1' : args.first, token);

  stdout
    ..writeln('from   ${sender.accountAddress.toHexString()}')
    ..writeln('to     ${recipient.accountAddress.toHexString()}')
    ..writeln('amount ${amount.formatWithSymbol()}')
    ..writeln('');

  final before = await client.balanceOf(
    token: token,
    address: recipient.accountAddress,
  );
  stdout.writeln('recipient before: ${before.formatWithSymbol()}');

  final quote = await service.quote(
    keys: sender,
    token: token,
    recipient: recipient.accountAddress,
    amount: amount,
  );

  stdout
    ..writeln('fee estimate:     ${quote.fee?.formatWithSymbol() ?? 'unpriced'}')
    ..writeln('fee ceiling:      ${quote.maxFee?.formatWithSymbol() ?? 'unpriced'}');
  if (quote.needsDeployment) {
    stderr.writeln('Sender account is not deployed.');
    exit(1);
  }
  if (!quote.canSend) {
    stderr.writeln('Blocked: ${quote.blockers.join('; ')}');
    exit(1);
  }

  final hash = await service.send(keys: sender, quote: quote);
  stdout
    ..writeln('tx:               ${hash.toHexString()}')
    ..writeln('                  ${network.transactionUrl(hash)}')
    ..writeln('waiting...');

  final result = await client.awaitTransaction(hash);
  stdout.writeln('outcome:          ${result.outcome.name}'
      '${result.failureReason == null ? '' : ' (${result.failureReason})'}');

  final after = await client.balanceOf(
    token: token,
    address: recipient.accountAddress,
  );
  stdout.writeln('recipient after:  ${after.formatWithSymbol()}');

  final moved = TokenAmount(after.raw - before.raw, token);
  final ok = moved == amount;
  stdout.writeln(ok
      ? '\nArrived: ${moved.formatWithSymbol()}'
      : '\nMISMATCH: expected ${amount.formatWithSymbol()}, saw ${moved.formatWithSymbol()}');
  exit(ok ? 0 : 1);
}
