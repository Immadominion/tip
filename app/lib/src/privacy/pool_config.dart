/// Where the pool and its services live.
///
/// Endpoints are supplied at build time rather than compiled in. The Sepolia
/// environment was shared in confidence and is not ours to publish, and a
/// mainnet deployment will point somewhere else again, so neither belongs in
/// the repository.
///
///   flutter run \
///     --dart-define=STRK20_POOL=0x... \
///     --dart-define=STRK20_PROVER=https://... \
///     --dart-define=STRK20_DISCOVERY=https://... \
///     --dart-define=STRK20_RPC=https://... \
///     --dart-define=STRK20_OHTTP_KEY=BASE64_KEY_CONFIG
library;

import 'dart:convert';
import 'dart:typed_data';

class PoolConfig {
  const PoolConfig({
    required this.poolAddress,
    required this.provingUrl,
    required this.discoveryUrl,
    required this.rpcUrl,
    this.pinnedOhttpKey,
  });

  /// Reads the configuration a build was given, or null when it was given none.
  ///
  /// Null rather than throwing: the wallet works without the privacy layer and
  /// says so, and a build with no pool configured should show that state rather
  /// than fail to start.
  static PoolConfig? fromEnvironment() {
    const pool = String.fromEnvironment('STRK20_POOL');
    const prover = String.fromEnvironment('STRK20_PROVER');
    const discovery = String.fromEnvironment('STRK20_DISCOVERY');
    const rpc = String.fromEnvironment('STRK20_RPC');

    if (pool.isEmpty || prover.isEmpty || discovery.isEmpty || rpc.isEmpty) {
      return null;
    }
    const pinned = String.fromEnvironment('STRK20_OHTTP_KEY');

    return PoolConfig(
      poolAddress: BigInt.parse(pool.replaceFirst('0x', ''), radix: 16),
      provingUrl: Uri.parse(prover),
      discoveryUrl: Uri.parse(discovery),
      rpcUrl: Uri.parse(rpc),
      pinnedOhttpKey:
          pinned.isEmpty ? null : Uint8List.fromList(base64.decode(pinned)),
    );
  }

  final BigInt poolAddress;
  final Uri provingUrl;
  final Uri discoveryUrl;

  /// The node private transactions are submitted through.
  ///
  /// Not the same as the wallet's ordinary RPC list. A proved submission
  /// carries two fields standard Starknet RPC does not define, so it needs a
  /// node that accepts them.
  final Uri rpcUrl;

  /// The OHTTP key configuration, pinned at build time.
  ///
  /// Worth setting. Without it the config is fetched over the same TLS the
  /// encryption exists to be independent of, so anything terminating that TLS
  /// can substitute its own key and read every request after it. Unpinned
  /// OHTTP still hides the payload from a passive observer and from a CDN that
  /// is merely careless; pinned OHTTP is what holds against one that is not.
  final Uint8List? pinnedOhttpKey;

  String get poolHex => '0x${poolAddress.toRadixString(16)}';
}
