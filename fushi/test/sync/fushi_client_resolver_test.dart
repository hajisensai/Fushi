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

    // BUG-1550：鉴权拒绝不再株连其余候选——每台对端有自己的 per-peer 凭据，一台
    // 拒绝只说明那一台的 token 过期/被吊销了。全部试完都没救回来才抛 SyncAuthError。
    test('throws SyncAuthError only after every candidate was rejected',
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
      expect(probed, <String>['http://lan:8765', 'http://wan:8765']);
    });

    // BUG-1550 的核心回归：配对第二台对端后，第一台地址仍排在前列且可达，但它那份
    // 凭据已被覆盖/吊销。旧实现在第一台就 rethrow，整个互联瘫痪；现在跳过它继续问
    // 第二台，第二台用**自己那份** token 探测成功。
    test('a rejected peer does not block the next peer', () async {
      final List<String> probed = <String>[];
      final Map<String, String> tokensSeen = <String, String>{};
      final FushiClientUrl result = await resolveReachableFushiCandidate(
        const <FushiClientUrl>[
          FushiClientUrl(url: 'http://peer-a:8765', token: 'token-a'),
          FushiClientUrl(url: 'http://peer-b:8765', token: 'token-b'),
        ],
        'global-token',
        (String url, String token) async {
          probed.add(url);
          tokensSeen[url] = token;
          if (url == 'http://peer-a:8765') {
            throw SyncAuthError('revoked');
          }
          return true;
        },
      );

      expect(result.url, 'http://peer-b:8765');
      expect(probed, <String>['http://peer-a:8765', 'http://peer-b:8765']);
      // 每台用自己的凭据，绝不互相串用，也不再无脑套全局 token。
      expect(tokensSeen['http://peer-a:8765'], 'token-a');
      expect(tokensSeen['http://peer-b:8765'], 'token-b');
    });

    // 老配置（行上没有 token）回落全局键——升级路径零破坏。
    test('a candidate without its own token falls back to the global one',
        () async {
      final Map<String, String> tokensSeen = <String, String>{};
      final FushiClientUrl result = await resolveReachableFushiCandidate(
        const <FushiClientUrl>[FushiClientUrl(url: 'http://legacy:8765')],
        'global-token',
        (String url, String token) async {
          tokensSeen[url] = token;
          return true;
        },
      );

      expect(result.url, 'http://legacy:8765');
      expect(tokensSeen['http://legacy:8765'], 'global-token');
    });

    // 两边都没凭据的候选不该被探测（探了也必然 401），也不该被当成可达。
    test('candidates with no credential at all are skipped', () async {
      final List<String> probed = <String>[];
      await expectLater(
        resolveReachableFushiCandidate(
          const <FushiClientUrl>[FushiClientUrl(url: 'http://nocred:8765')],
          '',
          (String url, String token) async {
            probed.add(url);
            return true;
          },
        ),
        throwsA(isA<SyncBackendError>()),
      );
      expect(probed, isEmpty);
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
