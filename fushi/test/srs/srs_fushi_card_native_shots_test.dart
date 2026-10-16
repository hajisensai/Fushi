// Fushi 卡片原生卡面的真实像素截图（只在设了 FUSHI_SRS_NATIVE_SHOTS_OUT 目录时出图，平时空跑）。
// 释义区在 widget 测试里没有 WebView，画成标注出来的占位框；它的真实渲染见模板整页截图。
// 字体用 Noto Sans JP（覆盖默认族；目录见 FUSHI_SRS_SHOT_FONT_DIR），图标用 app 自带图标字体。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

class _App extends AppModel {
  _App() : super(testPlatformServices());

  @override
  SrsCardAppearance get srsCardAppearance => const SrsCardAppearance();
}

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

  // FUSHI_SRS_SHOT_FONT_DIR：放 NotoSansJP-Regular/Bold.otf 的目录（默认 Windows 字体目录）。
  final String fonts =
      Platform.environment['FUSHI_SRS_SHOT_FONT_DIR'] ?? r'C:\Windows\Fonts';
  for (final String family in <String>['Roboto', '.SF Pro Text', 'Noto']) {
    await load(family, <String>[
      '$fonts${Platform.pathSeparator}NotoSansJP-Regular.otf',
      '$fonts${Platform.pathSeparator}NotoSansJP-Bold.otf',
    ]);
  }
  for (final String family in <String>['FushiSymbols', 'FushiSymbolsFilled']) {
    await load(family, <String>[
      'assets/icon_fonts/${family == 'FushiSymbols' ? 'FushiSymbolsRounded' : 'FushiSymbolsRoundedFilled'}.ttf',
    ]);
  }
}

void main() {
  final String? out = Platform.environment['FUSHI_SRS_NATIVE_SHOTS_OUT'];
  if (out == null || out.isEmpty) {
    test('native shots (only with FUSHI_SRS_NATIVE_SHOTS_OUT)', () {});
    return;
  }
  setUp(() => LocaleSettings.setLocale(AppLocale.ja));

  final Map<String, String> fields = <String, String>{
    for (final String f in FushiCardNoteType.fields) f: '',
    ...srsSampleCardFields(),
    'SentenceTranslation': 'I go to the library almost every day.',
  };

  for (final (String name, Size size, bool answer, bool dark, bool apple)
      in <(String, Size, bool, bool, bool)>[
        ('phone-front-light', const Size(412, 915), false, false, false),
        ('phone-back-light', const Size(412, 915), true, false, false),
        ('phone-back-dark', const Size(412, 915), true, true, false),
        ('phone-back-apple', const Size(412, 915), true, false, true),
        ('phone-landscape-back', const Size(915, 412), true, false, false),
        ('desktop-back-light', const Size(1100, 760), true, false, false),
        ('desktop-back-dark', const Size(1100, 760), true, true, false),
      ]) {
    testWidgets('shot $name', (WidgetTester tester) async {
      await tester.runAsync(_loadFonts);
      const double dpr = 2;
      tester.view.physicalSize = size * dpr;
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      final GlobalKey boundary = GlobalKey();
      final List<SrsCardFace> faces = <SrsCardFace>[];
      final ColorScheme scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF386A58),
        brightness: dark ? Brightness.dark : Brightness.light,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((Ref ref) => _App()),
            srsMediaStoreProvider.overrideWith(
              (Ref ref) async => null as SrsMediaStore?,
            ),
            srsCardFaceBuilderProvider.overrideWithValue((
              BuildContext context,
              SrsCardFace face,
            ) {
              faces.add(face);
              final ColorScheme s = Theme.of(context).colorScheme;
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  border: Border.all(color: s.outline, width: 1.5),
                  borderRadius: BorderRadius.circular(20),
                  color: s.surfaceContainerLow,
                ),
                alignment: Alignment.center,
                child: Text(
                  '释义区 · WebView（${face.layout.name}）',
                  style: TextStyle(color: s.onSurfaceVariant, fontSize: 14),
                ),
              );
            }),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildFushiThemeData(
                scheme: scheme,
                textTheme: dark
                    ? Typography.material2021().white
                    : Typography.material2021().black,
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
                child: Scaffold(
                  body: SafeArea(
                    child: SrsFushiCardView(
                      face: SrsCardFace(
                        cardId: name,
                        showingAnswer: answer,
                        bodyHtml: '',
                        css: FushiCardNoteType.template.css,
                        languageCode: 'ja',
                        onBridgeKey: (_) {},
                      ),
                      fields: fields,
                      definitionsHtml: '<div class="fc-defs-only"></div>',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 900));
      // 窄版式：模拟页面上报的释义区内容高度。
      if (faces.isNotEmpty) faces.last.onContentHeight?.call(360);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      // 图片解码要真异步（FakeAsync 里永远解不完）。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
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
    });
  }
}
