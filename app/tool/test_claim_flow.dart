/// Runs a whole tip end to end on Sepolia: create a link, then claim it.
///
/// The part worth proving is the fee arithmetic in the middle. A throwaway
/// account has to deploy itself and empty itself out of the tip, and if that
/// budget is wrong the link is issued and cannot be redeemed.
///
///   dart run tool/test_claim_flow.dart [amount the recipient should get]
library;

import 'dart:convert';
import 'dart:io';

import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/chain_client.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/claim/claim_link.dart';
import 'package:tip/src/claim/claim_service.dart';
import 'package:tip/src/wallet/wallet.dart';

Future<void> main(List<String> args) async {
  final file = File('../.dev-account.json');
  if (!file.existsSync()) {
    stderr.writeln('No .dev-account.json. Run tool/new_dev_account.dart first.');
    exit(1);
  }

  final network = TipNetwork.sepolia;
  final client = ChainClient(network: network);
  final claims = ClaimService(client: client);
  final token = network.feeToken;

  final config = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final sender = WalletFactory(accountClassHash: network.accountClassHash)
      .deriveFrom(config['mnemonic'] as String);

  // A wallet that has never touched the chain, which is the whole point.
  final recipient = WalletFactory(accountClassHash: network.accountClassHash)
      .deriveFrom(WalletFactory.generateMnemonic());

  final wanted = TokenAmount.parse(args.isEmpty ? '0.2' : args.first, token);
  final cost = await claims.estimateClaimCost(sender.signing);
  final funding = TokenAmount(wanted.raw + cost.raw, token);

  stdout
    ..writeln('recipient should get ${wanted.formatWithSymbol()}')
    ..writeln('claim fees budgeted  ${cost.formatWithSymbol()}')
    ..writeln('funding the link     ${funding.formatWithSymbol()}')
    ..writeln('');

  final issue = await claims.createTip(from: sender.signing, amount: funding);
  stdout
    ..writeln('link    ${issue.key.link()}')
    ..writeln('address ${issue.key.address.toHexString()}')
    ..writeln('tx      ${network.transactionUrl(issue.transactionHash)}')
    ..writeln('waiting for the funding transfer...');

  final funded = await client.awaitTransaction(issue.transactionHash);
  if (funded.outcome != TransactionOutcome.succeeded) {
    stderr.writeln('Funding failed: ${funded.outcome.name} '
        '${funded.failureReason ?? ''}');
    exit(1);
  }

  // Re-parse the link rather than reusing the key, so the round trip through
  // the URL is part of what is being tested.
  final reopened = ClaimLinks.parse(
    issue.key.link().toString(),
    accountClassHash: network.accountClassHash,
  );

  final status = await claims.inspect(reopened, reference: sender.signing);
  stdout
    ..writeln('')
    ..writeln('at the link ${status.balance.formatWithSymbol()}')
    ..writeln('claimable   ${status.claimable.formatWithSymbol()}')
    ..writeln('deployed    ${status.deployed}');
  if (!status.canClaim) {
    stderr.writeln('Not claimable. Short by '
        '${status.shortfall?.formatWithSymbol() ?? 'unknown'}.');
    exit(1);
  }

  stdout.writeln('claiming into ${recipient.accountAddress.toHexString()}...');
  final result = await claims.claim(
    key: reopened,
    recipient: recipient.signing,
  );
  stdout.writeln('sweep tx    ${network.transactionUrl(result.transactionHash)}');

  final swept = await client.awaitTransaction(result.transactionHash);
  stdout.writeln('outcome     ${swept.outcome.name} '
      '${swept.failureReason ?? ''}');

  final received = await client.balanceOf(
    token: token,
    address: recipient.accountAddress,
  );
  final leftBehind = await client.balanceOf(
    token: token,
    address: reopened.address,
  );

  stdout
    ..writeln('')
    ..writeln('recipient received ${received.formatWithSymbol()}')
    ..writeln('left in the link   ${leftBehind.formatWithSymbol()}')
    ..writeln('wanted at least    ${wanted.formatWithSymbol()}');

  final ok = received.raw >= wanted.raw;
  stdout.writeln(ok ? '\nClaim worked.' : '\nSHORT by ${TokenAmount(wanted.raw - received.raw, token).formatWithSymbol()}');
  exit(ok ? 0 : 1);
}
