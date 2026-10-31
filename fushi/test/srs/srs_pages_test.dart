// 复习模块页面：牌组列表 / 复习页 / 笔记编辑页，MD3 与 Apple 两套设计系统各 pump 一次。
//
// 内存库 + 确定性假排程内核（真实数值由 packages/fushi_srs 的 FFI 测试覆盖）；
// widget 测试里没有 WebView，卡面经 srsCardFaceBuilderProvider 换成纯文本实现。
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_settings_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_layout_sheet.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_layout.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show DictionaryEntry, DictionarySearchResult;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'srs_test_support.dart' show SrsTestAppModel, openSrsTestStorage;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/popup_mining_target_overrides.dart';

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
    required SrsFsrsTrainingSet items,
    SrsOptimizerControl? control,
  }) => defaultParams(algorithm);
  @override
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
  @override
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsFsrsTrainingSet items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
}

/// 复习页「只留重来 / 良好」偏好放内存里（不碰数据库），其余同真 AppModel。
class _HideHardEasyApp extends SrsTestAppModel {
  _HideHardEasyApp();

  bool hidden = false;

  @override
  bool get srsReviewHideHardEasy => hidden;

  @override
  Future<void> setSrsReviewHideHardEasy(bool value) async {
    hidden = value;
    notifyListeners();
  }
}

/// 复习布局两项偏好钉在内存里（测试里偏好层没初始化）。
class _LayoutApp extends SrsTestAppModel {
  _LayoutApp();

  SrsReviewReplayButton replay = SrsReviewReplayButton.end;
  bool intervals = true;
  bool counts = true;
  double volume = 1.0;

  @override
  double get srsReviewVolume => volume;

  @override
  Future<void> setSrsReviewVolume(double value) async {
    volume = value;
    notifyListeners();
  }

  @override
  bool get srsReviewShowCounts => counts;

  @override
  Future<void> setSrsReviewShowCounts(bool value) async {
    counts = value;
    notifyListeners();
  }

  @override
  SrsReviewReplayButton get srsReviewReplayButton => replay;

  @override
  Future<void> setSrsReviewReplayButton(SrsReviewReplayButton value) async {
    replay = value;
    notifyListeners();
  }

  @override
  bool get srsReviewShowIntervals => intervals;

  @override
  Future<void> setSrsReviewShowIntervals(bool value) async {
    intervals = value;
    notifyListeners();
  }

  SrsReviewImageSize imageSize = SrsReviewImageSize.original;

  @override
  SrsReviewImageSize get srsReviewImageSize => imageSize;

  @override
  Future<void> setSrsReviewImageSize(SrsReviewImageSize value) async {
    imageSize = value;
    notifyListeners();
  }
}

/// 卡面查词：弹窗几何 / 历史读偏好的那几项钉成常量（测试里偏好层没初始化）。
class _LookupApp extends SrsTestAppModel {
  _LookupApp();

  @override
  int get maximumTerms => 10;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  double get dictionaryFontSize => 16;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  bool get lowMemoryMode => false;
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];
  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}
  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}
}

const String _kProfile = '01928c3e-0000-7000-8000-0000000000aa';

/// 把默认牌组切成 FSRS-7：评分按钮上的「进复习队列的天数」只有非 RWKV 牌组才显示（RWKV 牌组的复习卡按此刻
/// 的回忆率回来，天数不是它真正回来的时间；RWKV 没就绪时也不退回 FSRS-7 的到期日，BUG-3892）。
Future<void> _useFsrs7(WidgetTester tester, SrsDbStore store) async {
  await tester.runAsync(
    () => store.editFields(
      SrsEntityKind.deck,
      store.defaultDeckId,
      <String, Object?>{
        SrsFieldKeys.deckAlgorithm: <String, Object?>{
          'alg': SrsAlgorithm.fsrs7.wire,
          'auto': false,
        },
      },
    ),
  );
}

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final SrsStorage srs = (await tester.runAsync(openSrsTestStorage))!;
  return (await tester.runAsync(
    () => SrsDbStore.open(
      db: srs.db,
      core: srs.core,
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

/// 子牌组收起要等收起弹簧落定（FushiTreeReveal：ζ 钉 1，Apple 的 spatialDefault 刚度
/// 157.91 落到 0.1% 约 0.73 s），默认 12 轮 × 60 ms 不够，收起断言多等一段。
const int _kTreeSettleRounds = 20;

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
  AppModel? app,
  Size size = const Size(1100, 900),
  List<Override> overrides = const <Override>[],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel appModel = app ?? SrsTestAppModel();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        // 复习页先等 RWKV 服务装配到 store 上：测试不起真服务（会去下载权重），要用 RWKV 的用例自己给
        // `store.rwkv` 装替身。
        srsRwkvServiceProvider.overrideWith((Ref ref) async => null),
        srsCardFaceBuilderProvider.overrideWithValue(
          (BuildContext context, SrsCardFace face) =>
              SrsPlainCardFace(face: face),
        ),
        // 这里的用例按固定页头断言顶栏按钮；悬浮顶栏（默认）见
        // srs_review_floating_chrome_test.dart。
        srsReviewChromeFloatingProvider.overrideWithValue(false),
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

    testWidgets('[$ds] 牌组列表手机竖屏（412 宽，三级嵌套）：每级名字完整可见、行紧凑、长按出菜单', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await tester.runAsync(() async {
        await store.ensureDeckPath('Lapis');
        for (final String leaf in <String>['Vocabulary', 'N3', 'Kanji']) {
          await store.ensureDeckPath('Spark::JP-Mining-Note::$leaf');
        }
      });
      await _addLapis(tester, store, '食べる');
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsDeckListPage(),
        size: const Size(412, 915),
      );
      expect(tester.takeException(), isNull, reason: '窄屏行不溢出');
      for (final String name in <String>[
        'Default',
        'Lapis',
        'Spark',
        'JP-Mining-Note',
        'Vocabulary',
        'N3',
        'Kanji',
      ]) {
        final Finder title = find.text(name);
        expect(title, findsOneWidget, reason: '$name 在列表里');
        // 名字完整排下（不是只剩省略号）：此前真机上二级只剩「JP-…」、三级完全不显示。
        final RenderParagraph p = tester.renderObject<RenderParagraph>(title);
        expect(p.didExceedMaxLines, isFalse, reason: '$name 没被省略号截断');
        expect(p.size.width, greaterThan(0), reason: '$name 有宽度');
      }
      // 紧凑：单行名的行高不超过 56（改前每行 ~76，一屏只放得下约 8 行）。
      final Finder rows = find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('srs-deck-') &&
            !(w.key! as ValueKey<String>).value.contains('toggle') &&
            !(w.key! as ValueKey<String>).value.contains('indent'),
      );
      expect(rows, findsNWidgets(7));
      for (final Element e in rows.evaluate()) {
        expect(
          tester.getSize(find.byWidget(e.widget)).height,
          lessThanOrEqualTo(56),
          reason: '窄屏单行牌组行高',
        );
      }
      // 窄屏不画行尾「⋯」，长按行弹出同一份牌组菜单。
      expect(find.byTooltip(t.srs_deck_menu), findsNothing);
      await tester.longPress(find.text('Vocabulary'));
      await _settle(tester);
      expect(find.text(t.srs_deck_rename), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      await _unmount(tester);
    });

    testWidgets('[$ds] 牌组拖放：拖到行中间 = 挪成子牌组、拖到行上缘 = 排到它前面；拖着子牌组出现「移到顶层」落点', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await tester.runAsync(() async {
        await store.createDeck('Alpha');
        await store.createDeck('Beta');
      });
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsDeckListPage(),
      );
      Future<List<String>> names() async => (await tester.runAsync(
        store.deckSummaries,
      ))!.map((SrsDeckSummary d) => d.fullName).toList();
      final Finder zone = find.byKey(
        const ValueKey<String>('srs-drop-top-level'),
      );

      // 拖着顶层牌组：没有「移到顶层」落点。
      TestGesture g = await tester.startGesture(
        tester.getCenter(find.text('Beta')),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(0, 24));
      await tester.pump();
      expect(zone, findsNothing);
      await g.moveTo(tester.getCenter(find.text('Alpha')));
      await tester.pump();
      await g.up();
      await _settle(tester);
      expect(await names(), contains('Alpha::Beta'));

      // 拖着子牌组：顶上出现落点，放下 = 回到顶层。
      g = await tester.startGesture(
        tester.getCenter(find.text('Beta')),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(0, 24));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(zone, findsOneWidget);
      await g.moveTo(tester.getCenter(zone));
      await tester.pump();
      await g.up();
      await _settle(tester);
      final List<String> after = await names();
      expect(after, contains('Beta'));
      expect(after, isNot(contains('Alpha::Beta')));
      expect(zone, findsNothing);
      expect(after.indexOf('Alpha'), lessThan(after.indexOf('Beta')));

      // 拖到 Alpha 行的上缘 = 同级排到 Alpha 前面（不是挪成子牌组）。
      final String alphaId = (await tester.runAsync(
        store.deckSummaries,
      ))!.firstWhere((SrsDeckSummary d) => d.fullName == 'Alpha').deck.id;
      final Rect alphaRow = tester.getRect(
        find.byKey(ValueKey<String>('srs-drag-$alphaId')),
      );
      g = await tester.startGesture(
        tester.getCenter(find.text('Beta')),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(0, -24));
      await tester.pump();
      await g.moveTo(Offset(alphaRow.center.dx, alphaRow.top + 3));
      await tester.pump();
      await g.up();
      await _settle(tester);
      final List<String> reordered = await names();
      expect(reordered, isNot(contains('Alpha::Beta')));
      expect(reordered.indexOf('Beta'), lessThan(reordered.indexOf('Alpha')));
      await _unmount(tester);
    });

    testWidgets('[$ds] 牌组列表「导入」：一个入口列出 Anki 迁移 / 文件 / 制卡历史三种来源', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsDeckListPage(),
      );
      // 旧的分散入口不再出现在顶栏 / ⋯ 里。
      expect(
        find.byKey(const ValueKey<String>('srs_anki_migrate')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('srs_history_import')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey<String>('srs_import')).first);
      await _settle(tester);
      expect(find.text(t.srs_anki_migrate), findsOneWidget);
      expect(find.text(t.srs_import_file), findsOneWidget);
      expect(find.text(t.srs_history_import), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      await _unmount(tester);
    });

    testWidgets('[$ds] 牌组列表宽屏：三列计数与行尾「⋯」，行首不放图标', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await tester.runAsync(
        () => store.ensureDeckPath('Spark::JP-Mining-Note::Vocabulary'),
      );
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: const SrsDeckListPage(),
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w.runtimeType.toString().startsWith('FushiPopupMenuButton'),
        ),
        findsNWidgets(3),
        reason: '宽屏每行保留行尾「⋯」（空着又没有子牌组的 Default 不显示，见 srsVisibleDecks）',
      );
      expect(find.byType(FushiListLeadingIcon), findsNothing);
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

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(SrsDeckListPage)),
      );
      final int revisionBefore = container.read(srsRevisionProvider);
      await tester.tap(toggle);
      await _settle(tester, rounds: _kTreeSettleRounds);
      expect(childHeight(), 0, reason: '收起后后代消失');
      expect(
        await tester.runAsync(
          () async => (await store.deckTree())[parent]!.collapsed,
        ),
        isTrue,
        reason: '折叠写进牌组本身',
      );
      expect(
        container.read(srsRevisionProvider),
        revisionBefore,
        reason: '收起 / 展开只是界面状态，不触发牌组计数 / 角标重读',
      );

      // 之后别处（同步来的对端改动）把它改成展开、列表重读：以重读的数据为准，本地覆盖
      // 不能把它一直钉在「收起」。
      await tester.runAsync(() => store.setDeckCollapsed(parent, false));
      container.read(srsRevisionProvider.notifier).state++;
      await _settle(tester);
      expect(childHeight(), greaterThan(0), reason: '重读的数据晚于本地写入：撤掉覆盖');
      await tester.runAsync(() => store.setDeckCollapsed(parent, true));
      container.read(srsRevisionProvider.notifier).state++;
      await _settle(tester, rounds: _kTreeSettleRounds);
      expect(childHeight(), 0);

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
      await _settle(tester, rounds: _kTreeSettleRounds);
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

      // 整个行首（缩进 + 箭头 + 牌组图标）都是展开 / 收起的命中区：点图标只收起子牌组，
      // 不会打开复习（用户 2026-10-16：只有箭头能折叠时太容易误触开始复习）。
      final Finder leading = find.byKey(
        ValueKey<String>('srs-deck-leading-toggle-$parent'),
      );
      expect(leading, findsOneWidget);
      final Rect leadingRect = tester.getRect(leading);
      await tester.tapAt(Offset(leadingRect.right - 4, leadingRect.center.dy));
      await _settle(tester, rounds: _kTreeSettleRounds);
      expect(childHeight(), 0, reason: '点行首图标收起后代');
      expect(find.byType(SrsReviewPage), findsNothing, reason: '没有进入复习');
      // 行首左侧留白（缩进左边、贴着行边）同样算折叠区。
      await tester.tapAt(Offset(leadingRect.left + 1, leadingRect.center.dy));
      await _settle(tester);
      expect(childHeight(), greaterThan(0), reason: '点行首左缘重新展开');
      expect(find.byType(SrsReviewPage), findsNothing, reason: '没有进入复习');
      await _unmount(tester);
    });

    testWidgets('[$ds] 复习页 ⋯：卡面样式入口按笔记类型分流（Fushi 卡片 → 外观页；其它 → 模板编辑器）', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _addLapis(tester, store, '食べる');
      await tester.runAsync(
        () => store.createNote(
          noteTypeId: store.fushiCardNoteTypeId,
          fieldsById: <String, String>{
            srsFushiCardFieldId(_kProfile, 'Expression'): '飲む',
          },
        ),
      );
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'Default'),
      );
      final String lapisLabel = t.srs_card_edit_template(name: 'Lapis');
      // 菜单项在 MD3 可能平铺、可能收进 ⋯；Apple 平铺为图标按钮（文字进 tooltip）。
      Future<bool> hasItem(String label, {String? itemKey}) async {
        final String key =
            itemKey ??
            (label == t.srs_card_appearance_title
                ? 'srs_review_appearance'
                : 'srs_review_edit_template');
        if (find.text(label).evaluate().isNotEmpty ||
            find.byKey(ValueKey<String>(key)).evaluate().isNotEmpty) {
          return true;
        }
        final Finder more = find.byKey(
          const ValueKey<String>('fushi_floating_toolbar_overflow'),
        );
        if (more.evaluate().isEmpty) return false;
        await tester.tap(more.first);
        await _settle(tester);
        final bool found = find.text(label).evaluate().isNotEmpty;
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _settle(tester);
        return found;
      }

      final bool firstIsLapis = find
          .textContaining('食べる')
          .evaluate()
          .isNotEmpty;
      final String expected = firstIsLapis
          ? lapisLabel
          : t.srs_card_appearance_title;
      final String unexpected = firstIsLapis
          ? t.srs_card_appearance_title
          : lapisLabel;
      expect(await hasItem(expected), isTrue);
      expect(await hasItem(unexpected), isFalse);
      // 顶栏只剩一个卡面样式入口：「卡面跟随设计系统」「只留重来 / 良好」两个显示开关
      // 收进了「复习选项」面板，不再各占一颗（以前与模板入口同用调色板图标、并排两颗）。
      expect(
        await hasItem(
          t.srs_card_appearance_design_skin,
          itemKey: 'srs_review_design_skin',
        ),
        isFalse,
      );
      expect(
        await hasItem(
          t.srs_review_hide_hard_easy,
          itemKey: 'srs_review_hide_hard_easy',
        ),
        isFalse,
      );
      // 模板编辑器入口用代码图标，不与卡面外观的调色板图标撞成一样。
      final Finder tpl = find.byKey(
        const ValueKey<String>('srs_review_edit_template'),
      );
      if (tpl.evaluate().isNotEmpty) {
        expect(
          find.descendant(
            of: tpl.first,
            matching: find.byIcon(FushiIcons.appearance),
          ),
          findsNothing,
        );
      }
      await _unmount(tester);
    });

    testWidgets('[$ds] 复习页：显示答案 → 评分预览 → 评分', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _useFsrs7(tester, store);
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

    testWidgets('[$ds] 复习页 ⋯「隐藏困难和简单」：评分栏只剩重来 / 良好，按 2 仍评困难', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final List<String> noteIds = <String>[
        await _addLapis(tester, store, '食べる'),
        await _addLapis(tester, store, '飲む'),
      ];
      final _HideHardEasyApp app = _HideHardEasyApp();
      await _pumpPage(
        tester,
        store: store,
        apple: apple,
        app: app,
        page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'Default'),
      );
      Finder rate(int r) => find.byKey(ValueKey<String>('srs-rate-$r'));

      await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
      await _settle(tester);
      for (int r = 1; r <= 4; r++) {
        expect(rate(r), findsOneWidget, reason: '默认四个按钮：$r');
      }

      // 开关在「复习选项」面板里；面板入口在 MD3 可能平铺、可能收进 ⋯，Apple 平铺为图标按钮。
      Future<void> toggle() async {
        final Finder flat = find.byKey(
          const ValueKey<String>('srs_review_layout'),
        );
        if (flat.evaluate().isNotEmpty) {
          await tester.tap(flat.first);
        } else {
          await tester.tap(
            find
                .byKey(
                  const ValueKey<String>('fushi_floating_toolbar_overflow'),
                )
                .first,
          );
          await _settle(tester);
          await tester.tap(find.text(t.srs_review_layout_title).last);
        }
        await _settle(tester);
        // 设置行整行可点（两套设计系统的开关控件不同，点行最稳）。
        await tester.tap(
          find.byKey(
            const ValueKey<String>('srs-review-layout-hide-hard-easy'),
          ),
        );
        await _settle(tester);
        Navigator.of(tester.element(find.byType(SrsReviewLayoutSheet))).pop();
        await _settle(tester);
      }

      await toggle();
      expect(app.hidden, isTrue);
      expect(rate(1), findsOneWidget);
      expect(rate(2), findsNothing);
      expect(rate(3), findsOneWidget);
      expect(rate(4), findsNothing);
      // 两颗均分整行（对齐 AnkiDroid：不留空位）。
      final double w1 = tester.getSize(rate(1)).width;
      final double w3 = tester.getSize(rate(3)).width;
      expect(w1, moreOrLessEquals(w3, epsilon: 0.5));
      expect(
        w1 + w3,
        greaterThan(tester.getSize(find.byType(SrsReviewPage)).width * 0.6),
      );

      // 再点一次关掉：四个按钮回来；再打开。
      await toggle();
      expect(app.hidden, isFalse);
      for (int r = 1; r <= 4; r++) {
        expect(rate(r), findsOneWidget, reason: '关掉后四个按钮：$r');
      }
      await toggle();
      expect(app.hidden, isTrue);

      await tester.tap(rate(3));
      await _settle(tester);
      // 第二张卡：按钮隐藏了，键盘 2 照样评「困难」。
      await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
      await _settle(tester);
      expect(rate(2), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await _settle(tester);

      final List<int?> ratings = (await tester.runAsync(() async {
        final List<int?> out = <int?>[];
        for (final String noteId in noteIds) {
          for (final SrsCardCacheRow c in await store.cardsOfNote(noteId)) {
            final SrsCardHistory h = await store.history(c.id);
            out.addAll(h.all.map((SrsReviewLog l) => l.rating));
          }
        }
        return out;
      }))!;
      expect(ratings..sort((int? a, int? b) => a!.compareTo(b!)), <int>[2, 3]);

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
    Future<String> addWithAudio(
      WidgetTester tester,
      SrsDbStore store, {
      String? deckId,
    }) async => (await tester.runAsync(
      () => store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        deckId: deckId,
        fieldsById: <String, String>{
          srsLapisFieldId(_kProfile, 'Expression'): '食べる',
          srsLapisFieldId(_kProfile, 'MainDefinition'): 'to eat',
          srsLapisFieldId(_kProfile, 'ExpressionAudio'): '[sound:word.mp3]',
          srsLapisFieldId(_kProfile, 'SentenceAudio'): '[sound:sent.mp3]',
        },
      ),
    ))!;

    testWidgets('按牌组：没设过 = 自动播（同 Anki）；关掉的牌组及继承它的子牌组不播；重播都能用', (
      WidgetTester tester,
    ) async {
      for (final String mode in <String>['default', 'off', 'inherited-off']) {
        final SrsDbStore store = await _openStore(tester);
        String deckId = store.defaultDeckId;
        if (mode == 'off') {
          await tester.runAsync(
            () => store.editFields(
              SrsEntityKind.deck,
              deckId,
              <String, Object?>{SrsFieldKeys.deckAutoplay: false},
            ),
          );
        } else if (mode == 'inherited-off') {
          deckId = (await tester.runAsync(() async {
            final String parent = await store.createDeck('Parent');
            await store.editFields(
              SrsEntityKind.deck,
              parent,
              <String, Object?>{SrsFieldKeys.deckAutoplay: false},
            );
            return store.createDeck('Kid', parentId: parent);
          }))!;
        }
        await addWithAudio(tester, store, deckId: deckId);
        final _RecordingAudio audio = _RecordingAudio();
        await _pumpPage(
          tester,
          store: store,
          apple: false,
          page: SrsReviewPage(deckId: deckId, deckName: 'D'),
          overrides: <Override>[
            srsCardAudioOutputProvider.overrideWithValue(audio),
          ],
        );
        expect(audio.played, isEmpty, reason: 'Lapis 问题面没有音频');
        await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
        await _settle(tester);
        expect(
          audio.played,
          mode == 'default' ? <String>['word.mp3', 'sent.mp3'] : isEmpty,
          reason: mode,
        );
        // 「重播音频」：答案面上不管开关都能手动播。
        audio.played.clear();
        await tester.tap(
          find.byKey(const ValueKey<String>('srs_review_replay_audio')).first,
        );
        await _settle(tester);
        expect(audio.played, <String>['word.mp3', 'sent.mp3'], reason: mode);
        await _unmount(tester);
      }
    });

    testWidgets('复习布局：底部重播键放拇指那端、R 键重播、间隔副标签可关，⋯ 面板改了即生效', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _useFsrs7(tester, store);
      await addWithAudio(tester, store);
      final _RecordingAudio audio = _RecordingAudio();
      final _LayoutApp app = _LayoutApp();
      await _pumpPage(
        tester,
        store: store,
        apple: false,
        app: app,
        size: const Size(390, 844),
        page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'D'),
        overrides: <Override>[
          srsCardAudioOutputProvider.overrideWithValue(audio),
        ],
      );
      final Finder replay = find.byKey(
        const ValueKey<String>('srs-bottom-replay-0'),
      );
      final Finder replaySentence = find.byKey(
        const ValueKey<String>('srs-bottom-replay-1'),
      );
      // 每段音频一个键（单词 + 例句两颗），翻面前后同一位置：「显示答案」行右端就有。
      expect(replay, findsOneWidget);
      expect(replaySentence, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('srs-bottom-replay-2')),
        findsNothing,
      );
      expect(
        tester.getCenter(replay).dx,
        greaterThan(
          tester
              .getCenter(find.byKey(const ValueKey<String>('srs-show-answer')))
              .dx,
        ),
      );
      // 窄屏放不下对称空位：「显示答案」不被两颗重播键挤到最小宽度以下。
      expect(
        tester
            .getSize(find.byKey(const ValueKey<String>('srs-show-answer')))
            .width,
        greaterThanOrEqualTo(219.5),
      );
      await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
      await _settle(tester);
      // #17：重播键单独一行、在评分按钮上方（不再与评分按钮并排同高），靠选定的右端。
      expect(
        tester.getRect(replaySentence).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey<String>('srs-rate-4'))).top,
        ),
      );
      expect(
        tester.getRect(replaySentence).right,
        moreOrLessEquals(
          tester
              .getRect(find.byKey(const ValueKey<String>('srs-rate-4')))
              .right,
          epsilon: 0.5,
        ),
      );
      // 评分按钮：间隔 + 评价词两行；整颗不高过 64（M3E 中号按钮）。关掉间隔后只剩评价词。
      int rateTexts() => find
          .descendant(
            of: find.byKey(const ValueKey<String>('srs-rate-3')),
            matching: find.byType(Text),
          )
          .evaluate()
          .length;
      expect(rateTexts(), 2, reason: '间隔 + 评价词');
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('srs-rate-3'))).height,
        lessThanOrEqualTo(64),
      );

      // 各键只播自己那一段（只想听例句就只点例句那颗）。
      audio.played.clear();
      await tester.tap(replay);
      await _settle(tester);
      expect(audio.played, <String>['word.mp3']);
      audio.played.clear();
      await tester.tap(replaySentence);
      await _settle(tester);
      expect(audio.played, <String>['sent.mp3']);

      audio.played.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await _settle(tester);
      expect(audio.played, <String>['word.mp3', 'sent.mp3'], reason: 'R 重播');

      // ⋯「复习布局」：间隔关掉、重播键挪到左边，复习页立即跟着变。
      Future<void> openLayout() async {
        final Finder flat = find.byKey(
          const ValueKey<String>('srs_review_layout'),
        );
        if (flat.evaluate().isNotEmpty) {
          await tester.tap(flat.first);
        } else {
          await tester.tap(
            find
                .byKey(
                  const ValueKey<String>('fushi_floating_toolbar_overflow'),
                )
                .first,
          );
          await _settle(tester);
          await tester.tap(find.text(t.srs_review_layout_title).last);
        }
        await _settle(tester);
      }

      // 页头剩余卡数（对齐 Anki「显示剩余卡片数量」）：默认显示。
      Finder countsText() => find.byWidgetPredicate(
        (Widget w) =>
            w is Text && (w.data ?? '').startsWith('${t.srs_count_new} '),
      );
      expect(countsText(), findsWidgets, reason: '默认显示剩余卡数');

      await openLayout();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey<String>('srs-review-layout-intervals')),
          matching: find.byType(Switch),
        ),
      );
      await _settle(tester);
      expect(app.intervals, isFalse);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey<String>('srs-review-layout-counts')),
          matching: find.byType(Switch),
        ),
      );
      await _settle(tester);
      expect(app.counts, isFalse);
      // 音量滑杆：往左拖到底 = 静音，写穿偏好。
      final Finder volume = find.descendant(
        of: find.byKey(const ValueKey<String>('srs-review-layout-volume')),
        matching: find.byType(Slider),
      );
      expect(volume, findsOneWidget);
      await tester.drag(volume, const Offset(-2000, 0));
      await _settle(tester);
      expect(app.volume, 0.0);
      // 行宽放不下分段时设置行降级成菜单（设计系统行为）：先点开再选。
      final Finder left = find.text(t.srs_review_layout_replay_start);
      if (left.evaluate().isEmpty) {
        await tester.tap(
          find.byKey(const ValueKey<String>('srs-review-layout-replay')),
        );
        await _settle(tester);
      }
      await tester.tap(left.last);
      await _settle(tester);
      expect(app.replay, SrsReviewReplayButton.start);
      await tester.tapAt(const Offset(195, 40));
      await _settle(tester);
      expect(rateTexts(), 1, reason: '间隔关掉后只剩评价词');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('srs-rate-3')),
          matching: find.textContaining(RegExp(r'\d')),
        ),
        findsNothing,
        reason: '间隔关掉后评分按钮上不再有任何时间文字',
      );
      expect(countsText(), findsNothing, reason: '剩余卡数关掉后页头不显示');
      expect(
        tester.getCenter(replay).dx,
        lessThan(
          tester.getCenter(find.byKey(const ValueKey<String>('srs-rate-1'))).dx,
        ),
      );
      await _unmount(tester);
    });

    testWidgets('复习布局：一行放不下逐段重播键时退回一颗整面重播键，不把底栏挤窄', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      // 六段音频：340 宽的一行放不下六颗逐段键。
      await tester.runAsync(
        () => store.createNote(
          noteTypeId: store.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId(_kProfile, 'Expression'): '食べる',
            srsLapisFieldId(_kProfile, 'MainDefinition'): 'to eat',
            srsLapisFieldId(_kProfile, 'ExpressionAudio'):
                '[sound:w1.mp3][sound:w2.mp3][sound:w3.mp3]',
            srsLapisFieldId(_kProfile, 'SentenceAudio'):
                '[sound:s1.mp3][sound:s2.mp3][sound:s3.mp3]',
          },
        ),
      );
      final _RecordingAudio audio = _RecordingAudio();
      await _pumpPage(
        tester,
        store: store,
        apple: false,
        app: _LayoutApp(),
        size: const Size(340, 700),
        page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'D'),
        overrides: <Override>[
          srsCardAudioOutputProvider.overrideWithValue(audio),
        ],
      );
      final Finder replay = find.byKey(
        const ValueKey<String>('srs-bottom-replay-0'),
      );
      expect(replay, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('srs-bottom-replay-1')),
        findsNothing,
        reason: '六段音频在 340 宽的一行里放不下逐段键',
      );
      await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
      await _settle(tester);
      // 四颗评分键都保有 ≥ 48dp 命中区。
      for (int r = 1; r <= 4; r++) {
        final Finder rate = find.byKey(ValueKey<String>('srs-rate-$r'));
        if (rate.evaluate().isEmpty) continue;
        expect(tester.getSize(rate).width, greaterThanOrEqualTo(48));
      }
      // 单颗键是整面重播（同 R）。
      audio.played.clear();
      await tester.tap(replay);
      await _settle(tester);
      expect(audio.played, <String>[
        'w1.mp3',
        'w2.mp3',
        'w3.mp3',
        's1.mp3',
        's2.mp3',
        's3.mp3',
      ]);
      await _unmount(tester);
    });

    testWidgets('复习布局（Apple）：底部重播键单独一行在底栏按钮上方、靠选定那端、点了重播', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await addWithAudio(tester, store);
      final _RecordingAudio audio = _RecordingAudio();
      final _LayoutApp app = _LayoutApp()..replay = SrsReviewReplayButton.start;
      await _pumpPage(
        tester,
        store: store,
        apple: true,
        app: app,
        size: const Size(1024, 768),
        page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'D'),
        overrides: <Override>[
          srsCardAudioOutputProvider.overrideWithValue(audio),
        ],
      );
      final Finder replay = find.byKey(
        const ValueKey<String>('srs-bottom-replay-0'),
      );
      expect(replay, findsOneWidget);
      final Finder showAnswer = find.byKey(
        const ValueKey<String>('srs-show-answer'),
      );
      expect(
        tester.getCenter(replay).dx,
        lessThan(tester.getCenter(showAnswer).dx),
      );
      // 放得下对称空位时，重播键放哪端都不把「显示答案」推离屏幕中线。
      expect(
        tester.getCenter(showAnswer).dx,
        moreOrLessEquals(512, epsilon: 0.5),
      );
      expect(tester.getSize(replay).height, greaterThanOrEqualTo(48));
      // #17：重播键单独一行，在「显示答案」上方，与它不同行。
      expect(
        tester.getRect(replay).bottom,
        lessThanOrEqualTo(tester.getRect(showAnswer).top),
      );
      await tester.tap(showAnswer);
      await _settle(tester);
      final Rect rate = tester.getRect(
        find.byKey(const ValueKey<String>('srs-rate-1')),
      );
      // 在评分按钮上方、与第一颗评分按钮左对齐（选的是左端）。
      expect(tester.getRect(replay).bottom, lessThanOrEqualTo(rate.top));
      expect(
        tester.getRect(replay).left,
        moreOrLessEquals(rate.left, epsilon: 0.5),
      );
      audio.played.clear();
      await tester.tap(replay);
      await _settle(tester);
      expect(audio.played, <String>['word.mp3']);
      await _unmount(tester);
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

    testWidgets('牌组设置页：两个音频开关写进牌组；继承参数的子牌组只显示「继承自」', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final String kid = (await tester.runAsync(
        () => store.createDeck('Kid', parentId: store.defaultDeckId),
      ))!;
      await _pumpPage(
        tester,
        store: store,
        apple: false,
        page: SrsDeckSettingsPage(deckId: store.defaultDeckId),
      );
      final Finder autoplay = find.byKey(
        const ValueKey<String>('srs-settings-autoplay-audio'),
      );
      final Finder replay = find.byKey(
        const ValueKey<String>('srs-settings-replay-question-audio'),
      );
      expect(autoplay, findsOneWidget);
      expect(replay, findsOneWidget);
      await tester.ensureVisible(autoplay);
      await tester.tap(autoplay);
      await tester.pump();
      await tester.ensureVisible(replay);
      await tester.tap(replay);
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_settings_save')).first,
      );
      await _settle(tester);
      final SrsDeckTree tree = (await tester.runAsync(store.deckTree))!;
      expect(tree[store.defaultDeckId]!.autoplayAudio, isFalse);
      expect(tree[store.defaultDeckId]!.replayQuestionAudio, isFalse);
      expect(tree.paramsOwner(kid).autoplayAudio, isFalse, reason: '子牌组随继承');
      await _unmount(tester);

      await _pumpPage(
        tester,
        store: store,
        apple: false,
        page: SrsDeckSettingsPage(deckId: kid),
      );
      expect(autoplay, findsNothing);
      await _unmount(tester);
    });

    testWidgets('牌组设置页：新卡顺序缺省按词频，改成按位置写进牌组；继承参数的子牌组不显示选择', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final String kid = (await tester.runAsync(
        () => store.createDeck('Kid', parentId: store.defaultDeckId),
      ))!;
      expect(
        (await tester.runAsync(
          store.deckTree,
        ))![store.defaultDeckId]!.newCardOrder,
        SrsNewCardOrder.frequency,
        reason: '缺省 = 按词频',
      );
      await _pumpPage(
        tester,
        store: store,
        apple: false,
        page: SrsDeckSettingsPage(deckId: store.defaultDeckId),
      );
      final Finder order = find.byKey(
        const ValueKey<String>('srs-settings-new-order'),
      );
      await tester.scrollUntilVisible(
        order,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      // 顶栏浮在列表上：居中，免得滚到顶被顶栏盖住。
      await Scrollable.ensureVisible(tester.element(order), alignment: 0.5);
      await tester.pumpAndSettle();
      final Finder position = find.descendant(
        of: order,
        matching: find.text(t.srs_settings_new_order_position),
      );
      if (position.evaluate().isEmpty) {
        // 行宽放不下分段时设置行降级成菜单（设计系统行为）：先点开再选。
        await tester.tap(
          find.descendant(
            of: order,
            matching: find.text(t.srs_settings_new_order),
          ),
        );
        await _settle(tester);
      }
      await tester.tap(find.text(t.srs_settings_new_order_position).last);
      await _settle(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_settings_save')).first,
      );
      await _settle(tester);
      final SrsDeckTree tree = (await tester.runAsync(store.deckTree))!;
      expect(tree[store.defaultDeckId]!.newCardOrder, SrsNewCardOrder.position);
      expect(
        tree.paramsOwner(kid).newCardOrder,
        SrsNewCardOrder.position,
        reason: '子牌组随继承',
      );
      await _unmount(tester);

      await _pumpPage(
        tester,
        store: store,
        apple: false,
        page: SrsDeckSettingsPage(deckId: kid),
      );
      expect(order, findsNothing);
      await _unmount(tester);
    });

    testWidgets('牌组设置页：「让子牌组都继承这里」把整棵子树里单独设置的后代改成继承', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final (String kid, String grandKid, String plain) = (await tester
          .runAsync(() async {
            final String kid = await store.createDeck(
              'Kid',
              parentId: store.defaultDeckId,
            );
            final String grandKid = await store.createDeck(
              'GrandKid',
              parentId: kid,
            );
            final String plain = await store.createDeck(
              'Plain',
              parentId: store.defaultDeckId,
            );
            for (final String id in <String>[kid, grandKid]) {
              await store.editField(
                SrsEntityKind.deck,
                id,
                SrsFieldKeys.deckParamsMode,
                'own',
              );
            }
            return (kid, grandKid, plain);
          }))!;
      await _pumpPage(
        tester,
        store: store,
        apple: false,
        page: SrsDeckSettingsPage(deckId: store.defaultDeckId),
      );
      final Finder button = find.byKey(
        const ValueKey<String>('srs-settings-children-inherit'),
      );
      expect(button, findsOneWidget);
      expect(find.text(t.srs_settings_children_inherit(n: 2)), findsOneWidget);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await _settle(tester);
      final String label = t.srs_settings_children_inherit(n: 2);
      await tester.tap(
        find.byWidgetPredicate(
          (Widget w) => w is FushiDialogAction && w.label == label,
        ),
      );
      await _settle(tester);
      final SrsDeckTree tree = (await tester.runAsync(store.deckTree))!;
      for (final String id in <String>[kid, grandKid, plain]) {
        expect(tree[id]!.ownParams, isFalse);
        expect(tree.paramsOwner(id).id, store.defaultDeckId);
      }
      expect(button, findsNothing, reason: '没有单独设置的后代了，按钮收起');
      await _unmount(tester);
    });

    testWidgets('牌组设置页：RWKV 排队设置（每天最少复习数 / 同日重复间隔）写进牌组，子牌组随继承', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final String kid = (await tester.runAsync(
        () => store.createDeck('Kid', parentId: store.defaultDeckId),
      ))!;
      await _pumpPage(
        tester,
        store: store,
        apple: false,
        page: SrsDeckSettingsPage(deckId: store.defaultDeckId),
      );
      Future<void> enter(String key, String value) async {
        final Finder field = find.byKey(ValueKey<String>(key));
        await tester.ensureVisible(field);
        await tester.enterText(
          find.descendant(of: field, matching: find.byType(EditableText)),
          value,
        );
        await tester.pump();
      }

      // 默认算法是 RWKV：排队设置显示上游默认值。
      expect(
        find.byKey(const ValueKey<String>('srs-settings-rwkv-queue')),
        findsOneWidget,
      );
      await enter('srs-settings-rwkv-min-reviews', '7');
      await enter('srs-settings-rwkv-repeat-reviews', '2');
      await enter('srs-settings-rwkv-repeat-seconds', '15');
      await tester.tap(
        find.byKey(const ValueKey<String>('srs_settings_save')).first,
      );
      await _settle(tester);
      final SrsDeckTree tree = (await tester.runAsync(store.deckTree))!;
      const SrsRwkvQueueSettings want = SrsRwkvQueueSettings(
        minReviewsPerDay: 7,
        repeatMinReviews: 2,
        repeatMinSeconds: 15,
      );
      expect(tree[store.defaultDeckId]!.rwkvQueue, want);
      expect(tree.paramsOwner(kid).rwkvQueue, want, reason: '子牌组随继承');
      await _unmount(tester);
    });

    testWidgets('牌组设置页：同一次编辑里切换算法，步长显示与「是否改动」按新算法重算，保存后的生效值与显示一致', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      final String id = store.defaultDeckId;
      // 默认牌组是 RWKV、没写过步长：生效的是「不用步长」。
      SrsDeckTree tree = (await tester.runAsync(store.deckTree))!;
      expect(tree[id]!.localAlgorithm, SrsAlgorithm.rwkv);
      expect(tree[id]!.learnStepsSet, isFalse);
      await _pumpPage(
        tester,
        store: store,
        apple: false,
        page: SrsDeckSettingsPage(deckId: id),
      );
      String stepsText(String key) => tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(ValueKey<String>(key)),
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text;
      Future<void> reveal(String key) async {
        final Finder f = find.byKey(ValueKey<String>(key));
        await tester.scrollUntilVisible(
          f,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(tester.element(f), alignment: 0.5);
        await tester.pumpAndSettle();
      }

      Future<void> pickAlgorithm(String label) async {
        await reveal('srs-settings-algorithm');
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey<String>('srs-settings-algorithm')),
            matching: find.text(label),
          ),
        );
        await _settle(tester);
      }

      // 保存后重开设置页（测试里设置页是根页面，保存的 maybePop 不会退出）。
      Future<void> save() async {
        await tester.tap(
          find.byKey(const ValueKey<String>('srs_settings_save')).first,
        );
        await _settle(tester);
        await _unmount(tester);
        await _pumpPage(
          tester,
          store: store,
          apple: false,
          page: SrsDeckSettingsPage(deckId: id),
        );
      }

      await reveal('srs-settings-learn-steps');
      expect(stepsText('srs-settings-learn-steps'), '');
      expect(stepsText('srs-settings-relearn-steps'), '');
      // 切到 FSRS-7：没改过的步长输入换成 FSRS 下的生效值（默认 1 10 / 10）。
      await pickAlgorithm('FSRS-7');
      expect(stepsText('srs-settings-learn-steps'), '1 10');
      expect(stepsText('srs-settings-relearn-steps'), '10');
      await save();
      tree = (await tester.runAsync(store.deckTree))!;
      expect(tree[id]!.localAlgorithm, SrsAlgorithm.fsrs7);
      expect(tree[id]!.learnStepsSet, isFalse, reason: '显示的就是 FSRS 下的生效值：不写步长');
      SrsSchedulingConfig c = tree.schedulingConfig(id);
      expect(c.learnStepsMinutes, <double>[1, 10]);
      expect(c.relearnStepsMinutes, <double>[10]);

      // 反过来：FSRS → RWKV，显示跟着变成「不用步长」，保存后生效值也是空。
      await pickAlgorithm(t.srs_settings_algorithm_rwkv_recommended);
      await reveal('srs-settings-learn-steps');
      expect(stepsText('srs-settings-learn-steps'), '');
      expect(stepsText('srs-settings-relearn-steps'), '');
      await save();
      tree = (await tester.runAsync(store.deckTree))!;
      c = tree.schedulingConfig(id);
      expect(tree[id]!.localAlgorithm, SrsAlgorithm.rwkv);
      expect(c.learnStepsMinutes, isEmpty);
      expect(c.relearnStepsMinutes, isEmpty);

      // 用户先改了步长再切算法：输入保留，保存时按切换后的算法与生效值比，写进牌组。
      await reveal('srs-settings-learn-steps');
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey<String>('srs-settings-learn-steps')),
          matching: find.byType(EditableText),
        ),
        '5',
      );
      await tester.pump();
      await pickAlgorithm('FSRS-7');
      await reveal('srs-settings-learn-steps');
      expect(stepsText('srs-settings-learn-steps'), '5');
      expect(
        stepsText('srs-settings-relearn-steps'),
        '10',
        reason: '重学步长没改过：换成 FSRS 下的生效值',
      );
      await save();
      tree = (await tester.runAsync(store.deckTree))!;
      c = tree.schedulingConfig(id);
      expect(c.learnStepsMinutes, <double>[5]);
      expect(c.relearnStepsMinutes, <double>[10]);
      await _unmount(tester);
    });

    testWidgets('牌组设置页：新卡计划（按复习量调整的预算与多出比例 / 关掉调整）写进牌组', (
      WidgetTester tester,
    ) async {
      final SrsDbStore store = await _openStore(tester);
      await _pumpPage(
        tester,
        store: store,
        apple: false,
        page: SrsDeckSettingsPage(deckId: store.defaultDeckId),
      );
      // 设置页是懒构建的列表：新卡计划在基础设置末尾，先滚到它。
      Future<Finder> reveal(String key) async {
        final Finder field = find.byKey(ValueKey<String>(key));
        await tester.scrollUntilVisible(
          field,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        // 顶栏浮在列表上：居中，免得滚到顶被顶栏盖住。
        await Scrollable.ensureVisible(tester.element(field), alignment: 0.5);
        await tester.pumpAndSettle();
        return field;
      }

      Future<void> enter(String key, String value) async {
        final Finder field = await reveal(key);
        await tester.enterText(
          find.descendant(of: field, matching: find.byType(EditableText)),
          value,
        );
        await tester.pump();
      }

      Future<void> save() async {
        await tester.tap(
          find.byKey(const ValueKey<String>('srs_settings_save')).first,
        );
        await _settle(tester);
      }

      await enter('srs-settings-new-load-budget', '120');
      await enter('srs-settings-new-load-boost', '30');
      await save();
      SrsDeckTree tree = (await tester.runAsync(store.deckTree))!;
      expect(
        tree[store.defaultDeckId]!.newCardPlan,
        const SrsNewCardPlan(budgetPercent: 120, boostPercent: 30),
      );

      // 关掉按复习量调整：预算 / 多出两项收起，保存后只改开关。
      final Finder auto = await reveal('srs-settings-new-load-auto');
      await tester.tap(auto);
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('srs-settings-new-load-budget')),
        findsNothing,
      );
      await save();
      tree = (await tester.runAsync(store.deckTree))!;
      expect(
        tree[store.defaultDeckId]!.newCardPlan,
        const SrsNewCardPlan(
          autoLoad: false,
          budgetPercent: 120,
          boostPercent: 30,
        ),
      );
      await _unmount(tester);
    });
  });

  testWidgets('复习选项「卡面图片大小」：改了即换卡面注入的 CSS；卡面点图回传地址后全屏查看', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    await _addLapis(tester, store, '食べる');
    final _LayoutApp app = _LayoutApp();
    await _pumpPage(
      tester,
      store: store,
      apple: false,
      app: app,
      page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'D'),
      overrides: <Override>[
        srsMediaStoreProvider.overrideWith(
          (Ref ref) async => SrsMediaStore(Directory.systemTemp),
        ),
      ],
    );
    SrsCardFace face() =>
        tester.widget<SrsPlainCardFace>(find.byType(SrsPlainCardFace)).face;
    expect(face().hostCss, isEmpty, reason: '默认原样：不注入图片样式');
    expect(face().onImageTap, isNotNull);

    final Finder flat = find.byKey(const ValueKey<String>('srs_review_layout'));
    if (flat.evaluate().isNotEmpty) {
      await tester.tap(flat.first);
    } else {
      await tester.tap(
        find
            .byKey(const ValueKey<String>('fushi_floating_toolbar_overflow'))
            .first,
      );
      await _settle(tester);
      await tester.tap(find.text(t.srs_review_layout_title).last);
    }
    await _settle(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('srs-review-layout-image-size')),
    );
    await _settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('srs-review-layout-image-size')),
        matching: find.text(t.srs_review_layout_image_large),
      ),
    );
    await _settle(tester);
    expect(app.imageSize, SrsReviewImageSize.large);
    expect(face().hostCss, srsReviewImageSizeCss(SrsReviewImageSize.large));
    expect(face().hostCss, contains('.card img{width:100%!important'));
    Navigator.of(tester.element(find.byType(SrsReviewLayoutSheet))).pop();
    await _settle(tester);

    // 页内点图脚本经 onSrsImageTap 回传的是改写后的媒体地址：换回媒体名、全屏查看。
    expect(find.byType(InteractiveViewer), findsNothing);
    face().onImageTap!('https://srs.local/media/pic%201.png');
    await _settle(tester);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    final Image shown = tester.widget<Image>(
      find.descendant(
        of: find.byType(InteractiveViewer),
        matching: find.byType(Image),
      ),
    );
    expect(
      (shown.image as FileImage).file.path,
      endsWith('${Platform.pathSeparator}pic 1.png'),
    );
    await tester.tap(find.byType(InteractiveViewer));
    await _settle(tester);
    expect(find.byType(InteractiveViewer), findsNothing);

    // 不是卡面媒体的地址（远程图）不弹。
    face().onImageTap!('https://example.com/a.png');
    await _settle(tester);
    expect(find.byType(InteractiveViewer), findsNothing);
    await _unmount(tester);
  });

  testWidgets('排程内核不可用：横幅提示，复习页不给评分', (WidgetTester tester) async {
    final SrsStorage srs = (await tester.runAsync(openSrsTestStorage))!;
    final SrsDbStore store = (await tester.runAsync(
      () => SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: _kProfile,
        deviceId: 'd',
      ),
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

  testWidgets('RWKV 牌组评分按钮不显示进复习队列的天数（RWKV 没就绪也不显示）；学习步照常显示', (
    WidgetTester tester,
  ) async {
    for (final bool ready in <bool>[true, false]) {
      final SrsDbStore store = await _openStore(tester);
      store.rwkv = _FakeRwkv(ready: ready);
      // 这里要验学习步的显示：RWKV 牌组缺省不用步长，写上步长。
      await tester.runAsync(
        () => store.editFields(
          SrsEntityKind.deck,
          store.defaultDeckId,
          <String, Object?>{
            SrsFieldKeys.deckSteps: <String, Object?>{
              'learn': <double>[1, 10],
              'relearn': <double>[10],
            },
          },
        ),
      );
      await _addLapis(tester, store, '食べる');
      await _pumpPage(
        tester,
        store: store,
        apple: false,
        page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'D'),
      );
      await tester.tap(find.byKey(const ValueKey<String>('srs-show-answer')));
      await _settle(tester);
      int texts(int rating) => find
          .descendant(
            of: find.byKey(ValueKey<String>('srs-rate-$rating')),
            matching: find.byType(Text),
          )
          .evaluate()
          .length;
      // 新卡：「重来」进学习步（分钟），「简单」直接毕业进复习队列（天数）。
      expect(texts(1), 2, reason: '学习步按步长计时，ready=$ready');
      // RWKV 没就绪也一样（PR #2711）：RWKV 牌组的复习卡等 RWKV 就绪后按 R 出，不退回按存下的到期日排，
      // 所以 FSRS-7 的天数同样不是它回来的时间。
      expect(texts(4), 1, reason: 'RWKV 排队：天数不是它真正回来的时间，ready=$ready');
      await _unmount(tester);
    }
  });

  group('卡面查词', () {
    setUpAll(installFakeInAppWebViewPlatform);

    testWidgets('复习页：点卡面的字 → 查词弹窗；开着时空格 / 数字键不翻面不评分；'
        'Esc 关掉后焦点回到复习页', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _addLapis(tester, store, '食べる');
      await _pumpPage(
        tester,
        store: store,
        apple: false,
        app: _LookupApp(),
        page: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'Default'),
        overrides: <Override>[
          ...popupMiningTargetTestOverrides(),
          srsCardLookupSearchProvider.overrideWithValue(
            (String term, int max) async => DictionarySearchResult(
              searchTerm: term,
              entries: <DictionaryEntry>[
                DictionaryEntry(word: term, reading: 'たべる', meaning: 'eat'),
              ],
            ),
          ),
        ],
      );
      final Finder question = find.byKey(
        const ValueKey<String>('srs-face-question'),
      );
      expect(question, findsOneWidget);
      final SrsCardLookupController lookup = tester
          .element(question)
          .getInheritedWidgetOfExactType<SrsCardLookupScope>()!
          .controller!;

      // 点「食」→ 查「食べる」（按真实字形盒找到「食」）。
      await tester.pump(const Duration(seconds: 2));
      final RenderParagraph para = tester.renderObject<RenderParagraph>(
        find.descendant(of: question, matching: find.byType(RichText)),
      );
      final int at = para.text
          .toPlainText(includeSemanticsLabels: false)
          .indexOf('食べる');
      expect(at, greaterThanOrEqualTo(0));
      await tester.tapAt(
        para.localToGlobal(
          para
              .getBoxesForSelection(
                TextSelection(baseOffset: at, extentOffset: at + 1),
              )
              .first
              .toRect()
              .center,
        ),
      );
      await _settle(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(lookup.debugQueries, <String>['食べる']);
      expect(lookup.isOpen, isTrue);

      // 弹窗开着：空格不显示答案，数字键不评分。
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await _settle(tester);
      expect(question, findsOneWidget, reason: '弹窗开着时不翻面');
      expect(lookup.isOpen, isTrue);

      // 弹窗里继续查 → 第二层。
      await lookup.pushNested('食', const Rect.fromLTWH(40, 200, 20, 20));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(lookup.debugVisibleDepth, 2);

      // Esc 逐层关；全关后焦点回复习页，空格照常显示答案。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(lookup.debugVisibleDepth, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(lookup.isOpen, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('srs-face-answer')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 2));
      await _unmount(tester);
    });
  });
}

/// RWKV 排程的替身：只决定「现在能不能按 R 排队」。
class _FakeRwkv implements SrsRwkvScheduling {
  _FakeRwkv({required this.ready});

  @override
  final bool ready;

  @override
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int nowMs,
  }) async => ready ? List<double>.filled(cards.length, 0) : null;

  @override
  Future<void> onAnswered(String cardId, SrsReviewLog log) async {}
  @override
  Future<void> onCardsPurged(List<String> cardIds) async {}
}

/// 记下播了哪些音频的假播放出口。[holdOpen] = 每段都「播不完」，直到 stop。
class _RecordingAudio implements SrsCardAudioOutput {
  _RecordingAudio({this.holdOpen = false});

  final bool holdOpen;
  final List<String> played = <String>[];
  final List<Completer<bool>> _open = <Completer<bool>>[];
  int stops = 0;

  /// 路径即文件名：[played] 记的仍是卡面上的音频名。
  @override
  Future<String?> resolve(String name) => Future<String?>.value(name);

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
