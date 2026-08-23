/// Which links the app answers to.
///
/// The rule is deliberately loose about where a link came from and strict
/// about what it carries, because the thing that makes a link real is the
/// claim code in it, and that gets parsed before anything is acted on.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tip/src/chain/network.dart';
import 'package:tip/src/claim/claim_link.dart';
import 'package:tip/src/links/incoming_links.dart';

final _classHash = TipNetwork.sepolia.accountClassHash;

void main() {
  final key = ClaimLinks.create(accountClassHash: _classHash);

  group('recognising a claim link', () {
    test('accepts the https link', () {
      expect(IncomingLinks.isClaimLink(key.link()), isTrue);
    });

    test('accepts the tip scheme, which needs nothing hosted', () {
      expect(
        IncomingLinks.isClaimLink(Uri.parse('$tipScheme://claim#${key.token}')),
        isTrue,
      );
    });

    test('accepts the query form some clients rewrite fragments into', () {
      expect(
        IncomingLinks.isClaimLink(
          Uri.parse('https://$claimLinkHost$claimLinkPath?c=${key.token}'),
        ),
        isTrue,
      );
    });

    test('ignores an https link to somewhere else', () {
      // Otherwise any tapped link with a fragment would open the claim screen.
      expect(
        IncomingLinks.isClaimLink(
          Uri.parse('https://example.com/claim#${key.token}'),
        ),
        isFalse,
      );
    });

    test('ignores another app\'s scheme', () {
      expect(
        IncomingLinks.isClaimLink(Uri.parse('other://claim#${key.token}')),
        isFalse,
      );
    });

    test('ignores a link with no code in it', () {
      expect(
        IncomingLinks.isClaimLink(Uri.parse('https://$claimLinkHost/claim')),
        isFalse,
      );
      expect(
        IncomingLinks.isClaimLink(Uri.parse('$tipScheme://claim')),
        isFalse,
      );
    });
  });

  group('what a recognised link parses to', () {
    test('both forms reach the same claim address', () {
      final fromHttps = ClaimLinks.parse(
        key.link().toString(),
        accountClassHash: _classHash,
      );
      final fromScheme = ClaimLinks.parse(
        '$tipScheme://claim#${key.token}',
        accountClassHash: _classHash,
      );
      expect(fromHttps.address, equals(key.address));
      expect(fromScheme.address, equals(key.address));
    });

    test('recognition is not the same as validity', () {
      // A link can look right and still carry a code that has been cut short.
      // Recognising it is what gets it as far as the claim screen, which then
      // refuses it with a reason rather than silently doing nothing.
      final truncated = Uri.parse('https://$claimLinkHost/claim#abcd');
      expect(IncomingLinks.isClaimLink(truncated), isTrue);
      expect(
        ClaimLinks.tryParse(truncated.toString(), accountClassHash: _classHash),
        isNull,
      );
    });
  });
}
