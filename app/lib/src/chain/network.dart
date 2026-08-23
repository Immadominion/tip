/// Which chain the wallet is pointed at, and everything that changes with it.
///
/// Every chain-dependent constant lives here. Nothing else in the app should
/// hard-code an RPC URL, a token address, or an explorer link, so that pointing
/// the wallet at a different chain is a one-line change rather than a search.
library;

import 'package:starknet/starknet.dart';

import 'token.dart';

enum TipChain { mainnet, sepolia }

class TipNetwork {
  const TipNetwork({
    required this.chain,
    required this.label,
    required this.rpcUrls,
    required this.chainId,
    required this.explorerBase,
    required this.tokens,
    this.poolAddress,
  });

  final TipChain chain;

  /// Shown in the UI when the wallet is not on mainnet. Mainnet is the
  /// unmarked default; a testnet must always announce itself, because a user
  /// who thinks testnet funds are real is a user about to be disappointed.
  final String label;

  /// Endpoints to try, in order.
  ///
  /// A list rather than one URL because these are free public nodes and they
  /// do go down: Cartridge's mainnet endpoint was returning 502 while its
  /// Sepolia endpoint was healthy, on the same afternoon. A wallet that shows
  /// a blank balance because one node blinked is a wallet nobody trusts, so
  /// the client falls through to the next one.
  final List<Uri> rpcUrls;

  Uri get rpcUrl => rpcUrls.first;

  /// Chain ID as the ASCII short string the protocol uses, not a number.
  final Felt chainId;

  /// Base for building a transaction or address link.
  final String explorerBase;

  /// Tokens the wallet shows by default.
  final List<TipToken> tokens;

  /// The STRK20 privacy pool, when one is deployed on this chain.
  ///
  /// Nullable on purpose. Only the Sepolia pool address is confirmed against a
  /// live contract; inventing a mainnet address here would produce a wallet
  /// that silently sends funds nowhere.
  final Felt? poolAddress;

  bool get isMainnet => chain == TipChain.mainnet;

  /// Native fee token. Fees on Starknet are paid in STRK.
  TipToken get feeToken => tokens.firstWhere((t) => t.symbol == 'STRK');

  TipToken? tokenAt(Felt address) {
    for (final token in tokens) {
      if (token.address == address) return token;
    }
    return null;
  }

  String transactionUrl(Felt hash) => '$explorerBase/tx/${hash.toHexString()}';

  String addressUrl(Felt address) =>
      '$explorerBase/contract/${address.toHexString()}';

  static final mainnet = TipNetwork(
    chain: TipChain.mainnet,
    label: 'Mainnet',
    rpcUrls: _mainnetRpcs,
    chainId: _snMain,
    explorerBase: 'https://voyager.online',
    tokens: TipTokens.mainnet,
  );

  static final sepolia = TipNetwork(
    chain: TipChain.sepolia,
    label: 'Sepolia testnet',
    rpcUrls: _sepoliaRpcs,
    chainId: _snSepolia,
    explorerBase: 'https://sepolia.voyager.online',
    tokens: TipTokens.sepolia,
    poolAddress: _sepoliaPool,
  );

  static TipNetwork of(TipChain chain) =>
      chain == TipChain.mainnet ? mainnet : sepolia;
}

/// Endpoints confirmed by hand to answer `starknet_call`, in preference order.
///
/// Blast is deliberately absent: it now answers every request with a notice
/// that it has shut down, which a naive client reads as a live error rather
/// than a dead host. Lava's mainnet node is last because it still reports spec
/// 0.8.1 while the others are on 0.9.0.
///
/// All of these are rate limited. A keyed provider should lead this list
/// before the wallet sees real load.
final _mainnetRpcs = [
  Uri.parse('https://api.zan.top/public/starknet-mainnet'),
  Uri.parse('https://api.cartridge.gg/x/starknet/mainnet'),
  Uri.parse('https://rpc.starknet.lava.build'),
];

final _sepoliaRpcs = [
  Uri.parse('https://api.cartridge.gg/x/starknet/sepolia'),
  Uri.parse('https://api.zan.top/public/starknet-sepolia'),
];

/// `SN_MAIN` and `SN_SEPOLIA` as ASCII short strings.
final _snMain = Felt.fromHexString('0x534e5f4d41494e');
final _snSepolia = Felt.fromHexString('0x534e5f5345504f4c4941');

/// Confirmed live: version 2.0, deposit fee 2 STRK.
final _sepoliaPool = Felt.fromHexString(
  '0x0254a6b2997ef52e9f830ce1f543f6b29768295e8d17e2267d672c552cfe0d91',
);
