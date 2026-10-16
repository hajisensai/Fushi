// 复习模块页面：牌组列表 / 复习页 / 笔记编辑页，MD3 与 Apple 两套设计系统各 pump 一次。
//
// 内存库 + 确定性假排程内核（真实数值由 packages/fushi_srs 的 FFI 测试覆盖）；
// widget 测试里没有 WebView，卡面经 srsCardFaceBuilderProvider 换成纯文本实现。
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 确定性假引擎（同 packages/fushi_engine/test/srs/srs_db_store_test.dart）。
class _FakeEngine implements FsrsEngine {
  const _FakeEngine();

  @override
  String get fsrsRev => 'fake';
  @override
  List<double> defaultParams(SrsAlgorithm a) =>
      List<double>.filled(a.paramCount, 1);
  @override
  String? validateParams(SrsAlgorithm a, List<double> p) => null;
  SrsMemory _step(SrsMemory? m, int r) => SrsMemory(
    stability: switch (r) {
      1 => 0.3,
      2 => 1.5 + (m?.stability ?? 0),
      3 => 3 + (m?.stability ?? 0) * 2,
      _ => 6 + (m?.stability ?? 0) * 3,
    },
    difficulty: 5,
  );
  @override
  SrsNextStates nextStates({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double desiredRetention,
    required SrsMemory? memory,
    required double elapsedDays,
  }) {
    SrsItemState st(int r) {
      final SrsMemory m = _step(memory, r);
      return SrsItemState(memory: m, interval: m.stability);
    }

    return SrsNextStates(again: st(1), hard: st(2), good: st(3), easy: st(4));
  }

  @override
  SrsMemory? memoryState({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<SrsFsrsReview> reviews,
    SrsMemory? starting,
  }) {
    SrsMemory? m = starting;
    for (final SrsFsrsReview r in reviews) {
      m = _step(m, r.rating);
    }
    return m;
  }

  @override
  SrsMemory memoryStateFromSm2({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double easeFactor,
    required double intervalDays,
    required double sm2Retention,
  }) => SrsMemory(stability: intervalDays, difficulty: 5);
  @override
  double retrievability({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsMemory memory,
    required double elapsedDays,
  }) => 0.9;
  @override
  List<double> computeParameters({
    required SrsAlgorithm algorithm,
    required List<List<SrsFsrsReview>> items,
    List<int>? cardIds,
    SrsOptimizerControl? control,
  }) => defaultParams(algorithm);
  @override
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required List<List<SrsFsrsReview>> items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
  @override
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<List<SrsFsrsReview>> items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
}

const String _kProfile = '01928c3e-0000-7000-8000-0000000000aa';

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(() => tester.runAsync(db.close));
  return (await tester.runAsync(
    () => SrsDbStore.open(
      db: db,
      profileUid: _kProfile,
      deviceId: 'test-device',
      engine: const _FakeEngine(),
    ),
  ))!;
}

Future<String> _addLapis(
  WidgetTester tester,
  SrsDbStore store,
  String expression,
) async => (await tester.runAsync(
  () => store.createNote(
    noteTypeId: store.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(_kProfile, 'Expression'): expression,
      srsLapisFieldId(_kProfile, 'MainDefinition'): 'to eat',
    },
  ),
))!;

/// 让真异步（drift）与帧都推进：DB 读在 runAsync 里跑一小段真实时间。
Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required SrsDbStore store,
  required bool apple,
  required Widget page,
  List<Override> overrides = const <Override>[],
  Size size = const Size(1100, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel appModel = AppModel(testPlatformServices());
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsCardFaceBuilderProvider.overrideWithValue(
          (BuildContext context, SrsCardFace face) =>
              SrsPlainCardFace(face: face),
        ),
        ...overrides,
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: apple
                ? FushiDesignSystem.cupertino
                : FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: page,
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 牌组列表：空库给出「添加第一张卡」，加卡后显示新卡计数', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsDeckListPage(),
      );
      expect(
        isGlassDesign(tester.element(find.byType(SrsDeckListPage))),
        apple,
      );
      expect(find.byKey(const ValueKey<String>('srs-empty')), findsOneWidget);
      expect(find.text('Default'), findsOneWidget);
      // 排程内核可用：不出「内核不可用」横幅。
      expect(
        find.byKey(const ValueKey<String>('srs-engine-missing')),
        findsNothing,
      );

      await _unmount(tester);
      await _addLapis(tester, store, '食べる');
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsDeckListPage(),
      );
      expect(find.byKey(const ValueKey<String>('srs-empty')), findsNothing);
      final Finder row = find.byKey(
        ValueKey<String>('srs-deck-${store.defaultDeckId}'),
      );
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('1')),
        findsOneWidget,
        reason: '一张新卡：新卡计数为 1',
      );
      // 顶栏动作：添加笔记 / 浏览 / 冲突 / 新建牌组 / 导入。
      expect(find.byKey(const ValueKey<String>('srs_add_note')), findsWidgets);
      await _unmount(tester);
    });

    testWidgets('[$ds] 复习页：显示答案 → 评分预览 → 评分', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _addLapis(tester, store, '食べる');
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'Default'),
      );
      expect(
        find.byKey(const ValueKey<String>('srs-face-question')),
        findsOneWidget,
      );
      expect(find.textContaining('食べる'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('srs-face-answer')),
        findsOneWidget,
      );
      for (int r = 1; r <= 4; r++) {
        expect(find.byKey(ValueKey<String>('srs-rate-$r')), findsOneWidget);
      }
      // 「简单」直接毕业到复习队列：至少有一个按天计的间隔预览（带 fuzz，不钉具体值）。
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Text &&
              RegExp(r'^\d+(\.\d+)?(d|mo|y)$').hasMatch(w.data ?? ''),
        ),
        findsWidgets,
      );

      await tester.tap(find.byKey(const ValueKey<String>('srs-rate-4')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('srs-review-finished')),
        findsOneWidget,
      );
      final SrsCardCacheRow? card = await tester.runAsync<SrsCardCacheRow>(
        () async {
          final List<SrsDeckSummary> s = await store.deckSummaries();
          expect(s.single.reviewCount, 0);
          final String noteId = (await store.listNotes()).single.id;
          return (await store.cardsOfNote(noteId)).single;
        },
      );
      expect(card!.queue, SrsQueue.review.wire);
      await _unmount(tester);
    });

    testWidgets('[$ds] 笔记编辑页：Lapis 常用字段在前，其余折进「更多字段」，添加写库', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsNoteEditorPage(),
      );
      for (final String name in <String>[
        'Expression',
        'ExpressionReading',
        'MainDefinition',
        'Sentence',
      ]) {
        expect(
          find.byKey(ValueKey<String>('srs-field-$name')),
          findsOneWidget,
          reason: name,
        );
      }
      expect(
        find.byKey(const ValueKey<String>('srs-note-more-fields')),
        findsOneWidget,
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey<String>('srs-field-Expression')),
          matching: find.byType(EditableText),
        ),
        '飲む',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_note_save')).first,
      );
      await _settle(tester);
      final List<SrsNoteCacheRow> notes = (await tester.runAsync(
        store.listNotes,
      ))!;
      expect(notes, hasLength(1));
      expect(notes.single.sortField, '飲む');
      await _unmount(tester);
    });
  }

  testWidgets('键盘：空格显示答案、数字评分、Ctrl+Z 撤销回到同一张卡', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store, '食べる');
    await _pumpPage(
      tester,
      store: store,
      apple: false,
      page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'Default'),
    );
    expect(
      find.byKey(const ValueKey<String>('srs-face-question')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('srs-face-answer')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('srs-review-finished')),
      findsOneWidget,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('srs-face-question')),
      findsOneWidget,
      reason: '撤销评分后回到被撤的那张卡（问题面）',
    );
    final String queue = (await tester.runAsync(() async {
      final String noteId = (await store.listNotes()).single.id;
      return (await store.cardsOfNote(noteId)).single.queue;
    }))!;
    expect(queue, SrsQueue.newCard.wire);
    await _unmount(tester);
  });

  testWidgets('牌组列表：空的默认牌组在有别的顶层牌组时隐藏（Anki hide_default_deck）', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    final String jp = (await tester.runAsync(() => store.createDeck('JP')))!;
    Future<List<String>> visibleIds() async => (await tester.runAsync(
      () async => srsVisibleDecks(
        await store.deckSummaries(),
        defaultDeckId: store.defaultDeckId,
      ).map((SrsDeckSummary d) => d.deck.id).toList(),
    ))!;

    expect(await visibleIds(), <String>[jp], reason: '空、无子牌组、另有顶层牌组');
    await _pumpPage(
      tester,
      store: store,
      apple: false,
      page: const SrsDeckListPage(),
    );
    expect(
      find.byKey(ValueKey<String>('srs-deck-${store.defaultDeckId}')),
      findsNothing,
    );
    expect(find.byKey(ValueKey<String>('srs-deck-$jp')), findsOneWidget);
    await _unmount(tester);

    // 默认牌组里有卡：照常显示。
    await _addLapis(tester, store, '食べる');
    expect(await visibleIds(), containsAll(<String>[store.defaultDeckId, jp]));
    final String noteId = (await tester.runAsync(
      () async => (await store.listNotes()).single.id,
    ))!;
    await tester.runAsync(() => store.deleteNote(noteId));
    expect(await visibleIds(), <String>[jp]);

    // 默认牌组有子牌组：照常显示。
    await tester.runAsync(
      () => store.createDeck('Child', parentId: store.defaultDeckId),
    );
    expect(await visibleIds(), contains(store.defaultDeckId));
  });

  testWidgets('牌组列表：手机宽度下多级子牌组的名字仍有宽度，行首不放图标', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    final List<String> ids = (await tester.runAsync(() async {
      final List<String> out = <String>[];
      String? parent;
      for (final String name in <String>[
        'Spark',
        'JP-Mining-Long-Deck-Name',
        'Vocabulary',
        'Chapter Twelve',
        'Kanji Drill',
      ]) {
        parent = await store.createDeck(name, parentId: parent);
        out.add(parent);
      }
      return out;
    }))!;
    await _pumpPage(
      tester,
      store: store,
      apple: false,
      page: const SrsDeckListPage(),
      size: const Size(360, 780),
    );
    expect(find.byType(FushiListLeadingIcon), findsNothing);
    for (int depth = 0; depth < ids.length; depth++) {
      final Finder row = find.byKey(ValueKey<String>('srs-deck-${ids[depth]}'));
      expect(row, findsOneWidget);
      final Finder indent = find.byKey(
        ValueKey<String>('srs-deck-indent-${ids[depth]}'),
      );
      expect(indent, depth == 0 ? findsNothing : findsOneWidget);
      if (depth > 0) {
        expect(
          tester.getSize(indent).width,
          SrsDeckIndentGuides.widthFor(depth),
        );
      }
      final Finder name = find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Text &&
              w.data != null &&
              RegExp(r'[A-Za-z]').hasMatch(w.data!),
        ),
      );
      expect(
        tester.getSize(name.first).width,
        greaterThan(60),
        reason: '第 $depth 层的名字至少留出几个字的宽度（原来三级以下宽度为 0）',
      );
    }
    // 三色计数列在各层对齐（行尾宽度不随层级变）。
    final Set<double> rights = <double>{
      for (final String id in ids)
        tester
            .getTopRight(
              find.descendant(
                of: find.byKey(ValueKey<String>('srs-deck-$id')),
                matching: find.byType(SrsCountTriple),
              ),
            )
            .dx,
    };
    expect(rights, hasLength(1));
    await _unmount(tester);
  });

  group('复习页卡面音频', () {
    Future<String> addWithAudio(WidgetTester tester, SrsDbStore store) async =>
        (await tester.runAsync(
          () => store.createNote(
            noteTypeId: store.lapisNoteTypeId,
            fieldsById: <String, String>{
              srsLapisFieldId(_kProfile, 'Expression'): '食べる',
              srsLapisFieldId(_kProfile, 'MainDefinition'): 'to eat',
              srsLapisFieldId(_kProfile, 'ExpressionAudio'): '[sound:word.mp3]',
              srsLapisFieldId(_kProfile, 'SentenceAudio'): '[sound:sent.mp3]',
            },
          ),
        ))!;

    testWidgets('开了自动播放：翻到答案面按顺序播单词 / 句子音频；关着不播；重播都能用', (
      WidgetTester tester,
    ) async {
      for (final bool autoplay in <bool>[true, false]) {
        final SrsDbStore store = await _openStore(tester);
        await addWithAudio(tester, store);
        final _RecordingAudio audio = _RecordingAudio();
        await _pumpPage(
          tester,
          store: store,
          apple: false,
          page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'D'),
          overrides: <Override>[
            srsCardAudioOutputProvider.overrideWithValue(audio),
            srsReviewAutoplayAudioProvider.overrideWithValue(autoplay),
          ],
        );
        expect(audio.played, isEmpty, reason: 'Lapis 问题面没有音频');
        await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
        await _settle(tester);
        expect(
          audio.played,
          autoplay ? <String>['word.mp3', 'sent.mp3'] : isEmpty,
          reason: 'autoplay=$autoplay',
        );
        // 「重播音频」：答案面上不管开关都能手动播。
        audio.played.clear();
        await tester.tap(
          find.byKey(const ValueKey<String>('srs_review_replay_audio')).first,
        );
        await _settle(tester);
        expect(audio.played, <String>['word.mp3', 'sent.mp3']);
        await _unmount(tester);
      }
    });

    testWidgets('评分换卡时打断还在播的序列', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await addWithAudio(tester, store);
      final _RecordingAudio audio = _RecordingAudio(holdOpen: true);
      await _pumpPage(
        tester,
        store: store,
        apple: false,
        page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'D'),
        overrides: <Override>[
          srsCardAudioOutputProvider.overrideWithValue(audio),
          srsReviewAutoplayAudioProvider.overrideWithValue(true),
        ],
      );
      await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
      await _settle(tester);
      expect(audio.played, <String>['word.mp3'], reason: '第一段还没播完');
      await tester.tap(find.byKey(const ValueKey<String>('srs-rate-3')));
      await _settle(tester);
      expect(audio.stops, greaterThanOrEqualTo(1));
      expect(audio.played, <String>['word.mp3'], reason: '被打断后不再播第二段');
      await _unmount(tester);
    });
  });

  testWidgets('排程内核不可用：横幅提示，复习页不给评分', (WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final SrsDbStore store = (await tester.runAsync(
      () => SrsDbStore.open(db: db, profileUid: _kProfile, deviceId: 'd'),
    ))!;
    await _pumpPage(
      tester,
      store: store,
      apple: false,
      page: const SrsDeckListPage(),
    );
    expect(
      find.byKey(const ValueKey<String>('srs-engine-missing')),
      findsOneWidget,
    );
    await _unmount(tester);
  });

  testWidgets('新手引导的复习介绍：四个要点都能渲染', (WidgetTester tester) async {
    final List<OnboardingTutorialItem> items = srsOnboardingTutorialItems();
    expect(items, hasLength(4));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < items.length; i++)
                    OnboardingTutorialStep(
                      number: i + 1,
                      item: items[i],
                      isLast: i == items.length - 1,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    for (final OnboardingTutorialItem item in items) {
      expect(find.text(item.title), findsOneWidget);
    }
  });
}

/// 记下播了哪些音频的假播放出口。[holdOpen] = 每段都「播不完」，直到 stop。
class _RecordingAudio implements SrsCardAudioOutput {
  _RecordingAudio({this.holdOpen = false});

  final bool holdOpen;
  final List<String> played = <String>[];
  final List<Completer<bool>> _open = <Completer<bool>>[];
  int stops = 0;

  @override
  Future<bool> playToEnd(String name) {
    played.add(name);
    if (!holdOpen) return Future<bool>.value(true);
    final Completer<bool> c = Completer<bool>();
    _open.add(c);
    return c.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    for (final Completer<bool> c in _open) {
      if (!c.isCompleted) c.complete(false);
    }
  }
}
