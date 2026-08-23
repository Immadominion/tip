/// Signing in.
///
/// What this is for, and what it is emphatically not for, is worth stating at
/// the top of the file so nobody wires it up wrong later.
///
/// It establishes who someone is, so that a wallet can be reached from more
/// than one device and so a tip can one day be addressed to a handle rather
/// than to sixty-four hex digits.
///
/// It never sees a key. The seed is generated on the device and stays in the
/// platform keystore. Signing in does not produce a wallet and signing out
/// does not remove one. Anything that would let this server reconstruct
/// somebody's funds does not belong in this file, and a backup, when it comes,
/// will be a blob this server cannot read.
library;

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_config.dart';

/// Something the user needs to be told about, phrased for them.
class AuthFailure implements Exception {
  const AuthFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The ways in.
enum AuthMethod { google, x, email }

class AuthService {
  AuthService({GoTrueClient? client}) : _injected = client;

  final GoTrueClient? _injected;

  /// Whether Supabase started. Read before touching `Supabase.instance`, which
  /// throws rather than returning null when it has not.
  static bool _ready = false;

  /// True when sign-in can be offered at all.
  bool get isAvailable => _injected != null || _ready;

  GoTrueClient get _auth {
    final injected = _injected;
    if (injected != null) return injected;
    if (!_ready) {
      throw const AuthFailure('Sign-in is not available in this build');
    }
    return Supabase.instance.client.auth;
  }

  /// Starts Supabase once, before the app runs.
  ///
  /// Safe to call when nothing is configured: the app has to work without a
  /// backend, because the whole wallet does and sign-in is a convenience on
  /// top of it.
  static Future<bool> initialise() async {
    if (!AuthConfig.isConfigured) return false;
    if (_ready) return true;
    try {
      await Supabase.initialize(
        url: AuthConfig.url,
        publishableKey: AuthConfig.publishableKey,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
        ),
      );
      _ready = true;
      return true;
    } catch (_) {
      // A backend that will not start must not stop the wallet from opening.
      return false;
    }
  }

  User? get currentUser => isAvailable ? _auth.currentUser : null;

  bool get isSignedIn => currentUser != null;

  Stream<AuthState> get changes =>
      isAvailable ? _auth.onAuthStateChange : const Stream<AuthState>.empty();

  /// Best available name for the signed-in person.
  ///
  /// Providers disagree about where they put it, so this tries the usual
  /// places before falling back to the email.
  String? get displayName {
    final user = currentUser;
    if (user == null) return null;
    final data = user.userMetadata ?? const {};
    for (final key in ['user_name', 'preferred_username', 'name', 'full_name']) {
      final value = data[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return user.email;
  }

  /// Sends a one-time code to [email].
  ///
  /// A code rather than a magic link. A link has to come back through a
  /// browser and a deep link to land in the right app, and it breaks whenever
  /// a mail client opens it in its own web view. Six digits typed into the app
  /// works everywhere.
  Future<void> sendEmailCode(String email) async {
    final address = email.trim();
    if (!looksLikeEmail(address)) {
      throw const AuthFailure('That does not look like an email address');
    }
    try {
      await _auth.signInWithOtp(email: address);
    } on AuthException catch (error) {
      throw AuthFailure(error.message);
    } catch (_) {
      throw const AuthFailure('Could not reach the sign-in service');
    }
  }

  Future<void> verifyEmailCode({
    required String email,
    required String code,
  }) async {
    try {
      await _auth.verifyOTP(
        email: email.trim(),
        token: code.trim(),
        type: OtpType.email,
      );
    } on AuthException catch (error) {
      throw AuthFailure(
        error.message.toLowerCase().contains('expired')
            ? 'That code has expired. Ask for a new one.'
            : 'That code is not right. Check it and try again.',
      );
    }
  }

  /// Hands off to Google or X.
  ///
  /// Returns false when the provider is not switched on for this project,
  /// which is a configuration state rather than a bug, and the UI says so
  /// instead of showing a stack trace.
  Future<bool> signInWith(AuthMethod method) async {
    final provider = switch (method) {
      AuthMethod.google => OAuthProvider.google,
      AuthMethod.x => OAuthProvider.twitter,
      AuthMethod.email => throw ArgumentError('Use sendEmailCode for email'),
    };

    try {
      return await _auth.signInWithOAuth(
        provider,
        redirectTo: AuthConfig.oauthRedirect,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
    } on AuthException catch (error) {
      if (error.message.toLowerCase().contains('not enabled')) {
        throw AuthFailure(
          '${_label(method)} sign-in is not switched on for this project yet.',
        );
      }
      throw AuthFailure(error.message);
    }
  }

  /// Signs out. Deliberately leaves the wallet alone.
  ///
  /// The seed is on this device and belongs to whoever holds it, not to a
  /// session. Erasing a wallet is a separate, louder action in settings.
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (_) {
      // Already gone, or the network is down. Either way the session is not
      // usable, and telling the user off about it helps nobody.
    }
  }

  static String _label(AuthMethod method) => switch (method) {
        AuthMethod.google => 'Google',
        AuthMethod.x => 'X',
        AuthMethod.email => 'Email',
      };
}

/// A deliberately loose check.
///
/// The only job here is to catch an obvious slip before spending a round trip
/// and a rate limit on it. Anything stricter starts rejecting addresses that
/// are perfectly valid, and the real test is whether the code arrives.
bool looksLikeEmail(String value) {
  final at = value.indexOf('@');
  if (at <= 0 || at == value.length - 1) return false;
  final domain = value.substring(at + 1);
  return domain.contains('.') &&
      !domain.startsWith('.') &&
      !domain.endsWith('.') &&
      !value.contains(' ');
}
