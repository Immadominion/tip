/// Links arriving from outside the app.
///
/// A tip link is meant to be tapped, not pasted, so the app has to answer to
/// two things: the https link, which works once usetip.xyz serves its
/// association files, and the `tip://` scheme, which works today and needs
/// nothing hosted anywhere.
///
/// Cold start and warm resume are both handled, and they are genuinely
/// different: a link that launched the app arrives once as an initial value,
/// while a link tapped with the app already open arrives on the stream.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';

import '../claim/claim_link.dart';

class IncomingLinks {
  AppLinks? _links;

  /// Built on first use rather than in the constructor, so a subclass that
  /// overrides both members below never reaches for a platform channel. That
  /// is how the tests stand in for this without a running app.
  AppLinks get _appLinks => _links ??= AppLinks();

  /// The link that launched the app, if one did.
  Future<Uri?> initial() => _appLinks.getInitialLink();

  /// Links that arrive while the app is already running.
  Stream<Uri> get stream => _appLinks.uriLinkStream;

  /// Whether [uri] is something this app should act on.
  ///
  /// Deliberately loose about the host and path and strict about the payload.
  /// The thing that decides whether a link is real is whether it carries a
  /// claim code of the right length, and that is checked by parsing it.
  static bool isClaimLink(Uri uri) {
    if (uri.scheme != tipScheme && uri.scheme != 'https') return false;
    if (uri.scheme == 'https' && uri.host != claimLinkHost) return false;
    return uri.fragment.isNotEmpty ||
        (uri.queryParameters['c']?.isNotEmpty ?? false);
  }
}
