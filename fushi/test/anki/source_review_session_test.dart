import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/source_review_draft_store.dart';
import 'package:fushi/src/anki/source_review_session.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:path/path.dart' as p;

const String _sourceId = '00112233-4455-4677-8899-aabbccddeeff';
final CardSourceLink _link = CardSourceLink(
  kind: CardSourceKind.book,
  uid: 'book-uid',
  sourceId: _sourceId,
  chapterIndex: 2,
  charOffset: 42,
);

class _UncalledSourceSender
    implements RemoteMineSender, RemoteSourceNoteSender {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('Legacy remote draft must not contact a peer');
  }
}

class _DraftStore extends SourceReviewDraftStore {
  _DraftStore(super.root);
  int completedReads = 0;
  @override
  Future<SourceReviewDraft?> read(String sourceId) async {
    final SourceReviewDraft? result = await super.read(sourceId);
    completedReads++;
    return result;
  }
}

class _Repository implements BaseAnkiRepository {
  Map<String, String> current = <String, String>{
    'Sentence': 'original',
    'Meaning': 'hand edit',
  };
  Map<String, String> candidate = <String, String>{
    'Sentence': 'new sentence',
    'Meaning': 'new meaning',
  };
  int reads = 0;
  int prepares = 0;
  int patches = 0;
  int additions = 0;
  bool offline = false;
  bool conflict = false;
  Completer<AnkiSourceNote?>? pendingRead;
  AnkiSourceNote? patchedOriginal;
  Map<String, String>? patchedFields;

  AnkiSourceNote get snapshot =>
      AnkiSourceNote(sourceId: _sourceId, noteId: 17, fields: current);

  @override
  Future<AnkiSourceNote?> readSourceNote(String sourceId) async {
    reads++;
    if (offline) throw StateError('offline');
    return pendingRead != null ? pendingRead!.future : snapshot;
  }

  @override
  Future<Map<String, String>> prepareSourceNoteFields({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    prepares++;
    return candidate;
  }

  @override
  Future<void> patchSourceNote({
    required AnkiSourceNote original,
    required Map<String, String> fields,
  }) async {
    patches++;
    patchedOriginal = original;
    patchedFields = Map<String, String>.of(fields);
    if (conflict) throw StateError('note changed concurrently');
    current.addAll(fields);
  }

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    additions++;
    throw StateError('Source edits must never add notes');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

Future<void> _until(WidgetTester tester, bool Function() complete) async {
  for (int i = 0; i < 150 && !complete(); i++) {
    // Allow real filesystem completions while bounding the widget wait.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    complete(),
    isTrue,
    reason: 'Expected source-review state was not reached',
  );
}

Future<void> _chooseSentenceAndSave(WidgetTester tester) async {
  final Finder sentence = find.byKey(
    const ValueKey<String>('anki-source-change-Sentence'),
  );
  await _until(tester, () => sentence.evaluate().isNotEmpty);
  final Finder save = find.widgetWithText(
    FilledButton,
    t.card_source_review_save,
  );
  expect(tester.widget<FilledButton>(save).onPressed, isNull);
  expect(tester.widget<Checkbox>(sentence).value, isFalse);
  await tester.tap(sentence);
  await tester.pump();
  expect(tester.widget<Checkbox>(sentence).value, isTrue);
  await tester.tap(save);
  await tester.pump();
}

void main() {
  late Directory scratch;
  late _DraftStore store;
  late _Repository repository;
  late SourceReviewSession session;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('fushi_source_session_');
    store = _DraftStore(Directory(p.join(scratch.path, 'drafts')));
    repository = _Repository();
    session = SourceReviewSession(
      link: _link,
      repository: repository,
      draftStore: store,
    );
  });
  tearDown(() async {
    session.dispose();
    await scratch.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    final int previousReads = store.completedReads;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourceReviewBanner(session: session, onReturn: () {}),
        ),
      ),
    );
    await _until(tester, () => store.completedReads > previousReads);
  }

  test(
    'legacy remote draft without pairing identity stays local and intact',
    () async {
      final AnkiSourceNote original = AnkiSourceNote(
        sourceId: _sourceId,
        noteId: 17,
        fields: <String, String>{'Sentence': 'old'},
      );
      await store.savePatch(
        original: original,
        fields: <String, String>{'Sentence': 'saved draft'},
        peerUrl: 'https://owner:8765',
      );
      final _UncalledSourceSender sender = _UncalledSourceSender();
      session.dispose();
      session = SourceReviewSession(
        link: _link,
        repository: RemoteMiningAnkiRepository(
          local: repository,
          client: sender,
        ),
        draftStore: store,
      );
      await session.resumeDraft();
      expect(sender.calls, 0);
      expect(
        (await store.read(_sourceId))!.patch!.fields['Sentence'],
        'saved draft',
      );
    },
  );

  testWidgets('banner keyboard controls precede the reader host key handler', (
    WidgetTester tester,
  ) async {
    final Set<LogicalKeyboardKey> readerKeys = <LogicalKeyboardKey>{
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.gameButtonA,
      LogicalKeyboardKey.tab,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
    };
    final List<LogicalKeyboardKey> interceptedByReader = <LogicalKeyboardKey>[];
    int returns = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            onKeyEvent: (FocusNode node, KeyEvent event) {
              if (event is KeyDownEvent &&
                  readerKeys.contains(event.logicalKey)) {
                interceptedByReader.add(event.logicalKey);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: SourceReviewBanner(
              session: session,
              onReturn: () {
                returns++;
              },
            ),
          ),
        ),
      ),
    );
    await _until(tester, () => store.completedReads > 0);
    final Finder continueButton = find.widgetWithText(
      TextButton,
      t.card_source_review_continue,
    );
    final Finder back = find.widgetWithText(
      TextButton,
      t.card_source_review_return,
    );
    // The source toolbar offers navigation, with no original-field editor.
    expect(find.byType(TextButton), findsNWidgets(2));
    expect(back, findsOneWidget);
    expect(continueButton, findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    FocusNode buttonFocus(Finder button) => Focus.of(
          tester.element(
              find.descendant(of: button, matching: find.byType(Text))),
        );
    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }

    // Start inside the banner, as when the user traverses from its first
    // control. All further navigation must bypass the reader's caret handler.
    buttonFocus(back).requestFocus();
    await tester.pump();
    await press(LogicalKeyboardKey.tab);
    expect(buttonFocus(continueButton).hasPrimaryFocus, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await press(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(buttonFocus(back).hasPrimaryFocus, isTrue);
    await press(LogicalKeyboardKey.arrowRight);
    expect(buttonFocus(continueButton).hasPrimaryFocus, isTrue);
    await press(LogicalKeyboardKey.arrowLeft);
    expect(buttonFocus(back).hasPrimaryFocus, isTrue);
    await press(LogicalKeyboardKey.enter);
    expect(returns, 1);
    await press(LogicalKeyboardKey.numpadEnter);
    expect(returns, 2);
    await press(LogicalKeyboardKey.gameButtonA);
    expect(returns, 3);
    await press(LogicalKeyboardKey.arrowRight);
    expect(buttonFocus(continueButton).hasPrimaryFocus, isTrue);
    await press(LogicalKeyboardKey.enter);
    expect(session.isReview, isFalse);
    expect(find.text(t.card_source_review_source), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(interceptedByReader, isEmpty);
    expect(repository.reads, 0);
    expect(repository.patches, 0);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'rapid return requests restore reading once while the first is pending',
    () async {
      final Completer<void> restored = Completer<void>();
      int restores = 0;
      int fallbacks = 0;
      session.dispose();
      session = SourceReviewSession(
        link: _link,
        repository: repository,
        draftStore: store,
        onReturnToReading: () async {
          restores++;
          await restored.future;
        },
      );
      void fallback() => fallbacks++;

      // Do not await or pump between requests: this reproduces two callbacks
      // already dispatched before the disabled button has rebuilt.
      final Future<void> first = session.returnToReading(fallback);
      final Future<void> second = session.returnToReading(fallback);
      expect(session.busy, isTrue);
      expect(restores, 1);
      await second;
      expect(restores, 1);
      session.continueReading();
      expect(session.isReview, isTrue);

      restored.complete();
      await first;
      expect(session.busy, isFalse);
      expect(restores, 1);
      expect(fallbacks, 0);
      expect(repository.reads, 0);
      expect(repository.patches, 0);
    },
  );

  testWidgets(
    'video banner labels review and normal watching without a clip return',
    (WidgetTester tester) async {
      session.dispose();
      session = SourceReviewSession(
        link: CardSourceLink(
          kind: CardSourceKind.video,
          uid: 'video-uid',
          sourceId: _sourceId,
          episodeIndex: 0,
          fingerprint: 'a' * 64,
          startMs: 1200,
          endMs: 3400,
        ),
        repository: repository,
        draftStore: store,
      );
      await mount(tester);
      expect(find.text(t.card_source_review_video_title), findsOneWidget);
      expect(find.text(t.card_source_review_video_return), findsOneWidget);
      expect(find.text(t.card_source_review_title), findsNothing);
      expect(find.text(t.card_source_review_return), findsNothing);
      // Returning to the clip is the source link itself, not an in-page button:
      // the video page drops this whole banner once watching continues.
      expect(
        find.byKey(const ValueKey<String>('source-review-return-to-source')),
        findsNothing,
      );
      await tester.tap(
        find.widgetWithText(TextButton, t.card_source_review_video_continue),
      );
      await tester.pump();
      expect(session.isReview, isFalse);
      expect(find.text(t.card_source_review_video_watching), findsOneWidget);
      expect(find.text(t.card_source_review_source), findsNothing);
      expect(find.text(t.card_source_review_video_continue), findsNothing);
      expect(repository.reads, 0);
      expect(repository.patches, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'offline mining retains temporary media without adding or patching',
    (WidgetTester tester) async {
      await mount(tester);
      repository.offline = true;
      await tester.runAsync(() async {
        final File audio = await File(
          p.join(scratch.path, 'temporary.wav'),
        ).writeAsBytes(<int>[1, 2, 3]);
        final MineOutcome outcome = await session.mine(
          rawPayloadJson: jsonEncode(<String, String>{'audio': audio.path}),
          context: AnkiMiningContext(
            sentence: 'sentence',
            sentenceAudioPath: audio.path,
          ),
        );
        expect(outcome.result, MineResult.error);
        await audio.delete();
        final SourceReviewDraft draft = (await store.read(_sourceId))!;
        expect(
          await File(draft.mining!.context.sentenceAudioPath!).readAsBytes(),
          <int>[1, 2, 3],
        );
        final Map<String, dynamic> raw =
            jsonDecode(draft.mining!.rawPayloadJson) as Map<String, dynamic>;
        expect(await File(raw['audio'] as String).readAsBytes(), <int>[
          1,
          2,
          3,
        ]);
        expect(draft.patch, isNull);
      });
      expect(session.hasDraft, isTrue);
      expect(repository.reads, 1);
      expect(repository.prepares, 0);
      expect(repository.patches, 0);
      expect(repository.additions, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('conflict retains selected patch and does not retry', (
    WidgetTester tester,
  ) async {
    await mount(tester);
    repository.conflict = true;
    final Future<MineOutcome> pending = session.mine(
      rawPayloadJson: '{}',
      context: const AnkiMiningContext(sentence: 'sentence'),
    );
    await _chooseSentenceAndSave(tester);
    await _until(tester, () => !session.busy);
    final MineOutcome outcome = await pending;
    expect(outcome.result, MineResult.error);
    final SourceReviewDraft? draft = await tester.runAsync<SourceReviewDraft?>(
      () => store.read(_sourceId),
    );
    expect(draft!.patch!.fields, <String, String>{'Sentence': 'new sentence'});
    expect(draft.patch!.original.fields['Sentence'], 'original');
    expect(session.hasDraft, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(repository.patches, 1);
    expect(repository.reads, 1);
    expect(repository.additions, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'resume reads a fresh snapshot and patches only manually selected fields',
    (WidgetTester tester) async {
      await tester.runAsync(
        () => store.savePatch(
          original: repository.snapshot,
          fields: <String, String>{
            'Sentence': 'draft sentence',
            'Meaning': 'draft meaning',
          },
        ),
      );
      repository.current = <String, String>{
        'Sentence': 'changed in Anki',
        'Meaning': 'fresh manual meaning',
      };
      await mount(tester);
      final Future<void> pending = session.resumeDraft();
      await _chooseSentenceAndSave(tester);
      await _until(tester, () => !session.busy);
      await pending;
      expect(repository.reads, 1);
      expect(repository.patchedOriginal!.fields['Sentence'], 'changed in Anki');
      expect(repository.patchedFields, <String, String>{
        'Sentence': 'draft sentence',
      });
      expect(repository.current['Meaning'], 'fresh manual meaning');
      expect(repository.patches, 1);
      expect(repository.additions, 0);
      expect(
        await tester.runAsync<SourceReviewDraft?>(() => store.read(_sourceId)),
        isNull,
      );
      expect(session.hasDraft, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('existing draft blocks new mining from replacing saved work', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(
      () => store.saveMining(
        link: _link,
        rawPayloadJson: '{"expression":"saved"}',
        context: const AnkiMiningContext(sentence: 'saved sentence'),
      ),
    );
    await mount(tester);
    await tester.runAsync(() async {
      final MineOutcome outcome = await session.mine(
        rawPayloadJson: '{"expression":"replacement"}',
        context: const AnkiMiningContext(sentence: 'replacement'),
      );
      expect(outcome.result, MineResult.error);
      final SourceReviewDraft draft = (await store.read(_sourceId))!;
      expect(draft.mining!.rawPayloadJson, '{"expression":"saved"}');
      expect(draft.mining!.context.sentence, 'saved sentence');
    });
    expect(repository.reads, 0);
    expect(repository.prepares, 0);
    expect(repository.patches, 0);
    expect(repository.additions, 0);
    expect(session.hasDraft, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('busy review disables continue until pending edit ends', (
    WidgetTester tester,
  ) async {
    await mount(tester);
    repository.pendingRead = Completer<AnkiSourceNote?>();
    final Future<MineOutcome> pending = session.mine(
      rawPayloadJson: '{}',
      context: const AnkiMiningContext(sentence: 'sentence'),
    );
    await _until(tester, () => repository.reads == 1);
    session.continueReading();
    expect(session.isReview, isTrue);
    final Finder continueButton = find.widgetWithText(
      TextButton,
      t.card_source_review_continue,
    );
    expect(tester.widget<TextButton>(continueButton).onPressed, isNull);
    repository.pendingRead!.complete(null);
    await _until(tester, () => !session.busy);
    await pending;
    await tester.pump();
    expect(session.busy, isFalse);
    await tester.ensureVisible(continueButton);
    await tester.pump();
    await tester.tap(continueButton);
    await tester.pump();
    expect(session.isReview, isFalse);
    expect(repository.patches, 0);
    expect(repository.additions, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
