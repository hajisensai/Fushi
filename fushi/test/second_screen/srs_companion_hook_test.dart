import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_companion.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_page_link.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/srs_companion_schema.dart';

String _phase({
  bool loading = false,
  bool hasError = false,
  bool finished = false,
  bool rwkvPending = false,
  bool canSchedule = true,
  bool hasCard = true,
  bool showingAnswer = false,
}) => srsCompanionPhase(
  loading: loading,
  hasError: hasError,
  finished: finished,
  rwkvPending: rwkvPending,
  canSchedule: canSchedule,
  hasCard: hasCard,
  showingAnswer: showingAnswer,
);

void main() {
  group('phase', () {
    test('follows the page body precedence', () {
      expect(_phase(loading: true, hasError: true), SrsCompanionPhases.loading);
      expect(_phase(hasError: true), SrsCompanionPhases.unavailable);
      expect(_phase(finished: true), SrsCompanionPhases.done);
      expect(
        _phase(finished: true, rwkvPending: true),
        SrsCompanionPhases.unavailable,
      );
      expect(_phase(canSchedule: false), SrsCompanionPhases.unavailable);
      expect(_phase(hasCard: false), SrsCompanionPhases.loading);
      expect(_phase(), SrsCompanionPhases.question);
      expect(_phase(showingAnswer: true), SrsCompanionPhases.answer);
    });
  });

  test('snapshot carries counts, the four intervals and undo', () {
    final Map<String, Object?> s = buildSrsCompanionSnapshot(
      deck: 'Mined words',
      phase: SrsCompanionPhases.answer,
      newCount: 12,
      learnCount: 4,
      reviewCount: 57,
      intervals: const <String>['<10 min', '1 day', '3 days'],
      canUndo: true,
      busy: false,
      twoButtons: false,
    );
    expect(s.str(SrsCompanionKeys.deck), 'Mined words');
    expect(s.str(SrsCompanionKeys.phase), SrsCompanionPhases.answer);
    expect(s.integer(SrsCompanionKeys.newCount), 12);
    expect(s.integer(SrsCompanionKeys.learnCount), 4);
    expect(s.integer(SrsCompanionKeys.reviewCount), 57);
    // Always four entries (missing ones empty).
    expect(s.strings(SrsCompanionKeys.intervals), <String>[
      '<10 min',
      '1 day',
      '3 days',
      '',
    ]);
    expect(s.flag(SrsCompanionKeys.canUndo), isTrue);
    expect(s.flag(SrsCompanionKeys.busy), isFalse);
  });

  group('commands', () {
    late List<String> calls;

    void run(String action, Map<String, Object?> args, {bool busy = false}) =>
        handleSrsCompanionCommand(
          action,
          args,
          busy: busy,
          showAnswer: () => calls.add('show'),
          rate: (int r) => calls.add('rate:$r'),
          undo: () => calls.add('undo'),
        );

    setUp(() => calls = <String>[]);

    test('show answer, answer 1..4 and undo reach the page', () {
      run(SrsCompanionActions.showAnswer, const <String, Object?>{});
      for (int r = 1; r <= 4; r++) {
        run(SrsCompanionActions.answer, <String, Object?>{
          SrsCompanionKeys.rating: r,
        });
      }
      run(SrsCompanionActions.undo, const <String, Object?>{});
      expect(calls, <String>[
        'show',
        'rate:1',
        'rate:2',
        'rate:3',
        'rate:4',
        'undo',
      ]);
    });

    test('bad ratings, unknown actions and busy pages are ignored', () {
      run(SrsCompanionActions.answer, <String, Object?>{
        SrsCompanionKeys.rating: 0,
      });
      run(SrsCompanionActions.answer, <String, Object?>{
        SrsCompanionKeys.rating: 5,
      });
      run(SrsCompanionActions.answer, <String, Object?>{
        SrsCompanionKeys.rating: 'good',
      });
      run(SrsCompanionActions.answer, const <String, Object?>{});
      run('editCard', const <String, Object?>{});
      run(
        SrsCompanionActions.showAnswer,
        const <String, Object?>{},
        busy: true,
      );
      run(SrsCompanionActions.answer, <String, Object?>{
        SrsCompanionKeys.rating: 3,
      }, busy: true);
      run(SrsCompanionActions.undo, const <String, Object?>{}, busy: true);
      expect(calls, isEmpty);
    });
  });

  group('page link', () {
    Map<String, Object?> snapshot(String phase) => buildSrsCompanionSnapshot(
      deck: 'Deck',
      phase: phase,
      newCount: 1,
      learnCount: 2,
      reviewCount: 3,
      intervals: const <String>[],
      canUndo: false,
      busy: false,
      twoButtons: false,
    );

    test('inactive companion: no timer, nothing built', () {
      fakeAsync((FakeAsync async) {
        final CompanionContextRegistry registry = CompanionContextRegistry();
        final CompanionPageLink link = CompanionPageLink(registry: registry);
        int builds = 0;
        link.claim(
          const CompanionContext(CompanionContextKind.srs, title: 'Deck'),
        );
        link.startSnapshots(() {
          builds++;
          return snapshot(SrsCompanionPhases.question);
        });
        link.publishNow();
        async.elapse(const Duration(seconds: 5));
        expect(builds, 0);
        link.dispose();
      });
    });

    test('active: the review page owns srs over the route-level tab', () {
      fakeAsync((FakeAsync async) {
        final CompanionContextRegistry registry = CompanionContextRegistry();
        registry.setActive(true);
        final CompanionPageLink link = CompanionPageLink(registry: registry);
        String phase = SrsCompanionPhases.question;
        final List<(String, Map<String, Object?>)> commands =
            <(String, Map<String, Object?>)>[];
        link.claim(
          const CompanionContext(CompanionContextKind.srs, title: 'Deck'),
          onCommand: (String a, Map<String, Object?> args) =>
              commands.add((a, args)),
        );
        link.startSnapshots(() => snapshot(phase));
        expect(registry.current.kind, CompanionContextKind.srs);
        expect(identical(registry.currentOwner, link), isTrue);
        expect(
          registry.currentSnapshot?.str(SrsCompanionKeys.phase),
          SrsCompanionPhases.question,
        );
        // A reveal publishes right away (the page calls publishNow from
        // setState), without waiting for the timer.
        phase = SrsCompanionPhases.answer;
        link.publishNow();
        expect(
          registry.currentSnapshot?.str(SrsCompanionKeys.phase),
          SrsCompanionPhases.answer,
        );
        expect(
          registry.dispatchCommand(
            CompanionContextKind.srs,
            SrsCompanionActions.answer,
            <String, Object?>{SrsCompanionKeys.rating: 3},
          ),
          isTrue,
        );
        expect(commands.single.$1, SrsCompanionActions.answer);
        link.dispose();
        expect(registry.currentOwner, isNull);
        registry.dispose();
      });
    });
  });
}
