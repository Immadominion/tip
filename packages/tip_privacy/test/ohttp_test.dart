/// Oblivious HTTP checked against the complete worked exchange in RFC 9458
/// Appendix A, reproducing the encapsulated request byte for byte and opening
/// the RFC's own encapsulated response.
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tip_privacy/tip_privacy.dart';

Uint8List _hex(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The bare key configuration from RFC 9458 Appendix A.
const _configHex = '01002031e1f05a740102115220e9af918f738674aec95f54db6e04eb'
    '705aae8e79815500080001000100010003';

/// The client's ephemeral secret from the same appendix, so the encapsulation
/// is deterministic and can be compared against the published bytes.
const _ephemeralSecretHex =
    'bc51d5e930bda26589890ac7032f70ad12e4ecb37abb1b65b1256c9c48999c73';

void main() {
  group('key configuration parsing', () {
    test('parses the Appendix A configuration', () {
      final config = OhttpKeyConfig.parse(_hex(_configHex));

      expect(config.keyId, equals(1));
      expect(config.kemId, equals(0x0020));
      expect(
        _toHex(config.publicKey),
        equals('31e1f05a740102115220e9af918f738674aec95f54db6e04eb705aae8e79'
            '8155'),
      );
      expect(config.symmetricAlgorithms, hasLength(2));
      expect(config.symmetricAlgorithms[0].kdfId, equals(0x0001));
      expect(config.symmetricAlgorithms[0].aeadId, equals(0x0001));
      // The second pair offers ChaCha20Poly1305, which this client does not
      // implement; the first pair is the one it uses.
      expect(config.symmetricAlgorithms[1].aeadId, equals(0x0003));
      expect(config.supportsOurSuite, isTrue);
    });

    test('parses the same config wrapped in an ohttp-keys list', () {
      // The list form prefixes each config with its two-byte length: 45 = 0x2d.
      final configs = OhttpKeyConfig.parseList(_hex('002d$_configHex'));
      expect(configs, hasLength(1));
      expect(configs.single.keyId, equals(1));
    });

    test('parses several configurations from one document', () {
      final configs =
          OhttpKeyConfig.parseList(_hex('002d$_configHex' '002d$_configHex'));
      expect(configs, hasLength(2));
    });

    test('rejects a list whose length prefix overruns the buffer', () {
      expect(
        () => OhttpKeyConfig.parseList(_hex('00ff$_configHex')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a list whose prefix disagrees with the contents', () {
      // Claims 20 bytes for a 45-byte config.
      expect(
        () => OhttpKeyConfig.parseList(_hex('0014$_configHex')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects an empty document', () {
      expect(
        () => OhttpKeyConfig.parseList(Uint8List(0)),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a bare config with trailing bytes', () {
      expect(
        () => OhttpKeyConfig.parse(_hex('${_configHex}ff')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects an unknown KEM id rather than guessing a key length', () {
      expect(
        () => OhttpKeyConfig.parse(_hex('0100ff0000080001000100010003')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a symmetric algorithms length that is not a multiple of 4',
        () {
      final broken = _configHex.replaceFirst('0008', '0006');
      expect(
        () => OhttpKeyConfig.parse(_hex(broken)),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('reports an unsupported suite instead of failing later', () {
      // Only ChaCha20Poly1305 on offer.
      final chachaOnly = _hex('01002031e1f05a740102115220e9af918f738674aec95f'
          '54db6e04eb705aae8e798155000400010003');
      expect(OhttpKeyConfig.parse(chachaOnly).supportsOurSuite, isFalse);
    });
  });

  group('RFC 9458 Appendix A round trip', () {
    test('reproduces the encapsulated request byte for byte', () async {
      final encapsulated = await encapsulateRequest(
        config: OhttpKeyConfig.parse(_hex(_configHex)),
        request: const BinaryHttpRequest(
          method: 'GET',
          scheme: 'https',
          authority: 'example.com',
          path: '/',
        ),
        ephemeral: await keyPairFromSecret(_hex(_ephemeralSecretHex)),
      );

      expect(
        _toHex(encapsulated.body),
        equals('010020000100014b28f881333e7c164ffc499ad9796f877f4e1051ee6d31'
            'bad19dec96c208b4726374e469135906992e1268c594d2a10c695d858c40a0'
            '26e7965e7d86b83dd440b2c0185204b4d63525'),
      );
    });

    test('encodes the inner request exactly as the RFC does', () async {
      // Guards the BHTTP layer against the OHTTP vector independently.
      const request = BinaryHttpRequest(
        method: 'GET',
        scheme: 'https',
        authority: 'example.com',
        path: '/',
      );
      expect(
        _toHex(request.encode()),
        // The RFC's plaintext omits the trailing empty content and trailer
        // sections; ours writes them explicitly, which is also valid.
        startsWith('00034745540568747470730b6578616d706c652e636f6d012f'),
      );
    });

    test('opens the encapsulated response from the RFC', () async {
      final encapsulated = await encapsulateRequest(
        config: OhttpKeyConfig.parse(_hex(_configHex)),
        request: const BinaryHttpRequest(
          method: 'GET',
          scheme: 'https',
          authority: 'example.com',
          path: '/',
        ),
        ephemeral: await keyPairFromSecret(_hex(_ephemeralSecretHex)),
      );

      final response = await decapsulateResponse(
        context: encapsulated.context,
        body: _hex('c789e7151fcba46158ca84b04464910d86f9013e404feea014e7be4a'
            '441f234f857fbd'),
      );

      expect(response.statusCode, equals(200));
    });

    test('exports the response secret the RFC specifies', () async {
      final encapsulated = await encapsulateRequest(
        config: OhttpKeyConfig.parse(_hex(_configHex)),
        request: const BinaryHttpRequest(
          method: 'GET',
          scheme: 'https',
          authority: 'example.com',
          path: '/',
        ),
        ephemeral: await keyPairFromSecret(_hex(_ephemeralSecretHex)),
      );

      // max(Nn, Nk) = 16 for AES-128-GCM, not Nk by coincidence.
      expect(responseNonceLength, equals(16));

      final secret = await encapsulated.context
          .export('message/bhttp response'.codeUnits, responseNonceLength);
      expect(_toHex(secret), equals('62d87a6ba569ee81014c2641f52bea36'));
    });
  });

  group('response decapsulation failures', () {
    Future<HpkeContext> freshContext() async => (await encapsulateRequest(
          config: OhttpKeyConfig.parse(_hex(_configHex)),
          request: const BinaryHttpRequest(
            method: 'GET',
            scheme: 'https',
            path: '/',
          ),
        ))
            .context;

    test('rejects a response that is too short', () async {
      await expectLater(
        decapsulateResponse(context: await freshContext(), body: Uint8List(20)),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a response encrypted under a different context', () async {
      // A fresh context has a different ephemeral key, so the derived response
      // key differs and authentication must fail.
      await expectLater(
        decapsulateResponse(
          context: await freshContext(),
          body: _hex('c789e7151fcba46158ca84b04464910d86f9013e404feea014e7be'
              '4a441f234f857fbd'),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('suite negotiation', () {
    test('refuses a gateway that cannot do our suite', () async {
      final chachaOnly = _hex('01002031e1f05a740102115220e9af918f738674aec95f'
          '54db6e04eb705aae8e798155000400010003');
      await expectLater(
        encapsulateRequest(
          config: OhttpKeyConfig.parse(chachaOnly),
          request: const BinaryHttpRequest(
            method: 'GET',
            scheme: 'https',
            path: '/',
          ),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });
  });
}
