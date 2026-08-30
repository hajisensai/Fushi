import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/tracker_subscription.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('parseTrackerSubscription', () {
    test('keeps supported protocols and removes duplicates', () {
      const String body = '''
# generated list
udp://tracker.example:80/announce

https://tracker.example/announce
udp://tracker.example:80/announce
wss://unsupported.example/announce
file:///tmp/not-a-tracker
not a URL
''';

      expect(parseTrackerSubscription(body), <String>[
        'udp://tracker.example:80/announce',
        'https://tracker.example/announce',
      ]);
    });
  });

  group('appendTrackersToMagnet', () {
    test('preserves the magnet and only appends missing trackers', () {
      const String first = 'udp://one.example:80/announce';
      const String second = 'https://two.example/announce';
      final String magnet =
          'magnet:?xt=urn:btih:abc&dn=Example&tr=${Uri.encodeQueryComponent(first)}';

      final String result = appendTrackersToMagnet(magnet, const <String>[
        first,
        second,
        second,
      ]);

      expect(result, startsWith(magnet));
      expect(Uri.parse(result).queryParametersAll['tr'], <String>[
        first,
        second,
      ]);
    });

    test('leaves non-magnet inputs unchanged', () {
      expect(
        appendTrackersToMagnet(
          'https://example.test/file.torrent',
          const <String>['udp://tracker.example:80/announce'],
        ),
        'https://example.test/file.torrent',
      );
    });
  });

  group('TrackerSubscriptionService', () {
    test('fetches once and reuses the cache', () async {
      int requests = 0;
      final TrackerSubscriptionService service = TrackerSubscriptionService(
        httpClientFactory: () async => MockClient((http.Request request) async {
          requests++;
          return http.Response('udp://tracker.example:80/announce\n', 200);
        }),
      );

      final List<String> first = await service.fetch(
        'https://list.example/best.txt',
      );
      final List<String> second = await service.fetch(
        'https://list.example/best.txt',
      );

      expect(first, <String>['udp://tracker.example:80/announce']);
      expect(second, same(first));
      expect(requests, 1);
    });

    test('rejects non-http subscription URLs before creating a client', () {
      final TrackerSubscriptionService service = TrackerSubscriptionService(
        httpClientFactory: () async => throw StateError('must not run'),
      );

      expect(
        () => service.fetch('file:///tmp/trackers.txt'),
        throwsA(isA<TrackerSubscriptionException>()),
      );
    });

    test('reports request timeout', () async {
      final Completer<http.Response> stalled = Completer<http.Response>();
      final TrackerSubscriptionService service = TrackerSubscriptionService(
        requestTimeout: const Duration(milliseconds: 5),
        httpClientFactory: () async =>
            MockClient((http.Request request) => stalled.future),
      );

      await expectLater(
        service.fetch('https://list.example/best.txt'),
        throwsA(
          isA<TrackerSubscriptionException>().having(
            (TrackerSubscriptionException error) => error.message,
            'message',
            'request timed out',
          ),
        ),
      );
    });
  });
}
