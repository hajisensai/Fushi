// 反馈 O5YDP27Xko：复习卡静默回退整面 WebView，查不出卡在哪一道。
//
// 钉住：样式被改过的内置 Fushi 卡片在复习页走整面 WebView 卡面，并把原因记进诊断日志
// （`SrsCardFace.webFallback`，带 cssModified），同一笔记类型 × 模板 × 原因在会话内只记一次。
//
// 走真实路径：内存库 + SrsReviewPage。数据库读写放 tester.runAsync。

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show kFushiCardStylingCss;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

List<ErrorLogEntry> _fallbackLogs() => ErrorLogService
    .instance
    .diagnosticEntries
    .where((ErrorLogEntry e) => e.source == 'SrsCardFace.webFallback')
    .toList();

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('样式被改过的 Fushi 卡：整面 WebView，回退原因只记一次', (
    WidgetTester tester,
  ) async {
    final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
      () => openSrsTestStore(),
    ))!;
    addTearDown(() => tester.runAsync(db.close));
    await tester.runAsync(() async {
      await store.createNote(
        noteTypeId: store.fushiCardNoteTypeId,
        fieldsById: <String, String>{
          srsFushiCardFieldId(kSrsTestProfile, 'Expression'): '免許',
          srsFushiCardFieldId(kSrsTestProfile, 'MainDefinition'): 'licence',
        },
      );
      final SrsNoteTypeView type = (await store.noteType(
        store.fushiCardNoteTypeId,
      ))!;
      await store.saveTemplateEdits(
        type.id,
        type.templates.single.id,
        css: '$kFushiCardStylingCss\n.mine { color: red; }',
      );
    });
    final int before = _fallbackLogs().length;

    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppModel app = AppModel(testPlatformServices());
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => app),
          srsStoreProvider.overrideWith((Ref ref) async => store),
          srsMediaStoreProvider.overrideWith(
            (Ref ref) async => null as SrsMediaStore?,
          ),
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
            home: SrsReviewPage(
              deckId: store.defaultDeckId,
              deckName: 'Default',
            ),
          ),
        ),
      ),
    );
    await _settle(tester);

    expect(find.byType(SrsFushiCardView), findsNothing);
    expect(find.byType(SrsPlainCardFace), findsOneWidget);
    List<ErrorLogEntry> logs = _fallbackLogs().sublist(before);
    expect(logs, hasLength(1));
    expect(logs.single.error, contains('reason=cssModified'));
    expect(logs.single.error, contains('builtin=$kSrsBuiltinFushiCardKey'));

    // 翻面：卡面重建，同一原因不再重复记。
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(tester, rounds: 4);
    logs = _fallbackLogs().sublist(before);
    expect(logs, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
