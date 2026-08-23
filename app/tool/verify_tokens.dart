/// Checks every token in the registry against the chain it claims to live on.
///
/// A token address copied from memory is the kind of mistake that passes code
/// review, passes unit tests, and then sends someone's money to a contract
/// that has never heard of them. This asks the contracts themselves.
///
///   dart run tool/verify_tokens.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:starknet/starknet.dart';
import 'package:tip/src/chain/network.dart';

/// Tries each endpoint in turn, so one dead node does not read as a bad token.
Future<List<String>> _call(
  List<Uri> endpoints,
  Felt contract,
  String selector, {
  String method = 'starknet_call',
}) async {
  Object? lastError;
  for (final endpoint in endpoints) {
    try {
      return await _callOne(endpoint, contract, selector, method: method);
    } catch (error) {
      lastError = error;
    }
  }
  throw StateError('every endpoint failed: $lastError');
}

Future<List<String>> _callOne(
  Uri rpc,
  Felt contract,
  String selector, {
  String method = 'starknet_call',
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(rpc);
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': method == 'starknet_getClass'
            ? ['latest', contract.toHexString()]
            : [
                {
                  'contract_address': contract.toHexString(),
                  'entry_point_selector':
                      getSelectorByName(selector).toHexString(),
                  'calldata': <String>[],
                },
                'latest',
              ],
      }),
    );
    final response = await request.close();
    final body =
        jsonDecode(await response.transform(utf8.decoder).join()) as Map;
    if (body.containsKey('error')) {
      throw StateError('$selector: ${jsonEncode(body['error'])}');
    }
    final result = body['result'];
    if (result is! List) return const ['0x1'];
    return result.cast<String>();
  } finally {
    client.close();
  }
}

/// Decodes a token's name or symbol.
///
/// Starknet has two conventions in the wild. The tokens deployed before Cairo 1
/// return a single felt holding an ASCII short string; newer ones return a
/// ByteArray. Both are handled, because both are on chain right now.
String _decodeText(List<String> felts) {
  if (felts.length == 1) return _shortString(felts.single);

  // ByteArray: [num_full_words, ...words, pending_word, pending_len]
  final fullWords = int.parse(felts.first.substring(2), radix: 16);
  final buffer = StringBuffer();
  for (var i = 1; i <= fullWords; i++) {
    buffer.write(_shortString(felts[i]));
  }
  final pendingLength = int.parse(felts.last.substring(2), radix: 16);
  if (pendingLength > 0) {
    buffer.write(_shortString(felts[felts.length - 2]));
  }
  return buffer.toString();
}

String _shortString(String hex) {
  var digits = hex.substring(2);
  if (digits.length.isOdd) digits = '0$digits';
  final bytes = <int>[];
  for (var i = 0; i < digits.length; i += 2) {
    bytes.add(int.parse(digits.substring(i, i + 2), radix: 16));
  }
  return String.fromCharCodes(bytes.where((b) => b != 0));
}

Future<void> main() async {
  var failures = 0;

  for (final network in [TipNetwork.mainnet, TipNetwork.sepolia]) {
    stdout.writeln("\n${network.label}");

    for (final token in network.tokens) {
      try {
        final symbol = _decodeText(
          await _call(network.rpcUrls, token.address, 'symbol'),
        );
        final name = _decodeText(
          await _call(network.rpcUrls, token.address, 'name'),
        );
        final decimals = int.parse(
          (await _call(network.rpcUrls, token.address, 'decimals'))
              .single
              .substring(2),
          radix: 16,
        );

        final problems = <String>[
          if (symbol != token.symbol) 'symbol is "$symbol", registry says "${token.symbol}"',
          if (decimals != token.decimals) 'decimals is $decimals, registry says ${token.decimals}',
        ];

        if (problems.isEmpty) {
          stdout.writeln('  ok    ${token.symbol.padRight(6)} $name, $decimals decimals');
        } else {
          failures++;
          stdout.writeln('  WRONG ${token.symbol.padRight(6)} ${problems.join('; ')}');
        }
      } catch (error) {
        failures++;
        stdout.writeln('  FAIL  ${token.symbol.padRight(6)} $error');
      }
    }

    try {
      await _call(
        network.rpcUrls,
        network.accountClassHash,
        'nothing',
        method: 'starknet_getClass',
      );
      stdout.writeln('  ok    account class declared');
    } catch (error) {
      failures++;
      stdout.writeln('  FAIL  account class $error');
    }

    final pool = network.poolAddress;
    if (pool != null) {
      try {
        final version = _decodeText(await _call(network.rpcUrls, pool, 'get_version'));
        stdout.writeln('  ok    pool   version $version');
      } catch (error) {
        failures++;
        stdout.writeln('  FAIL  pool   $error');
      }
    }
  }

  stdout.writeln(failures == 0 ? '\nRegistry matches the chains.' : '\n$failures problem(s).');
  exit(failures == 0 ? 0 : 1);
}
