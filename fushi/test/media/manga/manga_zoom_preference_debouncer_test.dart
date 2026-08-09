import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_zoom_preference_debouncer.dart';

void main() {
  test('high-frequency zoom callbacks persist only the trailing value', () {
    fakeAsync((FakeAsync async) {
      final List<int> writes = <int>[];
      final MangaZoomPreferenceDebouncer debouncer =
          MangaZoomPreferenceDebouncer(
        persist: (int value) async => writes.add(value),
      );

      for (int value = 101; value <= 350; value++) {
        debouncer.queue(value);
      }
      async.elapse(const Duration(milliseconds: 249));
      expect(writes, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(writes, <int>[350]);
    });
  });

  test('dispose flushes the final pending zoom instead of losing it', () {
    fakeAsync((FakeAsync async) {
      final List<int> writes = <int>[];
      final MangaZoomPreferenceDebouncer debouncer =
          MangaZoomPreferenceDebouncer(
        persist: (int value) async => writes.add(value),
      );
      debouncer.queue(275);
      debouncer.dispose();
      async.flushMicrotasks();
      expect(writes, <int>[275]);
      async.elapse(const Duration(seconds: 1));
      expect(writes, <int>[275]);
    });
  });
}
