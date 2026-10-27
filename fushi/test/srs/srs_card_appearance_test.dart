// 卡面外观：设置 → CSS 变量 / 宿主类名映射、偏好 JSON 读写、字体供给的白名单 / 魔数校验、
// 外观定制页（控件改动即时更新预览；窄 / 宽两种尺寸不溢出；MD3 与 Apple 两套设计系统）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_appearance_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/reader/reader_settings.dart' show FontTarget;
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

const SrsCardLabels _labels = SrsCardLabels(
  allDefinitions: '全部"释义"',
  frequency: '词频',
  source: '来源',
);

String _css(
  SrsCardAppearance a, {
  bool dark = false,
  String? fontRoot,
  ColorScheme? scheme,
  List<Map<String, dynamic>> fonts = const <Map<String, dynamic>>[],
}) => srsCardAppearanceCss(
  appearance: a,
  tokens: SrsCardTokens.fromTheme(ThemeData()),
  appScheme:
      scheme ??
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF3F5F90),
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
  dark: dark,
  labels: _labels,
  fontUrl: (String path) => srsCardFontUrl(path, customScheme: false),
  fontRoot: fontRoot,
  fonts: fonts,
);

/// 外观定制页测试用的 AppModel：外观偏好放内存里（不碰数据库）。
class _AppearanceApp extends AppModel {
  _AppearanceApp() : super(testPlatformServices());

  SrsCardAppearance value = const SrsCardAppearance();

  @override
  SrsCardAppearance get srsCardAppearance => value;

  @override
  Future<void> setSrsCardAppearance(SrsCardAppearance appearance) async {
    value = appearance;
    notifyListeners();
  }
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('设置 → 注入', () {
    test('默认外观：配色变量齐全、倍率为 1、只有统一词典样式类', () {
      const SrsCardAppearance a = SrsCardAppearance();
      final String css = _css(a);
      for (final String v in <String>[
        '--fushi-srs-bg:',
        '--fushi-srs-fg:',
        '--fushi-srs-fg-muted:',
        '--fushi-srs-accent:',
        '--fushi-srs-accent-container:',
        '--fushi-srs-secondary-container:',
        '--fushi-srs-surface-container-highest:',
        '--fushi-srs-outline-variant:',
        '--fushi-srs-highlight:rgba(',
        '--fushi-srs-text-scale:1;',
        '--fushi-srs-term-scale:1;',
        '--fushi-srs-line-scale:1;',
      ]) {
        expect(css, contains(v));
      }
      expect(css, isNot(contains('--fushi-srs-font-')));
      expect(css, isNot(contains('@font-face')));
      expect(srsCardAppearanceClasses(a).split(' ').toSet(), <String>{
        'fushi-srs-dict-unified',
        'fushi-srs-freq-aggregate',
      });
    });

    test('跟随 app 主题 = ColorScheme 原样；自定义强调色 = 以它为种子', () {
      final ColorScheme app = ColorScheme.fromSeed(
        seedColor: const Color(0xFF3F5F90),
      );
      String accentOf(String css) => RegExp(
        r'--fushi-srs-accent:(#[0-9a-f]{6});',
      ).firstMatch(css)!.group(1)!;
      final String follow = accentOf(
        _css(const SrsCardAppearance(), scheme: app),
      );
      expect(
        follow,
        '#${(app.primary.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
      );
      final String custom = accentOf(
        _css(
          const SrsCardAppearance(
            colorSource: SrsCardColorSource.custom,
            customAccent: 0xFFB3261E,
          ),
          scheme: app,
        ),
      );
      expect(custom, isNot(follow));
    });

    test('标签文字按界面语言注入并转义引号', () {
      expect(
        _css(const SrsCardAppearance()),
        contains(r'--fushi-srs-label-more:"全部\"释义\"";'),
      );
    });

    test('字体库链：排在默认链之前，导入文件出 @font-face（只认字体目录内），系统字体只进族名', () {
      final String root = p.join(Directory.systemTemp.path, 'fonts-root');
      final List<Map<String, dynamic>> fonts = <Map<String, dynamic>>[
        <String, dynamic>{'name': 'Inter'},
        <String, dynamic>{'name': 'Klee One', 'path': p.join(root, 'klee.ttf')},
        <String, dynamic>{'name': 'Off', 'enabled': false},
        <String, dynamic>{
          'name': 'Evil',
          'path': p.join(Directory.systemTemp.path, 'elsewhere', 'evil.ttf'),
        },
      ];
      final String css = _css(
        const SrsCardAppearance(),
        fontRoot: root,
        fonts: fonts,
      );
      expect(
        css,
        contains(
          '@font-face { font-family: "Klee One"; src: url("https://srs.local/fonts/',
        ),
      );
      expect(css, isNot(contains('Evil')), reason: '目录外的字体文件等于没选');
      expect(css, isNot(contains('"Off"')));
      expect(
        css,
        contains('--fushi-srs-font-ja:"Inter", "Klee One", "Hiragino Sans"'),
      );
      expect(
        css,
        contains('--fushi-srs-font-zh:"Inter", "Klee One", "PingFang SC"'),
      );
      expect(
        css,
        contains('--fushi-srs-font-ui:"Inter", "Klee One", system-ui'),
      );

      // 没有字体目录：只留系统字体，文件一律不出。
      final String noRoot = _css(const SrsCardAppearance(), fonts: fonts);
      expect(noRoot, isNot(contains('@font-face')));
      expect(noRoot, contains('--fushi-srs-font-ja:"Inter", "Hiragino Sans"'));

      expect(srsCardFontWhitelist(fonts, fontRoot: root), <String>{
        p.canonicalize(p.join(root, 'klee.ttf')),
      });
      expect(srsCardFontWhitelist(fonts, fontRoot: null), isEmpty);
    });

    test('区块显隐 / 正面读音 / 密度 / 统一词典样式 → 宿主类名', () {
      final String c = srsCardAppearanceClasses(
        const SrsCardAppearance(
          dictUnified: false,
          aggregateFrequency: false,
          showPicture: false,
          showTranslation: false,
          showFrequency: false,
          showSource: false,
          glossaryExpanded: true,
          frontReading: true,
          frontFrequency: true,
          density: SrsCardDensity.comfortable,
        ),
      );
      expect(c.split(' ').toSet(), <String>{
        'fushi-srs-front-reading',
        'fushi-srs-front-freq',
        'fushi-srs-gloss-expanded',
        'fushi-srs-hide-picture',
        'fushi-srs-hide-translation',
        'fushi-srs-hide-frequency',
        'fushi-srs-hide-source',
        'fushi-srs-density-comfortable',
      });
    });

    test('词频聚合：运行时字段，不进 JSON、解码默认 true、参与 ==、决定类名', () {
      const SrsCardAppearance off = SrsCardAppearance(
        aggregateFrequency: false,
      );
      expect(off.toJson().containsKey('aggregateFrequency'), isFalse);
      expect(off.encode(), isNot(contains('aggregate')));
      expect(SrsCardAppearance.decode(off.encode()).aggregateFrequency, isTrue);
      expect(const SrsCardAppearance().aggregateFrequency, isTrue);
      expect(off == const SrsCardAppearance(), isFalse);
      expect(off.hashCode == const SrsCardAppearance().hashCode, isFalse);
      expect(
        srsCardAppearanceClasses(const SrsCardAppearance()).split(' '),
        contains('fushi-srs-freq-aggregate'),
      );
      expect(
        srsCardAppearanceClasses(off).split(' '),
        isNot(contains('fushi-srs-freq-aggregate')),
      );
    });

    test('偏好 JSON：往返一致；坏值 / 越界夹取；坏 JSON = 默认', () {
      const SrsCardAppearance a = SrsCardAppearance(
        textScale: 1.2,
        colorSource: SrsCardColorSource.custom,
        customAccent: 0xFF00696F,
        density: SrsCardDensity.compact,
        dictUnified: false,
        showSource: false,
      );
      expect(SrsCardAppearance.decode(a.encode()), a);
      expect(SrsCardAppearance.decode('not json'), const SrsCardAppearance());
      expect(SrsCardAppearance.decode(''), const SrsCardAppearance());
      final SrsCardAppearance clamped = SrsCardAppearance.fromJson(
        const <String, Object?>{
          'textScale': 9,
          'lineSpacing': 'x',
          'density': 'weird',
        },
      );
      expect(clamped.textScale, SrsCardAppearance.maxTextScale);
      expect(clamped.lineSpacing, 1);
      expect(clamped.density, SrsCardDensity.standard);
    });

    test('只换外观走换主题、不重放卡片', () async {
      final List<String> sent = <String>[];
      final SrsCardFaceSync sync = SrsCardFaceSync(
        evaluate: (String s) async {
          sent.add(s);
          return true;
        },
        reloadShell: () {},
      )..shellLoaded();
      SrsCardFaceDocument doc(SrsCardAppearance a) => SrsCardFaceDocument.of(
        SrsCardFace(
          cardId: 'c',
          showingAnswer: true,
          bodyHtml: '<b>x</b>',
          css: '.card{}',
          languageCode: 'ja',
          onBridgeKey: (_) {},
        ),
        dark: false,
        background: Colors.white,
        foreground: Colors.black,
        accent: Colors.teal,
        onAccent: Colors.white,
        mediaUrlPrefix: 'https://srs.local/media/',
        themedScrollbar: false,
        appearanceCss: _css(a),
        appearanceClasses: srsCardAppearanceClasses(a),
      );
      sync.update(doc(const SrsCardAppearance()));
      sync.update(
        doc(const SrsCardAppearance(textScale: 1.2, dictUnified: false)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sent, hasLength(2));
      expect(sent.last, contains('__fushiSrsSetTheme'));
      expect(sent.last, contains('--fushi-srs-text-scale:1.2;'));
      expect(sent.last, isNot(contains('__fushiSrsSetCard(')));
      expect(sent.last, isNot(contains('fushi-srs-dict-unified')));
    });
  });

  group('外观只作用于 Fushi 卡片', () {
    SrsCardFaceDocument docFor({required bool fushiCard}) =>
        srsCardFaceDocumentFor(
          SrsCardFace(
            cardId: 'c',
            showingAnswer: true,
            bodyHtml: '<b>x</b>',
            css: '.card{}',
            languageCode: 'ja',
            onBridgeKey: (_) {},
            fushiCard: fushiCard,
          ),
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          ),
          appearance: const SrsCardAppearance(
            colorSource: SrsCardColorSource.custom,
            customAccent: 0xFFB3261E,
            showPicture: false,
            // 设计系统样式覆盖另有专门测试（srs_card_design_skin_test.dart）；这里只看
            // Fushi 卡片专属的外观不外漏。
            designSkin: false,
          ),
          labels: _labels,
          mediaUrlPrefix: 'https://srs.local/media/',
          themedScrollbar: false,
          fontUrl: (String path) => path,
          fonts: const <Map<String, dynamic>>[
            <String, dynamic>{'name': 'Klee One'},
          ],
        );

    test('Fushi 卡片：变量 / 类名 / 字体 / 自定义配色都注入', () {
      final SrsCardFaceDocument d = docFor(fushiCard: true);
      expect(d.themeCss, contains('--fushi-srs-font-ja:"Klee One"'));
      expect(d.themeCss, contains('--fushi-srs-label-more:'));
      expect(d.classes, contains('fushi-srs-hide-picture'));
      expect(d.classes, contains('fushi-srs-dict-unified'));
    });

    test('Lapis / 自建类型：拿不到任何外观变量、类名与字体，配色就是 app 主题', () {
      final SrsCardFaceDocument d = docFor(fushiCard: false);
      expect(d.themeCss, isNot(contains('--fushi-srs-font')));
      expect(d.themeCss, isNot(contains('--fushi-srs-label')));
      expect(d.themeCss, isNot(contains('--fushi-srs-text-scale')));
      expect(d.themeCss, isNot(contains('@font-face')));
      expect(d.classes, isNot(contains('fushi-srs-')));
      final ColorScheme app = ColorScheme.fromSeed(seedColor: Colors.teal);
      expect(
        d.themeCss,
        contains(
          '--fushi-srs-accent:#${(app.primary.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
        ),
      );
    });

    test('底色：Fushi 卡片由宿主铺外观配色，其它类型宿主不铺、留给卡片 CSS', () {
      String hex(Color c) =>
          '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
      final ColorScheme custom = ColorScheme.fromSeed(
        seedColor: const Color(0xFFB3261E),
      );
      expect(
        docFor(fushiCard: true).themeCss,
        contains('html,body{background:${hex(custom.surface)};'),
      );
      // 模板 `.card` 写透明时要透出复习页背景（WebView 本身也是透明的），宿主不能
      // 再垫一层主题 surface。
      expect(
        docFor(fushiCard: false).themeCss,
        contains('html,body{background:transparent;'),
      );
    });
  });

  group('预览框（1:1 渲染，不缩放平台视图）', () {
    test('手机：宽 = min(390, 可用宽)，居中且对齐整设备像素，强制单栏', () {
      final SrsCardPreviewFrame narrow = srsCardPreviewFrame(
        SrsCardPreviewWidth.phone,
        availableWidth: 351.3,
        devicePixelRatio: 2,
      );
      expect(narrow.width, 351);
      expect(narrow.left, 0);
      expect(narrow.layout, SrsCardLayout.narrow);
      expect(narrow.pageZoom, isNull);
      final SrsCardPreviewFrame roomy = srsCardPreviewFrame(
        SrsCardPreviewWidth.phone,
        availableWidth: 861,
        devicePixelRatio: 1.25,
      );
      // 宽与左边距都落在整设备像素上（1.25 倍屏：390 → 389.6）。
      expect(roomy.width, closeTo(390, 0.8));
      expect(roomy.width * 1.25, (roomy.width * 1.25).roundToDouble());
      expect(roomy.left * 1.25, (roomy.left * 1.25).roundToDouble());
      expect(roomy.left, closeTo((861 - roomy.width) / 2, 0.8));
    });

    test('桌面：占满可用宽、强制双栏；比 760 窄时用页面内 zoom 模拟 1100 视口', () {
      final SrsCardPreviewFrame wide = srsCardPreviewFrame(
        SrsCardPreviewWidth.desktop,
        availableWidth: 840,
        devicePixelRatio: 1,
      );
      expect(wide.width, 840);
      expect(wide.layout, SrsCardLayout.wide);
      expect(wide.pageZoom, isNull);
      final SrsCardPreviewFrame phoneScreen = srsCardPreviewFrame(
        SrsCardPreviewWidth.desktop,
        availableWidth: 350,
        devicePixelRatio: 3,
      );
      expect(phoneScreen.pageZoom, closeTo(350 / 1100, 1e-6));
    });

    test('强制版式与 zoom 进外壳主题部分（换版式不重放卡片）', () {
      final SrsCardFace face = SrsCardFace(
        cardId: 'c',
        showingAnswer: true,
        bodyHtml: '<b>x</b>',
        css: '',
        languageCode: 'ja',
        onBridgeKey: (_) {},
      );
      SrsCardFaceDocument doc(SrsCardFace f) => SrsCardFaceDocument.of(
        f,
        dark: false,
        background: Colors.white,
        foreground: Colors.black,
        accent: Colors.teal,
        onAccent: Colors.white,
        mediaUrlPrefix: 'https://srs.local/media/',
        themedScrollbar: false,
      );
      final SrsCardFaceDocument wide = doc(
        face.withLayout(SrsCardLayout.wide, pageZoom: 0.5),
      );
      expect(wide.classes, contains('fushi-srs-layout-wide'));
      expect(wide.themeCss, contains('html{zoom:0.5000;}'));
      expect(doc(face).classes, isNot(contains('fushi-srs-layout')));
      expect(doc(face).themeCss, isNot(contains('zoom')));
    });
  });

  group('字体供给', () {
    late Directory root;
    late File good;
    late File junk;
    setUp(() {
      root = Directory.systemTemp.createTempSync('srs-fonts-');
      good = File(p.join(root.path, 'good.ttf'))
        ..writeAsBytesSync(<int>[0, 1, 0, 0, ...List<int>.filled(64, 7)]);
      junk = File(p.join(root.path, 'junk.ttf'))
        ..writeAsBytesSync(<int>[0x50, 0x4b, 3, 4, ...List<int>.filled(64, 1)]);
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<WebResourceResponse?> fetch(File f, Set<String> whitelist) =>
        srsCardFontResponse(
          Uri.parse(srsCardFontUrl(f.path, customScheme: false)),
          fontRoot: root.path,
          whitelist: whitelist,
        );

    test('字体目录内 + 外观引用 + 魔数对 → 200 带字节', () async {
      final WebResourceResponse? r = await fetch(good, <String>{
        p.canonicalize(good.path),
      });
      expect(r!.statusCode, 200);
      expect(r.data, isA<Uint8List>());
      expect(r.data!.length, 68);
    });

    test('外观没引用 / 魔数不对 / 目录外 → 404；不是字体 URL → null', () async {
      expect((await fetch(good, <String>{}))!.statusCode, 404);
      expect(
        (await fetch(junk, <String>{p.canonicalize(junk.path)}))!.statusCode,
        404,
      );
      final Directory other = Directory.systemTemp.createTempSync('srs-other-');
      addTearDown(() => other.deleteSync(recursive: true));
      final File outside = File(p.join(other.path, 'x.ttf'))
        ..writeAsBytesSync(good.readAsBytesSync());
      expect(
        (await fetch(outside, <String>{
          p.canonicalize(outside.path),
        }))!.statusCode,
        404,
      );
      expect(
        await srsCardFontResponse(
          Uri.parse('https://srs.local/media/a.png'),
          fontRoot: root.path,
          whitelist: const <String>{},
        ),
        isNull,
      );
    });
  });

  group('外观定制页', () {
    for (final bool apple in <bool>[false, true]) {
      for (final Size size in <Size>[
        const Size(1280, 900),
        const Size(390, 844),
      ]) {
        final String label =
            '${apple ? 'Apple' : 'MD3'} ${size.width.toInt()}x${size.height.toInt()}';
        testWidgets('[$label] 控件改动即时更新预览、不溢出', (WidgetTester tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
            () => openSrsTestStore(),
          ))!;
          addTearDown(() => tester.runAsync(db.close));
          final _AppearanceApp app = _AppearanceApp();
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                appProvider.overrideWith((Ref ref) => app),
                srsStoreProvider.overrideWith((Ref ref) async => store),
                srsCardFontRootProvider.overrideWithValue(null),
                // 预览卡面：显示当前外观注入的宿主类名（WebView 卡面在测试里没有）。
                srsCardFaceBuilderProvider.overrideWithValue(
                  (BuildContext context, SrsCardFace face) => Consumer(
                    builder: (BuildContext context, WidgetRef ref, _) => Text(
                      'face:${face.layout.name}:'
                      '${face.showingAnswer ? 'back' : 'front'}:'
                      '${srsCardAppearanceClasses(ref.watch(srsCardAppearanceProvider))}',
                      key: const ValueKey<String>('preview-face'),
                    ),
                  ),
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
                  home: const SrsCardAppearancePage(),
                ),
              ),
            ),
          );
          for (int i = 0; i < 8; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
            await tester.pump(const Duration(milliseconds: 80));
          }
          expect(tester.takeException(), isNull);
          String faceText() => tester
              .widget<Text>(find.byKey(const ValueKey<String>('preview-face')))
              .data!;
          final String layout = size.width >= 840 ? 'wide' : 'narrow';
          expect(
            faceText(),
            'face:$layout:back:fushi-srs-dict-unified fushi-srs-freq-aggregate',
          );
          expect(
            find.byKey(const ValueKey<String>('srs-card-preview-frame')),
            findsOneWidget,
          );
          // 预览链路里不许缩放卡面平台视图（缩放纹理 = 文字发糊）。
          final Finder faceFinder = find.byKey(
            const ValueKey<String>('preview-face'),
          );
          expect(
            find.ancestor(of: faceFinder, matching: find.byType(FittedBox)),
            findsNothing,
          );
          for (final Transform tr in tester.widgetList<Transform>(
            find.ancestor(of: faceFinder, matching: find.byType(Transform)),
          )) {
            expect(tr.transform.isIdentity(), isTrue);
          }
          // 卡面框左缘落在整设备像素上。
          final double left = tester
              .getTopLeft(
                find.byKey(const ValueKey<String>('srs-card-preview-frame')),
              )
              .dx;
          expect(left, left.roundToDouble());

          // 关掉统一词典样式：偏好立即变、预览立即跟。
          final Finder unify = find.byKey(
            const ValueKey<String>('srs-card-dict-unified'),
          );
          await tester.scrollUntilVisible(
            unify,
            200,
            scrollable: find
                .descendant(
                  of: find.byKey(
                    const ValueKey<String>('srs-card-appearance-controls'),
                  ),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          // 直接走开关行的 onChanged（与点按同一条路径：写偏好 → provider → 预览）。
          tester.widget<AdaptiveSettingsSwitchRow>(unify).onChanged!(false);
          await tester.pump(const Duration(milliseconds: 300));
          expect(app.value.dictUnified, isFalse);
          expect(faceText(), 'face:$layout:back:fushi-srs-freq-aggregate');

          // 预览与复习页一样走 Fushi 卡片的混合渲染：上面的卡面是释义区 WebView。
          expect(
            find.byKey(const ValueKey<String>('srs-card-preview-native')),
            findsOneWidget,
          );
          // 正面 / 背面切换：正面完全原生，释义 WebView 不在台面上（保活在 Offstage 里）。
          await tester.tap(find.text(t.srs_card_appearance_preview_front));
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.byKey(const ValueKey<String>('srs-fushi-front')),
            findsOneWidget,
          );
          expect(faceFinder, findsNothing);
          expect(tester.takeException(), isNull);

          // 卡面字体一行 → 统一字体库，用途预选「复习卡片」。
          if (!apple && size.width >= 840) {
            final Finder fontRow = find.byKey(
              const ValueKey<String>('srs-card-font-library'),
            );
            await tester.scrollUntilVisible(
              fontRow,
              -200,
              scrollable: find
                  .descendant(
                    of: find.byKey(
                      const ValueKey<String>('srs-card-appearance-controls'),
                    ),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            // 与点按同一条路径：行的 onTap → 推字体库页。
            tester.widget<AdaptiveSettingsNavigationRow>(fontRow).onTap();
            for (int i = 0; i < 6; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(
              find.byWidgetPredicate(
                (Widget w) =>
                    w is CustomFontsPage && w.target == FontTarget.srsCard,
              ),
              findsOneWidget,
            );
            tester.takeException();
          }
        });
      }
    }
  });
}
