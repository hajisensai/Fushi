import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_shell.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_browse.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_details_page.dart';
import 'package:material_ui/material_ui.dart';

import 'companion_panel_harness.dart';

const CompanionLibraryItem _book = CompanionLibraryItem(
  ref: 'book:kokoro',
  kind: CompanionLibraryItemKind.book,
  title: 'こころ',
  subtitle: '夏目漱石',
  progress: 0.34,
  progressLabel: '34%',
);

const CompanionLibraryItem _video = CompanionLibraryItem(
  ref: 'video:v1',
  kind: CompanionLibraryItemKind.video,
  title: 'Series A',
  progressLabel: 'E7',
);

const CompanionLibraryItem _manga = CompanionLibraryItem(
  ref: 'manga:m1',
  kind: CompanionLibraryItemKind.manga,
  title: 'Manga B',
  finished: true,
);

const CompanionLibraryItem _server = CompanionLibraryItem(
  ref: 'server:jellyfin.1',
  kind: CompanionLibraryItemKind.server,
  title: 'Home server',
);

const CompanionLibraryItem _onlineManga = CompanionLibraryItem(
  ref: 'mainOnly:onlineManga',
  kind: CompanionLibraryItemKind.mainOnly,
  title: 'Online manga',
  mainTarget: CompanionLibraryMainTarget.onlineManga,
);

const CompanionLibraryHome _home = CompanionLibraryHome(
  rows: <CompanionLibraryHomeRow>[
    CompanionLibraryHomeRow(
      kind: CompanionLibraryHomeRowKind.continueItems,
      items: <CompanionLibraryItem>[_book, _video],
    ),
    CompanionLibraryHomeRow(
      kind: CompanionLibraryHomeRowKind.recentlyAdded,
      items: <CompanionLibraryItem>[_manga],
    ),
  ],
  sections: <CompanionLibrarySection>[
    CompanionLibrarySection.home,
    CompanionLibrarySection.books,
    CompanionLibrarySection.manga,
    CompanionLibrarySection.servers,
  ],
);

const CompanionDailySummary _summary = CompanionDailySummary(
  dayKey: '2026-11-07',
  readingMs: 60000,
);

List<CompanionLibraryItem> _numbered(int from, int count) =>
    <CompanionLibraryItem>[
      for (int i = from; i < from + count; i++)
        CompanionLibraryItem(
          ref: 'book:b$i',
          kind: CompanionLibraryItemKind.book,
          title: 'Book $i',
        ),
    ];

void main() {
  late RecordingCompanionSession rec;

  setUp(() => rec = RecordingCompanionSession());

  List<CompanionRequestMessage> requests(String method) => rec.sent
      .whereType<CompanionRequestMessage>()
      .where((CompanionRequestMessage r) => r.method == method)
      .toList();

  void reply(CompanionRequestMessage request, Object? value) =>
      rec.push(CompanionReplyMessage(id: request.id, value: value));

  void fail(CompanionRequestMessage request, String error) =>
      rec.push(CompanionReplyMessage(id: request.id, error: error));

  Future<void> pumpBrowse(WidgetTester tester) async {
    await pumpCompanionPanel(
      tester,
      rec.session,
      const CompanionLibraryBrowseRoot(),
    );
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await pumpBrowse(tester);
    reply(requests(CompanionRequestMethods.libraryHome).single, _home.toJson());
    await tester.pumpAndSettle();
  }

  Finder chip(CompanionLibrarySection s) =>
      find.byKey(ValueKey<String>('companion-library-section-${s.wire}'));

  Finder searchField() => find.descendant(
    of: find.byKey(const ValueKey<String>('companion-library-search')),
    matching: find.byType(EditableText),
  );

  testWidgets('Home: rows, chips from the reply and the main-screen footer', (
    WidgetTester tester,
  ) async {
    await pumpBrowse(tester);
    expect(
      find.byKey(const ValueKey<String>('companion-library-loading')),
      findsOneWidget,
    );
    reply(requests(CompanionRequestMethods.libraryHome).single, _home.toJson());
    await tester.pumpAndSettle();

    expect(find.text(t.second_screen_library_browse_row_continue), findsOne);
    expect(
      find.text(t.second_screen_library_browse_row_recently_added),
      findsOne,
    );
    expect(find.text('こころ'), findsOneWidget);
    expect(find.text('夏目漱石 · 34%'), findsOneWidget);
    expect(find.text('Series A'), findsOneWidget);
    expect(find.text('Manga B'), findsOneWidget);
    expect(chip(CompanionLibrarySection.books), findsOneWidget);
    expect(chip(CompanionLibrarySection.servers), findsOneWidget);
    expect(chip(CompanionLibrarySection.video), findsNothing);
    expect(
      find.text(t.second_screen_library_browse_search_everything),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('companion-library-open-statistics')),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(
              const ValueKey<String>('companion-library-home-list'),
            ),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('companion-library-open-statistics')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('companion-library-open-statistics')),
    );
    await tester.pump();
    final CompanionRequestMessage open = requests(
      CompanionRequestMethods.libraryOpenOnMain,
    ).single;
    expect(open.args[CompanionLibraryArgs.target], 'statistics');
    reply(open, null);
    await tester.pumpAndSettle();
    expect(
      find.text(t.second_screen_library_browse_opened_on_main),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('section switch asks for the list; search on Home searches '
      'everything; search in a section filters only it', (
    WidgetTester tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(chip(CompanionLibrarySection.books));
    await tester.pumpAndSettle();
    final CompanionRequestMessage list = requests(
      CompanionRequestMethods.libraryList,
    ).single;
    expect(list.args, <String, Object?>{
      CompanionLibraryArgs.section: 'books',
      CompanionLibraryArgs.offset: 0,
      CompanionLibraryArgs.limit: CompanionLibraryArgs.pageSize,
    });
    reply(list, CompanionLibraryPage(items: _numbered(0, 3)).toJson());
    await tester.pumpAndSettle();
    expect(find.text('Book 2'), findsOneWidget);
    expect(find.text(t.second_screen_library_browse_search_list), findsOne);

    await tester.enterText(searchField(), 'abc');
    await tester.pump();
    final CompanionRequestMessage filtered = requests(
      CompanionRequestMethods.libraryList,
    ).last;
    expect(filtered.args[CompanionLibraryArgs.section], 'books');
    expect(filtered.args[CompanionLibraryArgs.query], 'abc');
    reply(filtered, const CompanionLibraryPage(items: []).toJson());
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_library_browse_no_match), findsOneWidget);
    expect(requests(CompanionRequestMethods.librarySearch), isEmpty);

    // Clearing restores the whole list.
    await tester.enterText(searchField(), '');
    await tester.pump();
    final CompanionRequestMessage cleared = requests(
      CompanionRequestMethods.libraryList,
    ).last;
    expect(cleared.args.containsKey(CompanionLibraryArgs.query), isFalse);
    reply(cleared, CompanionLibraryPage(items: _numbered(0, 3)).toJson());
    await tester.pumpAndSettle();
    expect(find.text('Book 1'), findsOneWidget);

    // Home: "Search everything".
    await tester.tap(chip(CompanionLibrarySection.home));
    await tester.pumpAndSettle();
    await tester.enterText(searchField(), 'neko');
    await tester.pump();
    final CompanionRequestMessage search = requests(
      CompanionRequestMethods.librarySearch,
    ).single;
    expect(search.args, <String, Object?>{
      CompanionLibraryArgs.query: 'neko',
      CompanionLibraryArgs.offset: 0,
      CompanionLibraryArgs.limit: CompanionLibraryArgs.pageSize,
    });
    reply(
      search,
      const CompanionLibraryPage(
        items: <CompanionLibraryItem>[_manga],
      ).toJson(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Manga B'), findsOneWidget);
    expect(
      find.text(t.second_screen_library_browse_row_continue),
      findsNothing,
    );
    await tester.enterText(searchField(), '');
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_library_browse_row_continue), findsOne);
    expect(requests(CompanionRequestMethods.libraryHome), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('paging: the next page near the end, appended; Load more', (
    WidgetTester tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(chip(CompanionLibrarySection.books));
    await tester.pumpAndSettle();
    reply(
      requests(CompanionRequestMethods.libraryList).single,
      CompanionLibraryPage(
        items: _numbered(0, 2),
        hasMore: true,
        total: 50,
      ).toJson(),
    );
    await tester.pumpAndSettle();
    // A short first page: the Load more row asks for the next one.
    final Finder loadMore = find.byKey(
      const ValueKey<String>('companion-library-load-more'),
    );
    expect(loadMore, findsOneWidget);
    await tester.tap(loadMore);
    await tester.pump();
    final CompanionRequestMessage second = requests(
      CompanionRequestMethods.libraryList,
    ).last;
    expect(second.args[CompanionLibraryArgs.offset], 2);
    expect(second.args[CompanionLibraryArgs.limit], 40);
    reply(
      second,
      CompanionLibraryPage(
        items: _numbered(2, 40),
        offset: 2,
        hasMore: true,
      ).toJson(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Book 0'), findsOneWidget);
    expect(requests(CompanionRequestMethods.libraryList), hasLength(2));

    // Scrolling near the end loads the third page by itself.
    await tester.drag(
      find.byKey(const ValueKey<String>('companion-library-grid')),
      const Offset(0, -2400),
    );
    await tester.pump();
    final CompanionRequestMessage third = requests(
      CompanionRequestMethods.libraryList,
    ).last;
    expect(third.args[CompanionLibraryArgs.offset], 42);
    reply(
      third,
      CompanionLibraryPage(items: _numbered(42, 3), offset: 42).toJson(),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey<String>('companion-library-grid')),
      const Offset(0, -2400),
    );
    await tester.pumpAndSettle();
    expect(find.text('Book 44'), findsOneWidget);
    expect(loadMore, findsNothing);
    expect(requests(CompanionRequestMethods.libraryList), hasLength(3));

    // A library change reloads the visible list, keeping what was loaded.
    rec.push(const CompanionLibraryChangedMessage());
    await tester.pump();
    final CompanionRequestMessage reload = requests(
      CompanionRequestMethods.libraryList,
    ).last;
    expect(reload.args[CompanionLibraryArgs.offset], 0);
    expect(reload.args[CompanionLibraryArgs.limit], 45);
    // Home (hidden) reloads only when shown again.
    expect(requests(CompanionRequestMethods.libraryHome), hasLength(1));
    reply(reload, CompanionLibraryPage(items: _numbered(0, 45)).toJson());
    await tester.pumpAndSettle();
    await tester.tap(chip(CompanionLibrarySection.home));
    await tester.pump();
    expect(requests(CompanionRequestMethods.libraryHome), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('media-server pages continue at the reply nextOffset', (
    WidgetTester tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(chip(CompanionLibrarySection.servers));
    await tester.pumpAndSettle();
    reply(
      requests(CompanionRequestMethods.libraryList).single,
      CompanionLibraryPage(
        items: _numbered(0, 2),
        hasMore: true,
        nextOffset: 10,
      ).toJson(),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('companion-library-load-more')),
    );
    await tester.pump();
    expect(
      requests(
        CompanionRequestMethods.libraryList,
      ).last.args[CompanionLibraryArgs.offset],
      10,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a container opens its list with parent; main-only entries '
      'open on the main screen', (WidgetTester tester) async {
    await pumpHome(tester);
    await tester.tap(chip(CompanionLibrarySection.servers));
    await tester.pumpAndSettle();
    reply(
      requests(CompanionRequestMethods.libraryList).single,
      const CompanionLibraryPage(
        items: <CompanionLibraryItem>[_server, _onlineManga],
      ).toJson(),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Online manga'));
    await tester.pump();
    final CompanionRequestMessage onMain = requests(
      CompanionRequestMethods.libraryOpenOnMain,
    ).single;
    expect(onMain.args[CompanionLibraryArgs.target], 'onlineManga');
    reply(onMain, null);
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_library_browse_opened_on_main), findsOne);

    await tester.tap(find.text('Home server'));
    await tester.pumpAndSettle();
    final CompanionRequestMessage children = requests(
      CompanionRequestMethods.libraryList,
    ).last;
    expect(children.args[CompanionLibraryArgs.section], 'servers');
    expect(children.args[CompanionLibraryArgs.parent], 'server:jellyfin.1');
    reply(
      children,
      CompanionLibraryPage(items: _numbered(0, 2), title: 'Jellyfin').toJson(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Jellyfin'), findsOneWidget);
    expect(find.text('Book 1'), findsOneWidget);

    // Back pops the list page.
    await tester.tap(
      find.byKey(const ValueKey<String>('companion-library-back')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Home server'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('load errors show the reply text and Retry asks again', (
    WidgetTester tester,
  ) async {
    await pumpBrowse(tester);
    fail(
      requests(CompanionRequestMethods.libraryHome).single,
      'Server offline',
    );
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_library_browse_load_failed), findsOne);
    expect(find.text('Server offline'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('companion-library-retry')),
    );
    await tester.pump();
    final List<CompanionRequestMessage> homes = requests(
      CompanionRequestMethods.libraryHome,
    );
    expect(homes, hasLength(2));
    reply(homes.last, _home.toJson());
    await tester.pumpAndSettle();
    expect(find.text('こころ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('details', () {
    Future<CompanionRequestMessage> pumpDetails(WidgetTester tester) async {
      await pumpCompanionPanel(
        tester,
        rec.session,
        const CompanionLibraryDetailsPage(
          itemRef: 'video:v1',
          title: 'Series A',
        ),
      );
      final CompanionRequestMessage request = requests(
        CompanionRequestMethods.libraryDetails,
      ).single;
      expect(request.args[CompanionLibraryArgs.ref], 'video:v1');
      return request;
    }

    testWidgets('missing fields are hidden', (WidgetTester tester) async {
      final CompanionRequestMessage request = await pumpDetails(tester);
      reply(
        request,
        const CompanionLibraryDetails(
          item: CompanionLibraryItem(
            ref: 'video:v1',
            kind: CompanionLibraryItemKind.video,
            title: 'Series A',
          ),
        ).toJson(),
      );
      await tester.pumpAndSettle();
      expect(find.text('Series A'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('companion-library-details-line')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('companion-library-genres')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('companion-library-description')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('companion-library-mark')),
        findsNothing,
      );
      expect(find.text(t.second_screen_library_browse_open_on_top), findsOne);
      expect(tester.takeException(), isNull);
    });

    testWidgets('full details: line, description More, genres, facts, '
        'entries; entry and mark finished requests', (
      WidgetTester tester,
    ) async {
      final CompanionRequestMessage request = await pumpDetails(tester);
      reply(
        request,
        CompanionLibraryDetails(
          item: const CompanionLibraryItem(
            ref: 'video:v1',
            kind: CompanionLibraryItemKind.video,
            title: 'Series A',
            count: 12,
          ),
          author: 'Studio X',
          description: List<String>.filled(30, 'A long overview.').join(' '),
          genres: const <String>['Drama', 'Slice of life'],
          rating: 8.1,
          year: 2020,
          facts: const <CompanionLibraryFact>[
            CompanionLibraryFact(label: 'Studio', value: 'Studio X'),
          ],
          entries: const <CompanionLibraryEntry>[
            CompanionLibraryEntry(id: 'e3', title: 'E3', subtitle: 'Watched'),
            CompanionLibraryEntry(
              id: 'e4',
              title: 'E4',
              subtitle: 'Next · 6:20 in',
              current: true,
            ),
          ],
          entriesLabel: 'Episodes',
          continueLabel: 'Continue E4 on top',
          canMarkFinished: true,
        ).toJson(),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          '${t.second_screen_library_browse_item_count(n: 12)} · ★ 8.1 · 2020',
        ),
        findsOneWidget,
      );
      expect(find.text('Continue E4 on top'), findsOneWidget);
      expect(find.text('Drama'), findsOneWidget);
      final Text description = tester.widget<Text>(
        find.byKey(const ValueKey<String>('companion-library-description')),
      );
      expect(description.maxLines, 2);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('companion-library-description-more'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey<String>('companion-library-description'),
              ),
            )
            .maxLines,
        isNull,
      );

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('companion-library-entry-e4')),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Studio'), findsOneWidget);
      expect(
        find.text(
          t.second_screen_library_browse_entries_hint(label: 'Episodes'),
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('companion-library-entry-e4')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('companion-library-entry-e4')),
      );
      await tester.pump();
      final CompanionRequestMessage open = requests(
        CompanionRequestMethods.libraryOpen,
      ).single;
      expect(open.args, <String, Object?>{
        CompanionLibraryArgs.ref: 'video:v1',
        CompanionLibraryArgs.entry: 'e4',
      });
      reply(open, const CompanionLibraryOpenResult(opened: false).toJson());
      await tester.pumpAndSettle();
      expect(find.text(t.second_screen_library_browse_open_failed), findsOne);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('companion-library-mark')),
        -100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('companion-library-mark')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('companion-library-mark')),
      );
      await tester.pump();
      final CompanionRequestMessage mark = requests(
        CompanionRequestMethods.libraryMarkFinished,
      ).single;
      expect(mark.args, <String, Object?>{
        CompanionLibraryArgs.ref: 'video:v1',
        CompanionLibraryArgs.finished: true,
      });
      reply(
        mark,
        const CompanionLibraryItem(
          ref: 'video:v1',
          kind: CompanionLibraryItemKind.video,
          title: 'Series A',
          count: 12,
          finished: true,
        ).toJson(),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(t.second_screen_library_browse_mark_unfinished),
        findsOne,
      );
      // ... and the details are read again.
      expect(requests(CompanionRequestMethods.libraryDetails), hasLength(2));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Continue opens on top, switches to Now and offers going back; '
      'the offer reopens the previous item', (WidgetTester tester) async {
    final GlobalKey<CompanionShellState> shellKey =
        GlobalKey<CompanionShellState>();
    rec.push(const CompanionSummaryMessage(_summary));
    await pumpCompanionPanel(
      tester,
      rec.session,
      CompanionShell(key: shellKey),
    );
    expect(requests(CompanionRequestMethods.libraryHome), isEmpty);
    await tester.tap(companionButton(t.second_screen_tab_library));
    await tester.pumpAndSettle();
    reply(requests(CompanionRequestMethods.libraryHome).single, _home.toJson());
    await tester.pumpAndSettle();

    // The info button opens the details; reselecting the tab goes back.
    await tester.tap(
      find.byKey(
        const ValueKey<String>('companion-library-details-book:kokoro'),
      ),
    );
    await tester.pumpAndSettle();
    final CompanionRequestMessage details = requests(
      CompanionRequestMethods.libraryDetails,
    ).single;
    expect(details.args[CompanionLibraryArgs.ref], 'book:kokoro');
    reply(details, const CompanionLibraryDetails(item: _book).toJson());
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('companion-library-continue')),
      findsOne,
    );
    await tester.tap(companionButton(t.second_screen_tab_library));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('companion-library-continue')),
      findsNothing,
    );
    expect(find.text(t.second_screen_library_browse_row_continue), findsOne);

    // The Continue card opens the book on top.
    await tester.tap(find.text('こころ'));
    await tester.pump();
    final CompanionRequestMessage open = requests(
      CompanionRequestMethods.libraryOpen,
    ).single;
    expect(open.args, <String, Object?>{
      CompanionLibraryArgs.ref: 'book:kokoro',
    });
    reply(
      open,
      const CompanionLibraryOpenResult(opened: true, previous: _video).toJson(),
    );
    await tester.pumpAndSettle();
    expect(shellKey.currentState!.tab, CompanionTab.now);
    final String backLabel = t.second_screen_library_browse_back_to(
      title: 'Series A',
    );
    expect(find.text(backLabel), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('companion-back-to-previous')),
    );
    await tester.pump();
    final CompanionRequestMessage back = requests(
      CompanionRequestMethods.libraryOpen,
    ).last;
    expect(back.args, <String, Object?>{CompanionLibraryArgs.ref: 'video:v1'});
    reply(
      back,
      const CompanionLibraryOpenResult(opened: true, previous: _book).toJson(),
    );
    await tester.pumpAndSettle();
    expect(find.text(backLabel), findsNothing);
    expect(
      find.text(t.second_screen_library_browse_back_to(title: 'こころ')),
      findsOneWidget,
    );

    // Dismissed: gone.
    await tester.tap(
      companionButton(t.second_screen_library_browse_back_to_dismiss),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('companion-back-to-previous')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
