// 牌组列表首帧问「首次 v2 同步」：确认框挂在根导航上，用户点「开始」时牌组列表这一页可能已经卸载（切了 tab /
// 换了页）。确认之后的那一轮同步归 app 级运行时，不能因为页面没了就不跑、更不能抛「No ProviderScope」
// （反馈 nxR7tmcOjw）。焦点驱动：确认按钮自动持焦，Enter 确认。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/srs/srs_app_runtime.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

/// 「首次 v2 同步」确认状态存在内存里（测试不装偏好层）。
class _UnconfirmedAppModel extends SrsTestAppModel {
  bool confirmed = false;

  @override
  bool get srsSync2MergeConfirmed => confirmed;

  @override
  Future<void> setSrsSync2MergeConfirmed(bool value) async => confirmed = value;
}

/// 只数「立即同步」跑了几轮的运行时（不碰通道）。
class _CountingRuntime extends SrsAppRuntime {
  _CountingRuntime(AppModel app)
    : super(
        app: app,
        readStore: () async => null,
        readMedia: () async => null,
        engine: () => null,
        bumpRevision: () {},
        bumpPulledRevision: () {},
      );

  int syncs = 0;

  @override
  Future<SrsSyncNowResult> syncNow() async {
    syncs++;
    return const SrsSyncNowResult(ran: 1);
  }
}

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    debugResetSrsFirstSyncAsked();
  });

  testWidgets('BUG：首次同步确认框还开着时牌组列表已卸载，确认后首次同步照跑、不抛错', (
    WidgetTester tester,
  ) async {
    final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
      openSrsTestStore,
    ))!;
    addTearDown(() => tester.runAsync(db.close));
    // 本机有用户笔记才会弹确认框（没有就直接记成已确认）。
    await tester.runAsync(
      () => store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kSrsTestProfile, 'Expression'): '食べる',
          srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'to eat',
        },
      ),
    );
    final _UnconfirmedAppModel app = _UnconfirmedAppModel();
    final _CountingRuntime runtime = _CountingRuntime(app);
    final ValueNotifier<bool> showPage = ValueNotifier<bool>(true);
    addTearDown(showPage.dispose);

    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => app),
          ...srsTestDonationOverrides,
          srsStoreProvider.overrideWith((Ref ref) async => store),
          srsAppRuntimeProvider.overrideWithValue(runtime),
          srsRwkvServiceProvider.overrideWith((Ref ref) async => null),
          srsCardFaceBuilderProvider.overrideWithValue(
            (BuildContext context, SrsCardFace face) =>
                SrsPlainCardFace(face: face),
          ),
          srsReviewChromeFloatingProvider.overrideWithValue(false),
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
            // 首页的一个 tab：切走时牌组列表卸载，根导航上的确认框还在。
            home: ValueListenableBuilder<bool>(
              valueListenable: showPage,
              builder: (BuildContext context, bool show, Widget? _) =>
                  show ? const SrsDeckListPage() : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text(t.srs_sync_confirm_title), findsOneWidget);

    showPage.value = false;
    await tester.pump();
    expect(find.byType(SrsDeckListPage), findsNothing);
    expect(find.text(t.srs_sync_confirm_title), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(find.text(t.srs_sync_confirm_title), findsNothing);
    expect(app.confirmed, isTrue);
    expect(runtime.syncs, 1, reason: '确认之后的首次同步不跟着页面卸载丢掉');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
