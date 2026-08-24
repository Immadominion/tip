/// The backup screens.
///
/// Both are checked for the same thing: that the part which cannot be undone
/// is stated before it happens, and that somebody who has forgotten the
/// password is never cornered.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/backup/backup_repository.dart';
import 'package:tip/src/backup/backup_service.dart';
import 'package:tip/src/backup/seed_vault.dart';
import 'package:tip/src/screens/backup_screen.dart';
import 'package:tip/src/screens/restore_backup_screen.dart';
import 'package:tip/src/theme/theme.dart';
import 'package:tip/src/wallet/wallet.dart';

final _phrase = WalletFactory.generateMnemonic();
const _password = 'a properly long password';

/// Cheap enough to run repeatedly. The real cost is checked next door in
/// seed_vault_test.dart, which seals with it for real.
const _cheap = SeedVault(
  cost: Argon2Cost(memoryKib: 64, iterations: 1, parallelism: 1),
);

/// Holds one blob in memory, the way the table holds one row.
class _MemoryRepository implements BackupRepository {
  SealedSeed? stored;
  bool failing = false;

  @override
  Future<void> put(SealedSeed sealed) async {
    if (failing) throw const BackupUnavailable('server is down');
    stored = sealed;
  }

  @override
  Future<SealedSeed?> fetch() async {
    if (failing) throw const BackupUnavailable('server is down');
    return stored;
  }

  @override
  Future<bool> exists() async => (await fetch()) != null;

  @override
  Future<void> remove() async => stored = null;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: TipTheme.light, home: child));
  await tester.pumpAndSettle();
}

Finder _fieldAt(int index) => find.byType(TextField).at(index);

void main() {
  group('making a backup', () {
    testWidgets('it says there is no reset before anything is typed',
        (tester) async {
      await _pump(
        tester,
        BackupScreen(
          service: BackupService(repository: _MemoryRepository(), vault: _cheap),
          mnemonic: _phrase,
        ),
      );
      expect(find.text('There is no way to reset this'), findsOneWidget);
    });

    testWidgets('a short password is refused with the reason', (tester) async {
      await _pump(
        tester,
        BackupScreen(
          service: BackupService(repository: _MemoryRepository(), vault: _cheap),
          mnemonic: _phrase,
        ),
      );

      await tester.enterText(_fieldAt(0), 'short');
      await tester.pump();

      expect(find.textContaining('nobody can reset'), findsWidgets);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
    });

    testWidgets('mismatched passwords are caught', (tester) async {
      await _pump(
        tester,
        BackupScreen(
          service: BackupService(repository: _MemoryRepository(), vault: _cheap),
          mnemonic: _phrase,
        ),
      );

      await tester.enterText(_fieldAt(0), _password);
      await tester.enterText(_fieldAt(1), 'a properly long passwerd');
      await tester.pump();

      expect(find.text('These do not match'), findsOneWidget);
    });

    testWidgets('it will not seal until the warning is acknowledged',
        (tester) async {
      await _pump(
        tester,
        BackupScreen(
          service: BackupService(repository: _MemoryRepository(), vault: _cheap),
          mnemonic: _phrase,
        ),
      );

      await tester.enterText(_fieldAt(0), _password);
      await tester.enterText(_fieldAt(1), _password);
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
        reason: 'checkbox not ticked yet',
      );

      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('sealing stores a blob the phrase is not visible in',
        (tester) async {
      final repository = _MemoryRepository();
      await _pump(
        tester,
        BackupScreen(
          service: BackupService(repository: repository, vault: _cheap),
          mnemonic: _phrase,
        ),
      );

      await tester.enterText(_fieldAt(0), _password);
      await tester.enterText(_fieldAt(1), _password);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(repository.stored, isNotNull);
      final blob = repository.stored!.encode();
      for (final word in _phrase.split(' ')) {
        expect(blob, isNot(contains(word)));
      }
    });
  });

  group('restoring one', () {
    Future<_MemoryRepository> withBackup() async {
      final repository = _MemoryRepository();
      await BackupService(repository: repository, vault: _cheap)
          .create(mnemonic: _phrase, password: _password);
      return repository;
    }

    testWidgets('the right password gives the phrase back', (tester) async {
      final repository = await withBackup();
      String? restored;

      await _pump(
        tester,
        RestoreBackupScreen(
          service: BackupService(repository: repository, vault: _cheap),
          onRestored: (mnemonic) async => restored = mnemonic,
          onUsePhrase: () {},
        ),
      );

      await tester.enterText(find.byType(TextField), _password);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await tester.pumpAndSettle();

      expect(restored, equals(_phrase));
    });

    testWidgets('a wrong password says so and restores nothing',
        (tester) async {
      final repository = await withBackup();
      var restored = false;

      await _pump(
        tester,
        RestoreBackupScreen(
          service: BackupService(repository: repository, vault: _cheap),
          onRestored: (_) async => restored = true,
          onUsePhrase: () {},
        ),
      );

      await tester.enterText(find.byType(TextField), 'not the password');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await tester.pumpAndSettle();

      expect(restored, isFalse);
      expect(find.textContaining('does not open this backup'), findsOneWidget);
    });

    testWidgets('the way out is offered from the start, not after failures',
        (tester) async {
      // Someone who knows immediately that they have forgotten the password
      // should not have to prove it to the app three times first.
      final repository = await withBackup();
      var wentToPhrase = false;

      await _pump(
        tester,
        RestoreBackupScreen(
          service: BackupService(repository: repository, vault: _cheap),
          onRestored: (_) async {},
          onUsePhrase: () => wentToPhrase = true,
        ),
      );

      expect(find.text('Forgotten the password?'), findsOneWidget);
      await tester.tap(find.text('Use my recovery phrase'));
      await tester.pump();
      expect(wentToPhrase, isTrue);
    });

    testWidgets('a server that will not answer is not a wrong password',
        (tester) async {
      final repository = await withBackup();
      repository.failing = true;

      await _pump(
        tester,
        RestoreBackupScreen(
          service: BackupService(repository: repository, vault: _cheap),
          onRestored: (_) async {},
          onUsePhrase: () {},
        ),
      );

      await tester.enterText(find.byType(TextField), _password);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await tester.pumpAndSettle();

      expect(find.textContaining('does not open this backup'), findsNothing);
      expect(find.textContaining('server is down'), findsOneWidget);
    });
  });

  group('the service', () {
    test('a missing backup is reported as missing, not as a bad password',
        () async {
      final service = BackupService(repository: _MemoryRepository(), vault: _cheap);
      expect(
        () => service.restore(password: _password),
        throwsA(isA<BackupUnavailable>()),
      );
    });

    test('exists is false rather than throwing when the server is down',
        () async {
      // Asked on the way into the app to pick a screen. A hiccup should send
      // someone down the ordinary path, not into an error.
      final repository = _MemoryRepository()..failing = true;
      expect(await BackupService(repository: repository, vault: _cheap).exists(), isFalse);
    });

    test('re-sealing replaces the old blob rather than adding one', () async {
      final repository = _MemoryRepository();
      final service = BackupService(repository: repository, vault: _cheap);

      await service.create(mnemonic: _phrase, password: _password);
      final first = repository.stored!.encode();
      await service.create(mnemonic: _phrase, password: 'a different long one');

      expect(repository.stored!.encode(), isNot(equals(first)));
      expect(
        await service.restore(password: 'a different long one'),
        equals(_phrase),
      );
      expect(
        () => service.restore(password: _password),
        throwsA(isA<SeedVaultException>()),
      );
    });
  });
}
