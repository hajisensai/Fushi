import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

void main() {
  group('composeLapisCss', () {
    test('无客制化时逐字节等于出厂 template.css（零破坏）', () {
      expect(
        composeLapisCss(fontScalePercent: 100, customCss: ''),
        LapisNoteType.template.css,
      );
    });

    test('有客制化时 = 出厂 CSS + 标记包裹的用户区段', () {
      const String custom = '.front-vocab { color: #8ab4f8; }';
      final String css =
          composeLapisCss(fontScalePercent: 100, customCss: custom);
      expect(css, startsWith(LapisNoteType.template.css));
      expect(css, contains(lapisUserCssBeginMarker));
      expect(css, contains(custom));
      expect(css, contains(lapisUserCssEndMarker));
      expect(
        css.indexOf(lapisUserCssBeginMarker),
        lessThan(css.indexOf(custom)),
      );
      expect(css.indexOf(custom), lessThan(css.indexOf(lapisUserCssEndMarker)));
    });

    test('extractLapisUserSectionBody 与 compose 往返一致', () {
      const String custom = '.jpsentence { line-height: 2.1; }';
      final String css =
          composeLapisCss(fontScalePercent: 125, customCss: custom);
      final String? body = extractLapisUserSectionBody(css);
      expect(body, isNotNull);
      expect(body, contains(custom));
      // 回填 body 后重组能精确复现（备份恢复对齐路径依赖这一点）。
      expect(
        normalizeCssForCompare(
            composeLapisCss(fontScalePercent: 100, customCss: body!)),
        normalizeCssForCompare(css),
      );
    });

    test('extractLapisUserSectionBody：无标记返回 null', () {
      expect(extractLapisUserSectionBody(LapisNoteType.css), isNull);
      expect(extractLapisUserSectionBody('body { color: red; }'), isNull);
    });
  });

  group('buildLapisFontScaleCss', () {
    test('100% 不产出覆写', () {
      expect(buildLapisFontScaleCss(100), isEmpty);
    });

    test('从 vendored CSS 提取全部 pc/mobile 字号变量并按比例缩放', () {
      final String css = buildLapisFontScaleCss(125);
      expect(css, startsWith(':root {'));
      // 抽查基准值（vendored v1.7.0）：pc-vocab 85px → 106px，mobile-main
      // 16px → 20px。变量集合应同时覆盖 pc 与 mobile 两组。
      expect(css, contains('--pc-vocab-font-size: 106px;'));
      expect(css, contains('--mobile-main-font-size: 20px;'));
      expect(css, contains('--pc-sentence-font-size:'));
      expect(css, contains('--mobile-sentence-font-size:'));
    });

    test('缩放值有下限保护（不会缩成 0px）', () {
      // 1% 时最小的 16px 变量 → 0.16 → round 0 → clamp 1。
      expect(buildLapisFontScaleCss(1), contains(': 1px;'));
      expect(buildLapisFontScaleCss(1), isNot(contains(': 0px;')));
    });
  });

  group('decideLapisStylingAction', () {
    final String expected =
        composeLapisCss(fontScalePercent: 110, customCss: '.x { color: red; }');

    test('内容一致（含 CRLF/尾空白差异）→ upToDate', () {
      expect(
        decideLapisStylingAction(
          ankiCss: '${expected.replaceAll('\n', '\r\n')}\n\n',
          expectedCss: expected,
          lastAppliedSha: null,
        ),
        LapisStylingDecision.upToDate,
      );
    });

    test('Anki 端 == 上次推送指纹 → safeUpdate（自动迁移放行）', () {
      final String previous =
          composeLapisCss(fontScalePercent: 100, customCss: '.old { }');
      expect(
        decideLapisStylingAction(
          ankiCss: previous,
          expectedCss: expected,
          lastAppliedSha: lapisCssSha256(previous),
        ),
        LapisStylingDecision.safeUpdate,
      );
    });

    test('Anki 端 == 出厂基线（纯 vendored / vendored+delta）→ safeUpdate', () {
      expect(
        decideLapisStylingAction(
          ankiCss: LapisNoteType.css,
          expectedCss: expected,
          lastAppliedSha: null,
        ),
        LapisStylingDecision.safeUpdate,
      );
      expect(
        decideLapisStylingAction(
          ankiCss: LapisNoteType.template.css,
          expectedCss: expected,
          lastAppliedSha: null,
        ),
        LapisStylingDecision.safeUpdate,
      );
    });

    test('来历不明内容 → foreignEdit（自动迁移不得覆盖）', () {
      expect(
        decideLapisStylingAction(
          ankiCss: '${LapisNoteType.template.css}\n.hand-edited { top: 0; }',
          expectedCss: expected,
          lastAppliedSha: null,
        ),
        LapisStylingDecision.foreignEdit,
      );
      // 指纹存在但对不上 → 仍是 foreignEdit。
      expect(
        decideLapisStylingAction(
          ankiCss: 'body { margin: 0; }',
          expectedCss: expected,
          lastAppliedSha: lapisCssSha256(expected),
        ),
        LapisStylingDecision.foreignEdit,
      );
    });
  });

  group('AnkiNoteTypeDefinition', () {
    test('JSON 往返（备份文件载荷）', () {
      const AnkiNoteTypeDefinition def = AnkiNoteTypeDefinition(
        name: 'Lapis',
        fields: <String>['Expression', 'Sentence'],
        templates: <AnkiCardTemplate>[
          AnkiCardTemplate(name: 'Card 1', front: '<f>', back: '<b>'),
        ],
        css: 'body { }',
      );
      final AnkiNoteTypeDefinition round =
          AnkiNoteTypeDefinition.fromJson(def.toJson());
      expect(round.name, def.name);
      expect(round.fields, def.fields);
      expect(round.templates.single.name, 'Card 1');
      expect(round.templates.single.front, '<f>');
      expect(round.templates.single.back, '<b>');
      expect(round.css, def.css);
    });
  });

  group('AnkiSettings Lapis 字段', () {
    test('JSON 往返 + 默认值', () {
      const AnkiSettings fresh = AnkiSettings();
      expect(fresh.lapisFontScalePercent, 100);
      expect(fresh.lapisCustomCss, '');
      expect(fresh.lapisAppliedCssSha, isNull);

      final AnkiSettings set = fresh.copyWith(
        lapisFontScalePercent: 125,
        lapisCustomCss: '.x { }',
        lapisAppliedCssSha: 'abc',
      );
      final AnkiSettings round = AnkiSettings.fromJson(set.toJson());
      expect(round.lapisFontScalePercent, 125);
      expect(round.lapisCustomCss, '.x { }');
      expect(round.lapisAppliedCssSha, 'abc');
    });

    test('旧版 JSON（无 Lapis 键）解析到默认值（向后兼容）', () {
      final AnkiSettings legacy =
          AnkiSettings.fromJson(<String, dynamic>{'tags': 'a'});
      expect(legacy.lapisFontScalePercent, 100);
      expect(legacy.lapisCustomCss, '');
      expect(legacy.lapisAppliedCssSha, isNull);
    });

    test('copyWith clearLapisAppliedCssSha 真能清空指纹', () {
      const AnkiSettings withSha = AnkiSettings(lapisAppliedCssSha: 'abc');
      expect(withSha.copyWith().lapisAppliedCssSha, 'abc');
      expect(
        withSha.copyWith(clearLapisAppliedCssSha: true).lapisAppliedCssSha,
        isNull,
      );
    });
  });
}
