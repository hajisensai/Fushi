import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';

void main() {
  group('resolveReachableFushiCandidate', () {
    test('returns the first reachable url', () async {
      final List<String> probed = <String>[];
      final FushiClientUrl result = await resolveReachableFushiCandidate(
        const <FushiClientUrl>[
          FushiClientUrl(url: 'http://lan:8765'),
          FushiClientUrl(url: 'http://wan:8765'),
        ],
        'tok',
        (String url, String token) async {
          probed.add(url);
          return true; // first one is reachable
        },
      );

      expect(result.url, 'http://lan:8765');
      expect(probed, <String>['http://lan:8765']); // stops at first success
    });

    test('falls through to the next url when the first is unreachable',
        () async {
      final List<String> probed = <String>[];
      final FushiClientUrl result = await resolveReachableFushiCandidate(
        const <FushiClientUrl>[
          FushiClientUrl(url: 'http://lan:8765'),
          FushiClientUrl(url: 'http://wan:8765'),
        ],
        'tok',
        (String url, String token) async {
          probed.add(url);
          return url == 'http://wan:8765';
        },
      );

      expect(result.url, 'http://wan:8765');
      expect(probed, <String>['http://lan:8765', 'http://wan:8765']);
    });

    test('skips disabled candidates', () async {
      final List<String> probed = <String>[];
      final FushiClientUrl result = await resolveReachableFushiCandidate(
        const <FushiClientUrl>[
          FushiClientUrl(url: 'http://lan:8765', enabled: false),
          FushiClientUrl(url: 'http://wan:8765'),
        ],
        'tok',
        (String url, String token) async {
          probed.add(url);
          return true;
        },
      );

      expect(result.url, 'http://wan:8765');
      expect(probed, <String>['http://wan:8765']); // disabled never probed
    });

    test('rethrows SyncAuthError immediately without probing the rest',
        () async {
      final List<String> probed = <String>[];
      await expectLater(
        resolveReachableFushiCandidate(
          const <FushiClientUrl>[
            FushiClientUrl(url: 'http://lan:8765'),
            FushiClientUrl(url: 'http://wan:8765'),
          ],
          'tok',
          (String url, String token) async {
            probed.add(url);
            throw SyncAuthError('unauthorized');
          },
        ),
        throwsA(isA<SyncAuthError>()),
      );
      expect(probed, <String>['http://lan:8765']); // stops on auth error
    });

    test('throws a retryable SyncBackendError when none are reachable',
        () async {
      await expectLater(
        resolveReachableFushiCandidate(
          const <FushiClientUrl>[
            FushiClientUrl(url: 'http://lan:8765'),
            FushiClientUrl(url: 'http://wan:8765'),
          ],
          'tok',
          (String url, String token) async => false,
        ),
        throwsA(isA<SyncBackendError>().having(
            (SyncBackendError e) => e.isRetryable, 'isRetryable', isTrue)),
      );
    });
  });
}
