/// Where a sealed recovery phrase is kept.
///
/// The server side of this is deliberately dull: one row per account holding
/// one opaque string. All the security lives in what the string is, which is
/// decided in `seed_vault.dart`, and in row level security, which is decided
/// in `supabase/migrations/0001_seed_backups.sql`.
///
/// This class knows nothing about phrases or passwords. It moves a blob.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'seed_vault.dart';

class BackupUnavailable implements Exception {
  const BackupUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

class BackupRepository {
  BackupRepository({SupabaseClient? client}) : _injected = client;

  final SupabaseClient? _injected;

  static const table = 'seed_backups';

  SupabaseClient get _db {
    final injected = _injected;
    if (injected != null) return injected;
    try {
      return Supabase.instance.client;
    } catch (_) {
      throw const BackupUnavailable('Backups need you to be signed in');
    }
  }

  String get _userId {
    final id = _db.auth.currentUser?.id;
    if (id == null) {
      throw const BackupUnavailable('Sign in before backing up');
    }
    return id;
  }

  /// Stores [sealed], replacing any backup already there.
  ///
  /// Replacing rather than refusing is the right behaviour: someone changing
  /// their password re-seals the same phrase, and the old blob is then just an
  /// older lock on the same door.
  Future<void> put(SealedSeed sealed) async {
    try {
      await _db.from(table).upsert({
        'user_id': _userId,
        'blob': sealed.encode(),
      });
    } on PostgrestException catch (error) {
      throw BackupUnavailable(_explain(error));
    }
  }

  /// The backup for the signed-in account, or null if there is none.
  Future<SealedSeed?> fetch() async {
    try {
      final row = await _db
          .from(table)
          .select('blob')
          .eq('user_id', _userId)
          .maybeSingle();
      final blob = row?['blob'];
      if (blob is! String) return null;
      return SealedSeed.decode(blob);
    } on PostgrestException catch (error) {
      throw BackupUnavailable(_explain(error));
    }
  }

  Future<bool> exists() async => await fetch() != null;

  Future<void> remove() async {
    try {
      await _db.from(table).delete().eq('user_id', _userId);
    } on PostgrestException catch (error) {
      throw BackupUnavailable(_explain(error));
    }
  }

  /// Turns a Postgrest error into something a person can act on.
  ///
  /// The missing-table case is worth naming, because it is what happens when
  /// the migration has not been run and the generic message would send someone
  /// hunting through the app instead of the database.
  static String _explain(PostgrestException error) {
    final code = error.code ?? '';
    if (code == '42P01') {
      return 'Backups are not set up on the server yet.';
    }
    if (code == '42501' || code.startsWith('PGRST')) {
      return 'This account is not allowed to read that backup.';
    }
    return 'Could not reach the backup service. ${error.message}';
  }
}
