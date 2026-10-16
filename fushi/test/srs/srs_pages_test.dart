// 复习模块页面：牌组列表 / 复习页 / 笔记编辑页，MD3 与 Apple 两套设计系统各 pump 一次。
//
// 内存库 + 确定性假排程内核（真实数值由 packages/fushi_srs 的 FFI 测试覆盖）；
// widget 测试里没有 WebView，卡面经 srsCardFaceBuilderProvider 换成纯文本实现。
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
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
}) async {
  tester.view.physicalSize = const Size(1100, 900);
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

    testWidgets('[$ds] 牌组列表：父牌组箭头收起 / 展开子牌组，键盘 ←/→ 同样生效并写库', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final String child = (await tester.runAsync(
        () => store.ensureDeckPath('Parent::Child'),
      ))!;
      final String parent = (await tester.runAsync(
        () async => (await store.deckTree()).parentOf(child)!,
      ))!;
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsDeckListPage(),
      );
      final Finder childRow = find.byKey(ValueKey<String>('srs-deck-$child'));
      final Finder toggle = find.byKey(
        ValueKey<String>('srs-deck-toggle-$parent'),
      );
      double childHeight() => tester.getSize(childRow).height;
      expect(toggle, findsOneWidget, reason: '有子牌组的行才有箭头');
      expect(
        find.byKey(ValueKey<String>('srs-deck-toggle-$child')),
        findsNothing,
      );
      // 首次（无状态）默认展开。
      expect(childHeight(), greaterThan(0));
      expect(
        tester.getSize(toggle).width,
        greaterThanOrEqualTo(apple ? 36 : 48),
      );

      await tester.tap(toggle);
      await _settle(tester);
      expect(childHeight(), 0, reason: '收起后后代消失');
      expect(
        await tester.runAsync(
          () async => (await store.deckTree())[parent]!.collapsed,
        ),
        isTrue,
        reason: '折叠写进牌组本身',
      );

      await tester.tap(toggle);
      await _settle(tester);
      expect(childHeight(), greaterThan(0), reason: '再展开后代出现');

      // 键盘：焦点在父牌组行内（这里取行首箭头按钮；真 app 里整行卡片的焦点目标同在行内）
      // ← 收起、→ 展开。测试没挂 FushiFocusRoot，Apple 卡片不挂焦点目标，所以不用标题找焦点。
      final Element toggleElement = tester.element(toggle);
      final FocusNode rowFocus = FocusManager.instance.rootScope.descendants
          .firstWhere((FocusNode n) {
            bool inside = false;
            n.context?.visitAncestorElements((Element e) {
              if (identical(e, toggleElement)) {
                inside = true;
                return false;
              }
              return true;
            });
            return inside && n.canRequestFocus;
          });
      rowFocus.requestFocus();
      await tester.pump();
      expect(rowFocus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await _settle(tester);
      expect(childHeight(), 0);
      expect(
        await tester.runAsync(
          () async => (await store.deckTree())[parent]!.collapsed,
        ),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _settle(tester);
      expect(childHeight(), greaterThan(0));
      expect(
        await tester.runAsync(
          () async => (await store.deckTree())[parent]!.collapsed,
        ),
        isFalse,
      );
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
