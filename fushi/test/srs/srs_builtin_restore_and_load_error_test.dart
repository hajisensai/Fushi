// 复习页面两类反馈的回归：
// - rSc_MnZkAs：内置 Fushi 卡片的模板 / 样式被改过（回滚带回旧版）后原生卡面停用。外观页要明说并给出
//   「恢复内置模板」，笔记类型编辑页也有同一入口；恢复写回内置定义。
// - pD2oUIn6rP：浏览页加载失败时不能永远停在加载态（以前 `_refresh` 不收口异常、库不可用时也直接 return）。
//
// 内存库 + 确定性假排程内核；数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_appearance_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_type_editor_page.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardNoteType;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

/// 外观偏好放内存里（不碰偏好层）。
class _App extends SrsTestAppModel {
  SrsCardAppearance value = const SrsCardAppearance();

  @override
  SrsCardAppearance get srsCardAppearance => value;

  @override
  Future<void> setSrsCardAppearance(SrsCardAppearance appearance) async {
    value = appearance;
    notifyListeners();
  }
}

Future<void> _settle(WidgetTester tester, {int rounds = 14}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required Future<SrsDbStore?> Function() store,
  required Widget page,
  bool apple = false,
}) async {
  tester.view.physicalSize = const Size(1100, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _App app = _App();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => app),
        srsStoreProvider.overrideWith((Ref ref) => store()),
        srsCardFontRootProvider.overrideWithValue(null),
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

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  return store;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('浏览页加载失败', () {
    testWidgets('库打不开：出错占位 + 重试，不停在加载态', (WidgetTester tester) async {
      await _pump(
        tester,
        store: () async => throw StateError('srs.db locked'),
        page: const SrsBrowsePage(),
      );
      expect(
        find.byKey(const ValueKey<String>('srs-browse-load-error')),
        findsOneWidget,
      );
      expect(find.byType(FushiLoadingView), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('srs-browse-load-retry')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('复习模块不可用（库为 null）：明说，不转圈', (WidgetTester tester) async {
      await _pump(tester, store: () async => null, page: const SrsBrowsePage());
      expect(find.text(t.srs_engine_unavailable), findsOneWidget);
      expect(find.byType(FushiLoadingView), findsNothing);
    });

    testWidgets('查询途中内核报错（库已关）：转出错状态', (WidgetTester tester) async {
      final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
        () => openSrsTestStore(),
      ))!;
      addTearDown(() => tester.runAsync(db.close));
      // 关掉内核（库被并发关闭 / 作废）：之后每条查询都抛 store is closed。
      store.core.close();
      await _pump(
        tester,
        store: () async => store,
        page: const SrsBrowsePage(),
      );
      expect(
        find.byKey(const ValueKey<String>('srs-browse-load-error')),
        findsOneWidget,
      );
      expect(find.byType(FushiLoadingView), findsNothing);
    });
  });

  group('恢复内置模板', () {
    for (final bool apple in <bool>[false, true]) {
      testWidgets('[${apple ? 'Apple' : 'MD3'}] 外观页：模板改过时提示原生卡面停用，恢复后提示消失', (
        WidgetTester tester,
      ) async {
        final SrsDbStore store = await _openStore(tester);
        final String nt = store.fushiCardNoteTypeId;
        await tester.runAsync(() => store.setCss(nt, '.card{max-width:1px}'));
        await _pump(
          tester,
          store: () async => store,
          page: const SrsCardAppearancePage(),
          apple: apple,
        );
        expect(
          find.byKey(const ValueKey<String>('srs-card-native-off')),
          findsOneWidget,
        );
        expect(
          find.text(t.srs_card_appearance_native_off_hint),
          findsOneWidget,
        );
        final Finder restore = find.byKey(
          const ValueKey<String>('srs-card-restore-builtin'),
        );
        expect(restore, findsOneWidget);

        await tester.tap(restore);
        await _settle(tester, rounds: 6);
        // 确认框：确认按钮与入口同名，取后出现的那个。
        await tester.tap(find.text(t.srs_note_types_builtin_restore).last);
        await _settle(tester);

        final SrsNoteTypeView? type = await tester.runAsync<SrsNoteTypeView?>(
          () => store.noteType(nt),
        );
        expect(type!.css, FushiCardNoteType.template.css);
        expect(
          find.byKey(const ValueKey<String>('srs-card-native-off')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('外观页：模板未改时没有提示', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _pump(
        tester,
        store: () async => store,
        page: const SrsCardAppearancePage(),
      );
      expect(
        find.byKey(const ValueKey<String>('srs-card-native-off')),
        findsNothing,
      );
    });

    testWidgets('笔记类型编辑页：只在内置模板被改过时出现恢复入口', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      final String nt = store.fushiCardNoteTypeId;
      await _pump(
        tester,
        store: () async => store,
        page: SrsNoteTypeEditorPage(noteTypeId: nt),
      );
      final Finder restore = find.byKey(
        const ValueKey<String>('srs-note-type-restore-builtin'),
      );
      expect(restore, findsNothing);

      await tester.runAsync(() => store.setCss(nt, '.changed{}'));
      await _pump(
        tester,
        store: () async => store,
        page: SrsNoteTypeEditorPage(key: UniqueKey(), noteTypeId: nt),
      );
      expect(restore, findsOneWidget);
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await _settle(tester, rounds: 6);
      await tester.tap(find.text(t.srs_note_types_builtin_restore).last);
      await _settle(tester);
      final SrsNoteTypeView? type = await tester.runAsync<SrsNoteTypeView?>(
        () => store.noteType(nt),
      );
      expect(type!.css, FushiCardNoteType.template.css);
      expect(restore, findsNothing);
    });
  });
}
