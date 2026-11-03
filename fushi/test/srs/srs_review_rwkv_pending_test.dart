// RWKV 没准备好时复习页 / 牌组列表 / 首页的状态（PR #2711 审查）：
//
// 1. 复习页不能永远停在「等 RWKV」：
//    a. 竞态——「就绪」事件在 `_loadNext` 等排队结果时就来了（那时 `_finished` 还是 false，事件被丢掉），
//       之后再也没有就绪事件。pending 落定时要当场看一次服务，已就绪就重排。
//    b. 服务就绪但打分失败——服务转「出错」（`SrsRwkvService._scoringFailed`，engine 测试覆盖），复习页
//       给出错误与「重试」，重试就绪后自动出卡，而不是一页静默的空白。
// 2. 牌组列表 / 首页：RWKV 牌组的到期数在等 RWKV 时显示「准备中」而不是 0；RWKV 就绪后列表自己重读。
//
// 走真实路径：内存库 + 确定性假排程内核 + 真 store 的 RWKV-Instant 排队；只把 RWKV 服务换成可控的替身
// （服务本身的行为在 packages/fushi_engine/test/srs/srs_rwkv_service_test.dart）。

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/home_nav_peek.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

/// 可控的 RWKV 服务替身：阶段由测试拨，事件**同步**发出（复现「事件在排队途中到达」的时序）。
class _FakeRwkvService extends SrsRwkvService {
  _FakeRwkvService({required super.store, required Directory dir})
    : super(
        models: SrsRwkvModels(dir: dir),
        snapshotDir: dir,
      );

  final StreamController<SrsRwkvStatus> _events =
      StreamController<SrsRwkvStatus>.broadcast(sync: true);
  SrsRwkvStatus _now = const SrsRwkvStatus(SrsRwkvPhase.preparing);

  /// 没就绪时被排队调用（store 触发准备）就当场就绪——就绪事件落在复习页还在等这次排队结果的时候。
  bool readyWhenAsked = false;

  /// 就绪时下一次打分失败：与真服务一样转「出错」并返回 null。
  bool failNextScoring = false;
  int scoringCalls = 0;

  void emit(SrsRwkvStatus status) {
    _now = status;
    _events.add(status);
  }

  @override
  SrsRwkvStatus get status => _now;

  @override
  Stream<SrsRwkvStatus> get statusChanges => _events.stream;

  @override
  bool get ready => _now.phase == SrsRwkvPhase.ready;

  @override
  Future<void> start({bool force = false}) async {
    emit(const SrsRwkvStatus(SrsRwkvPhase.ready));
  }

  @override
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int nowMs,
  }) async {
    scoringCalls++;
    if (!ready) {
      if (readyWhenAsked) emit(const SrsRwkvStatus(SrsRwkvPhase.ready));
      return null;
    }
    if (failNextScoring) {
      failNextScoring = false;
      emit(
        SrsRwkvStatus(SrsRwkvPhase.failed, error: StateError('worker exited')),
      );
      return null;
    }
    return List<double>.filled(cards.length, 0.1);
  }

  @override
  Future<void> close() async {
    await _events.close();
    await super.close();
  }
}

Future<void> _settle(WidgetTester tester, {int rounds = 16}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 默认牌组（算法缺省 RWKV）里 [n] 张已毕业的复习卡，时钟拨到第二天（避开同日重复守卫）。
Future<(FushiDatabase, SrsDbStore)> _storeWithReviewCards(int n) async {
  final SrsTestClock clock = SrsTestClock();
  final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore(
    clock: clock,
  );
  expect(
    (await store.schedulingConfigFor(store.defaultDeckId)).algorithm,
    SrsAlgorithm.rwkv,
  );
  for (int i = 0; i < n; i++) {
    final String note = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      createdAt: 1700000000000 + i,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '単語$i',
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): '意味$i',
      },
    );
    await store.answer((await store.cardsOfNote(note)).single.id, 4);
    clock.advance(const Duration(seconds: 1));
  }
  clock.advance(const Duration(days: 1));
  return (db, store);
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<(ProviderContainer, List<String>)> pumpReview(
    WidgetTester tester,
    SrsDbStore store,
    _FakeRwkvService rwkv,
  ) async {
    final List<String> faces = <String>[];
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => AppModel(testPlatformServices())),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsRwkvServiceProvider.overrideWith((Ref ref) async => rwkv),
        srsMediaStoreProvider.overrideWith(
          (Ref ref) async => null as SrsMediaStore?,
        ),
        srsCardFaceBuilderProvider.overrideWithValue((
          BuildContext context,
          SrsCardFace face,
        ) {
          // 卡面占位（还没有卡）的 id 是空串：只记真正上屏的卡。
          if (face.cardId.isNotEmpty) faces.add(face.cardId);
          return SrsPlainCardFace(face: face);
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildFushiThemeData(
              scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              textTheme: Typography.material2021().black,
              designSystem: FushiDesignSystem.material,
              glass: FushiGlassMaterial.off,
              glassDesign: false,
            ),
            builder: (BuildContext context, Widget? child) =>
                FushiGlassScope(child: child!),
            home: SrsReviewPage(
              deckId: store.defaultDeckId,
              deckName: 'Default',
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    return (container, faces);
  }

  testWidgets('就绪事件落在排队途中（被丢掉）：pending 落定时看到服务已就绪，当场重排出卡，不停在「等 RWKV」', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
      () => _storeWithReviewCards(2),
    ))!;
    addTearDown(() => tester.runAsync(db.close));
    final _FakeRwkvService rwkv = _FakeRwkvService(
      store: store,
      dir: Directory.systemTemp.createTempSync('srs_rwkv_page'),
    )..readyWhenAsked = true;
    store.rwkv = rwkv;
    addTearDown(() => tester.runAsync(rwkv.close));

    final (_, List<String> faces) = await pumpReview(tester, store, rwkv);

    expect(rwkv.ready, isTrue);
    expect(
      find.byKey(const ValueKey<String>('srs-review-rwkv-pending')),
      findsNothing,
      reason: '就绪事件已经来过，页面不能再等一个不会来的事件',
    );
    expect(faces, isNotEmpty, reason: 'RWKV 牌组的复习卡按此刻的 R 出了');
    expect(rwkv.scoringCalls, greaterThanOrEqualTo(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('就绪但打分失败：显示错误与「重试」（不是静默空页）；重试就绪后自动出卡', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
      () => _storeWithReviewCards(2),
    ))!;
    addTearDown(() => tester.runAsync(db.close));
    final _FakeRwkvService rwkv =
        _FakeRwkvService(
            store: store,
            dir: Directory.systemTemp.createTempSync('srs_rwkv_page'),
          )
          ..emit(const SrsRwkvStatus(SrsRwkvPhase.ready))
          ..failNextScoring = true;
    store.rwkv = rwkv;
    addTearDown(() => tester.runAsync(rwkv.close));

    final (_, List<String> faces) = await pumpReview(tester, store, rwkv);

    expect(rwkv.status.phase, SrsRwkvPhase.failed);
    expect(
      find.byKey(const ValueKey<String>('srs-review-rwkv-pending')),
      findsOneWidget,
    );
    expect(find.textContaining('worker exited'), findsOneWidget);
    final Finder retry = find.byKey(
      const ValueKey<String>('srs-review-rwkv-retry'),
    );
    expect(retry, findsOneWidget);
    expect(faces, isEmpty);

    await tester.tap(retry);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('srs-review-rwkv-pending')),
      findsNothing,
    );
    expect(faces, isNotEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('牌组列表 / 首页：等 RWKV 时到期一格显示「准备中」而不是 0；RWKV 就绪后列表自己重读成真实计数', (
    WidgetTester tester,
  ) async {
    final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
      () => _storeWithReviewCards(2),
    ))!;
    addTearDown(() => tester.runAsync(db.close));
    final _FakeRwkvService rwkv = _FakeRwkvService(
      store: store,
      dir: Directory.systemTemp.createTempSync('srs_rwkv_list'),
    );
    store.rwkv = rwkv;
    addTearDown(() => tester.runAsync(rwkv.close));
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => AppModel(testPlatformServices())),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        srsRwkvServiceProvider.overrideWith((Ref ref) async => rwkv),
      ],
    );
    addTearDown(container.dispose);
    // 只在 runAsync 里读：provider 的构建要真异步（库 / 内核），在假时钟的 zone 里起步会永远等不到。
    final SrsDeckListData pending = (await tester.runAsync<SrsDeckListData?>(
      () => container.read(srsDeckListProvider.future),
    ))!;
    final SrsDeckSummary root = pending.decks.singleWhere(
      (SrsDeckSummary d) => d.deck.id == store.defaultDeckId,
    );
    expect(root.reviewCount, 0);
    expect(root.rwkvPending, isTrue);
    expect(root.rwkvScheduled, isTrue);
    expect(pending.rwkvPending, isTrue);
    expect(pending.hasWorkToday, isFalse);
    expect(
      pending.firstRootWithWork?.deck.id,
      store.defaultDeckId,
      reason: '「开始复习」进复习页看准备进度，不当成今天已复习完',
    );
    expect(
      srsNavPeekCountsLabel(
        newCount: 0,
        learnCount: 0,
        reviewCount: 0,
        reviewPending: true,
      ),
      contains(t.srs_settings_rwkv_preparing_start),
    );

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          home: Scaffold(
            body: SrsCountTriple(
              newCount: root.newCount,
              learnCount: root.learnCount,
              reviewCount: root.reviewCount,
              reviewPending: root.rwkvPending,
            ),
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('srs-count-review-pending')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(
          '${RegExp.escape(t.srs_count_review)} '
          '\\(${RegExp.escape(t.srs_settings_rwkv_preparing_start)}\\)',
        ),
      ),
      findsOneWidget,
    );

    // RWKV 就绪不是 store 的写入（不推进 srsRevisionProvider）：列表自己等它、重读。
    await tester.runAsync(() => rwkv.start());
    final SrsDeckListData ready = (await tester.runAsync<SrsDeckListData?>(
      () => container.read(srsDeckListProvider.future),
    ))!;
    final SrsDeckSummary after = ready.decks.singleWhere(
      (SrsDeckSummary d) => d.deck.id == store.defaultDeckId,
    );
    expect(after.rwkvPending, isFalse);
    expect(after.reviewCount, 2);
    expect(ready.rwkvPending, isFalse);

    // 就绪后 RWKV 牌组的「到期」是此刻回忆率的快照、不是到期数：第三格不显示数（没有 FSRS 到期时「—」），
    // 也不编一个历史日均出来。
    expect(after.rwkvScheduled, isTrue);
    expect(after.fsrsDue, 0);
    expect(ready.rwkvScheduled, isTrue);
    expect(ready.todayFsrsDue, 0);
    expect(
      srsNavPeekCountsLabel(
        newCount: 0,
        learnCount: 0,
        reviewCount: after.reviewCount,
        fsrsDue: after.fsrsDue,
        rwkv: after.rwkvScheduled,
      ),
      t.srs_count_review_rwkv_live,
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          home: Scaffold(
            body: SrsCountTriple(
              newCount: after.newCount,
              learnCount: after.learnCount,
              reviewCount: after.reviewCount,
              reviewPending: after.rwkvPending,
              fsrsDue: after.fsrsDue,
              rwkv: after.rwkvScheduled,
            ),
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('srs-count-review-rwkv')),
      findsOneWidget,
    );
    expect(find.text('—'), findsOneWidget);
    expect(find.text('${after.reviewCount}'), findsNothing);
    expect(find.textContaining('≈'), findsNothing);
    expect(
      find.bySemanticsLabel(
        RegExp(RegExp.escape(t.srs_count_review_rwkv_live)),
      ),
      findsOneWidget,
    );
  });

  test('混合牌组：FSRS 到期照旧显示，RWKV 那部分不显示数；首页逐根求和', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore(
      clock: SrsTestClock(),
    );
    addTearDown(db.close);
    final SrsDeckView deck = (await store.deckTree())[store.defaultDeckId]!;
    SrsDeckSummary root({
      required int reviewCount,
      int? fsrsDue,
      bool scheduled = false,
      bool pending = false,
    }) => SrsDeckSummary(
      deck: deck,
      fullName: deck.name,
      depth: 0,
      newCount: 0,
      learnCount: 0,
      reviewCount: reviewCount,
      newBudget: const SrsNewCardBudget(
        limit: 20,
        allowed: 20,
        reviewBudget: 100,
        reason: null,
      ),
      totalCards: 100,
      rwkvPending: pending,
      rwkvScheduled: scheduled,
      fsrsDue: fsrsDue,
    );
    // 纯 FSRS 根（到期 50）+ 混合根（FSRS 子牌组到期 4、RWKV 子牌组此刻合格 5）。
    final SrsDeckListData data = SrsDeckListData(
      store: store,
      decks: <SrsDeckSummary>[
        root(reviewCount: 50, fsrsDue: 50),
        root(reviewCount: 9, fsrsDue: 4, scheduled: true),
      ],
    );
    expect(data.todayFsrsDue, 54);
    expect(data.rwkvScheduled, isTrue);
    expect(
      SrsReviewCell.of(
        reviewCount: data.todayReview,
        fsrsDue: data.todayFsrsDue,
        rwkv: data.rwkvScheduled,
      ).numbers,
      '54',
    );
    // 混合子树的牌组行：只显示 FSRS 到期；纯 RWKV（FSRS 到期 0）显示「—」。
    expect(
      SrsReviewCell.ofDeck(
        root(reviewCount: 9, fsrsDue: 4, scheduled: true),
      ).label(),
      '${t.srs_count_review} 4 · ${t.srs_count_review_rwkv_live}',
    );
    expect(
      SrsReviewCell.ofDeck(
        root(reviewCount: 3, fsrsDue: 0, scheduled: true),
      ).numbers,
      '—',
    );
    // 准备中：FSRS 到期照旧显示（RWKV 的卡本就没进计数），速览与牌组格同一份格式。
    expect(
      srsNavPeekCountsLabel(
        newCount: 0,
        learnCount: 0,
        reviewCount: 4,
        reviewPending: true,
        fsrsDue: 4,
        rwkv: true,
      ),
      '${t.srs_count_review} 4 · ${t.srs_count_review_rwkv_live} '
      '(${t.srs_settings_rwkv_preparing_start})',
    );
    expect(
      srsNavPeekCountsLabel(
        newCount: 0,
        learnCount: 0,
        reviewCount: 0,
        reviewPending: true,
        fsrsDue: 0,
        rwkv: true,
      ),
      '${t.srs_count_review_rwkv_live} (${t.srs_settings_rwkv_preparing_start})',
    );
    // 没有 RWKV 牌组：照旧是到期数。
    final SrsDeckListData fsrsOnly = SrsDeckListData(
      store: store,
      decks: <SrsDeckSummary>[root(reviewCount: 7)],
    );
    expect(fsrsOnly.rwkvScheduled, isFalse);
    expect(fsrsOnly.todayFsrsDue, 7);
    expect(
      srsNavPeekCountsLabel(newCount: 0, learnCount: 0, reviewCount: 7),
      '${t.srs_count_review} 7',
    );
  });
}
