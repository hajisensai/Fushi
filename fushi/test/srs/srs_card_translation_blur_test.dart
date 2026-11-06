import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/srs/srs_card_translation_blur.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiEinkTheme;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart'
    show FushiMotion;
import 'package:material_ui/material_ui.dart';

import '../helpers/node_runtime.dart';

/// 「例句翻译模糊、点按显示」的模板卡面一腿（[SrsCardAppearance.blurTranslation]，#2665）：
/// 与原生 Fushi 卡片视图同一套规则。
/// - 宿主类名 / 样式 / 页内脚本只在 Fushi 卡片 + 开关开着（且显示翻译）时下发（关 = 零注入）；
/// - 墨水屏挂 [kSrsCardNoMotionClass]，过渡瞬间到位；
/// - 外壳在换卡 / 换主题后调用脚本的装饰钩子；取词脚本认点按归属与模糊判定；
/// - 行为在真实 Chrome 里跑（外壳 HTML + 真实 Fushi 卡片模板样式 + 取词脚本）。
const SrsCardLabels _labels = SrsCardLabels(
  allDefinitions: 'all',
  frequency: 'freq',
  source: 'src',
);

const String _body =
    '<div class="fc fc-back" lang="ja">'
    '<div class="fc-sentence">ほぼ毎日図書館に行く。</div>'
    '<div class="fc-translation" lang="">I go to the library almost every day.</div>'
    '</div>';

String _templateCss() => File(
  '../packages/fushi_anki/templates/fushi_card/styling.css',
).readAsStringSync();

ThemeData _theme({bool eink = false}) => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
  extensions: <ThemeExtension<dynamic>>[if (eink) const FushiEinkTheme(true)],
);

SrsCardFaceDocument _doc({
  bool blur = true,
  bool showTranslation = true,
  bool fushiCard = true,
  bool eink = false,
  String cardId = 'c1',
  String? css,
}) => srsCardFaceDocumentFor(
  SrsCardFace(
    cardId: cardId,
    showingAnswer: true,
    bodyHtml: _body,
    css: css ?? '',
    languageCode: 'ja',
    onBridgeKey: (_) {},
    // 预览 / 模板编辑器口径（不桥 Enter / 空格）：键盘切换由页内脚本处理。复习页把这两个键
    // 桥给宿主做翻面 / 评分，与模板里其它可聚焦按钮一样由桥优先。
    bridgeKeys: const <String>[],
    fushiCard: fushiCard,
  ),
  theme: _theme(eink: eink),
  appearance: SrsCardAppearance(
    blurTranslation: blur,
    showTranslation: showTranslation,
  ),
  labels: _labels,
  mediaUrlPrefix: 'https://srs.local/media/',
  themedScrollbar: false,
  fontUrl: (String path) => path,
);

void main() {
  final NodeTestRuntime browserRuntime = NodeTestRuntime.probe(
    needsChrome: true,
  );

  group('外壳文档：开 / 关', () {
    test('开：类名、样式、页内脚本都下发', () {
      final SrsCardFaceDocument d = _doc();
      expect(d.classes.split(' '), contains(kSrsCardBlurTranslationClass));
      expect(d.themeCss, contains(kSrsCardTranslationBlurCss));
      expect(d.hostScript, contains(kSrsCardTranslationBlurScript));
    });

    test('关 / 翻译不显示：零注入', () {
      for (final SrsCardFaceDocument d in <SrsCardFaceDocument>[
        _doc(blur: false),
        _doc(showTranslation: false),
      ]) {
        expect(d.classes, isNot(contains(kSrsCardBlurTranslationClass)));
        expect(d.themeCss, isNot(contains(kSrsCardTranslationRevealedClass)));
        expect(d.hostScript, isNot(contains('__fushiSrsTranslationBlur')));
      }
    });

    test('非 Fushi 卡片拿不到外观：不挂类名、不下发脚本', () {
      final SrsCardFaceDocument d = _doc(fushiCard: false);
      expect(d.classes, isNot(contains(kSrsCardBlurTranslationClass)));
      expect(d.hostScript, isNot(contains('__fushiSrsTranslationBlur')));
    });

    test('墨水屏：挂无动效类名，样式里过渡归零', () {
      expect(
        _doc(eink: true).classes.split(' '),
        contains(kSrsCardNoMotionClass),
      );
      expect(_doc().classes, isNot(contains(kSrsCardNoMotionClass)));
      expect(
        kSrsCardTranslationBlurCss,
        contains('.$kSrsCardNoMotionClass $kSrsCardTranslationSelector'),
      );
      expect(kSrsCardTranslationBlurCss, contains('prefers-reduced-motion'));
    });

    test('外观样式只在开关开着时带模糊规则', () {
      String css(SrsCardAppearance a) => srsCardAppearanceCss(
        appearance: a,
        appScheme: _theme().colorScheme,
        tokens: SrsCardTokens.fromTheme(_theme()),
        dark: false,
        labels: _labels,
        fontUrl: (String p) => p,
      );
      expect(
        css(const SrsCardAppearance(blurTranslation: true)),
        contains(kSrsCardTranslationBlurCss),
      );
      expect(
        css(const SrsCardAppearance()),
        isNot(contains(kSrsCardBlurTranslationClass)),
      );
    });
  });

  group('接线', () {
    test('外壳在换卡（钩子之后）与换主题后调用装饰钩子', () {
      final int finish = kSrsCardShellScript.indexOf('function finish(');
      expect(
        kSrsCardShellScript.indexOf('translationBlur();', finish),
        greaterThan(finish),
      );
      final int setTheme = kSrsCardShellScript.indexOf(
        'window.__fushiSrsSetTheme',
      );
      expect(
        kSrsCardShellScript.indexOf('translationBlur();', setTheme),
        greaterThan(setTheme),
      );
    });

    test('取词脚本认点按归属与模糊判定；宿主侧取词调用带同一判定', () {
      expect(kSrsCardLookupScript, contains('window.__fushiSrsTapConsumed'));
      expect(
        kSrsCardLookupScript,
        contains('window.__fushiSrsTranslationBlocksLookup(x, y)'),
      );
      final String host = srsCardSelectInvocation(
        3.5,
        4.5,
        400,
        fromHover: false,
      );
      expect(
        host,
        startsWith(
          'if (!(window.__fushiSrsTranslationBlocksLookup && '
          'window.__fushiSrsTranslationBlocksLookup(3.5, 4.5)))',
        ),
      );
      expect(host, contains('window.fushiSelection.selectText(3.5, 4.5, 400'));
    });
  });

  test(
    '真实 Chrome：默认模糊、点开不查词、字上查词、字外再模糊、键盘切换、换卡复位、关掉复原',
    () async {
      final String node = browserRuntime.requireNode();
      final String css = _templateCss();
      final SrsCardFaceDocument on = _doc(css: css);
      final SrsCardFaceDocument next = _doc(css: css, cardId: 'c2');
      final SrsCardFaceDocument off = _doc(css: css, blur: false);
      final SrsCardFaceDocument eink = _doc(css: css, eink: true);
      final Directory temp = Directory.systemTemp.createTempSync('srs-blur-');
      try {
        final File payload = File('${temp.path}/payload.json')
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'shell': on.shellHtml,
              'calls': on.hostScript + on.fullCardScript,
              'lookup':
                  kSrsCardLookupScript +
                  srsCardLookupGateScript(
                    tap: true,
                    hover: false,
                    hostHover: false,
                    open: false,
                  ),
              'nextCard': next.fullCardScript,
              'offTheme': srsCardSetThemeScript(
                themeCss: off.themeCss,
                classes: off.classes,
              ),
              'einkShell': eink.shellHtml,
              'einkCalls': eink.hostScript + eink.fullCardScript,
              'hostSelect': srsCardSelectInvocation(
                1234.5,
                6789.5,
                400,
                fromHover: false,
              ),
              'durationMs': FushiMotion.short.inMilliseconds,
            }),
          );
        final ProcessResult result = await Process.run(node, <String>[
          'test/srs/srs_card_translation_blur_harness.mjs',
          payload.path,
        ]).timeout(const Duration(seconds: 80));
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('PASS 3 browser cases'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: browserRuntime.skipReason,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
