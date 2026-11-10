import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_details_page.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_main.dart';
import 'package:material_ui/material_ui.dart';

import 'companion_panel_harness.dart';

const CompanionLibraryItem _cat = CompanionLibraryItem(
  ref: 'book:neko',
  kind: CompanionLibraryItemKind.book,
  title: '吾輩は猫である',
  subtitle: '夏目漱石',
  progress: 0.62,
  progressLabel: '62%',
);

CompanionLibraryMainSnapshot _snapshot({
  CompanionLibraryItem? highlighted = _cat,
  String query = '',
  bool searchable = true,
  String sort = 'recent',
  String? filter,
}) => CompanionLibraryMainSnapshot(
  highlighted: highlighted,
  query: query,
  searchable: searchable,
  sorts: <CompanionLibraryOption>[
    for (final (String id, String label) in <(String, String)>[
      ('recent', 'Recent'),
      ('title', 'Title'),
    ])
      CompanionLibraryOption(id: id, label: label, selected: id == sort),
  ],
  filters: <CompanionLibraryOption>[
    for (final (String id, String label) in <(String, String)>[
      ('unread', 'Unread'),
      ('reading', 'In progress'),
      ('finished', 'Finished'),
    ])
      CompanionLibraryOption(id: id, label: label, selected: id == filter),
  ],
);

void main() {
  late RecordingCompanionSession rec;

  setUp(() => rec = RecordingCompanionSession());

  void showLibrary(CompanionLibraryMainSnapshot? snapshot) {
    rec.push(
      const CompanionContextMessage(
        CompanionContext(
          CompanionContextKind.library,
          library: CompanionLibraryKind.books,
        ),
      ),
    );
    if (snapshot != null) {
      rec.push(
        CompanionSnapshotMessage(
          kind: CompanionContextKind.library,
          data: snapshot.toJson(),
        ),
      );
    }
  }

  Future<void> pump(WidgetTester tester) => pumpCompanionPanel(
    tester,
    rec.session,
    // The Main mode root lives on its own navigator in the Library tab.
    Navigator(
      onGenerateRoute: (RouteSettings settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (BuildContext context) => const CompanionLibraryMainRoot(),
      ),
    ),
  );

  List<CompanionCommandMessage> commands(String action) =>
      <CompanionCommandMessage>[
        for (final CompanionCommandMessage c in rec.commands)
          if (c.kind == CompanionContextKind.library && c.action == action) c,
      ];

  testWidgets('label, tools and the highlighted item from the snapshot', (
    WidgetTester tester,
  ) async {
    showLibrary(_snapshot(filter: 'reading'));
    await pump(tester);

    expect(
      find.text(t.second_screen_library_main_filtering(library: t.books)),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('companion-library-main-search')),
      findsOneWidget,
    );
    expect(
      find.text(t.second_screen_library_main_sort(label: 'Recent')),
      findsOneWidget,
    );
    expect(find.text('Unread'), findsOneWidget);
    expect(find.text(t.second_screen_library_main_highlighted), findsOneWidget);
    expect(find.text('吾輩は猫である'), findsOneWidget);
    expect(find.text('夏目漱石'), findsOneWidget);
    expect(find.text('62%'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('companion-library-main-continue')),
      findsOneWidget,
    );
    expect(find.text(t.second_screen_library_main_hint), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Continue sends openHighlighted', (WidgetTester tester) async {
    showLibrary(_snapshot());
    await pump(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('companion-library-main-continue')),
    );
    await tester.pump();

    expect(commands(CompanionLibraryMainActions.openHighlighted), hasLength(1));
  });

  testWidgets('Details pushes the details page, which asks library.details', (
    WidgetTester tester,
  ) async {
    showLibrary(_snapshot());
    await pump(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('companion-library-main-details')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(CompanionLibraryDetailsPage), findsOneWidget);
    final CompanionRequestMessage request = rec.sent
        .whereType<CompanionRequestMessage>()
        .singleWhere(
          (CompanionRequestMessage r) =>
              r.method == CompanionRequestMethods.libraryDetails,
        );
    expect(request.args[CompanionLibraryArgs.ref], 'book:neko');
    rec.push(
      CompanionReplyMessage(
        id: request.id,
        value: const CompanionLibraryDetails(
          item: _cat,
          author: '夏目漱石',
        ).toJson(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CompanionLibraryDetailsPage), findsOneWidget);
    expect(find.text('吾輩は猫である'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search sends the query; one command in flight at a time', (
    WidgetTester tester,
  ) async {
    showLibrary(_snapshot());
    await pump(tester);

    final Finder field = find.byKey(
      const ValueKey<String>('companion-library-main-search'),
    );
    await tester.enterText(field, '猫');
    await tester.pump();
    await tester.enterText(field, '猫で');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    final List<String> queries = <String>[
      for (final CompanionCommandMessage c in commands(
        CompanionLibraryMainActions.search,
      ))
        c.args[CompanionLibraryMainActions.argQuery]! as String,
    ];
    expect(queries.first, '猫');
    expect(queries.last, '猫で');
    // The top's (older) query does not overwrite what is being typed.
    rec.push(
      CompanionSnapshotMessage(
        kind: CompanionContextKind.library,
        data: _snapshot(query: '猫').toJson(),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '猫で',
    );
  });

  testWidgets('the field follows the top when the user is not typing', (
    WidgetTester tester,
  ) async {
    showLibrary(_snapshot());
    await pump(tester);

    rec.push(
      CompanionSnapshotMessage(
        kind: CompanionContextKind.library,
        data: _snapshot(query: 'kokoro').toJson(),
      ),
    );
    await tester.pump();

    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'kokoro',
    );
    expect(commands(CompanionLibraryMainActions.search), isEmpty);
  });

  testWidgets('sort menu and filter chips send their ids', (
    WidgetTester tester,
  ) async {
    showLibrary(_snapshot(filter: 'reading'));
    await pump(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('companion-library-main-sort')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('companion-library-main-sort-title')),
    );
    await tester.pumpAndSettle();
    final List<CompanionCommandMessage> sorts = commands(
      CompanionLibraryMainActions.sort,
    );
    expect(sorts, hasLength(1));
    expect(sorts.single.args[CompanionLibraryMainActions.argId], 'title');

    await tester.tap(
      find.byKey(
        const ValueKey<String>('companion-library-main-filter-unread'),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('companion-library-main-filter-reading'),
      ),
    );
    await tester.pump();
    final List<CompanionCommandMessage> filters = commands(
      CompanionLibraryMainActions.filter,
    );
    expect(filters, hasLength(2));
    expect(filters[0].args, <String, Object?>{
      CompanionLibraryMainActions.argId: 'unread',
      CompanionLibraryMainActions.argSelected: true,
    });
    expect(filters[1].args, <String, Object?>{
      CompanionLibraryMainActions.argId: 'reading',
      CompanionLibraryMainActions.argSelected: false,
    });
  });

  testWidgets('nothing highlighted: the hint; no tools without a snapshot', (
    WidgetTester tester,
  ) async {
    showLibrary(null);
    await pump(tester);

    expect(find.text(t.second_screen_library_main_hint), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('companion-library-main-search')),
      findsNothing,
    );

    rec.push(
      CompanionSnapshotMessage(
        kind: CompanionContextKind.library,
        data: _snapshot(highlighted: null, searchable: false).toJson(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.second_screen_library_main_hint), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('companion-library-main-search')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('companion-library-main-sort')),
      findsOneWidget,
    );
  });

  testWidgets('a long title and every tool fit at 470x540 without overflow', (
    WidgetTester tester,
  ) async {
    showLibrary(
      _snapshot(
        highlighted: const CompanionLibraryItem(
          ref: 'video:v',
          kind: CompanionLibraryItemKind.video,
          title:
              'A very long series title that keeps going and going well past '
              'the width of the card on the bottom screen',
          subtitle: 'A studio with a long name as well, for good measure',
          progress: 0.3,
          progressLabel: 'E12',
          count: 24,
        ),
      ),
    );
    await pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.text(t.second_screen_library_main_continue), findsOneWidget);
  });
}
