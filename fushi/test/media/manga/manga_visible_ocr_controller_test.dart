import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_visible_ocr_controller.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

MokuroImage _page(int index) => MokuroImage(
  url: '$index.png',
  size: const MokuroSize(100, 100),
  blocks: const <MokuroBlock>[],
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'manual viewport refresh retains requested pages without scheduling new ones',
    () async {
      final List<int> requested = <int>[];
      final Map<int, Completer<MokuroImage>> jobs =
          <int, Completer<MokuroImage>>{};
      final MangaVisibleOcrController controller = MangaVisibleOcrController(
        recognize: (int page) {
          requested.add(page);
          return (jobs[page] = Completer<MokuroImage>()).future;
        },
        onPage: (int index, MokuroImage page) {},
        onError: (int index, Object error, StackTrace stack) => fail('$error'),
        onActivity: (Set<int> active) {},
      );
      controller.showPages(<int>[0, 1]);
      controller.retainPendingPages(<int>[0, 1, 2]);
      jobs[0]!.complete(_page(0));
      await _settle();
      expect(requested, <int>[0, 1]);
      jobs[1]!.complete(_page(1));
      await _settle();
      expect(requested, <int>[0, 1]);
      controller.showPages(<int>[3, 4]);
      controller.retainPendingPages(<int>[8]);
      jobs[3]!.complete(_page(3));
      await _settle();
      expect(requested, <int>[0, 1, 3]);
      controller.close();
    },
  );

  test(
    'jump replaces pending pages, including repeated viewport reports',
    () async {
      final List<int> requests = <int>[];
      final Map<int, Completer<MokuroImage>> jobs =
          <int, Completer<MokuroImage>>{};
      final List<int> completed = <int>[];
      final MangaVisibleOcrController controller = MangaVisibleOcrController(
        recognize: (int page) {
          requests.add(page);
          return (jobs[page] = Completer<MokuroImage>()).future;
        },
        onPage: (int index, MokuroImage page) => completed.add(index),
        onError: (int index, Object error, StackTrace stack) => fail('$error'),
        onActivity: (Set<int> active) {},
      );
      controller.showPages(<int>[0, 1]);
      controller.showPages(<int>[100, 101]);
      controller.showPages(<int>[200, 201]);
      expect(requests, <int>[0]);
      jobs[0]!.complete(_page(0));
      await _settle();
      expect(requests, <int>[0, 200]);
      jobs[200]!.complete(_page(200));
      await _settle();
      expect(requests, <int>[0, 200, 201]);
      jobs[201]!.complete(_page(201));
      await _settle();
      controller.showPages(<int>[200, 201]);
      await _settle();
      expect(requests, <int>[0, 200, 201]);
      expect(completed, <int>[0, 200, 201]);
      controller.close();
    },
  );

  test(
    'leaving cancels pending work and suppresses stale success and failure',
    () async {
      final List<Completer<MokuroImage>> jobs = <Completer<MokuroImage>>[];
      final List<int> published = <int>[];
      final List<Object> errors = <Object>[];
      final MangaVisibleOcrController controller = MangaVisibleOcrController(
        concurrency: 2,
        recognize: (int page) {
          final Completer<MokuroImage> job = Completer<MokuroImage>();
          jobs.add(job);
          return job.future;
        },
        onPage: (int index, MokuroImage page) => published.add(index),
        onError: (int index, Object error, StackTrace stack) =>
            errors.add(error),
        onActivity: (Set<int> active) {},
      );
      controller.showPages(<int>[0, 1, 2]);
      expect(jobs, hasLength(2));
      controller.close();
      jobs[0].complete(_page(0));
      jobs[1].completeError(StateError('old engine'));
      await _settle();
      expect(jobs, hasLength(2));
      expect(published, isEmpty);
      expect(errors, isEmpty);
    },
  );

  test(
    'blank successful pages are cached; failed pages retry only manually',
    () async {
      int requests = 0;
      bool failNext = true;
      final MangaVisibleOcrController controller = MangaVisibleOcrController(
        recognize: (int page) async {
          requests++;
          if (failNext) throw StateError('network offline');
          return _page(page);
        },
        onPage: (int index, MokuroImage page) {},
        onError: (int index, Object error, StackTrace stack) {},
        onActivity: (Set<int> active) {},
      );
      controller.showPages(<int>[3]);
      await _settle();
      controller.showPages(<int>[3]);
      await _settle();
      expect(requests, 1);
      failNext = false;
      controller.showPages(<int>[3], retry: true);
      await _settle();
      controller.showPages(<int>[3]);
      await _settle();
      expect(requests, 2);
      controller.close();
    },
  );
}
