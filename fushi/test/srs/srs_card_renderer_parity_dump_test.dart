// 卡面渲染器对照导出（只在设了 FUSHI_SRS_FACE_PARITY_OUT 目录时导出，平时空跑）。
//
// 三套卡面（整面 WebView / 原生 Fushi 混合 / 原生 HTML）共用的预处理与原生绘制收敛前后，
// 用同一批真实模板各导出一份，两份目录逐字节相同 = 渲染结果没变：
//   FUSHI_SRS_FACE_PARITY_OUT=<目录> flutter test test/srs/srs_card_renderer_parity_dump_test.dart
//   （改动前后各跑一次，`diff -r` 两个目录）
//
// 每张样例卡导出：
// - `route.txt`：srsCardFaceRoute 的路线与回退原因；
// - `host.txt`：宿主侧的媒体清单（自动播放 / 重播 / 远程预取读的那几份）；
// - `webdoc-*.txt`：整面 WebView 外壳收到的文档（主题样式、类名、卡片样式、正文、正文样式、
//   完整下发脚本）——页面 DOM 由它唯一决定；原生 Fushi 卡面另导出释义区那一份；
// - 原生路线：每个「面 × 明暗 × 宽度」一份渲染树（`*.render.txt`）、组件树（`*.widgets.txt`）
//   与真实像素截图（`*.png`，字体用 Windows 字体目录里的 Noto Sans JP，
//   目录见 FUSHI_SRS_SHOT_FONT_DIR）。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/pages/implementations/srs/srs_html_card_view.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart';
import 'package:fushi/src/srs/srs_card_face_route.dart';
import 'package:fushi/src/srs/srs_card_media.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_fushi_card_plan.dart';
import 'package:fushi/src/srs/srs_html_card.dart';
import 'package:fushi/src/srs/srs_native_template.dart'
    show kSrsNativeTemplateMarker;
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart'
    show kSrsBuiltinFushiCardKey, kSrsBuiltinLapisKey;
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsRenderedCard;
import 'package:fushi_engine/srs/srs_fushi_card_native_media.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_real_card_samples.dart';

class _App extends AppModel {
  _App(this.appearance) : super(testPlatformServices());

  final SrsCardAppearance appearance;

  @override
  SrsCardAppearance get srsCardAppearance => appearance;
}

/// 一张样例卡：渲染结果 + 是不是内置 Fushi 卡片。
class _Sample {
  const _Sample(this.name, this.rendered, {this.fushiCard = false});

  final String name;
  final SrsRenderedCard rendered;
  final bool fushiCard;
}

/// 与 `SrsDbStore.renderCard` 同一条流水：模板渲染 → 打字输入答案 → 原生 Fushi 判据。
SrsRenderedCard _render({
  required String front,
  required String back,
  required String css,
  required Map<String, String> fields,
  String? builtinKey,
  bool isCloze = false,
  int cardOrd = 0,
}) {
  final AnkiRenderedCard r = renderAnkiCard(
    questionTemplate: front,
    answerTemplate: back,
    noteFields: fields,
    cardOrd: cardOrd,
    isCloze: isCloze,
  );
  final ({String question, String answer}) faces = ankiResolveTypeAnswer(
    question: r.question,
    answer: r.answer,
    fields: fields,
    cardOrd: cardOrd,
  );
  final SrsFushiCardNativeProbe probe = srsFushiCardNative(
    builtinKey: builtinKey,
    front: front,
    back: back,
    css: css,
    fieldsByName: fields,
    cardOrd: isCloze ? 0 : cardOrd,
  );
  final SrsFushiCardNative? native = probe.native;
  return SrsRenderedCard(
    question: faces.question,
    answer: faces.answer,
    css: native?.css ?? css,
    isEmpty: r.isEmpty,
    fields: fields,
    fushiCardDefinitions: native?.definitions,
    fushiCardFront: native?.front ?? const <FushiCardItem>[],
    fushiCardBack: native?.back ?? const <FushiCardItem>[],
    nativeFallback: probe.fallback,
  );
}

SrsRenderedCard _prerendered(String question, String answer, String css) =>
    SrsRenderedCard(
      question: question,
      answer: answer,
      css: css,
      isEmpty: false,
      nativeFallback: const SrsCardNativeFallback(
        SrsCardNativeFallbackCode.notBuiltin,
      ),
    );

SrsRenderedCard _fushi(Map<String, String> extra) => _render(
  front: FushiCardNoteType.template.front,
  back: FushiCardNoteType.template.back,
  css: FushiCardNoteType.template.css,
  builtinKey: kSrsBuiltinFushiCardKey,
  fields: <String, String>{
    ...srsSampleCardFields(),
    'TermAudio': '[sound:kayou.mp3]',
    'SentenceAudio': '[sound:kayou_sentence.mp3]',
    ...extra,
  },
);

List<_Sample> _samples() {
  final SrsRenderedCard fushi = _fushi(const <String, String>{});
  final Map<String, String> lapis = <String, String>{
    for (final String f in LapisNoteType.fields) f: '',
    'Expression': '通う',
    'ExpressionFurigana': '通[かよ]う',
    'ExpressionReading': 'かよう',
    'ExpressionAudio': '[sound:kayou.mp3]',
    'MainDefinition': kSrsSampleMainDefinition,
    'Sentence': '毎日のように図書館に<b>通って</b>いる。',
    'SentenceFurigana': '毎日[まいにち]のように 図書館[としょかん]に<b>通[かよ]って</b>いる。',
    'SentenceAudio': '[sound:kayou_sentence.mp3]',
    'Picture': '<img src="kayou.webp">',
    'Glossary': kSrsSampleGlossary,
    'IsWordAndSentenceCard': 'x',
  };
  const Map<String, String> basic = <String, String>{
    'Front': '図書館<br>[sound:toshokan.mp3]',
    'Back':
        '<b>としょかん</b> · library<br><img src="toshokan.png">'
        '<div style="color:#888;font-size:14px">毎日 <ruby>図書館<rt>としょかん</rt></ruby> '
        'に<u>通って</u>いる。</div>[sound:toshokan_sentence.mp3]',
  };
  return <_Sample>[
    // ------------------------------------------------ 内置 Fushi 卡片
    _Sample('fushi-default', fushi, fushiCard: true),
    // 字段里的文件名带实体（Anki 把 `&` 存成 `&amp;`）。
    _Sample(
      'fushi-audio-entity',
      _fushi(const <String, String>{
        'TermAudio': '[sound:Tom &amp; Jerry.mp3]',
        'SentenceAudio': '[sound: spaced name.mp3 ]',
      }),
      fushiCard: true,
    ),
    // 自定义区块（字段区块 + HTML 区块）：原生 Fushi 卡面里嵌原生 HTML 片段。
    _Sample(
      'fushi-custom-blocks',
      SrsRenderedCard(
        question: fushi.question,
        answer: fushi.answer,
        css: fushi.css,
        isEmpty: false,
        fields: fushi.fields,
        fushiCardDefinitions: fushi.fushiCardDefinitions,
        fushiCardFront: fushi.fushiCardFront,
        fushiCardBack: <FushiCardItem>[
          ...fushi.fushiCardBack,
          const FushiCardHtmlItem(
            '<div style="padding:8px;border:1px solid #ccc;border-radius:6px">'
            '笔记：<ruby>図書館<rt>としょかん</rt></ruby> に <b>通う</b> '
            '[sound:note.mp3]</div>',
          ),
        ],
      ),
      fushiCard: true,
    ),
    // 样式改过：引擎不给布局，整面 WebView（同一份模板）。
    _Sample(
      'fushi-css-modified',
      _render(
        front: FushiCardNoteType.template.front,
        back: FushiCardNoteType.template.back,
        css: '${FushiCardNoteType.template.css}\n.card{letter-spacing:1px;}',
        builtinKey: kSrsBuiltinFushiCardKey,
        fields: fushi.fields,
      ),
      fushiCard: true,
    ),
    // ------------------------------------------------ Lapis（脚本模板，整面 WebView）
    _Sample(
      'lapis',
      _render(
        front: LapisNoteType.template.front,
        back: LapisNoteType.template.back,
        css: LapisNoteType.template.css,
        builtinKey: kSrsBuiltinLapisKey,
        fields: lapis,
      ),
    ),
    // ------------------------------------------------ Anki 自带类型
    _Sample(
      'anki-basic',
      _render(
        front: kSampleAnkiBasicFront,
        back: kSampleAnkiBasicBack,
        css: kSampleAnkiBasicCss,
        fields: basic,
      ),
    ),
    _Sample(
      'anki-basic-reversed-card2',
      _render(
        front: kSampleAnkiReversedFront,
        back: kSampleAnkiReversedBack,
        css: kSampleAnkiBasicCss,
        fields: basic,
        cardOrd: 1,
      ),
    ),
    _Sample(
      'anki-basic-type-answer',
      _render(
        front: kSampleAnkiTypeFront,
        back: kSampleAnkiTypeBack,
        css: kSampleAnkiBasicCss,
        fields: const <String, String>{'Front': '図書館', 'Back': 'としょかん'},
      ),
    ),
    _Sample(
      'anki-cloze',
      _render(
        front: kSampleAnkiClozeFront,
        back: kSampleAnkiClozeBack,
        css: kSampleAnkiClozeCss,
        fields: const <String, String>{
          'Text':
              '毎日のように{{c1::図書館::場所}}に{{c2::通って}}いる。'
              '[sound:cloze.mp3]',
          'Back Extra': '<i>library</i> / <b>commute</b>',
        },
        isCloze: true,
      ),
    ),
    // 文件名带实体 / 首尾空格 / 同名重复的 `[sound:]`。
    _Sample(
      'anki-basic-sound-entity',
      _render(
        front: kSampleAnkiBasicFront,
        back: kSampleAnkiBasicBack,
        css: kSampleAnkiBasicCss,
        fields: const <String, String>{
          'Front': 'Tom &amp; Jerry[sound:Tom &amp; Jerry.mp3]',
          'Back':
              '[sound: spaced name.mp3 ][sound:Tom &amp; Jerry.mp3]'
              '[sound:a&lt;b&gt;&quot;c&#39;.mp3]',
        },
      ),
    ),
    // ------------------------------------------------ 用户真实牌组的卡面
    _Sample(
      'kaishi',
      _prerendered(
        kSampleKaishiQuestion,
        kSampleKaishiAnswer,
        kSampleKaishiCss,
      ),
    ),
    _Sample(
      'grammar-onigiri-back',
      _prerendered(kSampleGrammarBack, kSampleGrammarBack, kSampleGrammarCss),
    ),
    _Sample(
      'jlpt-n1',
      _prerendered(kSampleJlptBack, kSampleJlptBack, kSampleJlptCss),
    ),
    // 模板标了「原生渲染」：画不了的块就地提示。
    _Sample(
      'native-marked-table',
      _prerendered(
        '$kSrsNativeTemplateMarker\n<div>猫[sound:neko.mp3]</div>\n'
            '<table><tr><td>表格内容</td></tr></table>',
        '$kSrsNativeTemplateMarker\n<div>猫[sound:neko.mp3]</div>\n'
            '<table><tr><td>表格内容</td></tr></table><div>cat</div>',
        '',
      ),
    ),
  ];
}

ThemeData _theme({required bool dark}) => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF386A58),
    brightness: dark ? Brightness.dark : Brightness.light,
  ),
  textTheme: dark
      ? Typography.material2021().white
      : Typography.material2021().black,
  designSystem: FushiDesignSystem.material,
  glass: FushiGlassMaterial.off,
  glassDesign: false,
);

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final FontLoader loader = FontLoader(family);
    for (final String path in paths) {
      final File f = File(path);
      if (!f.existsSync()) continue;
      loader.addFont(
        Future<ByteData>.value(ByteData.sublistView(await f.readAsBytes())),
      );
    }
    await loader.load();
  }

  final String fonts =
      Platform.environment['FUSHI_SRS_SHOT_FONT_DIR'] ?? r'C:\Windows\Fonts';
  final String sep = Platform.pathSeparator;
  for (final String family in <String>['Roboto', '.SF Pro Text', 'Noto']) {
    await load(family, <String>[
      '$fonts${sep}NotoSansJP-Regular.otf',
      '$fonts${sep}NotoSansJP-Bold.otf',
    ]);
  }
  for (final String family in <String>['FushiSymbols', 'FushiSymbolsFilled']) {
    await load(family, <String>[
      'assets/icon_fonts/${family == 'FushiSymbols' ? 'FushiSymbolsRounded' : 'FushiSymbolsRoundedFilled'}.ttf',
    ]);
  }
}

/// 树的文字导出里与内容无关的部分：对象身份哈希、闭包的来源函数名、导出目录（图片的
/// 本地路径里带着它）。
String _stable(String dump, String out) => dump
    .replaceAll(RegExp(r'#[0-9a-f]{5}\b'), '#')
    .replaceAll(RegExp(r'Closure: [^\n]*'), 'Closure')
    .replaceAll(out, '<out>');

SrsCardFace _face(
  _Sample s, {
  required bool answer,
  String? body,
  void Function(List<String>)? onPlayAudio,
}) => SrsCardFace(
  cardId: s.name,
  showingAnswer: answer,
  bodyHtml: body ?? (answer ? s.rendered.answer : s.rendered.question),
  css: s.rendered.css,
  languageCode: 'ja',
  onBridgeKey: (_) {},
  fushiCard: s.fushiCard,
  onPlayAudio: onPlayAudio,
);

String _webDocument(SrsCardFace face, {required bool dark}) {
  final SrsCardFaceDocument d = srsCardFaceDocumentFor(
    face,
    theme: _theme(dark: dark),
    appearance: const SrsCardAppearance(),
    labels: srsCardLabels(),
    mediaUrlPrefix: srsMediaUrlPrefix(customScheme: false),
    themedScrollbar: true,
    fontUrl: (String path) => 'font://$path',
  );
  return <String>[
    '== classes\n${d.classes}',
    '== lang\n${d.lang}',
    '== themeCss\n${d.themeCss}',
    '== cardCss\n${d.cardCss}',
    '== bodyStyles (${d.bodyStyles.length})\n${d.bodyStyles.join('\n----\n')}',
    '== bodyHtml\n${d.bodyHtml}',
    '== hostScript\n${d.hostScript}',
    '== fullCardScript\n${d.fullCardScript}',
    '== shellHtml\n${d.shellHtml}',
  ].join('\n\n');
}

/// 一张 4×4 的 PNG（样例卡引用的图片文件都用它，测的是版式不是图片内容）。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEklEQVR4nGNoaPgPRwzEcQCukw/x0F8jngAAAABJRU5ErkJggg==',
);

void main() {
  final String? out = Platform.environment['FUSHI_SRS_FACE_PARITY_OUT'];
  if (out == null || out.isEmpty) {
    test(
      'card renderer parity dump (only with FUSHI_SRS_FACE_PARITY_OUT)',
      () {},
    );
    return;
  }
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  final Directory mediaDir = Directory('$out/_media')
    ..createSync(recursive: true);
  for (final String name in <String>[
    'toshokan.png',
    'kayou.webp',
    '36c069fec673d92a00e09c6c166dd8aeaa82f018.webp',
  ]) {
    File('${mediaDir.path}/$name').writeAsBytesSync(_png);
  }
  final SrsMediaStore store = SrsMediaStore(mediaDir);

  void write(String sample, String file, String text) {
    final File f = File('$out/$sample/$file');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  for (final _Sample s in _samples()) {
    final SrsRenderedCard r = s.rendered;
    final SrsCardFaceRoute route = srsCardFaceRoute(
      r,
      fushiCard: s.fushiCard,
      languageCode: 'ja',
    );

    test('${s.name}: 路线、宿主媒体清单、WebView 文档', () {
      write(s.name, 'route.txt', switch (route) {
        SrsCardFaceFushiNative() => 'fushi-native',
        SrsCardFaceHtmlNative() => 'html-native',
        SrsCardFaceWeb(:final SrsCardNativeFallback fallback) =>
          'web: $fallback',
      });
      final StringBuffer host = StringBuffer();
      for (final bool inline in <bool>[false, true]) {
        host
          ..writeln('== inlineMedia=$inline')
          ..writeln(
            'autoplay question: ${srsAutoplaySounds(questionHtml: r.question, answerHtml: r.answer, answerSide: false, inlineMedia: inline)}',
          )
          ..writeln(
            'autoplay answer: ${srsAutoplaySounds(questionHtml: r.question, answerHtml: r.answer, answerSide: true, inlineMedia: inline)}',
          )
          ..writeln(
            'replay answer (+question): ${srsReplaySounds(questionHtml: r.question, answerHtml: r.answer, answerSide: true, includeQuestion: true, inlineMedia: inline)}',
          )
          ..writeln(
            'replay answer (only): ${srsReplaySounds(questionHtml: r.question, answerHtml: r.answer, answerSide: true, includeQuestion: false, inlineMedia: inline)}',
          );
      }
      host
        ..writeln('== srsCardSoundNames')
        ..writeln('question: ${srsCardSoundNames(r.question)}')
        ..writeln('answer: ${srsCardSoundNames(r.answer)}')
        ..writeln('== srsCardReferencedMedia')
        ..writeln(
          (srsCardReferencedMedia(
            '${r.css}\n${r.question}\n${r.answer}',
          ).toList()..sort()).join('\n'),
        );
      if (route is SrsCardFaceFushiNative) {
        final SrsFushiCardPlan plan = srsFushiCardPlan(
          r.fields,
          const SrsCardAppearance(),
          front: r.fushiCardFront,
          back: r.fushiCardBack,
        );
        host
          ..writeln('== srsFushiCardPlan.media')
          ..writeln('front: ${plan.media.front}')
          ..writeln('back: ${plan.media.back}')
          ..writeln('word: ${plan.media.word}')
          ..writeln('sentence: ${plan.media.sentence}')
          ..writeln('clip: ${plan.media.clip}')
          ..writeln('companionSentence: ${plan.media.companionSentence}');
      }
      if (route is SrsCardFaceHtmlNative) {
        for (final bool answer in <bool>[false, true]) {
          for (final bool dark in <bool>[false, true]) {
            host.writeln(
              'srsHtmlVisibleSounds ${answer ? 'answer' : 'question'} '
              '${dark ? 'dark' : 'light'}: ${srsHtmlVisibleSounds(route.card.face(answerSide: answer).layout(dark: dark, foreground: dark ? 0xFFFFFFFF : 0xFF000000))}',
            );
          }
        }
      }
      write(s.name, 'host.txt', host.toString());
      for (final bool answer in <bool>[false, true]) {
        for (final bool dark in <bool>[false, true]) {
          write(
            s.name,
            'webdoc-${answer ? 'answer' : 'question'}-${dark ? 'dark' : 'light'}.txt',
            _webDocument(_face(s, answer: answer), dark: dark),
          );
        }
      }
      final String? defs = r.fushiCardDefinitions;
      if (defs != null) {
        for (final bool dark in <bool>[false, true]) {
          write(
            s.name,
            'webdoc-definitions-${dark ? 'dark' : 'light'}.txt',
            _webDocument(_face(s, answer: true, body: defs), dark: dark),
          );
        }
      }
    });

    if (route is SrsCardFaceWeb) continue;
    for (final (String variant, Size size, bool dark) in <(String, Size, bool)>[
      ('phone-light', const Size(412, 915), false),
      ('phone-dark', const Size(412, 915), true),
      ('desktop-light', const Size(1100, 760), false),
    ]) {
      for (final bool answer in <bool>[false, true]) {
        final String tag = '${answer ? 'answer' : 'question'}-$variant';
        testWidgets('${s.name}: 原生卡面 $tag', (WidgetTester tester) async {
          await tester.runAsync(_loadFonts);
          const double dpr = 2;
          tester.view.physicalSize = size * dpr;
          tester.view.devicePixelRatio = dpr;
          addTearDown(tester.view.reset);
          final GlobalKey boundary = GlobalKey();
          final List<SrsCardFace> defsFaces = <SrsCardFace>[];
          final List<List<String>> played = <List<String>>[];
          final SrsCardFace face = _face(
            s,
            answer: answer,
            onPlayAudio: played.add,
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                appProvider.overrideWith(
                  (Ref ref) => _App(const SrsCardAppearance()),
                ),
                srsMediaStoreProvider.overrideWith(
                  (Ref ref) async => store as SrsMediaStore?,
                ),
                // 释义区在 widget 测试里没有 WebView：画成占位框，它收到的那面卡另导出文档。
                srsCardFaceBuilderProvider.overrideWithValue((
                  BuildContext context,
                  SrsCardFace defs,
                ) {
                  defsFaces.add(defs);
                  final ColorScheme c = Theme.of(context).colorScheme;
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      border: Border.all(color: c.outline, width: 1.5),
                      borderRadius: BorderRadius.circular(20),
                      color: c.surfaceContainerLow,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'definitions WebView (${defs.layout.name})',
                      style: TextStyle(color: c.onSurfaceVariant, fontSize: 14),
                    ),
                  );
                }),
              ],
              child: TranslationProvider(
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: _theme(dark: dark),
                  builder: (BuildContext context, Widget? child) =>
                      FushiGlassScope(child: child!),
                  home: RepaintBoundary(
                    key: boundary,
                    child: Scaffold(
                      body: SafeArea(
                        child: route is SrsCardFaceHtmlNative
                            ? SrsHtmlCardView(
                                face: face,
                                source: route.card.face(answerSide: answer),
                              )
                            : SrsFushiCardView(
                                face: face,
                                fields: r.fields,
                                definitionsHtml: r.fushiCardDefinitions!,
                                front: r.fushiCardFront,
                                back: r.fushiCardBack,
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
          if (defsFaces.isNotEmpty) defsFaces.last.onContentHeight?.call(360);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 900));
          // 图片解码要真异步（FakeAsync 里 FileImage 永远读不完）。
          for (int i = 0; i < 4; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 150)),
            );
            await tester.pump();
          }
          expect(tester.takeException(), isNull);
          final RenderRepaintBoundary rb =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          write(s.name, '$tag.render.txt', _stable(rb.toStringDeep(), out));
          write(
            s.name,
            '$tag.widgets.txt',
            _stable(tester.element(find.byKey(boundary)).toStringDeep(), out),
          );
          if (defsFaces.isNotEmpty) {
            final SrsCardFace d = defsFaces.last;
            write(
              s.name,
              '$tag.defs-face.txt',
              'layout: ${d.layout.name}\nfushiCard: ${d.fushiCard}\n'
                  'showingAnswer: ${d.showingAnswer}\nhostCss: ${d.hostCss}\n'
                  'hostScript: ${d.hostScript}\n== css\n${d.css}\n'
                  '== bodyHtml\n${d.bodyHtml}',
            );
          }
          await tester.runAsync(() async {
            final ui.Image image = await rb.toImage(pixelRatio: dpr);
            final ByteData? png = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            File(
              '$out/${s.name}/$tag.png',
            ).writeAsBytesSync(png!.buffer.asUint8List());
          });
          // 卡面上的每颗发音键点一下：交给宿主播放序列的名字（与画出来的同一份）。
          final List<String> taps = <String>[];
          for (final Element e in find.byTooltip('Play').evaluate().toList()) {
            played.clear();
            await tester.ensureVisible(find.byWidget(e.widget));
            await tester.pump();
            await tester.tap(find.byWidget(e.widget), warnIfMissed: false);
            await tester.pump();
            taps.add(played.toString());
          }
          write(s.name, '$tag.sound-taps.txt', taps.join('\n'));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
