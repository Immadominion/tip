/// The screen lock.
///
/// What this does and does not protect against is worth being exact about,
/// because a lock that is oversold is worse than none.
///
/// It stops someone who picks up an unlocked phone from opening the wallet.
/// That is the realistic threat for a phone in a pocket, and it is the whole
/// of what this is for.
///
/// It does not protect the seed. The seed lives in the platform keystore and
/// is readable by the app whether or not this lock is on, so anyone able to
/// run code as the app, or to restore its data elsewhere, is unaffected by it.
/// The UI must not imply otherwise.
///
/// It can never strand anyone. Biometrics fall back to the device passcode,
/// the lock can be turned off from inside the app, and the recovery phrase
/// restores the wallet anywhere regardless. A lock that can permanently
/// separate someone from their money is not a security feature.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class AppLock {
  AppLock({FlutterSecureStorage? storage, LocalAuthentication? auth})
      : _storage = storage ?? const FlutterSecureStorage(),
        _auth = auth ?? LocalAuthentication();

  final FlutterSecureStorage _storage;
  final LocalAuthentication _auth;

  static const _key = 'tip.lock.v1';

  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
  );
  static const _androidOptions = AndroidOptions();

  /// Whether the device can authenticate at all.
  ///
  /// True for a device passcode alone, not only for biometrics: a phone with
  /// no fingerprint enrolled can still be locked, and refusing to offer that
  /// would be arbitrary.
  Future<bool> get isAvailable async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  Future<bool> isEnabled() async {
    try {
      final value = await _storage.read(
        key: _key,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );
      return value == 'on';
    } catch (_) {
      // A keystore that will not answer must not lock the user out of their
      // own wallet, so an unreadable setting reads as off.
      return false;
    }
  }

  Future<void> setEnabled(bool enabled) => _storage.write(
        key: _key,
        value: enabled ? 'on' : 'off',
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );

  /// Asks the device to confirm who is holding it.
  ///
  /// `biometricOnly` is deliberately false. Tying this to biometrics alone
  /// locks out anyone whose fingerprint stops reading, and the passcode is the
  /// same secret the phone already trusts.
  Future<bool> authenticate({
    String reason = 'Unlock your wallet',
  }) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // False on purpose. Tying this to biometrics alone locks out anyone
        // whose fingerprint stops reading, and the passcode is the same secret
        // the phone already trusts.
        biometricOnly: false,
        // Retry on foregrounding rather than failing, since the system
        // backgrounds the app during the prompt on some devices.
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
