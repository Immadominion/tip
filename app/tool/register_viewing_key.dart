/// Registers this wallet's viewing key with the STRK20 pool, for real.
///
/// The whole loop in one place: build the action, prove it, take the compiled
/// server actions out of the proof, and submit them on chain.
///
/// Two things about the submission are not obvious from the interface.
///
/// The pool collects its fee with `transfer_from` rather than by being paid,
/// so the caller has to approve it first. That makes this a multicall:
/// approve, then apply.
///
/// And the proof rides on the transaction as two extra top-level fields that
/// standard Starknet RPC does not define, so the transaction is assembled and
/// posted by hand rather than through the SDK's `execute`.
///
///   `dart run tool/register_viewing_key.dart [--submit]`
///
/// Without `--submit` it stops after proving and prints what it would send.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/wallet/wallet.dart';
import 'package:tip_privacy/tip_privacy.dart' as tp;

Map<String, dynamic> _env() {
  for (final path in ['../.strk20-env.json', '.strk20-env.json']) {
    final f = File(path);
    if (f.existsSync()) {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  stderr.writeln('No .strk20-env.json found.');
  exit(1);
}

BigInt _felt(String hex) => BigInt.parse(hex.replaceFirst('0x', ''), radix: 16);
String _hex(BigInt v) => '0x${v.toRadixString(16)}';

Future<Map<String, dynamic>> _rpc(Uri node, String method, Object params) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(node);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': method,
      'params': params,
    }));
    final response = await request.close();
    return jsonDecode(await response.transform(utf8.decoder).join())
        as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

final _proofL2Gas = Felt.fromHexString(tp.provingL2GasLimit);

Map<String, ResourceBounds> _proofBounds() => {
      'l1_gas': ResourceBounds(maxAmount: Felt.zero, maxPricePerUnit: Felt.zero),
      'l1_data_gas':
          ResourceBounds(maxAmount: Felt.zero, maxPricePerUnit: Felt.zero),
      'l2_gas':
          ResourceBounds(maxAmount: _proofL2Gas, maxPricePerUnit: Felt.zero),
    };

Future<void> main(List<String> args) async {
  final submit = args.contains('--submit');
  final env = _env();
  final node = Uri.parse(env['rpcUrl'] as String);
  final pool = _felt(env['poolAddress'] as String);
  final strk = _felt(env['feeTokenAddress'] as String);

  final devFile = File('../.dev-account.json');
  if (!devFile.existsSync()) {
    stderr.writeln('No .dev-account.json.');
    exit(1);
  }
  final keys = WalletFactory(
    accountClassHash: TipNetwork.sepolia.accountClassHash,
  ).deriveFrom(
    (jsonDecode(devFile.readAsStringSync()) as Map<String, dynamic>)['mnemonic']
        as String,
  );

  stdout
    ..writeln('account  ${keys.accountAddress.toHexString()}')
    ..writeln('pool     ${env['poolAddress']}');

  // Already registered? SetViewingKey is immutable once set, so a second
  // attempt is a wasted proof and a reverted transaction.
  final existing = await _rpc(node, 'starknet_call', [
    {
      'contract_address': _hex(pool),
      'entry_point_selector': getSelectorByName('get_public_key').toHexString(),
      'calldata': [keys.accountAddress.toHexString()],
    },
    'latest',
  ]);
  if (existing['error'] != null) {
    stderr.writeln('node said: ${jsonEncode(existing['error'])}');
    exit(1);
  }
  final existingKey = _felt(((existing['result'] as List).first) as String);
  stdout.writeln('registered key: ${_hex(existingKey)}');
  if (existingKey != BigInt.zero) {
    stdout.writeln('Already registered. Nothing to do.');
    return;
  }

  // ---- prove -----------------------------------------------------------
  final random = _SecureRandom();
  final actions = tp.buildRegister(random: random);
  final inner = tp.compileActionsCalldata(
    userAddress: keys.accountAddress.toBigInt(),
    viewingKey: keys.viewingKey,
    actions: actions,
  );
  final compileCall = FunctionCall(
    contractAddress: Felt(pool),
    entryPointSelector: getSelectorByName('compile_actions'),
    calldata: inner.map(Felt.new).toList(),
  );
  final proofSignature = await StarkAccountSigner(
    signer: StarkSigner(privateKey: keys.accountPrivateKey),
  ).signTransactions(
    transactions: [compileCall],
    contractAddress: Felt(pool),
    chainId: TipNetwork.sepolia.chainId,
    nonce: Felt(tp.proofInvocationNonce),
    resourceBounds: _proofBounds(),
    accountDeploymentData: const [],
    paymasterData: const [],
    tip: Felt.zero,
    feeDataAvailabilityMode: 'L1',
    nonceDataAvailabilityMode: 'L1',
  );

  final invocation = tp.buildProofInvocation(
    poolAddress: pool,
    userAddress: keys.accountAddress.toBigInt(),
    viewingKey: keys.viewingKey,
    actions: actions,
    compileActionsSelector: getSelectorByName('compile_actions').toBigInt(),
    signature: proofSignature.map((f) => f.toBigInt()).toList(),
  );

  final proving = tp.ProvingClient(
    transport: tp.PlainJsonTransport(
      baseUrl: Uri.parse(env['provingUrl'] as String),
    ),
  );

  // Prove against a block behind the head, not against the head itself. The
  // node refuses a proof that is too recent, and blocks keep arriving between
  // proving and submitting, so the lag has to absorb that gap too.
  final blockResponse = await _rpc(node, 'starknet_blockNumber', <Object>[]);
  final chainHead = (blockResponse['result'] as num).toInt();
  final provingBlock = tp.provingBlockFor(chainHead);
  stdout.writeln('proving against block $provingBlock (head $chainHead)');

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
    ..writeln('proved: ${proof.proofFacts.length} facts, '
        '${proof.proof.length} base64 chars')
    ..writeln('apply_actions calldata: ${applyCalldata.length} felts');

  final feeCall = await _rpc(node, 'starknet_call', [
    {
      'contract_address': _hex(pool),
      'entry_point_selector': getSelectorByName('get_fee_amount').toHexString(),
      'calldata': <String>[],
    },
    'latest',
  ]);
  final feeAmount = _felt(((feeCall['result'] as List).first) as String);
  stdout.writeln('pool fee: ${feeAmount / BigInt.from(10).pow(18)} STRK');

  if (!submit) {
    stdout.writeln('\nStopping before submission. Pass --submit to send it.');
    return;
  }

  // ---- submit ----------------------------------------------------------
  final calls = [
    FunctionCall(
      contractAddress: Felt(strk),
      entryPointSelector: getSelectorByName('approve'),
      calldata: [Felt(pool), Felt(feeAmount), Felt.zero],
    ),
    FunctionCall(
      contractAddress: Felt(pool),
      entryPointSelector: getSelectorByName('apply_actions'),
      calldata: applyCalldata.map(Felt.fromHexString).toList(),
    ),
  ];

  final nonceResponse = await _rpc(node, 'starknet_getNonce', [
    'latest',
    keys.accountAddress.toHexString(),
  ]);
  final nonce = Felt.fromHexString(nonceResponse['result'] as String);

  final head = await _rpc(node, 'starknet_getBlockWithTxHashes', ['latest']);
  final header = head['result'] as Map<String, dynamic>;
  Felt price(String key) => Felt.fromHexString(
        ((header[key] as Map<String, dynamic>?)?['price_in_fri'] as String?) ??
            '0x1',
      );

  // Generous ceilings. Verifying a proof is heavy, and the account pays what
  // execution uses rather than the ceiling, so erring high costs nothing.
  final bounds = tp.ResourceBounds(
    l1Gas: tp.ResourceBound(
      maxAmount: '0x30d40',
      maxPricePerUnit: price('l1_gas_price').toHexString(),
    ),
    l1DataGas: tp.ResourceBound(
      maxAmount: '0x30d40',
      maxPricePerUnit: price('l1_data_gas_price').toHexString(),
    ),
    l2Gas: tp.ResourceBound(
      maxAmount: '0x3b9aca00',
      maxPricePerUnit: price('l2_gas_price').toHexString(),
    ),
  );

  final calldata =
      functionCallsToCalldata(functionCalls: calls, useLegacyCalldata: false);

  // Signed over our own hash, not the SDK's. The proof facts are part of the
  // transaction hash, and a signature that leaves them out is a signature over
  // a different message: the account rejects it saying only "invalid
  // signature", which names neither the cause nor the field.
  final messageHash = tp.provedInvokeTransactionHash(
    senderAddress: keys.accountAddress.toBigInt(),
    calldata: calldata.map((f) => f.toBigInt()).toList(),
    chainId: TipNetwork.sepolia.chainId.toBigInt(),
    nonce: nonce.toBigInt(),
    resourceBounds: bounds,
    proofFacts: proof.proofFacts.map(_felt).toList(),
  );

  final signature =
      await StarkSigner(privateKey: keys.accountPrivateKey)
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
    final detail = jsonEncode(sent['error']);
    stderr.writeln(
      'rejected: ${detail.length > 1200 ? detail.substring(0, 1200) : detail}',
    );
    exit(1);
  }
  final hash = (sent['result'] as Map)['transaction_hash'] as String;
  stdout
    ..writeln('sent: $hash')
    ..writeln('https://sepolia.voyager.online/tx/$hash');
}

/// Real randomness. Salts and blinding factors must be unpredictable, since
/// reusing one links two transactions that should look unrelated.
class _SecureRandom implements tp.RandomSource {
  final _random = Random.secure();

  List<int> _bytes(int n) => List<int>.generate(n, (_) => _random.nextInt(256));

  BigInt _pack(int n) {
    var value = BigInt.zero;
    for (final byte in _bytes(n)) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  @override
  BigInt nextFelt() {
    final value = _pack(31);
    return value == BigInt.zero ? BigInt.one : value;
  }

  @override
  BigInt nextNoteSalt() {
    final value = _pack(15);
    return value <= BigInt.one ? BigInt.two : value;
  }
}
