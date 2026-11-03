import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/source_review_navigation.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/platform/widget_link_actions.dart'
    show isWidgetContinueItemOpen;
import 'package:fushi/src/platform/widget_links.dart';
import 'package:material_ui/material_ui.dart';

/// Android 桌面小组件深链（`fushi://widget/...`）：解析、冷启动排队与落地行为。
/// 纯 Navigator 装置，不挂 AppModel / ProviderScope（与 app_shortcut_router_test
/// 同口径）。
void main() {
  const ModuleVisibility allModules = ModuleVisibility(<ModuleId>{
    ModuleId.books,
    ModuleId.manga,
    ModuleId.video,
    ModuleId.lookup,
    ModuleId.srs,
    ModuleId.music,
    ModuleId.games,
    ModuleId.cardCreation,
  });

  group('WidgetLink.tryParse', () {
    test('continue carries kind and id', () {
      final WidgetLink? link = WidgetLink.tryParse(
        'fushi://widget/continue?kind=manga&id=abc',
      );
      expect(
        link,
        const WidgetContinueLink(kind: WidgetMediaKind.manga, id: 'abc'),
      );
    });

    test('continue decodes percent-encoded ids', () {
      const String id = 'hoshi://book/a b&c';
      final WidgetLink? link = WidgetLink.tryParse(
        'fushi://widget/continue?kind=book&id=${Uri.encodeQueryComponent(id)}',
      );
      expect(link, WidgetContinueLink(kind: WidgetMediaKind.book, id: id));
    });

    test('continue with a missing id still parses (falls back to the tab)', () {
      expect(
        WidgetLink.tryParse('fushi://widget/continue?kind=video'),
        const WidgetContinueLink(kind: WidgetMediaKind.video, id: ''),
      );
    });

    test('continue needs a known kind', () {
      expect(WidgetLink.tryParse('fushi://widget/continue?id=x'), isNull);
      expect(
        WidgetLink.tryParse('fushi://widget/continue?kind=game&id=x'),
        isNull,
      );
      expect(WidgetLink.tryParse('fushi://widget/continue'), isNull);
    });

    test('srs, stats and open', () {
      expect(WidgetLink.tryParse('fushi://widget/srs'), isA<WidgetSrsLink>());
      expect(
        WidgetLink.tryParse('fushi://widget/stats'),
        isA<WidgetStatsLink>(),
      );
      expect(WidgetLink.tryParse('fushi://widget/open'), isA<WidgetOpenLink>());
    });

    test('tab links parse every destination', () {
      for (final WidgetTab tab in WidgetTab.values) {
        expect(WidgetLink.tryParse(tab.link), WidgetTabLink(tab));
      }
      expect(WidgetTab.values.map((WidgetTab t) => t.wire), <String>[
        'books',
        'manga',
        'video',
        'music',
        'games',
        'dictionaries',
        'srs',
      ]);
      expect(
        WidgetLink.tryParse('FUSHI://widget/TAB/Music'),
        const WidgetTabLink(WidgetTab.music),
      );
    });

    test('tab links reject unknown, empty or missing destinations', () {
      expect(WidgetLink.tryParse('fushi://widget/tab'), isNull);
      expect(WidgetLink.tryParse('fushi://widget/tab/'), isNull);
      expect(WidgetLink.tryParse('fushi://widget/tab/audiobooks'), isNull);
      expect(WidgetLink.tryParse('fushi://widget/tab/home'), isNull);
    });

    test('lookup carries the decoded, trimmed word', () {
      expect(
        WidgetLink.tryParse(
          'fushi://widget/lookup?word=%E9%A3%9F%E3%81%B9%E3%82%8B',
        ),
        const WidgetLookupLink('食べる'),
      );
      expect(
        WidgetLink.tryParse(
          'fushi://widget/lookup?word=${Uri.encodeQueryComponent('  كلمة & more ')}',
        ),
        const WidgetLookupLink('كلمة & more'),
      );
    });

    test('lookup without a word is rejected', () {
      expect(WidgetLink.tryParse('fushi://widget/lookup'), isNull);
      expect(WidgetLink.tryParse('fushi://widget/lookup?word='), isNull);
      expect(WidgetLink.tryParse('fushi://widget/lookup?word=%20%20'), isNull);
      expect(WidgetLink.tryParse('fushi://widget/lookup?w=x'), isNull);
    });

    test('settings and vocab links', () {
      expect(
        WidgetLink.tryParse('fushi://widget/settings/cards'),
        const WidgetSettingsLink(WidgetSettingsTarget.cards),
      );
      expect(
        WidgetLink.tryParse('fushi://widget/settings/widgets'),
        const WidgetSettingsLink(WidgetSettingsTarget.widgets),
      );
      expect(WidgetLink.tryParse('fushi://widget/settings'), isNull);
      expect(WidgetLink.tryParse('fushi://widget/settings/privacy'), isNull);
      expect(
        WidgetLink.tryParse('fushi://widget/vocab'),
        isA<WidgetVocabLink>(),
      );
    });

    test('music player link', () {
      expect(
        WidgetLink.tryParse(kWidgetMusicPlayerLink),
        isA<WidgetMusicPlayerLink>(),
      );
      expect(
        WidgetLink.tryParse('FUSHI://widget/Music/NOW'),
        isA<WidgetMusicPlayerLink>(),
      );
      expect(WidgetLink.tryParse('fushi://widget/music'), isNull);
      expect(WidgetLink.tryParse('fushi://widget/music/queue'), isNull);
    });

    test('continue links round-trip through toUri', () {
      const String id = 'reader_fushi://book/a b&c';
      const WidgetContinueLink link = WidgetContinueLink(
        kind: WidgetMediaKind.book,
        id: id,
      );
      expect(WidgetLink.tryParse(link.toUri()), link);
    });

    test('downloads link', () {
      expect(
        WidgetLink.tryParse('fushi://widget/downloads'),
        isA<WidgetDownloadsLink>(),
      );
    });

    test('server link carries source, server and item', () {
      final String url = WidgetServerLink.build(
        source: WidgetServerSource.audiobookshelf,
        serverId: 'srv 1',
        itemId: 'li_abc/ep&1',
      );
      expect(url, startsWith('fushi://widget/server?'));
      expect(
        WidgetLink.tryParse(url),
        const WidgetServerLink(
          source: WidgetServerSource.audiobookshelf,
          serverId: 'srv 1',
          itemId: 'li_abc/ep&1',
        ),
      );
      expect(
        WidgetLink.tryParse(
          'fushi://widget/server?source=mediaServer&server=s&item=i',
        ),
        const WidgetServerLink(
          source: WidgetServerSource.mediaServer,
          serverId: 's',
          itemId: 'i',
        ),
      );
    });

    test('server link needs a known source, server and item', () {
      for (final String bad in <String>[
        'fushi://widget/server',
        'fushi://widget/server?source=plex&server=s&item=i',
        'fushi://widget/server?source=mediaServer&item=i',
        'fushi://widget/server?source=mediaServer&server=s',
        'fushi://widget/server?source=mediaServer&server=&item=i',
      ]) {
        expect(WidgetLink.tryParse(bad), isNull, reason: bad);
      }
    });

    test('malformed input never throws', () {
      for (final String bad in <String>[
        'fushi://widget/tab/%',
        'fushi://widget/lookup?word=%E0%A4%A',
        'fushi://widget//tab/books',
        'fushi:widget/tab/books',
        ':::',
        'fushi://widget/tab/books/extra?x=%zz',
      ]) {
        expect(() => WidgetLink.tryParse(bad), returnsNormally, reason: bad);
      }
    });

    test('tab modules map to the module gate and home tab', () {
      expect(WidgetTab.music.module, ModuleId.music);
      expect(WidgetTab.music.homeTab, HomeTab.music);
      expect(WidgetTab.games.module, ModuleId.games);
      expect(WidgetTab.games.homeTab, HomeTab.games);
      expect(WidgetTab.dictionaries.module, ModuleId.lookup);
      expect(WidgetTab.dictionaries.homeTab, HomeTab.dictionaries);
      expect(WidgetTab.srs.module, ModuleId.srs);
      expect(WidgetTab.srs.homeTab, HomeTab.srs);
    });

    test('scheme, host and action match case-insensitively', () {
      expect(WidgetLink.tryParse('FUSHI://Widget/SRS'), isA<WidgetSrsLink>());
    });

    test('rejects everything that is not a known widget link', () {
      expect(WidgetLink.tryParse(null), isNull);
      expect(WidgetLink.tryParse(''), isNull);
      expect(WidgetLink.tryParse('fushi://widget'), isNull);
      expect(WidgetLink.tryParse('fushi://widget/'), isNull);
      expect(WidgetLink.tryParse('fushi://widget/unknown'), isNull);
      expect(WidgetLink.tryParse('fushi://shortcut/books'), isNull);
      expect(WidgetLink.tryParse('fushi://lookup?word=x'), isNull);
      expect(WidgetLink.tryParse('https://widget/srs'), isNull);
    });

    test('media kinds map to their module and tab', () {
      expect(WidgetMediaKind.book.module, ModuleId.books);
      expect(WidgetMediaKind.book.homeTab, HomeTab.books);
      expect(WidgetMediaKind.manga.module, ModuleId.manga);
      expect(WidgetMediaKind.manga.homeTab, HomeTab.manga);
      expect(WidgetMediaKind.video.module, ModuleId.video);
      expect(WidgetMediaKind.video.homeTab, HomeTab.video);
    });
  });

  group('WidgetLinkQueue (cold start)', () {
    testWidgets(
      'holds the link until ready, then runs only the last one once',
      (WidgetTester tester) async {
        await tester.pumpWidget(const SizedBox());
        final List<WidgetLink> ran = <WidgetLink>[];
        final WidgetLinkQueue queue = WidgetLinkQueue(
          isActive: () => true,
          run: (WidgetLink l) async => ran.add(l),
        );

        queue.enqueue(const WidgetSrsLink(), ready: false);
        queue.enqueue(const WidgetStatsLink(), ready: false);
        await tester.pump();
        expect(ran, isEmpty, reason: 'not initialised yet: must wait');

        queue.schedule();
        queue.schedule();
        await tester.pump();
        expect(ran, hasLength(1));
        expect(ran.single, isA<WidgetStatsLink>());
        expect(queue.pending, isNull);

        queue.schedule();
        await tester.pump();
        expect(ran, hasLength(1), reason: 'nothing pending: no-op');
      },
    );

    testWidgets('a ready app runs it on the next frame', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final List<WidgetLink> ran = <WidgetLink>[];
      final WidgetLinkQueue queue = WidgetLinkQueue(
        isActive: () => true,
        run: (WidgetLink l) async => ran.add(l),
      );
      queue.enqueue(const WidgetOpenLink(), ready: true);
      await tester.pump();
      expect(ran.single, isA<WidgetOpenLink>());
    });

    testWidgets('drops the link when the host was unmounted meanwhile', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final List<WidgetLink> ran = <WidgetLink>[];
      bool active = true;
      final WidgetLinkQueue queue = WidgetLinkQueue(
        isActive: () => active,
        run: (WidgetLink l) async => ran.add(l),
      );
      queue.enqueue(const WidgetSrsLink(), ready: true);
      active = false;
      await tester.pump();
      expect(ran, isEmpty);
    });
  });

  group('runWidgetLink', () {
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
    late List<HomeTab> selectedTabs;
    late List<WidgetContinueLink> openedItems;
    late int srsOpens;
    late int statsOpens;
    late List<String> lookups;
    late List<WidgetSettingsTarget> settingsOpens;
    late int vocabOpens;
    late int musicPlayerOpens;
    late int downloadsOpens;
    late List<WidgetServerLink> serverOpens;
    late bool itemExists;
    late bool srsHasWork;
    late ExternalMediaNavigation media;

    setUp(() {
      selectedTabs = <HomeTab>[];
      openedItems = <WidgetContinueLink>[];
      srsOpens = 0;
      statsOpens = 0;
      lookups = <String>[];
      settingsOpens = <WidgetSettingsTarget>[];
      vocabOpens = 0;
      musicPlayerOpens = 0;
      downloadsOpens = 0;
      serverOpens = <WidgetServerLink>[];
      itemExists = true;
      srsHasWork = true;
    });

    Future<void> pumpHome(WidgetTester tester) {
      media = ExternalMediaNavigation.forTesting();
      return tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('home')),
        ),
      );
    }

    Future<void> run(
      WidgetTester tester,
      WidgetLink link, {
      ModuleVisibility visibility = allModules,
      bool onboardingCompleted = true,
      bool Function(WidgetContinueLink link)? isContinueItemOpen,
    }) async {
      bool done = false;
      runWidgetLink(
        link,
        visibility: visibility,
        onboardingCompleted: onboardingCompleted,
        navigator: navigatorKey.currentState,
        selectHomeTab: selectedTabs.add,
        openContinueItem: (WidgetContinueLink l) async {
          openedItems.add(l);
          return itemExists;
        },
        openSrsReview: () async {
          srsOpens++;
          return srsHasWork;
        },
        openStats: () async => statsOpens++,
        openLookup: (String word) async => lookups.add(word),
        openSettings: (WidgetSettingsTarget t) async => settingsOpens.add(t),
        openVocab: () async => vocabOpens++,
        openMusicPlayer: () async => musicPlayerOpens++,
        openDownloads: () async => downloadsOpens++,
        openServerItem: (WidgetServerLink l) async {
          serverOpens.add(l);
          return true;
        },
        isContinueItemOpen: isContinueItemOpen,
        media: media,
      ).whenComplete(() => done = true);
      await tester.pumpAndSettle();
      expect(done, isTrue, reason: 'runWidgetLink must finish, not hang');
    }

    testWidgets('open does nothing', (WidgetTester tester) async {
      await pumpHome(tester);
      await run(tester, const WidgetOpenLink());
      expect(selectedTabs, isEmpty);
      expect(openedItems, isEmpty);
      expect(srsOpens + statsOpens, 0);
    });

    testWidgets('continue selects the tab then opens the item', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      const WidgetContinueLink link = WidgetContinueLink(
        kind: WidgetMediaKind.manga,
        id: 'm1',
      );
      await run(tester, link);
      expect(selectedTabs, <HomeTab>[HomeTab.manga]);
      expect(openedItems, <WidgetContinueLink>[link]);
    });

    testWidgets('continue on the item that is already open does nothing', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      const WidgetContinueLink link = WidgetContinueLink(
        kind: WidgetMediaKind.book,
        id: 'fushi://book/a',
      );
      await run(
        tester,
        link,
        isContinueItemOpen: (WidgetContinueLink l) => l == link,
      );
      expect(selectedTabs, isEmpty, reason: 'must not leave the open page');
      expect(openedItems, isEmpty, reason: 'must not reload the open item');
    });

    testWidgets(
      'continue on a different item than the open one still opens it',
      (WidgetTester tester) async {
        await pumpHome(tester);
        const WidgetContinueLink link = WidgetContinueLink(
          kind: WidgetMediaKind.book,
          id: 'fushi://book/b',
        );
        await run(tester, link, isContinueItemOpen: (_) => false);
        expect(selectedTabs, <HomeTab>[HomeTab.books]);
        expect(openedItems, <WidgetContinueLink>[link]);
      },
    );

    testWidgets('the open-item check only gates continue links', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(
        tester,
        const WidgetStatsLink(),
        isContinueItemOpen: (_) => true,
      );
      expect(statsOpens, 1);
    });

    testWidgets('continue still lands on the tab when the item is gone', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      itemExists = false;
      await run(
        tester,
        const WidgetContinueLink(kind: WidgetMediaKind.video, id: 'gone'),
      );
      expect(selectedTabs, <HomeTab>[HomeTab.video]);
      expect(openedItems, hasLength(1), reason: 'the opener decides existence');
    });

    testWidgets('continue into a disabled module is ignored', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(
        tester,
        const WidgetContinueLink(kind: WidgetMediaKind.video, id: 'v'),
        visibility: const ModuleVisibility(<ModuleId>{ModuleId.books}),
      );
      expect(selectedTabs, isEmpty);
      expect(openedItems, isEmpty);
    });

    testWidgets('before onboarding it only switches tab', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(
        tester,
        const WidgetContinueLink(kind: WidgetMediaKind.book, id: 'b'),
        onboardingCompleted: false,
      );
      expect(selectedTabs, <HomeTab>[HomeTab.books]);
      expect(openedItems, isEmpty);
    });

    testWidgets('does not open over a page that refuses to close', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => PopScope(
            canPop: false,
            child: const Scaffold(body: Text('blocked')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await run(
        tester,
        const WidgetContinueLink(kind: WidgetMediaKind.book, id: 'b'),
      );
      expect(selectedTabs, <HomeTab>[HomeTab.books]);
      expect(openedItems, isEmpty);
    });

    testWidgets('srs opens the review, needs the module', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(tester, const WidgetSrsLink());
      expect(selectedTabs, <HomeTab>[HomeTab.srs]);
      expect(srsOpens, 1);

      selectedTabs.clear();
      srsOpens = 0;
      await run(
        tester,
        const WidgetSrsLink(),
        visibility: const ModuleVisibility(<ModuleId>{ModuleId.books}),
      );
      expect(selectedTabs, isEmpty);
      expect(srsOpens, 0);
    });

    testWidgets('stats opens the statistics page', (WidgetTester tester) async {
      await pumpHome(tester);
      await run(tester, const WidgetStatsLink());
      expect(selectedTabs, <HomeTab>[HomeTab.home]);
      expect(statsOpens, 1);
    });

    testWidgets('tab links only switch the tab', (WidgetTester tester) async {
      await pumpHome(tester);
      for (final WidgetTab tab in WidgetTab.values) {
        selectedTabs.clear();
        await run(tester, WidgetTabLink(tab));
        expect(selectedTabs, <HomeTab>[tab.homeTab], reason: '$tab');
      }
      expect(openedItems, isEmpty);
      expect(srsOpens + statsOpens + vocabOpens + lookups.length, 0);
    });

    testWidgets('a tab whose module is off falls back to home', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(
        tester,
        const WidgetTabLink(WidgetTab.music),
        visibility: const ModuleVisibility(<ModuleId>{ModuleId.books}),
      );
      expect(selectedTabs, <HomeTab>[HomeTab.home]);
    });

    testWidgets('lookup switches to the dictionary tab and delivers the word', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(tester, const WidgetLookupLink('食べる'));
      expect(selectedTabs, <HomeTab>[HomeTab.dictionaries]);
      expect(lookups, <String>['食べる']);
    });

    testWidgets('lookup is ignored when the dictionary module is off', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(
        tester,
        const WidgetLookupLink('x'),
        visibility: const ModuleVisibility(<ModuleId>{ModuleId.books}),
      );
      expect(selectedTabs, isEmpty);
      expect(lookups, isEmpty);
    });

    testWidgets('settings links open their page over the settings tab', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(tester, const WidgetSettingsLink(WidgetSettingsTarget.widgets));
      expect(selectedTabs, <HomeTab>[HomeTab.settings]);
      expect(settingsOpens, <WidgetSettingsTarget>[
        WidgetSettingsTarget.widgets,
      ]);
    });

    testWidgets('card settings need the card creation module', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(tester, const WidgetSettingsLink(WidgetSettingsTarget.cards));
      expect(settingsOpens, <WidgetSettingsTarget>[WidgetSettingsTarget.cards]);

      selectedTabs.clear();
      settingsOpens.clear();
      await run(
        tester,
        const WidgetSettingsLink(WidgetSettingsTarget.cards),
        visibility: const ModuleVisibility(<ModuleId>{ModuleId.books}),
      );
      expect(selectedTabs, <HomeTab>[HomeTab.home]);
      expect(settingsOpens, isEmpty);
    });

    testWidgets('vocab opens the collections page', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(tester, const WidgetVocabLink());
      expect(selectedTabs, <HomeTab>[HomeTab.home]);
      expect(vocabOpens, 1);
    });

    testWidgets('music player opens the player on the music tab', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(tester, const WidgetMusicPlayerLink());
      expect(selectedTabs, <HomeTab>[HomeTab.music]);
      expect(musicPlayerOpens, 1);
    });

    testWidgets('music player with the music module off falls back home', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(
        tester,
        const WidgetMusicPlayerLink(),
        visibility: const ModuleVisibility(<ModuleId>{ModuleId.books}),
      );
      expect(selectedTabs, <HomeTab>[HomeTab.home]);
      expect(musicPlayerOpens, 0);
    });

    testWidgets('downloads opens the browse tab then the download center', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(
        tester,
        const WidgetDownloadsLink(),
        visibility: const ModuleVisibility(<ModuleId>{ModuleId.browse}),
      );
      expect(selectedTabs, <HomeTab>[HomeTab.browse]);
      expect(downloadsOpens, 1);
    });

    testWidgets('downloads does nothing when the browse module is off', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(tester, const WidgetDownloadsLink());
      expect(selectedTabs, isEmpty);
      expect(downloadsOpens, 0);
    });

    testWidgets('server item lands on home then opens the item', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      const WidgetServerLink link = WidgetServerLink(
        source: WidgetServerSource.mediaServer,
        serverId: 's',
        itemId: 'i',
      );
      await run(tester, link);
      expect(selectedTabs, <HomeTab>[HomeTab.home]);
      expect(serverOpens, <WidgetServerLink>[link]);
    });

    testWidgets('server item respects its module gate', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(
        tester,
        const WidgetServerLink(
          source: WidgetServerSource.audiobookshelf,
          serverId: 's',
          itemId: 'i',
        ),
        visibility: const ModuleVisibility(<ModuleId>{ModuleId.video}),
      );
      expect(selectedTabs, isEmpty);
      expect(serverOpens, isEmpty);
    });

    testWidgets('before onboarding new links only switch tab', (
      WidgetTester tester,
    ) async {
      await pumpHome(tester);
      await run(
        tester,
        const WidgetLookupLink('x'),
        onboardingCompleted: false,
      );
      expect(selectedTabs, <HomeTab>[HomeTab.dictionaries]);
      expect(lookups, isEmpty);
    });
  });

  group('isWidgetContinueItemOpen', () {
    const WidgetContinueLink book = WidgetContinueLink(
      kind: WidgetMediaKind.book,
      id: 'fushi://book/a',
    );
    const WidgetContinueLink video = WidgetContinueLink(
      kind: WidgetMediaKind.video,
      id: 'uid-1',
    );

    test('books and manga match the open media identifier', () {
      expect(
        isWidgetContinueItemOpen(
          book,
          openMediaIdentifier: 'fushi://book/a',
          activeVideoUid: null,
        ),
        isTrue,
      );
      expect(
        isWidgetContinueItemOpen(
          book,
          openMediaIdentifier: 'fushi://book/other',
          activeVideoUid: 'fushi://book/a',
        ),
        isFalse,
        reason: 'a playing video must not count as an open book',
      );
      expect(
        isWidgetContinueItemOpen(
          book,
          openMediaIdentifier: null,
          activeVideoUid: null,
        ),
        isFalse,
      );
    });

    test('videos match the registered playing uid', () {
      expect(
        isWidgetContinueItemOpen(
          video,
          openMediaIdentifier: null,
          activeVideoUid: 'uid-1',
        ),
        isTrue,
      );
      expect(
        isWidgetContinueItemOpen(
          video,
          openMediaIdentifier: 'uid-1',
          activeVideoUid: 'uid-2',
        ),
        isFalse,
      );
    });

    test('an empty id is never "open"', () {
      expect(
        isWidgetContinueItemOpen(
          const WidgetContinueLink(kind: WidgetMediaKind.book, id: ''),
          openMediaIdentifier: '',
          activeVideoUid: '',
        ),
        isFalse,
      );
    });
  });
}
