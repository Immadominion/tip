/// Backing a wallet up, and getting it back.
///
/// Two pieces that have no business knowing about each other: the vault, which
/// seals a phrase and has never heard of a server, and the repository, which
/// moves an opaque string and has never heard of a phrase. This joins them and
/// is the only place that holds both at once.
library;

import 'backup_repository.dart';
import 'seed_vault.dart';

class BackupService {
  BackupService({
    BackupRepository? repository,
    this.vault = const SeedVault(),
  }) : _repository = repository ?? BackupRepository();

  final BackupRepository _repository;

  /// Defaults to the production cost. Tests pass a cheaper one so a suite that
  /// seals a dozen times finishes in seconds.
  final SeedVault vault;

  /// Whether this account already has a backup waiting.
  ///
  /// False on any failure rather than throwing. This is asked on the way into
  /// the app to decide which screen to show, and a server hiccup should send
  /// someone down the ordinary path, not into an error.
  Future<bool> exists() async {
    try {
      return await _repository.exists();
    } catch (_) {
      return false;
    }
  }

  /// Seals [mnemonic] under [password] and stores it.
  ///
  /// Sealing happens before anything is sent, so a rejected password costs a
  /// key derivation and nothing else.
  Future<void> create({
    required String mnemonic,
    required String password,
  }) async {
    final sealed = await vault.seal(mnemonic: mnemonic, password: password);
    await _repository.put(sealed);
  }

  /// Fetches the backup and opens it, returning the phrase.
  ///
  /// Throws [SeedVaultException] for a wrong password and [BackupUnavailable]
  /// when the blob could not be fetched at all. Keeping those apart matters:
  /// one is the user's problem to fix and the other is not.
  Future<String> restore({required String password}) async {
    final sealed = await _repository.fetch();
    if (sealed == null) {
      throw const BackupUnavailable('This account has no backup');
    }
    return vault.open(sealed: sealed, password: password);
  }

  /// Removes the backup. The wallet on the device is untouched.
  Future<void> remove() => _repository.remove();
}
