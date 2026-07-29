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

    test('覆盖 vendored CSS 里每一个 px 取值的 pc/mobile 变量（漏一个即红）', () {
      // 守卫 PR#457 审查 §10-1 的原始缺陷：正则只认 `font-size`，把上游命名
      // 例外 `--pc-main-def-size` / `--mobile-main-def-size` 漏在缩放之外，
      // 释义字号不跟随「界面缩放」。判据不写死变量清单，而是直接从
      // LapisNoteType.css 反推：**所有** px 取值的 --pc-* / --mobile-* 变量
      // 都必须出现在缩放块里，vendored 升级新增变量同样会打红。
      final RegExp declared =
          RegExp(r'--((?:pc|mobile)-[a-z0-9-]+):\s*(\d+)px');
      final Map<String, int> baselines = <String, int>{
        for (final RegExpMatch m in declared.allMatches(LapisNoteType.css))
          m.group(1)!: int.parse(m.group(2)!),
      };
      expect(baselines, isNotEmpty);
      final String css = buildLapisFontScaleCss(125);
      final List<String> missing = <String>[
        for (final String name in baselines.keys)
          if (!css.contains('--$name:')) name,
      ];
      // 前瞻风险留痕：本断言把「pc-/mobile- 前缀 + px 取值 == 字号」制度化了。
      // 上游若新增非字号的 px 变量（如 --pc-main-picture-size），正确做法是给
      // buildLapisFontScaleCss 加排除表并在这里显式豁免，**不是**把守卫改绿。
      expect(missing, isEmpty, reason: '这些 Lapis 字号变量没被缩放覆盖: $missing');
      // 释义字号显式断言基准与缩放结果（pc 20px、mobile 16px @125%）。
      expect(baselines['pc-main-def-size'], 20);
      expect(baselines['mobile-main-def-size'], 16);
      expect(css, contains('--pc-main-def-size: 25px;'));
      expect(css, contains('--mobile-main-def-size: 20px;'));
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

  group('Lapis visual style sheet', () {
    test('自由 CSS 与字段规则往返，托管区段始终排在最后', () {
      const String freeform = '.custom { line-height: 1.8; }';
      const LapisVisualRule expression = LapisVisualRule(
        fontScalePercent: 125,
        bold: true,
        alignment: LapisVisualTextAlign.center,
        colorHex: '#2F6B5F',
      );
      final String css = composeLapisVisualStyleSheet(
        freeformCss: freeform,
        rules: const <LapisVisualField, LapisVisualRule>{
          LapisVisualField.expression: expression,
        },
      );

      expect(css, startsWith(freeform));
      expect(css, contains(lapisVisualCssBeginMarker));
      expect(css, contains('.front-vocab, .vocab'));
      expect(css, contains('font-weight: 700 !important'));
      expect(css, contains('text-align: center !important'));
      expect(css, contains('color: #2F6B5F !important'));
      expect(
        css,
        contains(
          'font-size: calc(var(--vocab-font-size) * 1.25) !important',
        ),
      );
      expect(
        css,
        contains(
          'font-size: calc(var(--back-vocab-font-size) * 1.25) !important',
        ),
      );

      final LapisVisualStyleSheet round = splitLapisVisualStyleSheet(css);
      expect(round.freeformCss, freeform);
      expect(
        round.ruleFor(LapisVisualField.expression).fontScalePercent,
        125,
      );
      expect(round.ruleFor(LapisVisualField.expression).bold, isTrue);
      expect(
        round.ruleFor(LapisVisualField.expression).alignment,
        LapisVisualTextAlign.center,
      );
      expect(
        composeLapisVisualStyleSheet(
          freeformCss: round.freeformCss,
          rules: round.rules,
        ),
        css,
      );
    });

    test('没有非默认规则时不制造托管区段', () {
      expect(
        composeLapisVisualStyleSheet(
          freeformCss: '.custom { color: red; }',
          rules: const <LapisVisualField, LapisVisualRule>{
            LapisVisualField.sentence: LapisVisualRule(),
          },
        ),
        '.custom { color: red; }',
      );
    });

    test('损坏或不完整的托管区段按自由 CSS 原样保留', () {
      const String broken = '$lapisVisualCssBeginMarker\n.bad { color: red; }';
      final LapisVisualStyleSheet sheet = splitLapisVisualStyleSheet(broken);
      expect(sheet.freeformCss, broken);
      expect(sheet.rules, isEmpty);
    });

    test('残缺旧标记不会吞掉其后的新托管区段或手写 CSS', () {
      const String broken = '$lapisVisualCssBeginMarker\n.bad { color: red; }';
      final String withRule = composeLapisVisualStyleSheet(
        freeformCss: broken,
        rules: const <LapisVisualField, LapisVisualRule>{
          LapisVisualField.sentence: LapisVisualRule(bold: true),
        },
      );
      final LapisVisualStyleSheet round = splitLapisVisualStyleSheet(withRule);
      expect(round.freeformCss, broken);
      expect(round.ruleFor(LapisVisualField.sentence).bold, isTrue);
    });

    test('每个可视字段都有稳定 selector 与对应字号变量', () {
      for (final LapisVisualField field in LapisVisualField.values) {
        final String css = composeLapisVisualStyleSheet(
          freeformCss: '',
          rules: <LapisVisualField, LapisVisualRule>{
            field: const LapisVisualRule(fontScalePercent: 110),
          },
        );
        expect(lapisVisualSelector(field), isNotEmpty);
        expect(css, contains('font-size: calc('));
        expect(
          splitLapisVisualStyleSheet(css).ruleFor(field).fontScalePercent,
          110,
        );
      }
    });

    test('整段释义与释义框生成真实层级 selector，子级规则排在父级之后', () {
      final String css = composeLapisVisualStyleSheet(
        freeformCss: '',
        rules: const <LapisVisualField, LapisVisualRule>{
          LapisVisualField.definitionBox: LapisVisualRule(
            backgroundColorHex: '#D9EAD3',
          ),
          LapisVisualField.definitionContent: LapisVisualRule(
            colorHex: '#2F6B5F',
          ),
          LapisVisualField.primaryDefinition: LapisVisualRule(bold: true),
        },
      );

      expect(css, contains('.main-def {'));
      expect(css, contains('.main-def > .definition > div {'));
      expect(css, contains('#primary {'));
      expect(css.indexOf('.main-def {'), lessThan(css.indexOf('#primary {')));
      expect(
        css.indexOf('.main-def > .definition > div {'),
        lessThan(css.indexOf('#primary {')),
      );
    });

    test('背景、行高和区域外观完整往返并生成受控 CSS', () {
      const LapisVisualRule rule = LapisVisualRule(
        fontScalePercent: 115,
        bold: true,
        alignment: LapisVisualTextAlign.start,
        colorHex: '#2F6B5F',
        lineHeightPercent: 175,
        backgroundColorHex: '#FFF0A6',
        borderWidthPx: 2,
        borderColorHex: '#3D5A80',
        borderRadiusPx: 12,
        paddingPx: 16,
        marginBlockPx: 8,
      );
      final String css = composeLapisVisualStyleSheet(
        freeformCss: '',
        rules: const <LapisVisualField, LapisVisualRule>{
          LapisVisualField.definitionBox: rule,
        },
      );

      expect(css, contains('line-height: 1.75 !important'));
      expect(css, contains('background-color: #FFF0A6 !important'));
      expect(css, contains('border-style: solid !important'));
      expect(css, contains('border-width: 2px !important'));
      expect(css, contains('border-color: #3D5A80 !important'));
      expect(css, contains('border-radius: 12px !important'));
      expect(css, contains('padding: 16px !important'));
      expect(css, contains('margin-block: 8px !important'));

      final LapisVisualRule round = splitLapisVisualStyleSheet(css)
          .ruleFor(LapisVisualField.definitionBox);
      expect(round.fontScalePercent, 115);
      expect(round.lineHeightPercent, 175);
      expect(round.backgroundColorHex, '#FFF0A6');
      expect(round.borderWidthPx, 2);
      expect(round.borderColorHex, '#3D5A80');
      expect(round.borderRadiusPx, 12);
      expect(round.paddingPx, 16);
      expect(round.marginBlockPx, 8);
    });

    test('损坏或越界的可视参数安全归一化', () {
      final LapisVisualRule? rule = LapisVisualRule.fromJson(
        <String, dynamic>{
          'fontScalePercent': 999,
          'lineHeightPercent': 999,
          'backgroundColorHex': 'red',
          'borderWidthPx': -4,
          'borderColorHex': '#aabbcc',
          'borderRadiusPx': 999,
          'paddingPx': -1,
          'marginBlockPx': 999,
        },
      );

      expect(rule, isNotNull);
      expect(rule!.fontScalePercent, 250);
      expect(rule.lineHeightPercent, 250);
      expect(rule.backgroundColorHex, isNull);
      expect(rule.borderWidthPx, 0);
      expect(rule.borderColorHex, '#AABBCC');
      expect(rule.borderRadiusPx, 48);
      expect(rule.paddingPx, 0);
      expect(rule.marginBlockPx, 48);
    });

    test('正面目标与背面层级目标有明确平台侧切换语义', () {
      expect(LapisVisualField.expression.backOnly, isFalse);
      expect(LapisVisualField.sentence.backOnly, isFalse);
      expect(LapisVisualField.reading.backOnly, isTrue);
      expect(LapisVisualField.definitionBox.backOnly, isTrue);
      expect(LapisVisualField.dictionaryEntry.backOnly, isTrue);
      expect(LapisVisualField.definitionBox.supportsBoxLayout, isTrue);
      expect(LapisVisualField.dictionaryEntry.supportsBoxLayout, isTrue);
      expect(LapisVisualField.dictionaryName.supportsBoxLayout, isFalse);
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
