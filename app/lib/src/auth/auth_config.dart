/// Where sign-in points.
///
/// These two values ship inside the app binary and are meant to. Supabase's
/// publishable key is a client credential: it identifies the project and
/// nothing more, and every security decision is made by row level security on
/// the server. Treating it as a secret would be theatre, since anyone can pull
/// it out of an installed app in a minute.
///
/// They are still overridable, so a fork or a staging build does not need a
/// code change:
///
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...
library;

class AuthConfig {
  AuthConfig._();

  static const url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://eebqwpansmxcbsetyetw.supabase.co',
  );

  static const publishableKey = String.fromEnvironment(
    'SUPABASE_KEY',
    defaultValue: 'sb_publishable_L-oHYpG5nskojZ-_oNS5Ig_03Xwc4sX',
  );

  /// Where an OAuth provider sends the user back to.
  ///
  /// The app's own scheme, so this works with nothing hosted. It has to be
  /// listed under Redirect URLs in the Supabase dashboard or the provider will
  /// refuse the round trip.
  static const oauthRedirect = 'tip://auth-callback';

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;
}
