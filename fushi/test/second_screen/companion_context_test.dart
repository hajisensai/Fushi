import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:material_ui/material_ui.dart';

const CompanionContext _reader = CompanionContext(
  CompanionContextKind.reader,
  title: 'こころ',
);
const CompanionContext _video = CompanionContext(CompanionContextKind.video);

void main() {
  late ValueNotifier<HomeTab> tab;
  late CompanionContextRegistry registry;
  late int notified;

  setUp(() {
    tab = ValueNotifier<HomeTab>(HomeTab.home);
    registry = CompanionContextRegistry(homeTab: tab);
    notified = 0;
    registry.addListener(() => notified++);
  });

  tearDown(() {
    registry.dispose();
    tab.dispose();
  });

  group('route level', () {
    test('follows the home shell tab', () {
      expect(registry.current.kind, CompanionContextKind.home);
      tab.value = HomeTab.manga;
      expect(
        registry.current,
        const CompanionContext(
          CompanionContextKind.library,
          library: CompanionLibraryKind.manga,
        ),
      );
      tab.value = HomeTab.settings;
      expect(registry.current.kind, CompanionContextKind.settings);
      tab.value = HomeTab.dictionaries;
      expect(registry.current, CompanionContext.none);
      expect(notified, 3);
      expect(registry.currentOwner, isNull);
    });

    test('every home tab has a context', () {
      for (final HomeTab t in HomeTab.values) {
        expect(companionContextForHomeTab(t), isA<CompanionContext>());
      }
      expect(
        companionContextForHomeTab(HomeTab.books).library,
        CompanionLibraryKind.books,
      );
      expect(
        companionContextForHomeTab(HomeTab.srs).kind,
        CompanionContextKind.srs,
      );
      expect(companionContextForHomeTab(null).kind, CompanionContextKind.home);
    });
  });

  group('claims', () {
    test('a claim beats the route level; release goes back', () {
      final Object page = Object();
      registry.claim(page, _reader);
      expect(registry.current, _reader);
      expect(registry.currentOwner, same(page));
      registry.release(page);
      expect(registry.current.kind, CompanionContextKind.home);
      expect(registry.currentOwner, isNull);
    });

    test('the newest claim wins; releasing an older one changes nothing', () {
      final Object first = Object();
      final Object second = Object();
      registry.claim(first, _reader);
      registry.claim(second, _video);
      expect(registry.current, _video);
      final int before = notified;
      registry.release(first);
      expect(registry.current, _video);
      expect(notified, before);
      registry.release(second);
      expect(registry.current.kind, CompanionContextKind.home);
    });

    test('claiming again updates in place and drops a stale snapshot', () {
      final Object first = Object();
      final Object second = Object();
      registry.claim(first, _reader);
      registry.claim(second, _video);
      // `first` re-claims (e.g. its title changed): `second` stays on top.
      registry.claim(
        first,
        const CompanionContext(CompanionContextKind.reader),
      );
      expect(registry.current, _video);
      registry.release(second);
      expect(
        registry.current,
        const CompanionContext(CompanionContextKind.reader),
      );
    });

    test('snapshots count only from the owner of the context', () {
      final Object reader = Object();
      final Object other = Object();
      registry.claim(reader, _reader);
      registry.claim(other, _video);
      final int revision = registry.snapshotRevision;
      registry.publishSnapshot(reader, <String, Object?>{'page': 1});
      expect(registry.snapshotRevision, revision);
      expect(registry.currentSnapshot, isNull);
      registry.publishSnapshot(other, <String, Object?>{'pos': 2});
      expect(registry.snapshotRevision, revision + 1);
      expect(registry.currentSnapshot, <String, Object?>{'pos': 2});
      // The reader's own snapshot comes back with it.
      registry.release(other);
      expect(registry.currentSnapshot, <String, Object?>{'page': 1});
    });

    test('commands reach the owner only for its context', () {
      final List<String> got = <String>[];
      registry.claim(
        Object(),
        _reader,
        onCommand: (String action, Map<String, Object?> args) =>
            got.add('$action ${args['n']}'),
      );
      expect(
        registry.dispatchCommand(
          CompanionContextKind.reader,
          'turnPage',
          <String, Object?>{'n': 1},
        ),
        isTrue,
      );
      expect(
        registry.dispatchCommand(
          CompanionContextKind.video,
          'seek',
          const <String, Object?>{},
        ),
        isFalse,
      );
      expect(got, <String>['turnPage 1']);
    });
  });

  group('pages on a navigator', () {
    late GlobalKey<NavigatorState> navigator;

    Future<void> pumpApp(WidgetTester tester) async {
      navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: <NavigatorObserver>[
            CompanionContextRouteObserver(registry),
          ],
          home: const Scaffold(body: Text('home')),
        ),
      );
    }

    Route<void> page(Widget child) =>
        MaterialPageRoute<void>(builder: (BuildContext _) => child);

    testWidgets('a claimed page owns the context only while it is the top '
        'page; dialogs over it do not count', (WidgetTester tester) async {
      await pumpApp(tester);
      tab.value = HomeTab.books;
      expect(registry.current.kind, CompanionContextKind.library);

      navigator.currentState!.push(
        page(
          CompanionContextClaim(
            registry: registry,
            companionContext: _reader,
            child: const Scaffold(body: Text('reader')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(registry.current, _reader);

      // A dialog over the reader: still the reader.
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (BuildContext _) => const AlertDialog(title: Text('d')),
      );
      await tester.pumpAndSettle();
      expect(registry.current, _reader);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();

      // A page nobody claimed over the reader: nothing the companion knows.
      navigator.currentState!.push(page(const Scaffold(body: Text('other'))));
      await tester.pumpAndSettle();
      expect(registry.current, CompanionContext.none);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(registry.current, _reader);

      // Closing the reader: back to the library tab under it.
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        registry.current,
        const CompanionContext(
          CompanionContextKind.library,
          library: CompanionLibraryKind.books,
        ),
      );
      expect(registry.currentOwner, isNull);
    });
  });

  // Pause on lookup with the companion: every lookup it shows reaches the
  // context owner's popup-open path, its close the popup-close path.
  group('companion lookup hold', () {
    late List<String> log;

    void claimLogged(Object owner, CompanionContext context, String name) =>
        registry.claim(
          owner,
          context,
          onLookupOpened: () => log.add('$name:opened'),
          onLookupClosed: ({required bool resume}) =>
              log.add('$name:closed:$resume'),
        );

    setUp(() => log = <String>[]);

    test('opened / closed reach the owner; the holder is known', () {
      final Object reader = Object();
      claimLogged(reader, _reader, 'reader');
      expect(registry.isLookupOpenFor(reader), isFalse);
      registry.lookupOpened();
      expect(registry.isLookupOpenFor(reader), isTrue);
      // Every new lookup, not just the first (pages pause idempotently).
      registry.lookupOpened();
      registry.lookupClosed(resume: true);
      expect(registry.isLookupOpenFor(reader), isFalse);
      // Nothing open any more: a second close is a no-op.
      registry.lookupClosed(resume: true);
      expect(log, <String>[
        'reader:opened',
        'reader:opened',
        'reader:closed:true',
      ]);
    });

    test('the holder reads "not open" inside its close handler', () {
      final Object reader = Object();
      final List<bool> seen = <bool>[];
      registry.claim(
        reader,
        _reader,
        onLookupClosed: ({required bool resume}) =>
            seen.add(registry.isLookupOpenFor(reader)),
      );
      registry.lookupOpened();
      registry.lookupClosed(resume: true);
      expect(seen, <bool>[false]);
    });

    test('companion gone: the holder drops its hold without resuming', () {
      final Object video = Object();
      claimLogged(video, _video, 'video');
      registry.lookupOpened();
      registry.lookupClosed(resume: false);
      expect(log, <String>['video:opened', 'video:closed:false']);
    });

    test('route-level context: no owner, nothing to pause', () {
      registry.lookupOpened();
      registry.lookupClosed(resume: true);
      expect(log, isEmpty);
    });

    test('a lookup for another page replaces the hold without resuming', () {
      final Object reader = Object();
      final Object video = Object();
      claimLogged(reader, _reader, 'reader');
      registry.lookupOpened();
      claimLogged(video, _video, 'video');
      registry.lookupOpened();
      expect(registry.isLookupOpenFor(reader), isFalse);
      expect(registry.isLookupOpenFor(video), isTrue);
      registry.lookupClosed(resume: true);
      expect(log, <String>[
        'reader:opened',
        'reader:closed:false',
        'video:opened',
        'video:closed:true',
      ]);
    });

    test('a released page is forgotten (no callback on close)', () {
      final Object reader = Object();
      claimLogged(reader, _reader, 'reader');
      registry.lookupOpened();
      registry.release(reader);
      registry.lookupClosed(resume: true);
      expect(log, <String>['reader:opened']);
    });

    test('a routed lookup pauses at once; a refused one does not', () async {
      final Object reader = Object();
      claimLogged(reader, _reader, 'reader');
      bool accept = true;
      registry.bindLookupSink(
        ({required String text, int charIndex = -1, String? sentence}) async =>
            accept,
      );
      // Companion not up: the page shows its popup (its own pause path).
      expect(await registry.routeLookup(text: '猫'), isFalse);
      expect(log, isEmpty);
      registry.setActive(true);
      expect(await registry.routeLookup(text: '猫'), isTrue);
      expect(log, <String>['reader:opened']);
      accept = false;
      expect(await registry.routeLookup(text: '犬'), isFalse);
      expect(log, <String>['reader:opened']);
      // "Lookups open on: Top screen": the popup path, no companion hold.
      registry.lookupClosed(resume: true);
      log.clear();
      accept = true;
      registry.setLookupsOnCompanion(false);
      expect(await registry.routeLookup(text: '猫'), isFalse);
      expect(log, isEmpty);
    });
  });
}
