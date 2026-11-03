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
    late bool itemExists;
    late bool srsHasWork;
    late ExternalMediaNavigation media;

    setUp(() {
      selectedTabs = <HomeTab>[];
      openedItems = <WidgetContinueLink>[];
      srsOpens = 0;
      statsOpens = 0;
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
