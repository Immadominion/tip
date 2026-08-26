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
///     --dart-define=STRK20_RPC=https://...
library;

class PoolConfig {
  const PoolConfig({
    required this.poolAddress,
    required this.provingUrl,
    required this.discoveryUrl,
    required this.rpcUrl,
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
    return PoolConfig(
      poolAddress: BigInt.parse(pool.replaceFirst('0x', ''), radix: 16),
      provingUrl: Uri.parse(prover),
      discoveryUrl: Uri.parse(discovery),
      rpcUrl: Uri.parse(rpc),
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

  String get poolHex => '0x${poolAddress.toRadixString(16)}';
}
