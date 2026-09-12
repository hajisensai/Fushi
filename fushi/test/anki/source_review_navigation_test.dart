import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/source_review_navigation.dart';

void main() {
  test(
    'source navigation serializes return and URL and recovers after failure',
    () async {
      final ExternalMediaNavigation nav = ExternalMediaNavigation.instance;
      final Completer<void> release = Completer<void>();
      final List<String> events = <String>[];
      final Future<void> first = nav.navigate(() async {
        events.add('close');
        await release.future;
        events.add('restore');
      });
      final Future<void> next = nav.navigate(() async {
        events.add('next');
      });
      await Future<void>.delayed(Duration.zero);
      expect(events, <String>['close']);
      release.complete();
      await Future.wait(<Future<void>>[first, next]);
      expect(events, <String>['close', 'restore', 'next']);
      await expectLater(
        nav.navigate(() async {
          throw StateError('failed');
        }),
        throwsStateError,
      );
      await nav.navigate(() async {
        events.add('recovered');
      });
      expect(events.last, 'recovered');
    },
  );

  test(
    'concurrent closes flush outgoing page once and old owner cannot unregister new page',
    () async {
      final ExternalMediaNavigation nav = ExternalMediaNavigation.instance;
      final Object oldOwner = Object();
      final Object newOwner = Object();
      final Completer<bool> closed = Completer<bool>();
      int calls = 0;
      nav.register(oldOwner, () {
        calls++;
        return closed.future;
      });
      final Future<bool> first = nav.closeActive();
      final Future<bool> second = nav.closeActive();
      expect(calls, 1);
      closed.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
      bool reviewing = true;
      int restores = 0;
      Future<void> restore() async {
        restores++;
      }

      nav.register(
        newOwner,
        () async => true,
        videoUid: () => 'video/current',
        returnToReading: restore,
        isSourceReview: () => reviewing,
      );
      nav.unregister(oldOwner);
      expect(nav.activeVideoUid, 'video/current');
      expect(nav.returnToReading, same(restore));
      await nav.returnToReading!();
      expect(restores, 1);
      reviewing = false;
      expect(nav.returnToReading, isNull);
      await nav.returnToReading?.call();
      expect(restores, 1);
      // The getter reads the live session state without re-registering a page.
      reviewing = true;
      expect(nav.returnToReading, same(restore));
      nav.unregister(newOwner);
      expect(nav.activeVideoUid, isNull);
      expect(nav.returnToReading, isNull);
    },
  );
}
