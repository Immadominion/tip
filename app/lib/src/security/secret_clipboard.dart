/// Putting a secret on the clipboard, and taking it off again.
///
/// The recovery phrase was copied with no timer, no sensitivity flag, and no
/// clearing, and the app then asked the user to clean up after it: "Clear your
/// clipboard when you are done." Almost nobody does, and on a modern phone the
/// clipboard is not a local scratchpad — clipboard managers persist it to disk,
/// iOS Universal Clipboard pushes it to the user's Mac, and Android 13+ shows a
/// preview of what was copied.
///
/// So the clipboard is cleared on a timer, and cleared again when the app is
/// backgrounded, which is the moment the user has most likely finished pasting.
///
/// Clearing is best effort by nature. Anything already read by another process
/// is gone, and a clipboard manager may keep its own copy regardless. Narrowing
/// the window is worth doing; pretending it closes the hole is not.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class SecretClipboard {
  SecretClipboard._();

  /// How long a secret is allowed to sit there.
  ///
  /// Long enough to switch apps and paste into a password manager, short enough
  /// that a phone left on a table is not holding a recovery phrase.
  static const holdFor = Duration(seconds: 60);

  static Timer? _timer;
  static String? _outstanding;
  static _Lifecycle? _lifecycle;

  /// Copies [secret], then clears it after [holdFor] or on backgrounding,
  /// whichever comes first.
  static Future<void> copy(String secret) async {
    await Clipboard.setData(ClipboardData(text: secret));
    _outstanding = secret;

    _timer?.cancel();
    _timer = Timer(holdFor, clear);

    _lifecycle ??= _Lifecycle(onBackground: clear);
    WidgetsBinding.instance.removeObserver(_lifecycle!);
    WidgetsBinding.instance.addObserver(_lifecycle!);
  }

  /// Clears the clipboard, but only if it still holds what we put there.
  ///
  /// Checking first matters: the user has very likely copied something else in
  /// the meantime, and wiping *that* would be the app reaching outside its own
  /// business to destroy something it does not own.
  static Future<void> clear() async {
    _timer?.cancel();
    _timer = null;

    final ours = _outstanding;
    _outstanding = null;
    if (_lifecycle case final observer?) {
      WidgetsBinding.instance.removeObserver(observer);
    }
    if (ours == null) return;

    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text != ours) return;
      await Clipboard.setData(const ClipboardData(text: ''));
    } catch (_) {
      // A platform that will not answer about its own clipboard is not a
      // reason to throw into a screen that was only copying a string.
    }
  }
}

class _Lifecycle extends WidgetsBindingObserver {
  _Lifecycle({required this.onBackground});

  final Future<void> Function() onBackground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      onBackground();
    }
  }
}
