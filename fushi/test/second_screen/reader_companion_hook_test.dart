import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_lookup_routing.dart';
import 'package:fushi/src/second_screen/companion/companion_page_link.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/audiobook_companion_schema.dart';
import 'package:fushi/src/second_screen/companion/modules/reader_companion_hook.dart';
import 'package:fushi/src/second_screen/companion/modules/reader_companion_schema.dart';

class _FakeReaderPage implements ReaderCompanionPage {
  @override
  bool mounted = true;

  @override
  String? bookTitle = 'こころ';

  @override
  bool audiobookView = false;

  int chapter = 2;
  int readerBuilds = 0;
  int bookmarkLoads = 0;
  int statsLoads = 0;
  int infoLoads = 0;
  ReaderCompanionBookInfo info = const ReaderCompanionBookInfo(author: '夏目漱石');
  List<ReaderCompanionBookmark> bookmarks = <ReaderCompanionBookmark>[
    (id: 7, label: '先生と私', chapter: 3),
  ];
  final StreamController<void> bookmarkTable =
      StreamController<void>.broadcast();
  final List<(String, Map<String, Object?>)> readerCommands =
      <(String, Map<String, Object?>)>[];
  final List<(String, Map<String, Object?>)> audioCommands =
      <(String, Map<String, Object?>)>[];

  @override
  Map<String, Object?> readerState() {
    readerBuilds++;
    return <String, Object?>{
      ReaderCompanionKeys.chapterTitle: '上 先生と私',
      ReaderCompanionKeys.chapterIndex: chapter,
      ReaderCompanionKeys.chapterCount: 110,
      ReaderCompanionKeys.percent: 34.0,
      ReaderCompanionKeys.toc: const <Map<String, Object?>>[],
      ReaderCompanionKeys.tocCurrent: -1,
      ReaderCompanionKeys.hasAudio: false,
      ReaderCompanionKeys.playing: false,
    };
  }

  @override
  Map<String, Object?> audiobookState() => <String, Object?>{
    AudiobookCompanionKeys.chapterTitle: '上 先生と私',
    AudiobookCompanionKeys.playing: true,
    AudiobookCompanionKeys.speed: 1.0,
    AudiobookCompanionKeys.current: 0,
    AudiobookCompanionKeys.lines: const <Map<String, Object?>>[
      <String, Object?>{'index': 0, 'text': '私はその人を常に先生と呼んでいた。'},
    ],
  };

  @override
  Future<ReaderCompanionBookInfo> loadBookInfo() async {
    infoLoads++;
    return info;
  }

  @override
  bool get bookmarksEnabled => true;

  @override
  Future<List<ReaderCompanionBookmark>> loadBookmarks() async {
    bookmarkLoads++;
    return bookmarks;
  }

  @override
  Stream<void>? bookmarkChanges() => bookmarkTable.stream;

  @override
  Future<ReaderCompanionStats?> loadStats() async {
    statsLoads++;
    return (
      todayMs: 38 * 60000,
      todayChars: 9420,
      todayLookups: 14,
      todayCards: 2,
      allMs: 5 * 3600000,
      allChars: 123456,
    );
  }

  @override
  Future<void> runReaderCommand(
    String action,
    Map<String, Object?> args,
  ) async => readerCommands.add((action, args));

  @override
  Future<void> runAudiobookCommand(
    String action,
    Map<String, Object?> args,
  ) async => audioCommands.add((action, args));

  int lookupsCounted = 0;

  @override
  void countLookup() => lookupsCounted++;

  final List<String> lookupHold = <String>[];

  @override
  void lookupOpened() => lookupHold.add('opened');

  @override
  void lookupClosed({required bool resume}) => lookupHold.add('closed:$resume');
}

void main() {
  late CompanionContextRegistry registry;
  late _FakeReaderPage page;

  setUp(() {
    registry = CompanionContextRegistry();
    page = _FakeReaderPage();
  });

  tearDown(() => registry.dispose());

  group('CompanionPageLink', () {
    test('no builds and no timer while the companion is inactive', () {
      fakeAsync((FakeAsync async) {
        int builds = 0;
        final CompanionPageLink link = CompanionPageLink(registry: registry)
          ..claim(const CompanionContext(CompanionContextKind.reader))
          ..startSnapshots(() {
            builds++;
            return <String, Object?>{'n': builds};
          });
        async.elapse(const Duration(seconds: 5));
        expect(builds, 0);
        expect(async.periodicTimerCount, 0);
        registry.setActive(true);
        expect(builds, 1);
        async.elapse(const Duration(seconds: 3));
        expect(builds, 4);
        registry.setActive(false);
        expect(async.periodicTimerCount, 0);
        link.dispose();
      });
    });

    test('unchanged snapshots are not published again', () {
      fakeAsync((FakeAsync async) {
        registry.setActive(true);
        int notified = 0;
        registry.addListener(() => notified++);
        final CompanionPageLink link = CompanionPageLink(registry: registry)
          ..claim(const CompanionContext(CompanionContextKind.reader));
        notified = 0;
        link.startSnapshots(() => const <String, Object?>{'same': true});
        async.elapse(const Duration(seconds: 5));
        expect(notified, 1);
        expect(registry.currentSnapshot, <String, Object?>{'same': true});
        link.dispose();
      });
    });

    test('builds only while its page owns the context', () {
      fakeAsync((FakeAsync async) {
        registry.setActive(true);
        int builds = 0;
        final CompanionPageLink link = CompanionPageLink(registry: registry)
          ..claim(const CompanionContext(CompanionContextKind.reader))
          ..startSnapshots(() {
            builds++;
            return <String, Object?>{'n': builds};
          });
        final Object other = Object();
        registry.claim(
          other,
          const CompanionContext(CompanionContextKind.video),
        );
        final int before = builds;
        async.elapse(const Duration(seconds: 3));
        expect(builds, before);
        registry.release(other);
        async.elapse(const Duration(seconds: 1));
        expect(builds, greaterThan(before));
        link.dispose();
      });
    });
  });

  group('ReaderCompanionHook', () {
    test('companion lookups count through the page counter (reader and '
        'audiobook view)', () {
      final ReaderCompanionHook hook = ReaderCompanionHook(
        page,
        registry: registry,
      )..attach(null);
      expect(registry.countLookup(), isTrue);
      expect(page.lookupsCounted, 1);
      page.audiobookView = true;
      hook.attach(null);
      expect(registry.current.kind, CompanionContextKind.audiobook);
      expect(registry.countLookup(), isTrue);
      expect(page.lookupsCounted, 2);
      hook.dispose();
      expect(registry.countLookup(), isFalse);
      expect(page.lookupsCounted, 2);
    });

    test('pause on lookup: companion lookups reach the popup open / '
        'close path (reader and audiobook view)', () {
      final ReaderCompanionHook hook = ReaderCompanionHook(
        page,
        registry: registry,
      )..attach(null);
      expect(hook.lookupOpen, isFalse);
      registry.lookupOpened();
      expect(hook.lookupOpen, isTrue);
      registry.lookupClosed(resume: true);
      expect(hook.lookupOpen, isFalse);
      page.audiobookView = true;
      hook.attach(null);
      registry.lookupOpened();
      registry.lookupClosed(resume: false);
      expect(page.lookupHold, <String>[
        'opened',
        'closed:true',
        'opened',
        'closed:false',
      ]);
      registry.lookupOpened();
      hook.dispose();
      registry.lookupClosed(resume: true);
      expect(page.lookupHold.length, 5, reason: 'disposed page: no close');
    });

    test('inactive: claims but builds and loads nothing', () {
      fakeAsync((FakeAsync async) {
        final ReaderCompanionHook hook = ReaderCompanionHook(
          page,
          registry: registry,
        )..attach(null);
        async.elapse(const Duration(minutes: 3));
        expect(registry.current.kind, CompanionContextKind.reader);
        expect(registry.current.title, 'こころ');
        expect(page.readerBuilds, 0);
        expect(page.bookmarkLoads + page.statsLoads + page.infoLoads, 0);
        expect(async.periodicTimerCount, 0);
        hook.dispose();
      });
    });

    test('active: snapshot with book info, bookmarks and today stats', () {
      fakeAsync((FakeAsync async) {
        final ReaderCompanionHook hook = ReaderCompanionHook(
          page,
          registry: registry,
        )..attach(null);
        registry.setActive(true);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        final Map<String, Object?> snap = registry.currentSnapshot!;
        expect(snap.str(ReaderCompanionKeys.title), 'こころ');
        expect(snap.str(ReaderCompanionKeys.author), '夏目漱石');
        expect(snap.integer(ReaderCompanionKeys.chapterCount), 110);
        expect(snap.flag(ReaderCompanionKeys.bookmarksEnabled), isTrue);
        expect(
          snap.maps(ReaderCompanionKeys.bookmarks).single,
          <String, Object?>{'id': 7, 'label': '先生と私', 'chapter': 3},
        );
        expect(
          snap
              .mapOrNull(ReaderCompanionKeys.stats)!
              .integer(ReaderCompanionKeys.todayChars),
          9420,
        );
        // All-time totals and the bookmark count ride along (S5 info card);
        // no series declared: no series keys.
        expect(
          snap
              .mapOrNull(ReaderCompanionKeys.stats)!
              .integer(ReaderCompanionKeys.allChars),
          123456,
        );
        expect(snap.integer(ReaderCompanionKeys.bookmarkCount), 1);
        expect(snap.containsKey(ReaderCompanionKeys.series), isFalse);
        expect(snap.containsKey(ReaderCompanionKeys.seriesIndex), isFalse);
        hook.dispose();
      });
    });

    test('series from the book info, loaded once', () {
      fakeAsync((FakeAsync async) {
        page.info = const ReaderCompanionBookInfo(
          author: '夏目漱石',
          series: '漱石全集',
          seriesIndex: 3,
        );
        final ReaderCompanionHook hook = ReaderCompanionHook(
          page,
          registry: registry,
        )..attach(null);
        registry.setActive(true);
        async.elapse(const Duration(seconds: 5));
        final Map<String, Object?> snap = registry.currentSnapshot!;
        expect(snap.str(ReaderCompanionKeys.series), '漱石全集');
        expect(snap.intOrNull(ReaderCompanionKeys.seriesIndex), 3);
        expect(page.infoLoads, 1);
        hook.dispose();
      });
    });

    test('bookmarks reload on table changes; stats every period', () {
      fakeAsync((FakeAsync async) {
        final ReaderCompanionHook hook = ReaderCompanionHook(
          page,
          registry: registry,
        )..attach(null);
        registry.setActive(true);
        async.elapse(const Duration(seconds: 1));
        expect(page.bookmarkLoads, 1);
        expect(page.statsLoads, 1);
        page.bookmarks = <ReaderCompanionBookmark>[
          (id: 8, label: '雑司ヶ谷の墓地', chapter: 5),
          ...page.bookmarks,
        ];
        page.bookmarkTable.add(null);
        async.elapse(const Duration(seconds: 1));
        expect(page.bookmarkLoads, 2);
        expect(
          registry.currentSnapshot!.maps(ReaderCompanionKeys.bookmarks),
          hasLength(2),
        );
        async.elapse(const Duration(minutes: 1));
        expect(page.statsLoads, 2);
        registry.setActive(false);
        page.bookmarkTable.add(null);
        async.elapse(const Duration(minutes: 3));
        expect(page.bookmarkLoads, 2);
        expect(page.statsLoads, 2);
        expect(async.periodicTimerCount, 0);
        hook.dispose();
      });
    });

    test('audiobook view claims the audiobook context and routes its '
        'commands', () {
      fakeAsync((FakeAsync async) {
        final ReaderCompanionHook hook = ReaderCompanionHook(
          page,
          registry: registry,
        )..attach(null);
        registry.setActive(true);
        async.elapse(const Duration(seconds: 1));
        expect(
          registry.dispatchCommand(
            CompanionContextKind.reader,
            ReaderCompanionActions.turnPage,
            const <String, Object?>{ReaderCompanionActions.forward: true},
          ),
          isTrue,
        );
        async.flushMicrotasks();
        expect(page.readerCommands.single.$1, ReaderCompanionActions.turnPage);

        page.audiobookView = true;
        async.elapse(const Duration(seconds: 1));
        expect(registry.current.kind, CompanionContextKind.audiobook);
        final Map<String, Object?> snap = registry.currentSnapshot!;
        expect(snap.str(AudiobookCompanionKeys.title), 'こころ');
        expect(snap.maps(AudiobookCompanionKeys.lines), hasLength(1));
        // A reader command made for the old context is dropped.
        expect(
          registry.dispatchCommand(
            CompanionContextKind.reader,
            ReaderCompanionActions.turnPage,
            const <String, Object?>{},
          ),
          isFalse,
        );
        expect(
          registry.dispatchCommand(
            CompanionContextKind.audiobook,
            AudiobookCompanionActions.seekRelative,
            const <String, Object?>{AudiobookCompanionActions.seconds: -10},
          ),
          isTrue,
        );
        async.flushMicrotasks();
        expect(page.audioCommands.single, (
          AudiobookCompanionActions.seekRelative,
          const <String, Object?>{AudiobookCompanionActions.seconds: -10},
        ));
        hook.dispose();
        expect(registry.current.kind, CompanionContextKind.home);
      });
    });

    test('no snapshot until the book is loaded', () {
      fakeAsync((FakeAsync async) {
        page.bookTitle = null;
        final ReaderCompanionHook hook = ReaderCompanionHook(
          page,
          registry: registry,
        )..attach(null);
        registry.setActive(true);
        async.elapse(const Duration(seconds: 2));
        expect(registry.currentSnapshot, isNull);
        expect(page.infoLoads, 0);
        page.bookTitle = 'こころ';
        async.elapse(const Duration(seconds: 1));
        expect(registry.current.title, 'こころ');
        expect(registry.currentSnapshot, isNotNull);
        expect(page.infoLoads, 1);
        hook.dispose();
      });
    });
  });

  group('lookup routing', () {
    tearDown(() {
      companionContexts.setActive(false);
      companionContexts.bindLookupSink(null);
    });

    final List<(String, int, String?)> sent = <(String, int, String?)>[];
    bool accept = true;
    Future<bool> sink({
      required String text,
      int charIndex = -1,
      String? sentence,
    }) async {
      sent.add((text, charIndex, sentence));
      return accept;
    }

    setUp(() {
      sent.clear();
      accept = true;
      companionContexts.bindLookupSink(sink);
    });

    test('companion off: false, nothing sent (in-page popup)', () async {
      expect(await routeCompanionLookup(text: '先生と呼んでいた'), isFalse);
      expect(sent, isEmpty);
    });

    test('companion up: the Lookup tab takes it', () async {
      companionContexts.setActive(true);
      expect(
        await routeCompanionLookup(
          text: '私はその人を常に先生と呼んでいた。',
          charIndex: 8,
          sentence: '私はその人を常に先生と呼んでいた。',
        ),
        isTrue,
      );
      expect(sent.single.$2, 8);
    });

    test('panel did not take it / no sink / empty text: false', () async {
      companionContexts.setActive(true);
      accept = false;
      expect(await routeCompanionLookup(text: '先生'), isFalse);
      expect(await routeCompanionLookup(text: '  '), isFalse);
      companionContexts.bindLookupSink(null);
      expect(await routeCompanionLookup(text: '先生'), isFalse);
      expect(sent, hasLength(1));
    });
  });
}
