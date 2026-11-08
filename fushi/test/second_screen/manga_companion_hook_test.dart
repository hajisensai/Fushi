import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/reader/manga_companion_hook.dart';
import 'package:fushi/src/second_screen/companion/companion_bridge.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_lookup_routing.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/manga_companion_schema.dart';
import 'package:fushi_core/fushi_core.dart';

/// The reader side as the hook sees it: a mutable state + recorded calls.
class _FakeReader implements MangaCompanionReader {
  int session = 1;
  int page = 3;
  int pageCount = 20;
  int currentChapter = 1;
  List<String> chapterNames = <String>['Ch 3', 'Ch 2', 'Ch 1'];
  List<String> pageTexts = <String>[];
  bool readerOcrBusy = false;
  int builds = 0;
  final List<String> calls = <String>[];
  final List<int> recognized = <int>[];
  Completer<MangaCompanionOcrOutcome>? pending;
  String title = 'Series';
  MangaCompanionInfo? info;
  int infoLoads = 0;

  @override
  MangaCompanionReadState? readState() {
    builds++;
    return MangaCompanionReadState(
      title: title,
      pageKey: '$session/$page',
      page: page,
      pageCount: pageCount,
      chapter: chapterNames.isEmpty ? null : chapterNames[currentChapter],
      author: 'Author',
      description: 'About it',
      genres: const <String>['Comedy'],
      rtl: true,
      chapterNames: chapterNames,
      currentChapterIndex: chapterNames.isEmpty ? -1 : currentChapter,
      pageTexts: pageTexts,
      readerOcrBusy: readerOcrBusy,
    );
  }

  @override
  void previousPage() => calls.add('previousPage');
  @override
  void nextPage() => calls.add('nextPage');
  @override
  void previousChapter() => calls.add('previousChapter');
  @override
  void nextChapter() => calls.add('nextChapter');
  @override
  void goToChapter(int index) => calls.add('goToChapter:$index');

  @override
  Future<MangaCompanionOcrOutcome> recognizePage(int page) {
    recognized.add(page);
    return (pending = Completer<MangaCompanionOcrOutcome>()).future;
  }

  @override
  Future<MangaCompanionInfo?> loadInfo() async {
    infoLoads++;
    return info;
  }
}

class _FakeBridge implements CompanionBridge {
  _FakeBridge({required this.accept});

  final bool accept;
  final List<(String, int, String?)> lookups = <(String, int, String?)>[];

  @override
  Future<bool> sendLookup({
    required String text,
    int charIndex = -1,
    String? sentence,
  }) async {
    lookups.add((text, charIndex, sentence));
    return accept;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late CompanionContextRegistry registry;
  late _FakeReader reader;
  late MangaCompanionHook hook;

  setUp(() {
    registry = CompanionContextRegistry();
    reader = _FakeReader();
    hook = MangaCompanionHook(reader: reader, registry: registry);
  });

  tearDown(() {
    hook.dispose();
    registry.dispose();
  });

  Map<String, Object?> snapshot() => registry.currentSnapshot!;

  group('claim and snapshot', () {
    test('inactive: claims the context but builds nothing, no timer', () {
      fakeAsync((FakeAsync async) {
        hook.claim('Series');
        expect(registry.current.kind, CompanionContextKind.manga);
        expect(registry.current.title, 'Series');
        async.elapse(const Duration(seconds: 5));
        hook.publishNow();
        expect(reader.builds, 0);
        expect(registry.currentSnapshot, isNull);
        expect(async.periodicTimerCount, 0);
      });
    });

    test('active: publishes the reader state, throttled to 1/s', () {
      fakeAsync((FakeAsync async) {
        hook.claim('Series');
        registry.setActive(true);
        final Map<String, Object?> s = snapshot();
        expect(s.str(MangaCompanionKeys.title), 'Series');
        expect(s.str(MangaCompanionKeys.chapter), 'Ch 2');
        expect(s.str(MangaCompanionKeys.author), 'Author');
        expect(s.str(MangaCompanionKeys.description), 'About it');
        expect(s.strings(MangaCompanionKeys.genres), <String>['Comedy']);
        expect(s.integer(MangaCompanionKeys.page), 3);
        expect(s.integer(MangaCompanionKeys.pageCount), 20);
        expect(s.flag(MangaCompanionKeys.rtl), isTrue);
        expect(s.integer(MangaCompanionKeys.chapterCount), 3);
        expect(s.integer(MangaCompanionKeys.chapterPosition), 2);
        expect(s.integer(MangaCompanionKeys.currentChapter), 1);
        // Reading order: oldest first, `i` = source index.
        expect(
          <String>[
            for (final Map<String, Object?> c in s.maps(
              MangaCompanionKeys.chapters,
            ))
              '${c.integer(MangaCompanionKeys.chapterIndex)}:'
                  '${c.str(MangaCompanionKeys.chapterName)}',
          ],
          <String>['2:Ch 1', '1:Ch 2', '0:Ch 3'],
        );
        expect(s.str(MangaCompanionKeys.ocr), 'idle');
        expect(s.containsKey(MangaCompanionKeys.lines), isFalse);
        expect(async.periodicTimerCount, 1);

        final int revision = registry.snapshotRevision;
        reader.page = 4;
        async.elapse(const Duration(milliseconds: 500));
        expect(registry.snapshotRevision, revision);
        async.elapse(const Duration(milliseconds: 600));
        expect(registry.snapshotRevision, revision + 1);
        expect(snapshot().integer(MangaCompanionKeys.page), 4);

        // Unchanged state: nothing re-sent.
        async.elapse(const Duration(seconds: 3));
        expect(registry.snapshotRevision, revision + 1);

        registry.setActive(false);
        expect(async.periodicTimerCount, 0);
      });
    });

    test('page text is capped; chapter window keeps the current one', () {
      reader
        ..pageTexts = <String>[
          for (int i = 0; i < 60; i++) 'line $i',
          '   ',
          'x' * 1000,
        ]
        ..chapterNames = <String>[for (int i = 0; i < 1000; i++) 'Ch $i']
        ..currentChapter = 10;
      hook.claim('Series');
      registry.setActive(true);
      final Map<String, Object?> s = snapshot();
      expect(s.strings(MangaCompanionKeys.lines), hasLength(40));
      final List<Map<String, Object?>> chapters = s.maps(
        MangaCompanionKeys.chapters,
      );
      expect(chapters, hasLength(kMangaCompanionMaxChapters));
      expect(
        chapters.any(
          (Map<String, Object?> c) =>
              c.integer(MangaCompanionKeys.chapterIndex) == 10,
        ),
        isTrue,
      );
      expect(s.integer(MangaCompanionKeys.chapterCount), 1000);
      expect(s.integer(MangaCompanionKeys.chapterPosition), 990);
      expect(s.str(MangaCompanionKeys.ocr), 'done');

      final Map<String, Object?> long = buildMangaCompanionSnapshot(
        MangaCompanionReadState(
          title: 'T',
          pageKey: 'k',
          page: 0,
          pageCount: 1,
          pageTexts: <String>['x' * 1000],
        ),
        ocr: MangaCompanionOcrState.done,
      );
      expect(
        long.strings(MangaCompanionKeys.lines).single.length,
        kMangaCompanionMaxLineChars + 1,
      );
    });

    test('a local volume has no chapter keys', () {
      reader.chapterNames = <String>[];
      hook.claim('Vol. 1');
      registry.setActive(true);
      final Map<String, Object?> s = snapshot();
      expect(s.containsKey(MangaCompanionKeys.chapters), isFalse);
      expect(s.containsKey(MangaCompanionKeys.chapterPosition), isFalse);
      expect(s.containsKey(MangaCompanionKeys.chapter), isFalse);
    });

    test('a new title re-claims and republishes', () {
      hook.claim('Series');
      registry.setActive(true);
      final int revision = registry.snapshotRevision;
      hook.claim('Other series');
      expect(registry.current.title, 'Other series');
      expect(registry.snapshotRevision, greaterThan(revision));
      expect(registry.currentSnapshot, isNotNull);
    });
  });

  group('commands', () {
    setUp(() {
      hook.claim('Series');
      registry.setActive(true);
    });

    bool send(String action, [Map<String, Object?>? args]) =>
        registry.dispatchCommand(
          CompanionContextKind.manga,
          action,
          args ?? const <String, Object?>{},
        );

    test('page and chapter controls reach the reader', () {
      expect(send(MangaCompanionActions.previousPage), isTrue);
      send(MangaCompanionActions.nextPage);
      send(MangaCompanionActions.previousChapter);
      send(MangaCompanionActions.nextChapter);
      send(MangaCompanionActions.goToChapter, <String, Object?>{
        MangaCompanionActions.argIndex: 2,
      });
      expect(reader.calls, <String>[
        'previousPage',
        'nextPage',
        'previousChapter',
        'nextChapter',
        'goToChapter:2',
      ]);
    });

    test('goToChapter ignores the current, missing and bad indexes', () {
      send(MangaCompanionActions.goToChapter, <String, Object?>{
        MangaCompanionActions.argIndex: 1,
      });
      send(MangaCompanionActions.goToChapter, <String, Object?>{
        MangaCompanionActions.argIndex: 3,
      });
      send(MangaCompanionActions.goToChapter, <String, Object?>{
        MangaCompanionActions.argIndex: -1,
      });
      send(MangaCompanionActions.goToChapter);
      send('unknown');
      expect(reader.calls, isEmpty);
    });

    test('commands for another kind are not delivered', () {
      expect(
        registry.dispatchCommand(
          CompanionContextKind.video,
          MangaCompanionActions.nextPage,
          const <String, Object?>{},
        ),
        isFalse,
      );
      expect(reader.calls, isEmpty);
    });
  });

  group('OCR this page', () {
    setUp(() {
      hook.claim('Series');
      registry.setActive(true);
    });

    void ocrCommand() => registry.dispatchCommand(
      CompanionContextKind.manga,
      MangaCompanionActions.ocrPage,
      const <String, Object?>{},
    );

    test('never runs on its own: not on open, not on page turns', () {
      fakeAsync((FakeAsync async) {
        for (int p = 0; p < 5; p++) {
          reader.page = p;
          hook.publishNow();
          async.elapse(const Duration(seconds: 1));
        }
        expect(reader.recognized, isEmpty);
        expect(snapshot().str(MangaCompanionKeys.ocr), 'idle');
      });
    });

    test('runs on the command: busy, then the page text', () async {
      ocrCommand();
      expect(reader.recognized, <int>[3]);
      expect(snapshot().str(MangaCompanionKeys.ocr), 'running');
      // A second press while it runs does not start another one.
      ocrCommand();
      expect(reader.recognized, <int>[3]);

      reader.pageTexts = <String>['こんにちは'];
      reader.pending!.complete(
        const MangaCompanionOcrOutcome(
          MangaCompanionOcrResult.recognized,
          blocks: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(snapshot().str(MangaCompanionKeys.ocr), 'done');
      expect(snapshot().strings(MangaCompanionKeys.lines), <String>['こんにちは']);
    });

    test('nothing found reads empty; the next page starts idle', () async {
      ocrCommand();
      reader.pending!.complete(
        const MangaCompanionOcrOutcome(MangaCompanionOcrResult.recognized),
      );
      await Future<void>.delayed(Duration.zero);
      expect(snapshot().str(MangaCompanionKeys.ocr), 'empty');

      reader.page = 4;
      hook.publishNow();
      expect(snapshot().str(MangaCompanionKeys.ocr), 'idle');
      expect(reader.recognized, <int>[3]);

      // Same page index in another chapter is another page.
      reader
        ..page = 3
        ..session = 2;
      hook.publishNow();
      expect(snapshot().str(MangaCompanionKeys.ocr), 'idle');
    });

    test('a result for a page the reader left does not show', () async {
      ocrCommand();
      reader.page = 5;
      hook.publishNow();
      expect(snapshot().str(MangaCompanionKeys.ocr), 'idle');
      reader.pending!.complete(
        const MangaCompanionOcrOutcome(MangaCompanionOcrResult.recognized),
      );
      await Future<void>.delayed(Duration.zero);
      expect(snapshot().str(MangaCompanionKeys.ocr), 'idle');
    });

    test('handed to the reader OCR: busy while it runs', () async {
      ocrCommand();
      reader.readerOcrBusy = true;
      reader.pending!.complete(
        const MangaCompanionOcrOutcome(MangaCompanionOcrResult.delegated),
      );
      await Future<void>.delayed(Duration.zero);
      expect(snapshot().str(MangaCompanionKeys.ocr), 'running');
      reader.readerOcrBusy = false;
      hook.publishNow();
      expect(snapshot().str(MangaCompanionKeys.ocr), 'empty');
    });

    test('failure, no engine, unsupported, declined', () async {
      Future<String> outcome(MangaCompanionOcrOutcome o) async {
        reader.page++;
        ocrCommand();
        reader.pending!.complete(o);
        await Future<void>.delayed(Duration.zero);
        return snapshot().str(MangaCompanionKeys.ocr);
      }

      expect(
        await outcome(
          const MangaCompanionOcrOutcome(
            MangaCompanionOcrResult.failed,
            error: 'boom',
          ),
        ),
        'failed',
      );
      expect(snapshot().str(MangaCompanionKeys.ocrError), 'boom');
      expect(
        await outcome(
          const MangaCompanionOcrOutcome(MangaCompanionOcrResult.noEngine),
        ),
        'noEngine',
      );
      expect(
        await outcome(
          const MangaCompanionOcrOutcome(MangaCompanionOcrResult.unsupported),
        ),
        'unsupported',
      );
      expect(
        await outcome(
          const MangaCompanionOcrOutcome(MangaCompanionOcrResult.declined),
        ),
        'idle',
      );
    });
  });

  group('top-screen lookup routing', () {
    tearDown(() {
      companionContexts.setActive(false);
      companionContexts.bindLookupSink(null);
    });

    testWidgets('companion off: falls back to the in-page popup', (
      WidgetTester tester,
    ) async {
      final _FakeBridge bridge = _FakeBridge(accept: true);
      companionContexts.bindLookupSink(bridge.sendLookup);
      expect(
        await routeCompanionLookup(text: '読む', sentence: '本を読む。'),
        isFalse,
      );
      expect(bridge.lookups, isEmpty);
    });

    testWidgets('companion up: the Lookup tab takes it', (
      WidgetTester tester,
    ) async {
      final _FakeBridge bridge = _FakeBridge(accept: true);
      companionContexts.bindLookupSink(bridge.sendLookup);
      companionContexts.setActive(true);
      expect(await routeCompanionLookup(text: '読む', sentence: '本を読む。'), isTrue);
      expect(bridge.lookups.single, ('読む', -1, '本を読む。'));
    });

    testWidgets('panel not ready: falls back to the in-page popup', (
      WidgetTester tester,
    ) async {
      final _FakeBridge bridge = _FakeBridge(accept: false);
      companionContexts.bindLookupSink(bridge.sendLookup);
      companionContexts.setActive(true);
      expect(
        await routeCompanionLookup(text: '読む', sentence: '本を読む。'),
        isFalse,
      );
    });
  });

  group('info (cover + cached rating)', () {
    test('loaded once per title, outside the tick; missing = no keys', () {
      fakeAsync((FakeAsync async) {
        hook.claim('Series');
        registry.setActive(true);
        async.flushMicrotasks();
        expect(reader.infoLoads, 1);
        expect(snapshot().containsKey(MangaCompanionKeys.cover), isFalse);
        expect(snapshot().containsKey(MangaCompanionKeys.rating), isFalse);
        expect(snapshot().containsKey(MangaCompanionKeys.votes), isFalse);
        async.elapse(const Duration(seconds: 5));
        reader.page = 9;
        async.elapse(const Duration(seconds: 2));
        // Page turns do not reload it.
        expect(reader.infoLoads, 1);
        registry.setActive(false);
      });
    });

    test('published when it lands and reloaded for another title', () {
      fakeAsync((FakeAsync async) {
        reader.info = const MangaCompanionInfo(
          cover: '/covers/series.jpg',
          rating: 7.84,
          votes: 1234,
        );
        hook.claim('Series');
        registry.setActive(true);
        async.flushMicrotasks();
        expect(snapshot().str(MangaCompanionKeys.cover), '/covers/series.jpg');
        expect(snapshot().doubleOrNull(MangaCompanionKeys.rating), 7.84);
        expect(snapshot().intOrNull(MangaCompanionKeys.votes), 1234);
        reader
          ..title = 'Other'
          ..info = const MangaCompanionInfo(rating: 6.5);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(reader.infoLoads, 2);
        expect(snapshot().containsKey(MangaCompanionKeys.cover), isFalse);
        expect(snapshot().doubleOrNull(MangaCompanionKeys.rating), 6.5);
        expect(snapshot().containsKey(MangaCompanionKeys.votes), isFalse);
        registry.setActive(false);
      });
    });

    test('a zero rating is not shown', () {
      final Map<String, Object?> s = buildMangaCompanionSnapshot(
        const MangaCompanionReadState(
          title: 'T',
          pageKey: 'k',
          page: 0,
          pageCount: 1,
        ),
        ocr: MangaCompanionOcrState.idle,
        info: const MangaCompanionInfo(rating: 0, votes: 10, cover: ''),
      );
      expect(s.containsKey(MangaCompanionKeys.rating), isFalse);
      expect(s.containsKey(MangaCompanionKeys.votes), isFalse);
      expect(s.containsKey(MangaCompanionKeys.cover), isFalse);
    });
  });

  group('loadMangaCompanionRating', () {
    late FushiDatabase db;

    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('not in a collection: null', () async {
      expect(
        await loadMangaCompanionRating(db, bookKey: 'manga_a', bookUid: 'u1'),
        isNull,
      );
    });

    test('primary collection scrape rating, by uid or key', () async {
      final int first = await db.createMediaCollection('Series A');
      final int second = await db.createMediaCollection('Series B');
      await db.addToCollection(second, MediaKind.epub, 'u1');
      await db.addToCollection(first, MediaKind.epub, 'manga_a');
      await db.upsertCollectionScrapeMeta(
        CollectionScrapeMetaCompanion.insert(
          collectionId: Value<int>(first),
          source: 'bangumi',
          subjectId: '1',
          title: 'Series A',
          rating: const Value<double?>(7.6),
          ratingCount: const Value<int?>(321),
          scrapedAt: DateTime(2026),
        ),
      );
      await db.upsertCollectionScrapeMeta(
        CollectionScrapeMetaCompanion.insert(
          collectionId: Value<int>(second),
          source: 'bangumi',
          subjectId: '2',
          title: 'Series B',
          rating: const Value<double?>(5.0),
          scrapedAt: DateTime(2026),
        ),
      );
      final ({double rating, int? votes})? r = await loadMangaCompanionRating(
        db,
        bookKey: 'manga_a',
        bookUid: 'u1',
      );
      // Smallest collection id wins (the library's fold rule).
      expect(r?.rating, 7.6);
      expect(r?.votes, 321);
      expect(
        (await loadMangaCompanionRating(
          db,
          bookKey: 'x',
          bookUid: 'u1',
        ))?.rating,
        5.0,
      );
      expect((await loadMangaCompanionRating(db, bookKey: 'x'))?.votes, null);
    });

    test('a collection without a rating: null', () async {
      final int id = await db.createMediaCollection('Unrated');
      await db.addToCollection(id, MediaKind.epub, 'manga_b');
      await db.upsertCollectionScrapeMeta(
        CollectionScrapeMetaCompanion.insert(
          collectionId: Value<int>(id),
          source: 'bangumi',
          subjectId: '3',
          title: 'Unrated',
          scrapedAt: DateTime(2026),
        ),
      );
      expect(await loadMangaCompanionRating(db, bookKey: 'manga_b'), isNull);
    });
  });
}
