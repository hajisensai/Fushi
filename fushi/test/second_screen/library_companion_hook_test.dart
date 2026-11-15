import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_hook.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:material_ui/material_ui.dart';

/// A library page as the hook sees it: its own search / sort / filter state
/// and a highlighted item.
class _Page extends StatefulWidget {
  const _Page({required this.registry, required this.focus, super.key});

  final CompanionContextRegistry registry;
  final ValueNotifier<int> focus;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  String query = '';
  String sort = 'recent';
  String? filter;
  String? highlighted;
  int opened = 0;
  int builds = 0;

  late final LibraryCompanionHook hook = LibraryCompanionHook(
    library: CompanionLibraryKind.books,
    registry: widget.registry,
    snapshot: () {
      builds++;
      final String? h = highlighted;
      return CompanionLibraryMainSnapshot(
        highlighted: h == null
            ? null
            : CompanionLibraryItem(
                ref: CompanionLibraryRef.book(h),
                kind: CompanionLibraryItemKind.book,
                title: h,
              ),
        query: query,
        sorts: libraryCompanionOptions<String>(
          values: const <String>['recent', 'title'],
          id: (String s) => s,
          label: (String s) => s.toUpperCase(),
          selected: (String s) => s == sort,
        ),
        filters: libraryCompanionOptions<String>(
          values: const <String>['unread', 'finished'],
          id: (String s) => s,
          label: (String s) => s,
          selected: (String s) => s == filter,
        ),
      );
    },
    onSearch: (String q) => setState(() => query = q),
    onSort: (String id) => setState(() => sort = id),
    onFilter: (String id, bool selected) =>
        setState(() => filter = selected ? id : (filter == id ? null : filter)),
    onOpenHighlighted: () => opened++,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    hook.attach(context, focusChanges: widget.focus);
  }

  @override
  void dispose() {
    hook.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text('q=$query s=$sort f=$filter');
}

void main() {
  late CompanionContextRegistry registry;
  late ValueNotifier<HomeTab> tab;
  late ValueNotifier<int> focus;
  final GlobalKey<_PageState> pageKey = GlobalKey<_PageState>();

  setUp(() {
    tab = ValueNotifier<HomeTab>(HomeTab.books);
    registry = CompanionContextRegistry(homeTab: tab);
    focus = ValueNotifier<int>(0);
  });

  tearDown(() {
    registry.dispose();
    tab.dispose();
    focus.dispose();
  });

  Future<void> pump(WidgetTester tester, {bool onScreen = true}) =>
      tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: onScreen,
            child: _Page(key: pageKey, registry: registry, focus: focus),
          ),
        ),
      );

  Map<String, Object?>? published() => registry.currentSnapshot;

  CompanionLibraryMainSnapshot snapshot() =>
      CompanionLibraryMainSnapshot.fromJson(published()!);

  group('LibraryCompanionHook', () {
    testWidgets('claims while on screen, releases when its tab is hidden', (
      WidgetTester tester,
    ) async {
      await pump(tester);
      expect(registry.current.kind, CompanionContextKind.library);
      expect(registry.current.library, CompanionLibraryKind.books);
      expect(registry.currentOwner, isNotNull);

      // The user switches to the video tab: the books page stays mounted but
      // its TickerMode turns off.
      tab.value = HomeTab.video;
      await pump(tester, onScreen: false);
      expect(registry.currentOwner, isNull);
      expect(registry.current.library, CompanionLibraryKind.video);

      tab.value = HomeTab.books;
      await pump(tester);
      expect(registry.currentOwner, isNotNull);

      await tester.pumpWidget(const SizedBox());
      expect(registry.currentOwner, isNull);
    });

    testWidgets('builds nothing while the companion is off', (
      WidgetTester tester,
    ) async {
      await pump(tester);
      pageKey.currentState!.highlighted = 'kokoro';
      focus.value++;
      await tester.pump(const Duration(seconds: 3));
      expect(pageKey.currentState!.builds, 0);
      expect(published(), isNull);
    });

    testWidgets('publishes the page state; focus changes publish at once', (
      WidgetTester tester,
    ) async {
      await pump(tester);
      registry.setActive(true);
      await tester.pump();
      CompanionLibraryMainSnapshot snap = snapshot();
      expect(snap.highlighted, isNull);
      expect(snap.sorts.map((CompanionLibraryOption o) => o.label), <String>[
        'RECENT',
        'TITLE',
      ]);
      expect(snap.sorts.first.selected, isTrue);

      pageKey.currentState!.highlighted = 'kokoro';
      focus.value++;
      snap = snapshot();
      expect(snap.highlighted?.ref, 'book:kokoro');
      expect(snap.highlighted?.title, 'kokoro');

      registry.setActive(false);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('commands change the page state and republish', (
      WidgetTester tester,
    ) async {
      await pump(tester);
      registry.setActive(true);
      await tester.pump();

      expect(
        registry.dispatchCommand(
          CompanionContextKind.library,
          CompanionLibraryMainActions.search,
          <String, Object?>{CompanionLibraryMainActions.argQuery: '猫'},
        ),
        isTrue,
      );
      registry.dispatchCommand(
        CompanionContextKind.library,
        CompanionLibraryMainActions.sort,
        <String, Object?>{CompanionLibraryMainActions.argId: 'title'},
      );
      registry.dispatchCommand(
        CompanionContextKind.library,
        CompanionLibraryMainActions.filter,
        <String, Object?>{
          CompanionLibraryMainActions.argId: 'unread',
          CompanionLibraryMainActions.argSelected: true,
        },
      );
      await tester.pump();
      expect(find.text('q=猫 s=title f=unread'), findsOneWidget);
      final CompanionLibraryMainSnapshot snap = snapshot();
      expect(snap.query, '猫');
      expect(
        snap.sorts.singleWhere((CompanionLibraryOption o) => o.selected).id,
        'title',
      );
      expect(
        snap.filters.singleWhere((CompanionLibraryOption o) => o.selected).id,
        'unread',
      );

      registry.dispatchCommand(
        CompanionContextKind.library,
        CompanionLibraryMainActions.filter,
        <String, Object?>{
          CompanionLibraryMainActions.argId: 'unread',
          CompanionLibraryMainActions.argSelected: false,
        },
      );
      registry.dispatchCommand(
        CompanionContextKind.library,
        CompanionLibraryMainActions.openHighlighted,
        const <String, Object?>{},
      );
      await tester.pump();
      expect(find.text('q=猫 s=title f=null'), findsOneWidget);
      expect(pageKey.currentState!.opened, 1);

      // A command for another context is not delivered.
      expect(
        registry.dispatchCommand(
          CompanionContextKind.video,
          CompanionLibraryMainActions.search,
          <String, Object?>{CompanionLibraryMainActions.argQuery: 'x'},
        ),
        isFalse,
      );

      registry.setActive(false);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a hidden page takes no commands', (WidgetTester tester) async {
      await pump(tester, onScreen: false);
      expect(
        registry.dispatchCommand(
          CompanionContextKind.library,
          CompanionLibraryMainActions.search,
          <String, Object?>{CompanionLibraryMainActions.argQuery: 'x'},
        ),
        isFalse,
      );
      expect(find.text('q= s=recent f=null'), findsOneWidget);
    });
  });

  group('helpers', () {
    test('focus keys', () {
      expect(
        libraryCompanionFocusKey(
          'reader-shelf-book-hoshi://book/abc',
          'reader-shelf-book-',
        ),
        'hoshi://book/abc',
      );
      expect(
        libraryCompanionFocusKey('reader-shelf-srt-1', 'reader-shelf-book-'),
        isNull,
      );
      expect(
        libraryCompanionFocusKey('reader-shelf-book-', 'reader-shelf-book-'),
        isNull,
      );
      expect(libraryCompanionFocusKey(null, 'x'), isNull);
    });

    test('highlight order: focused, then pressed, then selected', () {
      LibraryCompanionHighlight h(String ref) => LibraryCompanionHighlight(
        item: CompanionLibraryItem(
          ref: ref,
          kind: CompanionLibraryItemKind.book,
          title: ref,
        ),
        open: () {},
      );
      expect(
        pickLibraryCompanionHighlight(
          focused: () => h('book:f'),
          pressed: () => h('book:p'),
          selected: () => h('book:s'),
        )?.item.ref,
        'book:f',
      );
      expect(
        pickLibraryCompanionHighlight(
          focused: () => null,
          pressed: () => h('book:p'),
          selected: () => h('book:s'),
        )?.item.ref,
        'book:p',
      );
      expect(
        pickLibraryCompanionHighlight(
          focused: () => null,
          pressed: () => null,
          selected: () => h('book:s'),
        )?.item.ref,
        'book:s',
      );
      expect(
        pickLibraryCompanionHighlight(
          focused: () => null,
          pressed: () => null,
          selected: () => null,
        ),
        isNull,
      );
    });
  });
}
