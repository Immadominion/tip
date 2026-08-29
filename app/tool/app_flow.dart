/// Drives the app's own privacy code path against Sepolia.
///
/// The screens do not call the tools. They call `PrivateOperations`, which was
/// lifted out of the tools afterwards and has never produced a real proof.
/// Everything below it is proven; this proves the layer the screens actually
/// sit on, so the only untested thing left is the widgets themselves.
///
/// `PrivacyController` is deliberately not used here. It is a ChangeNotifier,
/// so it pulls in `dart:ui` and cannot run outside a Flutter host. What it does
/// beyond holding state is one discovery sync, and that has already been proven
/// over the encrypted transport by `tool/ohttp_probe.dart`.
///
///   `dart run tool/app_flow.dart shield 0.2 [--submit]`
///   `dart run tool/app_flow.dart send RECIPIENT 0.1 [--submit]`
///   `dart run tool/app_flow.dart unshield 0.1 [--submit]`
///   `dart run tool/app_flow.dart balance`
library;

import 'dart:convert';
import 'dart:io';

import 'package:tip/src/chain/amount.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/privacy/pool_config.dart';
import 'package:tip/src/privacy/pool_session.dart';
import 'package:tip/src/privacy/private_operations.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

BigInt _felt(String hex) => BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);

Future<void> main(List<String> args) async {
  final submit = args.contains('--submit');
  final rest = args.where((a) => !a.startsWith('--')).toList();
  if (rest.isEmpty) {
    stderr.writeln('usage: dart run tool/app_flow.dart '
        '<balance|shield|send|unshield> [args] [--submit]');
    exit(64);
  }

  final env = jsonDecode(File('../.strk20-env.json').readAsStringSync())
      as Map<String, dynamic>;
  final network = TipNetwork.sepolia;

  final config = PoolConfig(
    poolAddress: _felt(env['poolAddress'] as String),
    provingUrl: Uri.parse(env['provingUrl'] as String),
    discoveryUrl: Uri.parse(env['discoveryUrl'] as String),
    rpcUrl: Uri.parse(env['rpcUrl'] as String),
  );

  final keys = WalletFactory(accountClassHash: network.accountClassHash)
      .deriveFrom(
    (jsonDecode(File('../.dev-account.json').readAsStringSync())
        as Map<String, dynamic>)['mnemonic'] as String,
  );

  final token = network.feeToken;
  final session = PoolSession(
    config: config,
    keys: keys,
    chainId: network.chainId,
    feeToken: token.address.toBigInt(),
  );

  // Same read the controller does, over the same encrypted transport.
  final self = keys.accountAddress.toBigInt();
  final publicKey = await session.registeredPublicKey(self);
  final channel = session.channelTo(
    recipient: self,
    recipientPublicKey: publicKey,
    token: token.address.toBigInt(),
  );

  final discovery = tp.DiscoveryClient(
    transport: session.transportTo(config.discoveryUrl),
    poolContractAddress: config.poolAddress,
  );
  final incoming =
      await discovery.syncIncoming(address: self, viewingKey: keys.viewingKey);
  discovery.close();

  final notes = [
    for (final note in incoming.notes)
      tp.SpendableNote(
        channelKey: channel.key,
        token: note.token,
        index: note.index,
        amount: note.amount,
      ),
  ];
  final held = notes.fold(BigInt.zero, (sum, n) => sum + n.amount);

  stdout
    ..writeln('registered ${publicKey != BigInt.zero}')
    ..writeln('shielded   ${TokenAmount(held, token).formatWithSymbol()} '
        'across ${notes.length} notes');

  if (rest.first == 'balance') return;

  final operations = PrivateOperations(
    session: session,
    random: tp.SecureRandomSource(),
  )..onStage = (stage) => stdout.writeln('  ${stage.name}...');

  Future<PoolSubmission> Function() action;
  switch (rest.first) {
    case 'shield':
      final amount = TokenAmount.parse(rest[1], token);
      stdout.writeln('shielding ${amount.formatWithSymbol()}');
      action = () => operations.shield(token: token, amount: amount.raw);
    case 'send':
      final amount = TokenAmount.parse(rest[2], token);
      stdout.writeln('sending   ${amount.formatWithSymbol()} to ${rest[1]}');
      action = () => operations.privateTransfer(
            recipient: _felt(rest[1]),
            token: token,
            amount: amount.raw,
            available: notes,
          );
    case 'unshield':
      final amount = TokenAmount.parse(rest[1], token);
      stdout.writeln('unshielding ${amount.formatWithSymbol()}');
      action = () => operations.unshield(
            to: keys.accountAddress.toBigInt(),
            token: token,
            amount: amount.raw,
            available: notes,
          );
    default:
      stderr.writeln('Unknown command: ${rest.first}');
      exit(64);
  }

  if (!submit) {
    stdout.writeln('\nDry run. Pass --submit to send it.');
    return;
  }

  try {
    final sent = await action();
    stdout
      ..writeln('sent      ${sent.transactionHash.toHexString()}')
      ..writeln('          ${network.transactionUrl(sent.transactionHash)}')
      ..writeln('outcome   ${await session.awaitSettled(sent.transactionHash)}');
  } on OperationRefused catch (refusal) {
    stderr.writeln('refused: $refusal');
    exit(1);
  } on PoolException catch (failure) {
    stderr.writeln('failed: $failure');
    exit(1);
  }
}
