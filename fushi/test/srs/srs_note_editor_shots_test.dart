// 笔记编辑页（可视化字段编辑）的真实像素截图：只在设了 FUSHI_SRS_EDITOR_SHOTS_OUT 目录时出图，
// 平时空跑。结构化释义的预览在 widget 测试里没有 WebView，画成「去标签的纯文字」占位。
// 字体用 Noto Sans JP（目录见 FUSHI_SRS_SHOT_FONT_DIR，默认 Windows 字体目录），图标用 app 自带字体。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart' show srsPlainText;
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final FontLoader loader = FontLoader(family);
    for (final String path in paths) {
      final File f = File(path);
      if (!f.existsSync()) continue;
      final Uint8List bytes = await f.readAsBytes();
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  // FUSHI_SRS_SHOT_FONT_FILES：以 | 分隔的字体文件（Mac 上可给 Arial Unicode.ttf）；
  // 否则取 FUSHI_SRS_SHOT_FONT_DIR（默认 Windows 字体目录）下的 Noto Sans JP。
  final String fonts =
      Platform.environment['FUSHI_SRS_SHOT_FONT_DIR'] ?? r'C:\Windows\Fonts';
  final String? files = Platform.environment['FUSHI_SRS_SHOT_FONT_FILES'];
  for (final String family in <String>['Roboto', '.SF Pro Text', 'Noto']) {
    await load(
      family,
      files != null && files.isNotEmpty
          ? files.split('|')
          : <String>[
              '$fonts${Platform.pathSeparator}NotoSansJP-Regular.otf',
              '$fonts${Platform.pathSeparator}NotoSansJP-Bold.otf',
            ],
    );
  }
  for (final String family in <String>['FushiSymbols', 'FushiSymbolsFilled']) {
    await load(family, <String>[
      'assets/icon_fonts/${family == 'FushiSymbols' ? 'FushiSymbolsRounded' : 'FushiSymbolsRoundedFilled'}.ttf',
    ]);
  }
}

void main() {
  final String? out = Platform.environment['FUSHI_SRS_EDITOR_SHOTS_OUT'];
  if (out == null || out.isEmpty) {
    test('editor shots (only with FUSHI_SRS_EDITOR_SHOTS_OUT)', () {});
    return;
  }
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  for (final (String name, Size size, bool apple, bool focus)
      in <(String, Size, bool, bool)>[
        ('phone-md3', const Size(412, 1800), false, true),
        ('phone-apple', const Size(412, 1800), true, false),
        ('phone-landscape-md3', const Size(915, 412), false, false),
        ('desktop-md3', const Size(1280, 1100), false, true),
      ]) {
    testWidgets('shot $name', (WidgetTester tester) async {
      await tester.runAsync(_loadFonts);
      final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
        () => openSrsTestStore(),
      ))!;
      addTearDown(() => tester.runAsync(db.close));
      final Map<String, String> fields = <String, String>{
        ...srsSampleCardFields(),
        'ExpressionAudio': '[sound:kayou_word.mp3]',
        'SentenceAudio': '[sound:kayou_sentence.mp3]',
      };
      final String note = (await tester.runAsync(
        () => store.createNote(
          noteTypeId: store.fushiCardNoteTypeId,
          fieldsById: <String, String>{
            for (final MapEntry<String, String> e in fields.entries)
              srsFushiCardFieldId(kSrsTestProfile, e.key): e.value,
          },
        ),
      ))!;

      const double dpr = 2;
      tester.view.physicalSize = size * dpr;
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      final GlobalKey boundary = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith(
              (Ref ref) => AppModel(testPlatformServices()),
            ),
            srsStoreProvider.overrideWith((Ref ref) async => store),
            srsMediaStoreProvider.overrideWith(
              (Ref ref) async => null as SrsMediaStore?,
            ),
            srsCardFaceBuilderProvider.overrideWithValue((
              BuildContext context,
              SrsCardFace face,
            ) {
              final ColorScheme s = Theme.of(context).colorScheme;
              return SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Text(
                  srsPlainText(face.bodyHtml),
                  style: TextStyle(color: s.onSurface, fontSize: 14),
                ),
              );
            }),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildFushiThemeData(
                scheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xFF386A58),
                ),
                textTheme: Typography.material2021().black,
                designSystem: apple
                    ? FushiDesignSystem.cupertino
                    : FushiDesignSystem.material,
                glass: FushiGlassMaterial.off,
                glassDesign: apple,
              ),
              builder: (BuildContext context, Widget? child) =>
                  FushiGlassScope(child: child!),
              home: RepaintBoundary(
                key: boundary,
                child: SrsNoteEditorPage(noteId: note),
              ),
            ),
          ),
        ),
      );
      for (int i = 0; i < 16; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 80));
      }
      if (focus) {
        // 聚焦例句、选中目标词：工具条出现，「B」高亮；展开色板。
        final Finder input = find.descendant(
          of: find.byKey(const ValueKey<String>('srs-field-input-Sentence')),
          matching: find.byType(EditableText),
        );
        await tester.ensureVisible(input);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(input);
        await tester.pump(const Duration(milliseconds: 300));
        final EditableText editable = tester.widget<EditableText>(input);
        editable.controller.selection = const TextSelection(
          baseOffset: 10,
          extentOffset: 13,
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(
          find.byKey(const ValueKey<String>('srs-format-color-Sentence')),
        );
        await tester.pump(const Duration(milliseconds: 600));
      }
      // 图片解码要真异步。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final RenderRepaintBoundary rb =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final ui.Image image = await rb.toImage(pixelRatio: dpr);
        final ByteData? png = await image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        Directory(out).createSync(recursive: true);
        File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
