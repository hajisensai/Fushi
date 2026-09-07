import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_ingame_mining_binding.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

void main() {
  final DateTime startedAt = DateTime(2026, 9, 7);
  late TexthookerService service;
  setUp(() => service = TexthookerService.test());

  TexthookerLineEntry append(String text, int seq, {String thread = 'body'}) =>
      service.appendLine(
        text,
        source: TexthookerLineSource.engineHook,
        sourceLabel: 'Siglus',
        textThreadKey: thread,
        sourceSequence: seq,
      )!;

  GalIngameMiningBinding bind(int seq) => GalIngameMiningBinding(
    textEventId: seq,
    sessionStartedAt: startedAt,
    targetHwnd: 901,
    selectedLines: service.entries,
  );

  String? resolve(
    GalIngameMiningBinding binding, {
    Iterable<TexthookerLineEntry>? lines,
    DateTime? session,
    int hwnd = 901,
  }) => binding.resolve(
    currentSessionStartedAt: session ?? startedAt,
    currentTargetHwnd: hwnd,
    selectedLines: lines ?? service.entries,
  );

  test(
    'real whitespace fold preserves popup occurrence after seq replacement',
    () {
      final TexthookerLineEntry original = append('ABC DEF', 1);
      final GalIngameMiningBinding popup = bind(1);
      final TexthookerLineEntry folded = append('ABC\nDEF', 2);
      expect(folded.id, original.id);
      expect(folded.sourceSequence, 2);
      expect(service.entries.where((e) => e.sourceSequence == 1), isEmpty);
      expect(resolve(popup), original.id);

      // Identical strings are distinct occurrences, not a whitespace fold.
      final TexthookerLineEntry repeated = append('ABC\nDEF', 3);
      expect(repeated.id, isNot(original.id));
      expect(resolve(popup), original.id);
    },
  );

  test('session, HWND and selected thread remain required after binding', () {
    final TexthookerLineEntry original = append('ABC DEF', 1);
    final GalIngameMiningBinding popup = bind(1);
    final TexthookerLineEntry other = append('ABC DEF', 2, thread: 'speaker');
    expect(resolve(popup, lines: <TexthookerLineEntry>[other]), isNull);
    expect(resolve(popup, hwnd: 902), isNull);
    expect(
      resolve(popup, session: startedAt.add(const Duration(seconds: 1))),
      isNull,
    );
    expect(resolve(popup, lines: <TexthookerLineEntry>[original]), original.id);
  });

  test(
    'removed occurrence never adopts same-text row even with reused seq',
    () {
      final TexthookerLineEntry original = append('ABC DEF', 1);
      final GalIngameMiningBinding popup = bind(1);
      service.clear();
      final TexthookerLineEntry replacement = append('ABC DEF', 1);
      expect(replacement.id, isNot(original.id));
      expect(resolve(popup), isNull);
    },
  );

  test('unseen event stays exact and may bind only when its row arrives', () {
    append('ABC DEF', 2);
    final GalIngameMiningBinding popup = bind(1);
    expect(resolve(popup), isNull);
    final TexthookerLineEntry exact = append('ABC DEF', 1);
    expect(resolve(popup), exact.id);
    expect(resolve(bind(0)), isNull);
  });

  test(
    'missed pre-fold event is not inferred from surviving same-text row',
    () {
      final GalIngameMiningBinding popup = bind(1);
      append('ABC DEF', 1);
      append('ABC\nDEF', 2);
      expect(resolve(popup), isNull);
    },
  );

  test('ambiguous event or altered endpoint metadata cannot bind', () {
    final TexthookerLineEntry original = append('ABC DEF', 1);
    final GalIngameMiningBinding popup = bind(1);
    append('ABC DEF', 1, thread: 'speaker');
    expect(resolve(bind(1)), isNull);
    expect(
      resolve(
        popup,
        lines: <TexthookerLineEntry>[
          TexthookerLineEntry(
            id: original.id,
            text: original.text,
            source: original.source,
            sourceLabel: original.sourceLabel,
            sourceSequence: original.sourceSequence,
            receivedAt: original.receivedAt,
            textThreadKey: 'speaker',
          ),
        ],
      ),
      isNull,
    );
  });
}
