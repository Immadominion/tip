/// The minimum needed to sign for a Starknet account.
///
/// The wallet's own account is not the only thing this app signs for. A claim
/// link controls a throwaway account that has to deploy itself and then send
/// its balance onward, and that account has no seed phrase, no viewing key,
/// and no history. Pinning the transfer layer to the full wallet type would
/// have meant either fabricating those or duplicating the transfer logic.
library;

import 'package:starknet/starknet.dart';

class SigningAccount {
  const SigningAccount({
    required this.privateKey,
    required this.publicKey,
    required this.address,
  });

  final Felt privateKey;
  final Felt publicKey;

  /// Derived from the class hash and the public key, so it is known before the
  /// contract exists and can be paid into meanwhile.
  final Felt address;
}
