// 复习库打开失败（readSrsStore 原样抛出，BUG-4285）后各页面的落点：进错误态（不是永远转圈、不是未处理
// 异常），「重试」作废缓存着失败的 provider、库恢复后真的重新打开并显示内容。
//
// 内存库 + 确定性假排程内核；打开失败用 srsStoreProvider 的覆盖模拟（可切换成功 / 失败）。
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_inspector.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_conflicts_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_history_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_load_error.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_types_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_app_runtime.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

/// 复习库的打开：[failing] 为真时打开失败；记下打开了几次（重试真的重开 = 次数增加）。
class _Opener {
  _Opener(this.store);

  final SrsDbStore store;
  bool failing = true;
  int attempts = 0;

  Future<SrsDbStore?> open() {
    attempts++;
    return failing
        ? Future<SrsDbStore?>.error(StateError('srs.db corrupt'))
        : Future<SrsDbStore?>.value(store);
  }
}

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): '食べる',
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'eat',
      },
    ),
  );
  return store;
}

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pump(WidgetTester tester, _Opener opener, Widget page) async {
  tester.view.physicalSize = const Size(1100, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel app = SrsTestAppModel();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsStoreProvider.overrideWith((Ref ref) => opener.open()),
        srsAppRuntimeProvider.overrideWithValue(null),
        srsReviewChromeFloatingProvider.overrideWithValue(false),
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
            designSystem: FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: Scaffold(body: page),
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

/// 打开失败 → 错误态（带真实错误与重试），不在转圈；库恢复后点重试 → 重新打开、错误态消失。
Future<void> _expectErrorThenRecover(
  WidgetTester tester,
  _Opener opener,
  String retryKey,
) async {
  expect(tester.takeException(), isNull, reason: '打开失败不变成未处理异常');
  expect(find.byType(SrsLoadErrorView), findsOneWidget);
  expect(find.textContaining('srs.db corrupt'), findsOneWidget);
  expect(find.byType(FushiLoadingView), findsNothing, reason: '不是永远转圈');
  final int before = opener.attempts;

  opener.failing = false;
  await tester.tap(find.byKey(ValueKey<String>(retryKey)));
  await _settle(tester);
  expect(opener.attempts, greaterThan(before), reason: '重试作废了缓存的失败，真的重开');
  expect(find.byType(SrsLoadErrorView), findsNothing);
  expect(find.byType(FushiLoadingView), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('复习页：打开失败进错误态，重试后出卡', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    final _Opener opener = _Opener(store);
    final List<SrsCardFace> faces = <SrsCardFace>[];
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppModel app = SrsTestAppModel();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => app),
          srsStoreProvider.overrideWith((Ref ref) => opener.open()),
          srsReviewChromeFloatingProvider.overrideWithValue(false),
          srsCardFaceBuilderProvider.overrideWithValue((
            BuildContext context,
            SrsCardFace face,
          ) {
            faces.add(face);
            return SrsPlainCardFace(face: face);
          }),
        ],
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
            home: SrsReviewPage(deckId: store.defaultDeckId, deckName: 'D'),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.textContaining('srs.db corrupt'), findsOneWidget);
    final int before = opener.attempts;

    opener.failing = false;
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-review-load-retry')),
    );
    await _settle(tester);
    expect(opener.attempts, greaterThan(before), reason: '重试真的重开了库');
    expect(find.byType(SrsLoadErrorView), findsNothing);
    expect(
      faces.where((SrsCardFace f) => f.cardId.isNotEmpty),
      isNotEmpty,
      reason: '库恢复后出卡',
    );
    await _unmount(tester);
  });

  testWidgets('同步历史页：打开失败进错误态（以前空状态，上抛后一直转圈），重试后显示页面', (
    WidgetTester tester,
  ) async {
    final _Opener opener = _Opener(await _openStore(tester));
    await _pump(tester, opener, const SrsHistoryPage());
    await _expectErrorThenRecover(tester, opener, 'srs-history-load-retry');
    await _unmount(tester);
  });

  testWidgets('同步冲突页：打开失败进错误态，重试后显示（无冲突）', (WidgetTester tester) async {
    final _Opener opener = _Opener(await _openStore(tester));
    await _pump(tester, opener, const SrsConflictsPage());
    await _expectErrorThenRecover(tester, opener, 'srs-conflicts-load-retry');
    expect(find.text(t.srs_conflicts_empty), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('笔记类型页：打开失败进错误态，重试后列出笔记类型', (WidgetTester tester) async {
    final _Opener opener = _Opener(await _openStore(tester));
    await _pump(tester, opener, const SrsNoteTypesPage());
    await _expectErrorThenRecover(tester, opener, 'srs-note-types-load-retry');
    await _unmount(tester);
  });

  group('浏览检查器', () {
    Future<SrsBrowseRow> firstRow(
      WidgetTester tester,
      SrsDbStore store,
    ) async => (await tester.runAsync(() async {
      final SrsBrowseSession session = SrsBrowseSession(store);
      try {
        return (await (await session.query()).all()).first;
      } finally {
        await session.close();
      }
    }))!;

    Widget inspector(SrsBrowseRow row, ValueNotifier<int> revision) => SizedBox(
      width: 600,
      height: 1200,
      child: ValueListenableBuilder<int>(
        valueListenable: revision,
        builder: (BuildContext context, int rev, Widget? _) =>
            SrsBrowseInspector(
              row: row,
              revision: rev,
              tab: SrsBrowseInspectorTab.history,
              onTabChanged: (_) {},
              showAnswer: false,
              onCommand: (_) {},
              onSaveField: (_, _, _) async {},
              onSaveTags: (_, _, _) async {},
              onOpenEditor: (_) {},
              actions: SrsBrowseInspectorActions(
                onSuspend: () {},
                onFlag: () {},
                onMore: () {},
                suspended: false,
              ),
            ),
      ),
    );

    testWidgets('读这张卡时打开失败：页签进错误态，重试后显示历史', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      final _Opener opener = _Opener(store);
      final SrsBrowseRow row = await firstRow(tester, store);
      final ValueNotifier<int> revision = ValueNotifier<int>(0);
      addTearDown(revision.dispose);
      await _pump(tester, opener, inspector(row, revision));
      await _expectErrorThenRecover(
        tester,
        opener,
        'srs-browse-inspector-load-retry',
      );
      await _unmount(tester);
    });

    testWidgets('历史页签重读时打开失败：页签进错误态，重试后恢复', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      final _Opener opener = _Opener(store)..failing = false;
      final SrsBrowseRow row = await firstRow(tester, store);
      final ValueNotifier<int> revision = ValueNotifier<int>(0);
      addTearDown(revision.dispose);
      await _pump(tester, opener, inspector(row, revision));
      expect(find.byType(SrsLoadErrorView), findsNothing);
      expect(find.byType(FushiLoadingView), findsNothing);

      // 库被关掉重开时失败（provider 作废后重读），随后这一行有写入（修订号变化）→ 检查器与历史页签都重读。
      opener.failing = true;
      ProviderScope.containerOf(
        tester.element(find.byType(SrsBrowseInspector)),
      ).invalidate(srsStoreProvider);
      revision.value = 1;
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('srs-browse-history-load-retry')),
        findsOneWidget,
      );
      await _expectErrorThenRecover(
        tester,
        opener,
        'srs-browse-history-load-retry',
      );
      await _unmount(tester);
    });
  });
}
