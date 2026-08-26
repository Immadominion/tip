/// Shields tokens into the pool, for real.
///
/// A first shield is more than a deposit. `create_enc_note` asserts the
/// subchannel exists, a subchannel needs a channel, and a channel needs both
/// parties registered, so the very first one has to arrange all of that in the
/// same batch. After that the setup is already there and the batch is just the
/// deposit and the note.
///
/// The wallet shields to itself, so sender and recipient are the same address
/// and the channel is one it owns both ends of.
///
///   `dart run tool/shield.dart <amount> [--submit]`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

Map<String, dynamic> _env() =>
    jsonDecode(File('../.strk20-env.json').readAsStringSync())
        as Map<String, dynamic>;

BigInt _felt(String hex) => BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);
String _hex(BigInt v) => '0x${v.toRadixString(16)}';

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

Future<List<String>> _call(
  Uri node,
  BigInt contract,
  String selector,
  List<String> calldata,
) async {
  final response = await _rpc(node, 'starknet_call', [
    {
      'contract_address': _hex(contract),
      'entry_point_selector': getSelectorByName(selector).toHexString(),
      'calldata': calldata,
    },
    'latest',
  ]);
  if (response['error'] != null) {
    throw StateError('$selector: ${jsonEncode(response['error'])}');
  }
  return (response['result'] as List).cast<String>();
}

Future<void> main(List<String> args) async {
  final submit = args.contains('--submit');
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final whole = positional.isEmpty ? '1' : positional.first;

  final env = _env();
  final node = Uri.parse(env['rpcUrl'] as String);
  final pool = _felt(env['poolAddress'] as String);
  final strk = _felt(env['feeTokenAddress'] as String);

  final keys = WalletFactory(
    accountClassHash: TipNetwork.sepolia.accountClassHash,
  ).deriveFrom(
    (jsonDecode(File('../.dev-account.json').readAsStringSync())
        as Map<String, dynamic>)['mnemonic'] as String,
  );

  final self = keys.accountAddress.toBigInt();
  final viewingKey = keys.viewingKey;
  final amount = _parseWhole(whole);

  // The pool stores our public key; it is also the recipient key for a note
  // we pay to ourselves.
  final registered = _felt((await _call(
    node,
    pool,
    'get_public_key',
    [keys.accountAddress.toHexString()],
  )).first);
  if (registered == BigInt.zero) {
    stderr.writeln('Not registered. Run tool/register_viewing_key.dart first.');
    exit(1);
  }

  final derived = tp.derivePublicKey(viewingKey);
  if (derived != registered) {
    stderr.writeln('The pool holds a different key than this seed derives.');
    exit(1);
  }

  final channelKey = tp.computeChannelKey(
    senderAddr: self,
    senderPrivateKey: viewingKey,
    recipientAddr: self,
    recipientPublicKey: registered,
  );

  final channelMarker = tp.computeChannelMarker(
    channelKey: channelKey,
    senderAddr: self,
    recipientAddr: self,
    recipientPublicKey: registered,
  );
  final subchannelMarker = tp.computeSubchannelMarker(
    channelKey: channelKey,
    recipientAddr: self,
    recipientPublicKey: registered,
    token: strk,
  );

  final channelExists =
      _felt((await _call(node, pool, 'channel_exists', [_hex(channelMarker)]))
              .first) !=
          BigInt.zero;
  final subchannelExists = _felt(
        (await _call(node, pool, 'subchannel_exists', [_hex(subchannelMarker)]))
            .first,
      ) !=
      BigInt.zero;

  // Where the next note goes. Slots are dense and append-only, so the count is
  // the first index the pool has nothing at.
  final noteCount = await tp.countOccupiedSlots(
    exists: (id) async {
      final note = await _call(node, pool, 'get_note', [_hex(id)]);
      return _felt(note.first) != BigInt.zero;
    },
    idFor: (index) =>
        tp.computeNoteId(channelKey: channelKey, token: strk, index: index),
  );

  final subchannelCount = channelExists
      ? await tp.countOccupiedSlots(
          exists: (id) async {
            final info =
                await _call(node, pool, 'get_subchannel_info', [_hex(id)]);
            return _felt(info.first) != BigInt.zero;
          },
          idFor: (index) =>
              tp.computeSubchannelId(channelKey: channelKey, index: index),
        )
      : 0;

  final channelCount = await tp.countOccupiedSlots(
    exists: (id) async {
      final info =
          await _call(node, pool, 'get_outgoing_channel_info', [_hex(id)]);
      return _felt(info.first) != BigInt.zero;
    },
    idFor: (index) => tp.computeOutgoingChannelId(
      senderAddr: self,
      senderPrivateKey: viewingKey,
      index: index,
    ),
  );

  stdout
    ..writeln('account       ${keys.accountAddress.toHexString()}')
    ..writeln('channel key   ${_hex(channelKey)}')
    ..writeln('channel       ${channelExists ? "open" : "not open"} '
        '(next index $channelCount)')
    ..writeln('subchannel    ${subchannelExists ? "open" : "not open"} '
        '(next index $subchannelCount)')
    ..writeln('notes so far  $noteCount')
    ..writeln('shielding     ${amount / BigInt.from(10).pow(18)} STRK');

  final random = _SecureRandom();
  final simulator = tp.PoolSimulator()
    ..observeNoteCount(channelKey: channelKey, token: strk, count: noteCount)
    ..observeSubchannelCount(channelKey: channelKey, count: subchannelCount)
    ..observeOutgoingChannelCount(channelCount);

  final batch = simulator.beginBatch();
  final actions = <tp.ClientAction>[
    ...tp.buildChannelSetup(
      recipientAddr: self,
      recipientPublicKey: registered,
      channelKey: channelKey,
      token: strk,
      channelIndex: channelExists ? channelCount : batch.takeOutgoingChannelIndex(),
      subchannelIndex:
          subchannelExists ? subchannelCount : batch.takeSubchannelIndex(channelKey),
      random: random,
      channelExists: channelExists,
      subchannelExists: subchannelExists,
    ),
    ...tp.buildShield(
      token: strk,
      amount: amount,
      recipientAddr: self,
      recipientPublicKey: registered,
      noteIndex: batch.takeNoteIndex(channelKey: channelKey, token: strk),
      random: random,
    ),
  ];

  stdout.writeln('actions       ${actions.map((a) => a.kind.name).join(", ")}');
  tp.assertPhaseOrder(actions);

  final problems = simulator.checkSequential(
    actions,
    channelKeyFor: (_, __) => channelKey,
  );
  if (problems.isNotEmpty) {
    stderr.writeln('index problems: ${problems.join("; ")}');
    exit(1);
  }

  // ---- prove -----------------------------------------------------------
  final inner = tp.compileActionsCalldata(
    userAddress: self,
    viewingKey: viewingKey,
    actions: actions,
  );
  final proofBounds = tp.ResourceBounds(
    l2Gas: tp.ResourceBound(
      maxAmount: tp.provingL2GasLimit,
      maxPricePerUnit: '0x0',
    ),
  );
  final proofHash = tp.provedInvokeTransactionHash(
    senderAddress: pool,
    calldata: tp
        .wrapAsExecuteCalldata(
          to: pool,
          selector: getSelectorByName('compile_actions').toBigInt(),
          calldata: inner,
        )
        .toList(),
    chainId: TipNetwork.sepolia.chainId.toBigInt(),
    nonce: tp.proofInvocationNonce,
    resourceBounds: proofBounds,
    proofFacts: const [],
  );
  final proofSignature = await StarkSigner(privateKey: keys.accountPrivateKey)
      .sign(proofHash, BigInt.from(32));

  final invocation = tp.buildProofInvocation(
    poolAddress: pool,
    userAddress: self,
    viewingKey: viewingKey,
    actions: actions,
    compileActionsSelector: getSelectorByName('compile_actions').toBigInt(),
    signature: proofSignature.map((f) => f.toBigInt()).toList(),
    resourceBounds: proofBounds,
  );

  final chainHead =
      ((await _rpc(node, 'starknet_blockNumber', <Object>[]))['result'] as num)
          .toInt();
  final provingBlock = tp.provingBlockFor(chainHead);
  stdout.writeln('proving against block $provingBlock (head $chainHead)');

  final proving = tp.ProvingClient(
    transport:
        tp.PlainJsonTransport(baseUrl: Uri.parse(env['provingUrl'] as String)),
  );
  final proof = await proving.proveTransaction(
    blockId: {'block_number': provingBlock},
    transaction: invocation.toJson(),
  );
  proving.close();

  final applyCalldata = tp.applyActionsCalldata(
    messagePayload: proof.serverActionsFor(_hex(pool)),
    screening: proof.screeningSignature == null
        ? null
        : tp.ScreeningAttestationFelts(
            issuedAt: _hex(BigInt.from(proof.screeningSignature!.issuedAt)),
            r: proof.screeningSignature!.r,
            s: proof.screeningSignature!.s,
          ),
  );

  stdout
    ..writeln('proved        ${proof.proofFacts.length} facts')
    ..writeln('screening     '
        '${proof.screeningSignature == null ? "not required" : "attested"}')
    ..writeln('calldata      ${applyCalldata.length} felts');

  final fee = _felt((await _call(node, pool, 'get_fee_amount', [])).first);

  if (!submit) {
    batch.abandon();
    stdout.writeln('\nStopping before submission. Pass --submit to send it.');
    return;
  }

  // The pool takes both the deposit and its fee with transfer_from, so the
  // approval has to cover the pair.
  final approval = amount + fee;
  final calls = [
    FunctionCall(
      contractAddress: Felt(strk),
      entryPointSelector: getSelectorByName('approve'),
      calldata: [Felt(pool), Felt(approval), Felt.zero],
    ),
    FunctionCall(
      contractAddress: Felt(pool),
      entryPointSelector: getSelectorByName('apply_actions'),
      calldata: applyCalldata.map(Felt.fromHexString).toList(),
    ),
  ];

  final nonce = Felt.fromHexString((await _rpc(node, 'starknet_getNonce',
      ['latest', keys.accountAddress.toHexString()]))['result'] as String);
  final header = (await _rpc(node, 'starknet_getBlockWithTxHashes',
      ['latest']))['result'] as Map<String, dynamic>;
  String price(String key) =>
      ((header[key] as Map<String, dynamic>?)?['price_in_fri'] as String?) ??
      '0x1';

  final bounds = tp.ResourceBounds(
    l1Gas: tp.ResourceBound(
      maxAmount: '0x30d40',
      maxPricePerUnit: price('l1_gas_price'),
    ),
    l1DataGas: tp.ResourceBound(
      maxAmount: '0x30d40',
      maxPricePerUnit: price('l1_data_gas_price'),
    ),
    l2Gas: tp.ResourceBound(
      maxAmount: '0x3b9aca00',
      maxPricePerUnit: price('l2_gas_price'),
    ),
  );

  final calldata =
      functionCallsToCalldata(functionCalls: calls, useLegacyCalldata: false);
  final messageHash = tp.provedInvokeTransactionHash(
    senderAddress: self,
    calldata: calldata.map((f) => f.toBigInt()).toList(),
    chainId: TipNetwork.sepolia.chainId.toBigInt(),
    nonce: nonce.toBigInt(),
    resourceBounds: bounds,
    proofFacts: proof.proofFacts.map(_felt).toList(),
  );
  final signature = await StarkSigner(privateKey: keys.accountPrivateKey)
      .sign(messageHash, BigInt.from(32));

  final transaction = <String, dynamic>{
    'type': 'INVOKE',
    'version': '0x3',
    'sender_address': keys.accountAddress.toHexString(),
    'calldata': calldata.map((f) => f.toHexString()).toList(),
    'signature': signature.map((f) => f.toHexString()).toList(),
    'nonce': nonce.toHexString(),
    'resource_bounds': bounds.toJson(),
    'tip': tp.requiredTip,
    'paymaster_data': <String>[],
    'account_deployment_data': <String>[],
    'nonce_data_availability_mode': 'L1',
    'fee_data_availability_mode': 'L1',
    ...tp.proofFields(proofFacts: proof.proofFacts, proof: proof.proof),
  };

  stdout.writeln('submitting...');
  final sent = await _rpc(node, 'starknet_addInvokeTransaction', [transaction]);
  if (sent['error'] != null) {
    batch.abandon();
    final detail = jsonEncode(sent['error']);
    stderr.writeln(
      'rejected: ${detail.length > 1400 ? detail.substring(0, 1400) : detail}',
    );
    exit(1);
  }
  batch.commit();
  final hash = (sent['result'] as Map)['transaction_hash'] as String;
  stdout
    ..writeln('sent: $hash')
    ..writeln('https://sepolia.voyager.online/tx/$hash');
}

BigInt _parseWhole(String value) {
  final parts = value.split('.');
  final whole = BigInt.parse(parts[0].isEmpty ? '0' : parts[0]);
  final fraction = parts.length > 1 ? parts[1].padRight(18, '0') : '0' * 18;
  return whole * BigInt.from(10).pow(18) + BigInt.parse(fraction);
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
