import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_design_skin.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:material_ui/material_ui.dart';

/// 卡面「跟随设计系统」样式覆盖（[SrsCardAppearance.designSkin]）：
/// - 开 / 关两态生成的外壳文档（关 = 零注入：主题样式、类名、外壳 HTML、下发脚本里都没有覆盖）；
/// - 只作用于非 Fushi 卡片；MD3 / Apple 取各自的形状令牌与字体；
/// - 切换只走换主题（不重放卡片），关掉时外壳里已定义的判定脚本会被调用来复原；
/// - 判定脚本在真实 Chrome 里跑（外壳 HTML + 仿 eggrolls 模板：米色纸底、灰框、衬线字）。
const SrsCardLabels _labels = SrsCardLabels(
  allDefinitions: 'all',
  frequency: 'freq',
  source: 'src',
);

/// 仿「eggrolls-JLPT10k」一类导入牌组的模板样式：米色整页底、细灰描边框、衬线字体，外加
/// 有彩色的高亮（必须原样保留）与灰色次要字。
const String _eggrollsCss = '''
.card { font-family: "Times New Roman", serif; background-color: #fdf8ec; color: #333333; text-align: center; }
.box { border: 1px solid #c8c8c8; background: #fdf8ec; padding: 12px; margin: 8px; }
.panel { background: #e9e4d8; padding: 6px; }
.hl { background: #ffd54f; color: #b71c1c; }
.sub { color: #8a8a8a; }
.mono { font-family: monospace; }
''';

const String _eggrollsBody =
    '<div class="box"><div class="word">単語</div>'
    '<div class="panel">reading <span class="hl">高亮</span></div>'
    '<div class="sub">note</div><a href="https://example.com">link</a>'
    '<span class="mono">x</span><hr></div>';

ThemeData _theme({bool dark = false, bool apple = false}) {
  final ThemeData base = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
  );
  return apple ? base.copyWith(platform: TargetPlatform.iOS) : base;
}

SrsCardFaceDocument _doc({
  required bool skin,
  bool fushiCard = false,
  bool dark = false,
  String cardId = 'c1',
  ThemeData? theme,
}) => srsCardFaceDocumentFor(
  SrsCardFace(
    cardId: cardId,
    showingAnswer: false,
    bodyHtml: _eggrollsBody,
    css: _eggrollsCss,
    languageCode: 'ja',
    onBridgeKey: (_) {},
    fushiCard: fushiCard,
  ),
  theme: theme ?? _theme(dark: dark),
  appearance: SrsCardAppearance(designSkin: skin),
  labels: _labels,
  mediaUrlPrefix: 'https://srs.local/media/',
  themedScrollbar: false,
  fontUrl: (String path) => path,
);

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

void main() {
  group('偏好', () {
    test('默认开；JSON 往返；缺项按默认、坏值按默认', () {
      expect(const SrsCardAppearance().designSkin, isTrue);
      const SrsCardAppearance off = SrsCardAppearance(designSkin: false);
      expect(off.toJson()['designSkin'], isFalse);
      expect(SrsCardAppearance.decode(off.encode()), off);
      expect(SrsCardAppearance.decode('{}').designSkin, isTrue);
      expect(
        SrsCardAppearance.fromJson(const <String, Object?>{'designSkin': 'x'})
            .designSkin,
        isTrue,
      );
      expect(off.copyWith(designSkin: true).designSkin, isTrue);
    });
  });

  group('外壳文档：开 / 关', () {
    test('开：主题样式带覆盖变量与规则、卡面挂宿主类名、随主题下发判定脚本', () {
      final SrsCardFaceDocument d = _doc(skin: true);
      final ColorScheme cs = _theme().colorScheme;
      expect(d.themeCss, contains('--fushi-ds-bg:${_hex(cs.surface)};'));
      expect(d.themeCss, contains('--fushi-ds-fg:${_hex(cs.onSurface)};'));
      expect(d.themeCss, contains('--fushi-ds-outline:${_hex(cs.outlineVariant)};'));
      expect(d.themeCss, contains('--fushi-ds-link:${_hex(cs.primary)};'));
      expect(d.themeCss, contains('[data-fushi-ds~="panel"]'));
      expect(d.classes.split(' '), contains(kSrsDesignSkinClass));
      expect(d.hostScript, kSrsCardDesignSkinScript);
      expect(d.shellHtml, contains('--fushi-ds-bg'));
    });

    test('关：零注入（主题样式、类名、外壳 HTML、下发脚本都没有覆盖）', () {
      final SrsCardFaceDocument d = _doc(skin: false);
      expect(d.themeCss, isNot(contains('fushi-ds')));
      expect(d.classes, isNot(contains(kSrsDesignSkinClass)));
      expect(d.hostScript, isEmpty);
      expect(d.shellHtml, isNot(contains('--fushi-ds-')));
      expect(d.shellHtml, isNot(contains('data-fushi-ds')));
      expect(d.shellHtml, isNot(contains(kSrsDesignSkinClass)));
      expect(d.fullCardScript, isNot(contains('fushi-ds')));
      // 模板样式原样进注册表。
      expect(d.cardCss, _eggrollsCss);
    });

    test('Fushi 卡片不吃覆盖（它本身就按设计系统画）', () {
      final SrsCardFaceDocument d = _doc(skin: true, fushiCard: true);
      expect(d.themeCss, isNot(contains('--fushi-ds-')));
      expect(d.classes, isNot(contains(kSrsDesignSkinClass)));
      expect(d.hostScript, isEmpty);
    });

    test('MD3 = M3E 形状令牌与界面字体链；Apple = inset grouped 圆角与系统字体', () {
      final SrsCardTokens md3 = SrsCardTokens.fromTheme(_theme());
      final String md3Css = srsCardDesignSkinCss(
        scheme: _theme().colorScheme,
        tokens: md3,
      );
      expect(md3.apple, isFalse);
      expect(
        md3Css,
        contains('--fushi-ds-radius:${FushiM3eShape.card.round()}px;'),
      );
      expect(md3Css, contains('--fushi-ds-font:$kSrsCardDefaultFontUi;'));

      const SrsCardTokens apple = SrsCardTokens(
        apple: true,
        applePalette: null,
        textTheme: TextTheme(),
        radius: 24,
        radiusSmall: 10,
        radiusInner: 6,
      );
      final String appleCss = srsCardDesignSkinCss(
        scheme: _theme().colorScheme,
        tokens: apple,
      );
      expect(appleCss, contains('--fushi-ds-radius:24px;'));
      expect(appleCss, contains('--fushi-ds-radius-small:10px;'));
      expect(appleCss, contains('--fushi-ds-font:-apple-system'));
    });

    test('深色：变量换成深色表面 / 前景', () {
      final SrsCardFaceDocument d = _doc(skin: true, dark: true);
      final ColorScheme cs = _theme(dark: true).colorScheme;
      expect(d.themeCss, contains('--fushi-ds-bg:${_hex(cs.surface)};'));
      expect(d.classes.split(' '), containsAll(<String>['nightMode', kSrsDesignSkinClass]));
    });
  });

  group('切换即时生效（只换主题，不重放卡片）', () {
    test('开 → 关 → 开：每次只下发换主题；开时带判定脚本，关时不带', () async {
      final List<String> sent = <String>[];
      final SrsCardFaceSync sync = SrsCardFaceSync(
        evaluate: (String source) async {
          sent.add(source);
          return true;
        },
        reloadShell: () {},
      );
      sync.shellLoaded();
      sync.update(_doc(skin: true));
      await Future<void>.delayed(Duration.zero);
      expect(sent.single, contains(kSrsCardDesignSkinScript));
      expect(sent.single, contains('__fushiSrsSetCard('));

      sync.update(_doc(skin: false));
      await Future<void>.delayed(Duration.zero);
      expect(sent, hasLength(2));
      expect(sent.last, contains('__fushiSrsSetTheme'));
      expect(sent.last, isNot(contains('__fushiSrsSetCard(')));
      expect(sent.last, isNot(contains('window.__fushiSrsDesignSkin = ')));
      expect(sent.last, isNot(contains('--fushi-ds-')));

      sync.update(_doc(skin: true));
      await Future<void>.delayed(Duration.zero);
      expect(sent, hasLength(3));
      expect(sent.last, contains('--fushi-ds-bg'));
      expect(sent.last, isNot(contains('__fushiSrsSetCard(')));
    });

    test('外壳调用判定：换卡钩子跑完后、换主题后都调 __fushiSrsDesignSkin', () {
      final int finish = kSrsCardShellScript.indexOf('function finish(');
      final int hooks = kSrsCardShellScript.indexOf(
        'runHooks(window.onShownHook);',
        finish,
      );
      final int skin = kSrsCardShellScript.indexOf('designSkin();', finish);
      expect(hooks, greaterThan(finish));
      expect(skin, greaterThan(hooks));
      final int setTheme = kSrsCardShellScript.indexOf(
        'window.__fushiSrsSetTheme = function',
      );
      expect(
        kSrsCardShellScript.indexOf('designSkin();', setTheme),
        greaterThan(setTheme),
      );
    });
  });

  test(
    '判定脚本在真实 Chrome 里：纸底 / 灰框 / 衬线换成设计系统，有彩色原样，关掉即复原',
    () async {
      final String? node = _resolveNode();
      if (node == null) {
        markTestSkipped('node not found on PATH');
        return;
      }
      final SrsCardFaceDocument light = _doc(skin: true);
      final SrsCardFaceDocument dark = _doc(skin: true, dark: true);
      final SrsCardFaceDocument off = _doc(skin: false);
      final ColorScheme cs = _theme().colorScheme;
      final ColorScheme dcs = _theme(dark: true).colorScheme;
      final SrsCardTokens tokens = SrsCardTokens.fromTheme(_theme());
      String rgb(Color c) {
        final int v = c.toARGB32();
        return 'rgb(${(v >> 16) & 0xFF}, ${(v >> 8) & 0xFF}, ${v & 0xFF})';
      }

      final Directory temp = Directory.systemTemp.createTempSync('srs-skin-');
      try {
        final File payload = File('${temp.path}/payload.json')
          ..writeAsStringSync(
            jsonEncode(<String, Object?>{
              'light': <String, String>{
                'shell': light.shellHtml,
                'calls': light.hostScript + light.fullCardScript,
              },
              'dark': <String, String>{
                'shell': dark.shellHtml,
                'calls': dark.hostScript + dark.fullCardScript,
              },
              'off': <String, String>{
                'shell': off.shellHtml,
                'calls': off.fullCardScript,
                'theme': srsCardSetThemeScript(
                  themeCss: off.themeCss,
                  classes: off.classes,
                ),
              },
              'expect': <String, String>{
                'bg': rgb(cs.surface),
                'fg': rgb(cs.onSurface),
                'muted': rgb(cs.onSurfaceVariant),
                'surface': rgb(tokens.surface1(cs)),
                'outline': rgb(cs.outlineVariant),
                'link': rgb(cs.primary),
                'radius': '${tokens.radius.round()}px',
                'darkBg': rgb(dcs.surface),
                'darkFg': rgb(dcs.onSurface),
              },
            }),
          );
        final ProcessResult result = await Process.run(node, <String>[
          'test/srs/srs_card_design_skin_harness.mjs',
          payload.path,
        ]).timeout(const Duration(seconds: 80));
        if (result.exitCode == 77) {
          markTestSkipped('Chrome unavailable: ${result.stdout}');
          return;
        }
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout, contains('PASS 4 browser cases'));
        // 判定的耗时（信息性，不断言）：开 / 关两态下换卡 + 排版的平均毫秒。
        // ignore: avoid_print
        print('[srs-skin-harness] ${result.stdout}'.trim());
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

String? _resolveNode() {
  for (final String name in Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node']) {
    try {
      if (Process.runSync(name, <String>['--version']).exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // 试下一个可执行名。
    }
  }
  return null;
}
