/// Varint and Binary HTTP encoding, checked against the worked examples in
/// RFC 9000 section 16 and RFC 9292 Appendix A.
library;

import 'dart:convert';
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

void main() {
  group('varint encoding', () {
    test('uses the shortest form at each boundary', () {
      expect(_toHex(encodeVarint(0)), equals('00'));
      expect(_toHex(encodeVarint(63)), equals('3f'));
      // 64 no longer fits in 6 bits, so it moves to the 2-byte form.
      expect(_toHex(encodeVarint(64)), equals('4040'));
      expect(_toHex(encodeVarint(16383)), equals('7fff'));
      expect(_toHex(encodeVarint(16384)), equals('80004000'));
      expect(_toHex(encodeVarint(1073741823)), equals('bfffffff'));
      expect(_toHex(encodeVarint(1073741824)), equals('c000000040000000'));
    });

    test('matches the RFC 9000 section 16 examples', () {
      // The RFC's four worked examples, one per length class.
      expect(decodeVarint(_hex('c2197c5eff14e88c'), 0).value,
          equals(151288809941952652));
      expect(decodeVarint(_hex('9d7f3e7d'), 0).value, equals(494878333));
      expect(decodeVarint(_hex('7bbd'), 0).value, equals(15293));
      expect(decodeVarint(_hex('25'), 0).value, equals(37));
    });

    test('accepts non-minimal encodings', () {
      // RFC 9292 section 3 explicitly permits these. A decoder that rejected
      // them would fail on valid messages from a conforming peer.
      expect(decodeVarint(_hex('4025'), 0).value, equals(37));
      expect(decodeVarint(_hex('80000025'), 0).value, equals(37));
      expect(decodeVarint(_hex('c000000000000025'), 0).value, equals(37));
    });

    test('round-trips across the length classes', () {
      for (final value in [0, 1, 63, 64, 1000, 16383, 16384, 1073741823]) {
        final encoded = encodeVarint(value);
        final decoded = decodeVarint(encoded, 0);
        expect(decoded.value, equals(value));
        expect(decoded.offset, equals(encoded.length));
      }
    });

    test('reports its end offset so fields can be chained', () {
      final buffer = _hex('25' '7bbd' '00');
      final first = decodeVarint(buffer, 0);
      expect(first.value, equals(37));
      final second = decodeVarint(buffer, first.offset);
      expect(second.value, equals(15293));
      expect(decodeVarint(buffer, second.offset).value, equals(0));
    });

    test('rejects a truncated varint', () {
      expect(
          () => decodeVarint(_hex('7b'), 0), throwsA(isA<ProtocolException>()));
      expect(() => decodeVarint(Uint8List(0), 0),
          throwsA(isA<ProtocolException>()));
    });

    test('rejects a negative value', () {
      expect(() => encodeVarint(-1), throwsA(isA<ArgumentError>()));
    });
  });

  group('BinaryHttpRequest', () {
    test('matches the RFC 9292 Figure 8 known-length request', () {
      // GET /hello.txt with the RFC's three header fields, byte for byte.
      const expected = '0003474554056874747073000a2f68656c6c6f2e747874406c'
          '0a757365722d6167656e74346375726c2f372e31362e33206c6962637572'
          '6c2f372e31362e33204f70656e53534c2f302e392e376c207a6c69622f31'
          '2e322e3304686f73740f7777772e6578616d706c652e636f6d0f61636365'
          '70742d6c616e677561676506656e2c206d690000';

      final request = BinaryHttpRequest(
        method: 'GET',
        scheme: 'https',
        path: '/hello.txt',
        headers: const {
          'user-agent': 'curl/7.16.3 libcurl/7.16.3 OpenSSL/0.9.7l zlib/1.2.3',
          'host': 'www.example.com',
          'accept-language': 'en, mi',
        },
      );

      expect(_toHex(request.encode()), equals(expected));
    });

    test('encodes an absent authority as a zero-length string', () {
      final encoded = BinaryHttpRequest(
        method: 'GET',
        scheme: 'https',
        path: '/x',
      ).encode();

      // framing(00) len(03) GET len(05) https authority(00) ...
      expect(_toHex(encoded).startsWith('0003474554056874747073' '00'), isTrue);
    });

    test('encodes a POST with a JSON body', () {
      final body = utf8.encode('{"a":1}');
      final encoded = BinaryHttpRequest(
        method: 'POST',
        scheme: 'https',
        path: '/v1/sync',
        headers: const {'content-type': 'application/json'},
        content: body,
      ).encode();

      // The body length and bytes must appear after the header section.
      final hex = _toHex(encoded);
      expect(hex, contains(_toHex(body)));
      expect(hex.startsWith('00' '04' '504f5354'), isTrue); // POST
      expect(hex.endsWith('00'), isTrue); // empty trailer section
    });

    test('lowercases field names', () {
      final encoded = BinaryHttpRequest(
        method: 'GET',
        scheme: 'https',
        path: '/',
        headers: const {'Content-Type': 'application/json'},
      ).encode();
      expect(_toHex(encoded), contains(_toHex(ascii.encode('content-type'))));
      expect(_toHex(encoded),
          isNot(contains(_toHex(ascii.encode('Content-Type')))));
    });
  });

  group('BinaryHttpResponse', () {
    test('decodes the RFC 9292 minimal 200 response', () {
      // framing(01) status(40c8 = 200) headers(00) content(00) trailers(00)
      final response = BinaryHttpResponse.decode(_hex('0140c8000000'));
      expect(response.statusCode, equals(200));
      expect(response.headers, isEmpty);
      expect(response.content, isEmpty);
    });

    test('decodes a 200 with headers and a JSON body', () {
      final body = utf8.encode('{"ok":true}');
      final builder = BytesBuilder()
        ..add(encodeVarint(1)) // framing: known-length response
        ..add(encodeVarint(200));

      final fields = BytesBuilder()
        ..add(encodeVarint(12))
        ..add(ascii.encode('content-type'))
        ..add(encodeVarint(16))
        ..add(ascii.encode('application/json'));
      final fieldBytes = fields.takeBytes();

      builder
        ..add(encodeVarint(fieldBytes.length))
        ..add(fieldBytes)
        ..add(encodeVarint(body.length))
        ..add(body)
        ..add(encodeVarint(0));

      final response = BinaryHttpResponse.decode(builder.takeBytes());
      expect(response.statusCode, equals(200));
      expect(response.headers['content-type'], equals('application/json'));
      expect(response.body, equals('{"ok":true}'));
    });

    test('skips informational responses before the final status', () {
      // A 1xx carries its own field section, so it cannot be skipped by a
      // fixed byte count. This is the case a naive parser gets wrong.
      final builder = BytesBuilder()
        ..add(encodeVarint(1))
        ..add(encodeVarint(103)) // Early Hints
        ..add(encodeVarint(4)) // its field section
        ..add(encodeVarint(1))
        ..add(ascii.encode('a'))
        ..add(encodeVarint(1))
        ..add(ascii.encode('b'))
        ..add(encodeVarint(404)) // final status
        ..add(encodeVarint(0))
        ..add(encodeVarint(0))
        ..add(encodeVarint(0));

      final response = BinaryHttpResponse.decode(builder.takeBytes());
      expect(response.statusCode, equals(404));
      // The informational block's fields must not leak into the real headers.
      expect(response.headers, isEmpty);
    });

    test('tolerates a truncated message with no content or trailers', () {
      // RFC 9292 section 3.8 permits omitting both.
      final response = BinaryHttpResponse.decode(_hex('0140c800'));
      expect(response.statusCode, equals(200));
      expect(response.content, isEmpty);
    });

    test('rejects the wrong framing indicator', () {
      // Framing 0 is a request; decoding it as a response must fail loudly.
      expect(
        () => BinaryHttpResponse.decode(_hex('0003474554')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a content length that overruns the buffer', () {
      // Claims 200 bytes of content with none present.
      expect(
        () => BinaryHttpResponse.decode(_hex('0140c80040c8')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a field section that overruns the buffer', () {
      expect(
        () => BinaryHttpResponse.decode(_hex('0140c840ff')),
        throwsA(isA<ProtocolException>()),
      );
    });
  });
}
