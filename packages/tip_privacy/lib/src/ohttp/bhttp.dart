/// Binary HTTP (RFC 9292), limited to what Oblivious HTTP needs.
///
/// OHTTP encrypts an HTTP message, and BHTTP is the encoding of the message
/// that goes inside the envelope. Only two of the four framings matter here:
/// known-length request (0) for what we send, and known-length response (1)
/// for what comes back.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import 'varint.dart';

/// Framing indicator for a known-length request.
const int framingKnownLengthRequest = 0;

/// Framing indicator for a known-length response.
const int framingKnownLengthResponse = 1;

/// An HTTP request encoded for transport inside an OHTTP envelope.
class BinaryHttpRequest {
  const BinaryHttpRequest({
    required this.method,
    required this.scheme,
    required this.path,
    this.authority = '',
    this.headers = const {},
    this.content = const [],
    this.truncateEmptyTrailingSections = true,
  });

  final String method;
  final String scheme;
  final String path;

  /// Usually empty. The gateway routes on path, and an authority here would
  /// leak whatever host the client happened to be configured with.
  final String authority;

  final Map<String, String> headers;
  final List<int> content;

  /// Whether to drop a trailing run of zero-length sections.
  ///
  /// RFC 9292 section 3.8 permits this and a decoder must read a missing
  /// section as empty, so both encodings are correct. The RFCs themselves are
  /// split: Figure 8 writes the trailing zeros, while the inner request in
  /// RFC 9458 Appendix A omits them. Truncating is the default because that is
  /// the form the OHTTP specification demonstrates, and it is what this code
  /// exists to speak.
  final bool truncateEmptyTrailingSections;

  /// Encodes this request as a known-length BHTTP message.
  Uint8List encode() {
    final out = BytesBuilder(copy: false);

    writeVarint(out, framingKnownLengthRequest);

    // Request control data, in this fixed order. An absent authority is a
    // zero-length string rather than an omitted field.
    writeVarintBytes(out, ascii.encode(method));
    writeVarintBytes(out, ascii.encode(scheme));
    writeVarintBytes(out, utf8.encode(authority));
    writeVarintBytes(out, utf8.encode(path));

    // The header section is prefixed by the total byte length of all field
    // lines, not by the number of fields.
    final fields = BytesBuilder(copy: false);
    headers.forEach((name, value) {
      // Field names are lowercase on the wire.
      writeVarintBytes(fields, utf8.encode(name.toLowerCase()));
      writeVarintBytes(fields, utf8.encode(value));
    });
    final fieldBytes = fields.takeBytes();

    // RFC 9292 section 3.8: a run of zero-length sections at the end of a
    // message may be omitted, and a decoder must read a missing section as
    // empty. Truncating is what the RFC's own examples do, so matching it
    // keeps encodings byte-identical to the spec.
    // Trailers are never generated here, so the trailer section is the first
    // candidate for truncation and content is the next.
    final needContent = content.isNotEmpty || !truncateEmptyTrailingSections;
    final needHeaders =
        fieldBytes.isNotEmpty || needContent || !truncateEmptyTrailingSections;

    if (needHeaders) {
      writeVarint(out, fieldBytes.length);
      out.add(fieldBytes);
    }
    if (needContent) {
      writeVarint(out, content.length);
      out.add(content);
    }
    if (!truncateEmptyTrailingSections) {
      writeVarint(out, 0);
    }

    return out.takeBytes();
  }
}

/// An HTTP response decoded from a BHTTP message.
class BinaryHttpResponse {
  const BinaryHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.content,
  });

  final int statusCode;
  final Map<String, String> headers;
  final List<int> content;

  /// The body decoded as UTF-8.
  String get body => utf8.decode(content, allowMalformed: true);

  /// Decodes a known-length BHTTP response.
  ///
  /// Informational (1xx) blocks are read and discarded until a final status is
  /// reached, which is what the RFC requires: each 1xx carries its own field
  /// section, and skipping them by byte count alone would desynchronise the
  /// parse.
  factory BinaryHttpResponse.decode(Uint8List bytes) {
    var offset = 0;

    final framing = decodeVarint(bytes, offset);
    offset = framing.offset;
    if (framing.value != framingKnownLengthResponse) {
      throw ProtocolException(
        'Expected a known-length BHTTP response (framing '
        '$framingKnownLengthResponse), got framing ${framing.value}',
      );
    }

    // Informational responses, then the final status.
    int status;
    while (true) {
      final read = decodeVarint(bytes, offset);
      offset = read.offset;
      status = read.value;
      if (status >= 200) break;
      if (status < 100) {
        throw ProtocolException('Invalid BHTTP status code $status');
      }
      offset = _skipFieldSection(bytes, offset);
    }

    // Any trailing run of zero-length sections may be omitted (RFC 9292
    // section 3.8), so every read past this point has to tolerate the buffer
    // simply ending. The RFC's own minimal response, 0140c8, stops right here.
    final headers = <String, String>{};
    if (offset >= bytes.length) {
      return BinaryHttpResponse(
        statusCode: status,
        headers: headers,
        content: const [],
      );
    }

    offset = _readFieldSection(bytes, offset, headers);

    if (offset >= bytes.length) {
      return BinaryHttpResponse(
        statusCode: status,
        headers: headers,
        content: const [],
      );
    }

    final contentLength = decodeVarint(bytes, offset);
    offset = contentLength.offset;
    if (offset + contentLength.value > bytes.length) {
      throw ProtocolException(
        'BHTTP content claims ${contentLength.value} bytes but only '
        '${bytes.length - offset} remain',
      );
    }
    final content =
        Uint8List.sublistView(bytes, offset, offset + contentLength.value);

    return BinaryHttpResponse(
      statusCode: status,
      headers: headers,
      content: content,
    );
  }
}

int _readFieldSection(
  Uint8List bytes,
  int offset,
  Map<String, String> into,
) {
  final sectionLength = decodeVarint(bytes, offset);
  offset = sectionLength.offset;
  final end = offset + sectionLength.value;
  if (end > bytes.length) {
    throw ProtocolException(
      'BHTTP field section claims ${sectionLength.value} bytes but only '
      '${bytes.length - offset} remain',
    );
  }

  while (offset < end) {
    final nameLength = decodeVarint(bytes, offset);
    offset = nameLength.offset;
    if (offset + nameLength.value > end) {
      throw const ProtocolException('BHTTP field name overruns its section');
    }
    final name = utf8.decode(
      Uint8List.sublistView(bytes, offset, offset + nameLength.value),
    );
    offset += nameLength.value;

    final valueLength = decodeVarint(bytes, offset);
    offset = valueLength.offset;
    if (offset + valueLength.value > end) {
      throw const ProtocolException('BHTTP field value overruns its section');
    }
    final value = utf8.decode(
      Uint8List.sublistView(bytes, offset, offset + valueLength.value),
    );
    offset += valueLength.value;

    into[name.toLowerCase()] = value;
  }

  return end;
}

int _skipFieldSection(Uint8List bytes, int offset) {
  final sectionLength = decodeVarint(bytes, offset);
  final end = sectionLength.offset + sectionLength.value;
  if (end > bytes.length) {
    throw const ProtocolException('BHTTP field section overruns the message');
  }
  return end;
}
