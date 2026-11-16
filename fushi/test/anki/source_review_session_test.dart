import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/source_review_draft_store.dart';
import 'package:fushi/src/anki/source_review_session.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:path/path.dart' as p;
import '../helpers/glass_unwrap.dart';

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
  bool missing = false;
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
    if (missing) return null;
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
  expect(
    tester.widget<FilledButton>(glassUnwrap<FilledButton>(save)).onPressed,
    isNull,
  );
  expect(
    tester.widget<Checkbox>(glassUnwrap<Checkbox>(sentence)).value,
    isFalse,
  );
  await tester.tap(sentence);
  await tester.pump();
  expect(
    tester.widget<Checkbox>(glassUnwrap<Checkbox>(sentence)).value,
    isTrue,
  );
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
      tester.element(find.descendant(of: button, matching: find.byType(Text))),
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

  testWidgets(
    'missing original leaves no draft and does not block the next mining '
    '(BUG-4232)',
    (WidgetTester tester) async {
      await mount(tester);
      repository.missing = true;
      await tester.runAsync(() async {
        final File audio = await File(
          p.join(scratch.path, 'temporary.wav'),
        ).writeAsBytes(<int>[1, 2, 3]);
        for (int attempt = 1; attempt <= 2; attempt++) {
          final MineOutcome outcome = await session.mine(
            rawPayloadJson: jsonEncode(<String, String>{'audio': audio.path}),
            context: AnkiMiningContext(
              sentence: 'sentence',
              sentenceAudioPath: audio.path,
            ),
          );
          expect(outcome.result, MineResult.error);
          // The definitive answer is surfaced, not "kept as a draft", and the
          // second attempt is not refused as "existing draft".
          expect(outcome.errorDetail, t.card_source_review_missing);
          expect(await store.read(_sourceId), isNull);
        }
      });
      expect(session.hasDraft, isFalse);
      expect(repository.reads, 2);
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
    expect(
      tester
          .widget<TextButton>(glassUnwrap<TextButton>(continueButton))
          .onPressed,
      isNull,
    );
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

  /// 反馈 m6TVBNxGa9：Android 横屏手机（792×363dp）上横幅固定「标题一行 + 按钮一行」，
  /// 占掉约 1/5 画面高度。矮窗口（高 < 480dp，M3 compact height）必须并成单行。
  Future<Rect> mountSized(
    WidgetTester tester,
    Size size, {
    FakeViewPadding padding = FakeViewPadding.zero,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
    addTearDown(tester.view.reset);
    final int previousReads = store.completedReads;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              SourceReviewBanner(session: session, onReturn: () {}),
              const Expanded(child: SizedBox.expand()),
            ],
          ),
        ),
      ),
    );
    await _until(tester, () => store.completedReads > previousReads);
    return tester.getRect(find.byType(SourceReviewBanner));
  }

  testWidgets('short landscape window folds banner into one row', (
    WidgetTester tester,
  ) async {
    const Size window = Size(792, 363);
    final Rect banner = await mountSized(tester, window);
    expect(banner.height, lessThanOrEqualTo(48));
    // 阅读器按 reservedContentHeight 给横幅留槽位，必须与横幅实际高度同源。
    expect(banner.height, SourceReviewBanner.reservedContentHeight(window));
    final Rect title = tester.getRect(find.text(t.card_source_review_title));
    final Rect back = tester.getRect(find.text(t.card_source_review_return));
    expect(title.center.dy, moreOrLessEquals(back.center.dy, epsilon: 1));
    expect(title.right, lessThanOrEqualTo(back.left));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tall window keeps title above the button row', (
    WidgetTester tester,
  ) async {
    const Size window = Size(411, 891);
    final Rect banner = await mountSized(tester, window);
    final Rect title = tester.getRect(find.text(t.card_source_review_title));
    final Rect back = tester.getRect(find.text(t.card_source_review_return));
    expect(title.bottom, lessThanOrEqualTo(back.top));
    expect(
      banner.height,
      lessThanOrEqualTo(SourceReviewBanner.reservedContentHeight(window)),
    );
    await tester.pumpWidget(const SizedBox());
  });

  /// 单行布局里按钮条按内容取宽：有草稿时四颗按钮（继续草稿 / 丢弃草稿 / 返回 /
  /// 继续）在放得下的矮宽窗口里必须全部摆出来，不能因为和标题平分宽度而被迫滚动、
  /// 把后面的按钮藏起来。
  testWidgets('compact banner with a draft lays out every button unscrolled', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(
      () => store.saveMining(
        link: _link,
        rawPayloadJson: '{"expression":"saved"}',
        context: const AnkiMiningContext(sentence: 'saved sentence'),
      ),
    );
    final Rect banner = await mountSized(tester, const Size(1280, 400));
    expect(session.hasDraft, isTrue);
    final ScrollableState strip = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(SourceReviewBanner),
        matching: find.byType(Scrollable),
      ),
    );
    expect(strip.position.maxScrollExtent, 0);
    final Rect last = tester.getRect(find.text(t.card_source_review_continue));
    expect(last.right, lessThanOrEqualTo(banner.right));
    final Rect title = tester.getRect(find.text(t.card_source_review_title));
    expect(
      title.right,
      lessThanOrEqualTo(
        tester.getRect(find.text(t.card_source_review_draft_resume)).left,
      ),
    );
    await tester.pumpWidget(const SizedBox());
  });

  /// 横屏刘海：横幅自己的 SafeArea 让出左侧刘海与状态栏，底色从窗口左缘铺起。
  /// 视频 / 漫画页外面不得再套一层 SafeArea（那会把刘海一侧让成空白条）。
  testWidgets('banner background spans the notch side and pads its content', (
    WidgetTester tester,
  ) async {
    final Rect banner = await mountSized(
      tester,
      const Size(792, 363),
      padding: const FakeViewPadding(left: 40, top: 24),
    );
    final Rect material = tester.getRect(
      find
          .descendant(
            of: find.byType(SourceReviewBanner),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.left, 0);
    expect(material.top, 0);
    expect(banner.height, 24 + SourceReviewBanner.compactContentHeight);
    final Rect title = tester.getRect(find.text(t.card_source_review_title));
    expect(title.left, greaterThanOrEqualTo(40));
    await tester.pumpWidget(const SizedBox());
  });

  test('pages host the banner without an extra SafeArea or fixed slot', () {
    final String video = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    final String manga = File(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ).readAsStringSync();
    final String reader = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    for (final MapEntry<String, String> page in <String, String>{
      'video': video,
      'manga': manga,
    }.entries) {
      final int at = page.value.indexOf('SourceReviewBanner(');
      expect(at, greaterThanOrEqualTo(0), reason: page.key);
      final String head = page.value.substring(at - 1500, at);
      expect(
        head.substring(head.lastIndexOf('if (_sourceReviewSession')),
        isNot(contains('SafeArea(')),
        reason: '${page.key}：外层 SafeArea 会把刘海一侧让成横幅底色外的空白条',
      );
    }
    expect(
      reader,
      contains('SourceReviewBanner.reservedContentHeight('),
      reason: '阅读器的横幅槽位高必须与横幅单行 / 两行判断同源',
    );
  });
}
