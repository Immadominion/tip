/// The wallet's keys, and where they come from.
///
/// One seed produces everything: the Starknet account key that authorises
/// spending, and the STRK20 viewing key that decrypts incoming notes. The
/// reference client asks the user to remember a separate passphrase for the
/// viewing key; deriving both from one seed means a single thing to back up and
/// a single thing to lose, which is the honest trade for a consumer wallet.
library;

import 'package:bip39/bip39.dart' as bip39;
import 'package:starknet/starknet.dart';
import '../chain/signing_account.dart';
import 'package:tip_privacy/tip_privacy.dart';

/// A wallet's derived key material, held in memory for the session.
class WalletKeys {
  const WalletKeys({
    required this.mnemonic,
    required this.accountPrivateKey,
    required this.accountPublicKey,
    required this.accountAddress,
    required this.viewingKey,
  });

  /// The BIP39 phrase. The only thing a user needs to write down.
  final String mnemonic;

  final Felt accountPrivateKey;
  final Felt accountPublicKey;
  final Felt accountAddress;

  /// The STRK20 viewing key, derived from the same seed.
  final BigInt viewingKey;

  /// What the transfer layer needs, and nothing more.
  SigningAccount get signing => SigningAccount(
        privateKey: accountPrivateKey,
        publicKey: accountPublicKey,
        address: accountAddress,
      );

  /// The address, shortened for display.
  String get shortAddress {
    final hex = accountAddress.toHexString();
    if (hex.length <= 12) return hex;
    return '${hex.substring(0, 6)}...${hex.substring(hex.length - 4)}';
  }
}

/// Derives a wallet's keys from a seed phrase.
class WalletFactory {
  const WalletFactory({required this.accountClassHash});

  /// Class hash of the account contract that will be deployed for the user.
  final Felt accountClassHash;

  /// Creates a fresh 24-word seed phrase.
  ///
  /// 256 bits of entropy rather than the 128 a 12-word phrase carries. The
  /// phrase is longer to write down, but this is the one secret behind both
  /// spending authority and the entire transaction history, so the stronger
  /// default is worth the extra words.
  static String generateMnemonic() => bip39.generateMnemonic(strength: 256);

  /// Whether [mnemonic] is a well-formed BIP39 phrase.
  ///
  /// Checks the checksum, so a mistyped word is caught at import rather than
  /// silently deriving a different, empty wallet.
  static bool isValidMnemonic(String mnemonic) =>
      bip39.validateMnemonic(mnemonic.trim());

  /// Derives every key from [mnemonic].
  WalletKeys deriveFrom(String mnemonic) {
    final normalised = mnemonic.trim();
    if (!isValidMnemonic(normalised)) {
      throw ArgumentError('Not a valid BIP39 seed phrase');
    }

    // Standard Starknet derivation path.
    final privateKey = derivePrivateKey(mnemonic: normalised);
    final signer = StarkSigner(privateKey: privateKey);
    final publicKey = signer.publicKey;

    // The account is a contract, and its address is determined by the class
    // hash and constructor arguments before it is ever deployed. That is what
    // lets the app show an address the user can be paid at immediately.
    final address = Contract.computeAddress(
      classHash: accountClassHash,
      calldata: [publicKey],
      salt: publicKey,
    );

    // The viewing key comes from the raw seed bytes rather than the account
    // key. Both descend from the same phrase, but a domain tag keeps them
    // independent, so exposing one does not expose the other.
    final seedBytes = bip39.mnemonicToSeed(normalised);
    final viewingKey = deriveViewingKeyFromSeed(
      seed: seedBytes,
      accountAddress: address.toBigInt(),
    );

    return WalletKeys(
      mnemonic: normalised,
      accountPrivateKey: privateKey,
      accountPublicKey: publicKey,
      accountAddress: address,
      viewingKey: viewingKey,
    );
  }
}
