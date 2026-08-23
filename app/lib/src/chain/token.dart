/// The tokens the wallet knows about.
///
/// Addresses here are verified against the live chains by `tool/verify_tokens
/// .dart` rather than copied from memory. A wrong token address in a wallet is
/// not a display bug: it is funds sent to a contract that will not give them
/// back.
library;

import 'package:starknet/starknet.dart';

class TipToken {
  const TipToken({
    required this.address,
    required this.symbol,
    required this.name,
    required this.decimals,
  });

  final Felt address;
  final String symbol;
  final String name;

  /// Smallest units per whole token. Read from the contract, never assumed:
  /// STRK and ETH use 18, USDC uses 6, and treating one as the other is a
  /// millionfold error in the direction the user notices least.
  final int decimals;

  @override
  bool operator ==(Object other) =>
      other is TipToken && other.address == address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => '$symbol(${address.toHexString()})';
}

/// Stands in where a token's identity is not needed, only its formatting.
///
/// Address one, which no real token uses.
final placeholderTokenAddress = Felt.fromInt(1);

class TipTokens {
  TipTokens._();

  /// STRK is the fee token and has the same address on every chain.
  static final strk = TipToken(
    address: Felt.fromHexString(
      '0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d',
    ),
    symbol: 'STRK',
    name: 'Starknet Token',
    decimals: 18,
  );

  /// Bridged ether. Same address on every chain, as with STRK.
  static final eth = TipToken(
    address: Felt.fromHexString(
      '0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7',
    ),
    symbol: 'ETH',
    name: 'Ether',
    decimals: 18,
  );

  static final usdcMainnet = TipToken(
    address: Felt.fromHexString(
      '0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8',
    ),
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6,
  );

  static final mainnet = <TipToken>[strk, eth, usdcMainnet];

  /// Sepolia carries no stablecoin worth listing. STRK and ETH are the two the
  /// faucet hands out, and they are the two the wallet needs to be testable.
  static final sepolia = <TipToken>[strk, eth];
}
