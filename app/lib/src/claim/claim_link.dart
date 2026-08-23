/// A tip that can be sent to someone who has no wallet.
///
/// The mechanism is a throwaway account. A random secret derives a Starknet
/// key, the sender pays the address that key controls, and the link carries
/// the secret. Whoever holds the link controls the funds until they sweep
/// them, and nothing is escrowed, custodied, or held by us.
///
/// What that buys, and what it costs, both matter:
///
/// It works with no server, no contract, and no account on the recipient's
/// side. They install the app, open the link, and the money is theirs.
///
/// It is bearer money. Anyone who reads the link can take it, so a link posted
/// in a public channel is a link anyone can claim, and a link sent over a
/// medium that keeps history stays claimable by whoever can read that history
/// later. The UI has to say so.
///
/// And the throwaway account has to be deployed before it can send, so a tip
/// costs one deployment and one transfer in fees. Tips below that are not
/// worth sending, and the app refuses them rather than producing a link that
/// cannot be claimed.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:starknet/starknet.dart';
import 'package:tip_privacy/tip_privacy.dart';

import '../chain/signing_account.dart';

/// Domain tag keeping a claim key away from every other key this app derives.
const claimKeyDomainTag = 'TIP_CLAIM_KEY:V1';

/// Bytes of entropy in a claim secret.
///
/// Sixteen. The secret is the only thing protecting the funds and it travels
/// in a URL, so it has to be short enough to share and long enough that
/// guessing one is hopeless. 128 bits encodes to 22 characters.
const claimSecretBytes = 16;

/// Where a claim link points. The path is handled by the app, and the secret
/// lives in the fragment.
const claimLinkHost = 'usetip.xyz';
const claimLinkPath = '/claim';

class ClaimLinkException implements Exception {
  const ClaimLinkException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A claim secret, and the throwaway account it controls.
class ClaimKey {
  const ClaimKey({
    required this.secret,
    required this.privateKey,
    required this.publicKey,
    required this.address,
  });

  final Uint8List secret;
  final Felt privateKey;
  final Felt publicKey;

  /// Address of the throwaway account. Payable before it is deployed, which
  /// is the whole reason this works.
  final Felt address;

  /// What the transfer layer needs to act as this throwaway account.
  SigningAccount get signing => SigningAccount(
        privateKey: privateKey,
        publicKey: publicKey,
        address: address,
      );

  /// The secret, URL safe and unpadded.
  String get token => base64Url.encode(secret).replaceAll('=', '');

  /// A link to hand to someone.
  ///
  /// The secret goes in the fragment rather than the query. A fragment is not
  /// sent to the server when the URL is opened, so a claim cannot leak into a
  /// web server's access log on the way to the app.
  Uri link({String host = claimLinkHost}) => Uri(
        scheme: 'https',
        host: host,
        path: claimLinkPath,
        fragment: token,
      );
}

class ClaimLinks {
  ClaimLinks._();

  /// Creates a fresh claim key.
  ///
  /// [random] must be a cryptographic source. The default is, and the
  /// parameter exists so tests can be deterministic, never so production can
  /// be cheap about it.
  static ClaimKey create({
    required Felt accountClassHash,
    Random? random,
  }) {
    final source = random ?? Random.secure();
    final secret = Uint8List.fromList(
      List<int>.generate(claimSecretBytes, (_) => source.nextInt(256)),
    );
    return fromSecret(secret: secret, accountClassHash: accountClassHash);
  }

  /// Rebuilds a claim key from its secret.
  static ClaimKey fromSecret({
    required Uint8List secret,
    required Felt accountClassHash,
  }) {
    if (secret.isEmpty) {
      throw const ClaimLinkException('That claim link is empty');
    }

    // Poseidon over the tagged secret, folded into the curve order. Zero is
    // not a usable key, and the fallback costs nothing to carry.
    var scalar = poseidonHash([
      claimKeyDomainTag,
      BigInt.from(secret.length),
      _packBytes(secret),
    ]) % curveOrder;
    if (scalar == BigInt.zero) scalar = BigInt.one;

    final privateKey = Felt(scalar);
    final publicKey = StarkSigner(privateKey: privateKey).publicKey;

    return ClaimKey(
      secret: secret,
      privateKey: privateKey,
      publicKey: publicKey,
      address: Contract.computeAddress(
        classHash: accountClassHash,
        calldata: [publicKey],
        salt: publicKey,
      ),
    );
  }

  /// Reads a link, or the bare token out of one.
  ///
  /// Accepts a whole URL or just the secret, because people paste both. The
  /// query string is accepted too: some chat clients rewrite fragments, and
  /// losing a real tip to a link rewriter would be worse than the slightly
  /// wider surface.
  static ClaimKey parse(String input, {required Felt accountClassHash}) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const ClaimLinkException('Paste a claim link');
    }

    var token = trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) {
      token = uri.fragment.isNotEmpty
          ? uri.fragment
          : (uri.queryParameters['c'] ?? '');
      if (token.isEmpty) {
        throw const ClaimLinkException(
          'That link has no claim code in it. Copy the whole link.',
        );
      }
    }

    final secret = _decodeToken(token);
    return fromSecret(secret: secret, accountClassHash: accountClassHash);
  }

  static ClaimKey? tryParse(String input, {required Felt accountClassHash}) {
    try {
      return parse(input, accountClassHash: accountClassHash);
    } on ClaimLinkException {
      return null;
    }
  }

  static Uint8List _decodeToken(String token) {
    // Padding is stripped when the link is made, and some clients add it back.
    final padded = token.padRight((token.length + 3) & ~3, '=');
    try {
      final bytes = base64Url.decode(padded);
      if (bytes.length != claimSecretBytes) {
        throw const ClaimLinkException(
          'That claim code is the wrong length. It may have been cut off.',
        );
      }
      return Uint8List.fromList(bytes);
    } on FormatException {
      throw const ClaimLinkException(
        'That does not look like a claim link.',
      );
    }
  }
}

/// Packs bytes into one felt. Sixteen bytes always fit in the 251 bits a felt
/// holds, so no chunking is needed at this size.
BigInt _packBytes(Uint8List bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}
