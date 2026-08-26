/// Moves tokens out of the pool to a public address.
///
/// The withdrawal itself is public: the recipient, the token and the amount are
/// all visible on chain. What stays hidden is which notes paid for it, and
/// therefore who the sender was.
///
/// Spends enough notes to cover the amount and returns the remainder as a new
/// note, because notes are indivisible.
///
///   `dart run tool/unshield.dart AMOUNT [TO] [--submit]`
///
/// Without TO it withdraws to this wallet's own public address.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tip/src/chain/network.dart';
import 'package:tip/src/privacy/pool_config.dart';
import 'package:tip/src/privacy/pool_session.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

BigInt _felt(String hex) => BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);

BigInt _whole(String value) {
  final parts = value.split('.');
  final units = BigInt.parse(parts[0].isEmpty ? '0' : parts[0]);
  final fraction =
      parts.length > 1 ? parts[1].padRight(18, '0').substring(0, 18) : '0' * 18;
  return units * BigInt.from(10).pow(18) + BigInt.parse(fraction);
}

String _display(BigInt raw) =>
    (raw / BigInt.from(10).pow(18)).toStringAsFixed(6);

Future<void> main(List<String> args) async {
  final submit = args.contains('--submit');
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('usage: dart run tool/unshield.dart AMOUNT [TO] [--submit]');
    exit(64);
  }

  final env = jsonDecode(File('../.strk20-env.json').readAsStringSync())
      as Map<String, dynamic>;
  final network = TipNetwork.sepolia;
  final token = _felt(env['feeTokenAddress'] as String);

  final keys = WalletFactory(accountClassHash: network.accountClassHash)
      .deriveFrom(
    (jsonDecode(File('../.dev-account.json').readAsStringSync())
        as Map<String, dynamic>)['mnemonic'] as String,
  );

  final session = PoolSession(
    config: PoolConfig(
      poolAddress: _felt(env['poolAddress'] as String),
      provingUrl: Uri.parse(env['provingUrl'] as String),
      discoveryUrl: Uri.parse(env['discoveryUrl'] as String),
      rpcUrl: Uri.parse(env['rpcUrl'] as String),
    ),
    keys: keys,
    chainId: network.chainId,
    feeToken: token,
  );

  final self = keys.accountAddress.toBigInt();
  final amount = _whole(positional[0]);
  final destination = positional.length > 1 ? _felt(positional[1]) : self;

  final selfKey = await session.registeredPublicKey(self);
  if (selfKey == BigInt.zero) {
    stderr.writeln('Not registered with the pool.');
    exit(1);
  }

  final ourChannel = session.channelTo(
    recipient: self,
    recipientPublicKey: selfKey,
    token: token,
  );

  final discovery = tp.DiscoveryClient(
    transport: tp.PlainJsonTransport(baseUrl: session.config.discoveryUrl),
    poolContractAddress: session.config.poolAddress,
  );
  final incoming = await discovery.syncIncoming(
    address: self,
    viewingKey: keys.viewingKey,
  );
  discovery.close();

  final spendable = <tp.SpendableNote>[];
  for (final note in incoming.notes.where((n) => n.token == token)) {
    final nullifier = tp.computeNullifier(
      channelKey: ourChannel.key,
      token: token,
      index: note.index,
      ownerPrivateKey: keys.viewingKey,
    );
    if (await session.nullifierExists(nullifier)) continue;
    spendable.add(
      tp.SpendableNote(
        channelKey: ourChannel.key,
        token: token,
        index: note.index,
        amount: note.amount,
      ),
    );
  }

  final held = spendable.fold(BigInt.zero, (sum, n) => sum + n.amount);
  stdout
    ..writeln('shielded    ${_display(held)} STRK across '
        '${spendable.length} unspent notes')
    ..writeln('withdrawing ${_display(amount)} STRK')
    ..writeln('to          0x${destination.toRadixString(16)}'
        '${destination == self ? "  (this wallet)" : ""}');

  if (held < amount) {
    stderr.writeln('Not enough shielded.');
    exit(1);
  }

  final ourNotes =
      await session.noteCount(channelKey: ourChannel.key, token: token);

  final simulator = tp.PoolSimulator()
    ..observeNoteCount(
      channelKey: ourChannel.key,
      token: token,
      count: ourNotes,
    );
  final batch = simulator.beginBatch();

  final actions = tp.buildUnshield(
    available: spendable,
    token: token,
    amount: amount,
    toAddr: destination,
    selfAddr: self,
    selfPublicKey: selfKey,
    changeNoteIndex:
        batch.takeNoteIndex(channelKey: ourChannel.key, token: token),
    random: _SecureRandom(),
  );

  stdout.writeln('actions     ${actions.map((a) => a.kind.name).join(", ")}');

  // Cheap here, expensive from the prover: an out-of-order batch costs a proof
  // and comes back saying only ACTIONS_OUT_OF_ORDER.
  tp.assertPhaseOrder(actions);
  stdout.writeln('note that the withdrawal itself is public: recipient, token '
      'and amount are all on chain. What stays hidden is which notes paid.');

  if (!submit) {
    batch.abandon();
    stdout.writeln('\nStopping before proving. Pass --submit to send it.');
    return;
  }

  stdout.writeln('proving...');
  final proof = await session.prove(actions);
  stdout.writeln('proved      ${proof.proofFacts.length} facts, screening '
      '${proof.screeningSignature == null ? "not required" : "attested"}');

  // Only the pool's own fee. A withdrawal takes value out; nothing is being
  // moved in that the pool would have to pull.
  final fee = await session.feeAmount();

  stdout.writeln('submitting...');
  try {
    final sent = await session.submit(proof: proof, approve: fee);
    batch.commit();
    stdout
      ..writeln('sent        ${sent.transactionHash.toHexString()}')
      ..writeln(network.transactionUrl(sent.transactionHash))
      ..writeln('waiting...')
      ..writeln('outcome     ${await session.awaitSettled(sent.transactionHash)}');
  } on PoolException catch (error) {
    batch.abandon();
    stderr.writeln('$error');
    exit(1);
  }
}

class _SecureRandom implements tp.RandomSource {
  final _random = Random.secure();

  BigInt _pack(int n) {
    var value = BigInt.zero;
    for (var i = 0; i < n; i++) {
      value = (value << 8) | BigInt.from(_random.nextInt(256));
    }
    return value;
  }

  @override
  BigInt nextFelt() {
    final v = _pack(31);
    return v == BigInt.zero ? BigInt.one : v;
  }

  @override
  BigInt nextNoteSalt() {
    final v = _pack(15);
    return v <= BigInt.one ? BigInt.two : v;
  }
}
