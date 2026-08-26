/// Sends tokens privately from this wallet to somebody else.
///
/// Nothing about it is visible on chain beyond the fact that the pool was
/// used: not the sender, not the recipient, not the amount. What it does is
/// spend notes, create one for the recipient, and return the change to a note
/// of our own.
///
/// The recipient has to be registered with the pool already. A note is
/// encrypted to their viewing key, so there is no way to pay someone the pool
/// has never heard of.
///
///   `dart run tool/private_transfer.dart RECIPIENT AMOUNT [--submit]`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tip/src/chain/network.dart';
import 'package:tip/src/privacy/pool_config.dart';
import 'package:tip/src/privacy/pool_session.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

String _hex(BigInt v) => '0x${v.toRadixString(16)}';
BigInt _felt(String hex) => BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);

BigInt _whole(String value) {
  final parts = value.split('.');
  final units = BigInt.parse(parts[0].isEmpty ? '0' : parts[0]);
  final fraction = parts.length > 1 ? parts[1].padRight(18, '0').substring(0, 18) : '0' * 18;
  return units * BigInt.from(10).pow(18) + BigInt.parse(fraction);
}

String _display(BigInt raw) =>
    (raw / BigInt.from(10).pow(18)).toStringAsFixed(6);

Future<void> main(List<String> args) async {
  final submit = args.contains('--submit');
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    stderr.writeln(
      'usage: dart run tool/private_transfer.dart RECIPIENT AMOUNT [--submit]',
    );
    exit(64);
  }

  final env = jsonDecode(File('../.strk20-env.json').readAsStringSync())
      as Map<String, dynamic>;
  final network = TipNetwork.sepolia;
  final token = _felt(env['feeTokenAddress'] as String);

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

  final session = PoolSession(
    config: config,
    keys: keys,
    chainId: network.chainId,
    feeToken: token,
  );

  final self = keys.accountAddress.toBigInt();
  final recipient = _felt(positional[0]);
  final amount = _whole(positional[1]);

  final recipientKey = await session.registeredPublicKey(recipient);
  if (recipientKey == BigInt.zero) {
    stderr.writeln(
      'That address is not registered with the pool. A note is encrypted to '
      'the recipient viewing key, so there is nobody to encrypt it to.',
    );
    exit(1);
  }

  final selfKey = await session.registeredPublicKey(self);

  // Our own notes come from discovery, which decrypts them with the viewing
  // key we hand it.
  final discovery = tp.DiscoveryClient(
    transport: tp.PlainJsonTransport(baseUrl: config.discoveryUrl),
    poolContractAddress: config.poolAddress,
  );
  final incoming = await discovery.syncIncoming(
    address: self,
    viewingKey: keys.viewingKey,
  );
  discovery.close();

  final ourChannel = session.channelTo(
    recipient: self,
    recipientPublicKey: selfKey,
    token: token,
  );

  // A note is only spendable if its nullifier has not been published.
  //
  // The discovery service already leaves spent notes out of what it returns,
  // so in practice this filters nothing. It stays because spendability is a
  // fact about the chain rather than about what a service chose to send, and
  // the cost of checking is one call per note.
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
    ..writeln('from        ${keys.accountAddress.toHexString()}')
    ..writeln('to          ${_hex(recipient)}')
    ..writeln('shielded    ${_display(held)} STRK across '
        '${spendable.length} unspent notes')
    ..writeln('sending     ${_display(amount)} STRK');

  if (held < amount) {
    stderr.writeln('Not enough shielded. Shield more first.');
    exit(1);
  }

  final theirChannel = session.channelTo(
    recipient: recipient,
    recipientPublicKey: recipientKey,
    token: token,
  );
  final channelOpen = await session.channelExists(theirChannel.channelMarker);
  final subchannelOpen =
      await session.subchannelExists(theirChannel.subchannelMarker);

  final theirNotes = channelOpen
      ? await session.noteCount(channelKey: theirChannel.key, token: token)
      : 0;
  final ourNotes =
      await session.noteCount(channelKey: ourChannel.key, token: token);
  final subchannels =
      channelOpen ? await session.subchannelCount(theirChannel.key) : 0;
  final channels = await session.outgoingChannelCount();

  stdout.writeln('their channel ${channelOpen ? "open" : "not open"}, '
      'notes $theirNotes; our notes $ourNotes');

  final random = _SecureRandom();
  final simulator = tp.PoolSimulator()
    ..observeNoteCount(
      channelKey: theirChannel.key,
      token: token,
      count: theirNotes,
    )
    ..observeNoteCount(channelKey: ourChannel.key, token: token, count: ourNotes)
    ..observeSubchannelCount(channelKey: theirChannel.key, count: subchannels)
    ..observeOutgoingChannelCount(channels);

  final batch = simulator.beginBatch();
  final actions = <tp.ClientAction>[
    ...tp.buildChannelSetup(
      recipientAddr: recipient,
      recipientPublicKey: recipientKey,
      channelKey: theirChannel.key,
      token: token,
      channelIndex:
          channelOpen ? channels : batch.takeOutgoingChannelIndex(),
      subchannelIndex: subchannelOpen
          ? subchannels
          : batch.takeSubchannelIndex(theirChannel.key),
      random: random,
      channelExists: channelOpen,
      subchannelExists: subchannelOpen,
    ),
    ...tp.buildPrivateTransfer(
      available: spendable,
      token: token,
      amount: amount,
      recipientAddr: recipient,
      recipientPublicKey: recipientKey,
      recipientNoteIndex:
          batch.takeNoteIndex(channelKey: theirChannel.key, token: token),
      selfAddr: self,
      selfPublicKey: selfKey,
      changeNoteIndex:
          batch.takeNoteIndex(channelKey: ourChannel.key, token: token),
      random: random,
    ),
  ];

  stdout.writeln('actions     ${actions.map((a) => a.kind.name).join(", ")}');

  if (!submit) {
    batch.abandon();
    stdout.writeln('\nStopping before proving. Pass --submit to send it.');
    return;
  }

  stdout.writeln('proving...');
  final proof = await session.prove(actions);
  stdout.writeln('proved      ${proof.proofFacts.length} facts, screening '
      '${proof.screeningSignature == null ? "not required" : "attested"}');

  // Only the pool's own fee. Nothing is being deposited: the value moves
  // between notes that are already inside.
  final fee = await session.feeAmount();

  stdout.writeln('submitting...');
  try {
    final sent = await session.submit(proof: proof, approve: fee);
    batch.commit();
    stdout
      ..writeln('sent        ${sent.transactionHash.toHexString()}')
      ..writeln(network.transactionUrl(sent.transactionHash));
    stdout.writeln('waiting...');
    stdout.writeln('outcome     ${await session.awaitSettled(sent.transactionHash)}');
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
