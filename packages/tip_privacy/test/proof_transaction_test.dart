/// The transaction hash for a submission that carries a proof.
///
/// The load-bearing test is the first one. Our hash has to agree with the SDK's
/// exactly when there are no proof facts, because that is what proves the only
/// difference between a proved submission and an ordinary one is the single
/// appended element. Everything else here is checking that the element is
/// appended when it should be and not when it should not.
library;

import 'package:starknet/starknet.dart';
import 'package:starknet_provider/starknet_provider.dart' as provider;
import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

final _privateKey = Felt.fromHexString('0x1234abcd');
final _sender = BigInt.parse('30a7cef4289ca322', radix: 16);
final _chainId = BigInt.parse('534e5f5345504f4c4941', radix: 16);
final _nonce = BigInt.from(7);

final _call = provider.FunctionCall(
  contractAddress: Felt(BigInt.from(0xbeef)),
  entryPointSelector: getSelectorByName('approve'),
  calldata: [Felt.fromInt(1), Felt.fromInt(2)],
);

const _bounds = ResourceBounds(
  l1Gas: ResourceBound(maxAmount: '0x186a0', maxPricePerUnit: '0x5f5e100'),
  l1DataGas: ResourceBound(maxAmount: '0x186a0', maxPricePerUnit: '0x3e8'),
  l2Gas: ResourceBound(maxAmount: '0x5f5e100', maxPricePerUnit: '0x64'),
);

Map<String, provider.ResourceBounds> _sdkBounds() => {
      'l1_gas': provider.ResourceBounds(
        maxAmount: Felt.fromHexString(_bounds.l1Gas.maxAmount),
        maxPricePerUnit: Felt.fromHexString(_bounds.l1Gas.maxPricePerUnit),
      ),
      'l1_data_gas': provider.ResourceBounds(
        maxAmount: Felt.fromHexString(_bounds.l1DataGas.maxAmount),
        maxPricePerUnit: Felt.fromHexString(_bounds.l1DataGas.maxPricePerUnit),
      ),
      'l2_gas': provider.ResourceBounds(
        maxAmount: Felt.fromHexString(_bounds.l2Gas.maxAmount),
        maxPricePerUnit: Felt.fromHexString(_bounds.l2Gas.maxPricePerUnit),
      ),
    };

BigInt _ourHash({required List<BigInt> proofFacts}) =>
    provedInvokeTransactionHash(
      senderAddress: _sender,
      calldata: functionCallsToCalldata(functionCalls: [_call])
          .map((f) => f.toBigInt())
          .toList(),
      chainId: _chainId,
      nonce: _nonce,
      resourceBounds: _bounds,
      proofFacts: proofFacts,
    );

void main() {
  test('with no proof facts it agrees with the SDK, felt for felt', () async {
    // Compared through signatures because the SDK keeps its hash private. Two
    // signatures over the same key match only if the hashes did.
    final fromSdk = await StarkAccountSigner(
      signer: StarkSigner(privateKey: _privateKey),
    ).signInvokeTransactionsV3(
      transactions: [_call],
      senderAddress: Felt(_sender),
      chainId: Felt(_chainId),
      nonce: Felt(_nonce),
      resourceBounds: _sdkBounds(),
      accountDeploymentData: const [],
      paymasterData: const [],
      tip: Felt.zero,
      feeDataAvailabilityMode: 'L1',
      nonceDataAvailabilityMode: 'L1',
    );

    final fromUs = await StarkSigner(privateKey: _privateKey)
        .sign(_ourHash(proofFacts: const []), BigInt.from(32));

    expect(fromUs.map((f) => f.toHexString()).toList(),
        equals(fromSdk.map((f) => f.toHexString()).toList()));
  });

  test('proof facts change the hash', () {
    // The whole reason this file exists: signing without them produces a
    // signature over a different message, and the account says only "invalid
    // signature".
    expect(
      _ourHash(proofFacts: [BigInt.one]),
      isNot(equals(_ourHash(proofFacts: const []))),
    );
  });

  test('different facts give different hashes', () {
    expect(
      _ourHash(proofFacts: [BigInt.one, BigInt.two]),
      isNot(equals(_ourHash(proofFacts: [BigInt.two, BigInt.one]))),
    );
  });

  test('an empty fact list is the same as none at all', () {
    // Matching how the field is omitted from the transaction rather than sent
    // as an empty array.
    expect(_ourHash(proofFacts: const []), equals(_ourHash(proofFacts: [])));
  });

  group('the fee field', () {
    test('depends on the tip', () {
      expect(
        hashFeeFields(tip: BigInt.zero, bounds: _bounds),
        isNot(equals(hashFeeFields(tip: BigInt.one, bounds: _bounds))),
      );
    });

    test('depends on every bound', () {
      const changed = ResourceBounds(
        l1Gas: ResourceBound(maxAmount: '0x1', maxPricePerUnit: '0x5f5e100'),
        l1DataGas: ResourceBound(maxAmount: '0x186a0', maxPricePerUnit: '0x3e8'),
        l2Gas: ResourceBound(maxAmount: '0x5f5e100', maxPricePerUnit: '0x64'),
      );
      expect(
        hashFeeFields(tip: BigInt.zero, bounds: _bounds),
        isNot(equals(hashFeeFields(tip: BigInt.zero, bounds: changed))),
      );
    });
  });

  group('data availability modes', () {
    test('both on L1 is zero', () {
      expect(packDataAvailabilityModes(), equals(BigInt.zero));
    });

    test('each mode occupies its own field', () {
      expect(
        packDataAvailabilityModes(nonceOnL1: false),
        equals(BigInt.one << 32),
      );
      expect(packDataAvailabilityModes(feeOnL1: false), equals(BigInt.one));
    });
  });
}
