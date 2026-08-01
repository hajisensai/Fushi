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
      expect(round.managedFirst, isFalse);
      expect(
        composeLapisVisualStyleSheet(
          freeformCss: round.freeformCss,
          rules: round.rules,
          managedFirst: round.managedFirst,
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

    test('缺 END 标记的托管区段按自由 CSS 原样保留', () {
      const String broken = '$lapisVisualCssBeginMarker\n.bad { color: red; }';
      final LapisVisualStyleSheet sheet = splitLapisVisualStyleSheet(broken);
      expect(sheet.freeformCss, broken);
      expect(sheet.rules, isEmpty);
    });

    // 下面两条守的是 splitLapisVisualStyleSheet 里另外两条 fail-safe 分支
    // （CONFIG 注释缺失 / CONFIG JSON 坏掉）。它们的存在理由就是「宁可留垃圾
    // 也不丢数据」——把 freeformCss 置空能让用户整段手写 CSS 在打开一次编辑器
    // 后人间蒸发，所以必须逐条钉死，不能只守「缺 END」那一条。
    test('CONFIG 注释缺失时整段原样保留（不销毁用户手写 CSS）', () {
      const String before = '.mine-before { color: #111111; }';
      const String after = '.mine-after { color: #222222; }';
      const String broken = '$before\n\n'
          '$lapisVisualCssBeginMarker\n'
          '.front-vocab {\n  color: #333333 !important;\n}\n'
          '$lapisVisualCssEndMarker\n\n'
          '$after';
      final LapisVisualStyleSheet sheet = splitLapisVisualStyleSheet(broken);
      expect(sheet.freeformCss, broken);
      expect(sheet.freeformCss, contains(before));
      expect(sheet.freeformCss, contains(after));
      expect(sheet.rules, isEmpty);
    });

    test('CONFIG JSON 损坏时整段原样保留（不销毁用户手写 CSS）', () {
      const String before = '.mine-before { color: #111111; }';
      const String after = '.mine-after { color: #222222; }';
      const String broken = '$before\n\n'
          '$lapisVisualCssBeginMarker\n'
          '/* HIBIKI-LAPIS-VISUAL-CONFIG {"expression": */\n'
          '$lapisVisualCssEndMarker\n\n'
          '$after';
      final LapisVisualStyleSheet sheet = splitLapisVisualStyleSheet(broken);
      expect(sheet.freeformCss, broken);
      expect(sheet.freeformCss, contains(before));
      expect(sheet.freeformCss, contains(after));
      expect(sheet.rules, isEmpty);
    });

    test('CONFIG 是合法 JSON 但不是对象时整段原样保留', () {
      const String mine = '.mine { color: #111111; }';
      const String broken = '$lapisVisualCssBeginMarker\n'
          '/* HIBIKI-LAPIS-VISUAL-CONFIG [1,2,3] */\n'
          '$lapisVisualCssEndMarker\n\n'
          '$mine';
      final LapisVisualStyleSheet sheet = splitLapisVisualStyleSheet(broken);
      expect(sheet.freeformCss, broken);
      expect(sheet.freeformCss, contains(mine));
      expect(sheet.rules, isEmpty);
    });

    test('用户写在托管区段之后的 CSS 保存后仍在托管区段之后（覆盖不被静默推翻）', () {
      const String override = '.main-def {\n'
          '  background-color: #101010 !important;\n'
          '}';
      final String managedOnly = composeLapisVisualStyleSheet(
        freeformCss: '',
        rules: const <LapisVisualField, LapisVisualRule>{
          LapisVisualField.definitionBox:
              LapisVisualRule(backgroundColorHex: '#FFF0A6'),
        },
      );
      final String stored = '$managedOnly\n\n$override';

      final LapisVisualStyleSheet sheet = splitLapisVisualStyleSheet(stored);
      expect(sheet.freeformCss, override);
      expect(sheet.managedFirst, isTrue);

      final String saved = composeLapisVisualStyleSheet(
        freeformCss: sheet.freeformCss,
        rules: sheet.rules,
        managedFirst: sheet.managedFirst,
      );
      // 逐字节等于存进来的样子：位置没被搬动，最后一句仍然是用户的覆盖。
      expect(saved, stored);
      expect(
        saved.indexOf(lapisVisualCssEndMarker),
        lessThan(saved.indexOf(override)),
      );
    });

    test('托管区段之前的用户 CSS 保存后仍在之前（默认布局不变）', () {
      const String freeform = '.custom { line-height: 1.8; }';
      final String stored = composeLapisVisualStyleSheet(
        freeformCss: freeform,
        rules: const <LapisVisualField, LapisVisualRule>{
          LapisVisualField.definitionBox:
              LapisVisualRule(backgroundColorHex: '#FFF0A6'),
        },
      );
      final LapisVisualStyleSheet sheet = splitLapisVisualStyleSheet(stored);
      expect(sheet.managedFirst, isFalse);
      expect(
        composeLapisVisualStyleSheet(
          freeformCss: sheet.freeformCss,
          rules: sheet.rules,
          managedFirst: sheet.managedFirst,
        ),
        stored,
      );
    });

    test('自由 CSS 的首尾空白与缩进原样保留（不再被 trim）', () {
      const String freeform = '  .custom { color: red; }\n\n';
      final String stored = composeLapisVisualStyleSheet(
        freeformCss: freeform,
        rules: const <LapisVisualField, LapisVisualRule>{
          LapisVisualField.expression: LapisVisualRule(bold: true),
        },
      );
      expect(stored, startsWith(freeform));
      expect(splitLapisVisualStyleSheet(stored).freeformCss, freeform);
      // 无托管规则时同样逐字节原样返回。
      expect(
        composeLapisVisualStyleSheet(
          freeformCss: freeform,
          rules: const <LapisVisualField, LapisVisualRule>{},
        ),
        freeform,
      );
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

    // 这张表是「可视编辑器改的到底是真卡上的哪个元素」的唯一断言。旧版本只断言
    // `isNotEmpty` + `contains('font-size: calc(')`，任何编造的 selector 都能混
    // 过去（真机改了没反应、预览却有效果）。所以这里逐字段钉死 selector 字面量与
    // 字号变量字面量：真实 DOM 依据见 lapisVisualSelector 的文档注释。
    const Map<LapisVisualField, String> expectedSelectors =
        <LapisVisualField, String>{
      LapisVisualField.expression: '.front-vocab, .vocab',
      LapisVisualField.reading: '.pitch',
      LapisVisualField.sentence:
          '#hint, .front-sentence, .sentence, .sentence-alt',
      LapisVisualField.definitionInfo: '.def-info',
      LapisVisualField.definitionBox: '.main-def',
      LapisVisualField.definitionContent: '.main-def > .definition > div',
      LapisVisualField.selectedDefinition: '#selection',
      LapisVisualField.primaryDefinition: '#primary',
      LapisVisualField.glossaries: '#glossaries',
      LapisVisualField.dictionaryEntry:
          '#primary li[data-dictionary], #glossaries li[data-dictionary]',
      LapisVisualField.dictionaryName: '.definition li[data-dictionary] > i',
      LapisVisualField.definitionExample:
          '.definition [data-sc-content|="example-sentence"]',
    };

    /// 字段 → 110% 缩放时必须逐字节出现的字号规则。选择器与变量名任意一处写错
    /// 都会让这里对不上。
    const Map<LapisVisualField, List<String>> expectedFontRules =
        <LapisVisualField, List<String>>{
      LapisVisualField.expression: <String>[
        '.front-vocab {\n  font-size: calc(var(--vocab-font-size) * 1.10)'
            ' !important;\n}',
        '.vocab {\n  font-size: calc(var(--back-vocab-font-size) * 1.10)'
            ' !important;\n}',
      ],
      LapisVisualField.reading: <String>[
        '.pitch {\n  font-size: calc(var(--info-font-size) * 1.10)'
            ' !important;\n}',
      ],
      LapisVisualField.sentence: <String>[
        '#hint {\n  font-size: calc(var(--hint-font-size) * 1.10)'
            ' !important;\n}',
        '.front-sentence {\n  font-size: calc(var(--sentence-font-size) * 1.10)'
            ' !important;\n}',
        '.sentence, .sentence-alt {\n'
            '  font-size: calc(var(--back-sentence-font-size) * 1.10)'
            ' !important;\n}',
      ],
      LapisVisualField.definitionInfo: <String>[
        '.def-info {\n  font-size: calc(0.9rem * 1.10) !important;\n}',
      ],
      LapisVisualField.definitionBox: <String>[
        '.main-def {\n  font-size: calc(var(--main-def-size) * 1.10)'
            ' !important;\n}',
      ],
      LapisVisualField.definitionContent: <String>[
        '.main-def > .definition > div {\n'
            '  font-size: calc(var(--main-def-size) * 1.10) !important;\n}',
      ],
      LapisVisualField.selectedDefinition: <String>[
        '#selection {\n  font-size: calc(var(--main-def-size) * 1.10)'
            ' !important;\n}',
      ],
      LapisVisualField.primaryDefinition: <String>[
        '#primary {\n  font-size: calc(var(--main-def-size) * 1.10)'
            ' !important;\n}',
      ],
      LapisVisualField.glossaries: <String>[
        '#glossaries {\n  font-size: calc(var(--main-def-size) * 1.10)'
            ' !important;\n}',
      ],
      LapisVisualField.dictionaryEntry: <String>[
        '#primary li[data-dictionary], #glossaries li[data-dictionary] {\n'
            '  font-size: calc(var(--main-def-size) * 1.10) !important;\n}',
      ],
      LapisVisualField.dictionaryName: <String>[
        '.definition li[data-dictionary] > i {\n'
            '  font-size: calc(var(--main-def-size) * 1.10) !important;\n}',
      ],
      LapisVisualField.definitionExample: <String>[
        '.definition [data-sc-content|="example-sentence"] {\n'
            '  font-size: calc(var(--main-def-size) * 1.10) !important;\n}',
      ],
    };

    test('每个可视字段绑定真实 Lapis selector 与字号变量', () {
      // 新增字段忘了登记 → 直接红，不给「先加字段、以后再补断言」的口子。
      expect(expectedSelectors.keys.toSet(), LapisVisualField.values.toSet());
      expect(expectedFontRules.keys.toSet(), LapisVisualField.values.toSet());

      for (final LapisVisualField field in LapisVisualField.values) {
        expect(
          lapisVisualSelector(field),
          expectedSelectors[field],
          reason: '${field.wireName} 的 selector 与真实 Lapis DOM 对不上',
        );
        final String css = composeLapisVisualStyleSheet(
          freeformCss: '',
          rules: <LapisVisualField, LapisVisualRule>{
            field: const LapisVisualRule(fontScalePercent: 110),
          },
        );
        for (final String rule in expectedFontRules[field]!) {
          expect(css, contains(rule),
              reason: '${field.wireName} 缺字号规则:\n$rule');
        }
        expect(
          splitLapisVisualStyleSheet(css).ruleFor(field).fontScalePercent,
          110,
        );
      }
    });

    test('selector 里不出现 Hibiki 自产卡从不产出的结构', () {
      // 这些锚点只存在于 vendored Lapis CSS（服务 JPMN 导入卡）与旧预览 mock：
      // popup.js 的 constructGlossaryHtml 永远产出
      // `div.yomitan-glossary > ol > li[data-dictionary] > (i + span)`。
      const List<String> neverProduced = <String>[
        'data-details',
        'dict-group',
        'data-sc-content="part-of-speech"',
        '#primary > div',
        '#glossaries > div',
      ];
      for (final LapisVisualField field in LapisVisualField.values) {
        final String selector = lapisVisualSelector(field);
        for (final String dead in neverProduced) {
          expect(
            selector,
            isNot(contains(dead)),
            reason: '${field.wireName} 用了自产卡不存在的锚点 $dead',
          );
        }
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

  group('Lapis 区块位置', () {
    test('布局保留键不与任何可视字段 wireName 相撞', () {
      // 撞上就意味着某个字段的规则会被当成布局吃掉（或反之）。
      expect(
        LapisVisualField.fromWireName(lapisVisualLayoutConfigKey),
        isNull,
      );
    });

    test('每项位置同时覆写桌面与移动端变量', () {
      const LapisVisualLayout layout = LapisVisualLayout(
        sentencePosition: LapisSentencePosition.below,
        picturePosition: LapisPicturePosition.alt,
        audioButtonsPosition: LapisAudioButtonsPosition.fixed,
      );
      final String css = buildLapisVisualLayoutCss(layout).join('\n');

      // 只写桌面变量的话，Lapis 的 `html.mobile { --sentence-position:
      // var(--mobile-sentence-position) }`（特异性高于 :root）会把手机端拉回
      // 出厂值 —— 桌面看着生效、手机上没反应。
      for (final String variable in <String>[
        '--sentence-position: "below";',
        '--mobile-sentence-position: "below";',
        '--main-picture-position: "alt";',
        '--mobile-main-picture-position: "alt";',
        '--audio-buttons: "fixed";',
        '--mobile-audio-buttons: "fixed";',
      ]) {
        expect(css, contains(variable), reason: '布局 CSS 缺 $variable');
      }
      // 自定义属性不能带 !important：一带上，html.mobile 那条重定向就被压死，
      // 移动端被迫吃桌面值。
      expect(css, isNot(contains('!important')));
    });

    test('覆写的变量名都真实存在于 vendored Lapis', () {
      const LapisVisualLayout layout = LapisVisualLayout(
        sentencePosition: LapisSentencePosition.above,
        picturePosition: LapisPicturePosition.left,
        audioButtonsPosition: LapisAudioButtonsPosition.alt,
      );
      final RegExp names = RegExp(r'--[a-z-]+(?=:)');
      final Iterable<String> used = names
          .allMatches(buildLapisVisualLayoutCss(layout).join('\n'))
          .map((RegExpMatch m) => m.group(0)!);
      expect(used, isNotEmpty);
      for (final String name in used) {
        expect(
          LapisNoteType.css.contains('$name:'),
          isTrue,
          reason: '$name 在 vendored Lapis 里不存在，改布局不会有任何效果',
        );
      }
      // 取值也必须是 vendored CSS 真认得的枚举值。
      for (final String value in <String>['above', 'below', 'right', 'left']) {
        expect(LapisNoteType.css, contains('"$value"'));
      }
    });

    test('默认布局不产出任何 CSS 与 CONFIG 条目', () {
      expect(buildLapisVisualLayoutCss(const LapisVisualLayout()), isEmpty);
      expect(
        composeLapisVisualStyleSheet(
          freeformCss: '.x { color: red; }',
          rules: const <LapisVisualField, LapisVisualRule>{},
        ),
        '.x { color: red; }',
      );
    });

    test('布局单独存在时也能往返（不依赖字段规则）', () {
      const LapisVisualLayout layout = LapisVisualLayout(
        sentencePosition: LapisSentencePosition.below,
      );
      final String css = composeLapisVisualStyleSheet(
        freeformCss: '',
        rules: const <LapisVisualField, LapisVisualRule>{},
        layout: layout,
      );
      final LapisVisualStyleSheet round = splitLapisVisualStyleSheet(css);
      expect(round.layout.sentencePosition, LapisSentencePosition.below);
      expect(round.layout.picturePosition, isNull);
      expect(round.rules, isEmpty);
      expect(round.freeformCss, isEmpty);
    });

    test('布局与字段规则共存时互不吞并', () {
      final String css = composeLapisVisualStyleSheet(
        freeformCss: '',
        rules: const <LapisVisualField, LapisVisualRule>{
          LapisVisualField.sentence: LapisVisualRule(bold: true),
        },
        layout: const LapisVisualLayout(
          picturePosition: LapisPicturePosition.left,
        ),
      );
      final LapisVisualStyleSheet round = splitLapisVisualStyleSheet(css);
      expect(round.layout.picturePosition, LapisPicturePosition.left);
      expect(round.rules[LapisVisualField.sentence]?.bold, isTrue);
    });

    test('旧版托管区段（无 layout 键）解析成默认布局，字段规则照常保留', () {
      // 老版本写下的 CONFIG 只有字段键。降级/升级都不许因此丢字段规则。
      const String legacy = '$lapisVisualCssBeginMarker\n'
          '/* HIBIKI-LAPIS-VISUAL-CONFIG '
          '{"sentence":{"fontScalePercent":100,"bold":true}} */\n'
          '.sentence {\n  font-weight: 700 !important;\n}\n'
          '$lapisVisualCssEndMarker';
      final LapisVisualStyleSheet sheet = splitLapisVisualStyleSheet(legacy);
      expect(sheet.rules[LapisVisualField.sentence]?.bold, isTrue);
      expect(sheet.layout.isDefault, isTrue);
    });

    test('CONFIG 里的未知位置取值被丢弃，不产出非法 CSS', () {
      const String hostile = '$lapisVisualCssBeginMarker\n'
          '/* HIBIKI-LAPIS-VISUAL-CONFIG '
          '{"layout":{"sentencePosition":"sideways"}} */\n'
          '$lapisVisualCssEndMarker';
      expect(
        splitLapisVisualStyleSheet(hostile).layout.isDefault,
        isTrue,
      );
    });

    test('copyWith 能把某项清回默认', () {
      const LapisVisualLayout layout = LapisVisualLayout(
        sentencePosition: LapisSentencePosition.below,
        picturePosition: LapisPicturePosition.left,
      );
      final LapisVisualLayout cleared = layout.copyWith(sentencePosition: null);
      expect(cleared.sentencePosition, isNull);
      expect(cleared.picturePosition, LapisPicturePosition.left);
      expect(layout.copyWith().sentencePosition, LapisSentencePosition.below);
    });
  });

  group('可视字段 → Anki 字段', () {
    test('来源字段都存在于 Lapis 卡型', () {
      for (final LapisVisualField field in LapisVisualField.values) {
        for (final String source in lapisVisualFieldSources(field)) {
          expect(
            LapisNoteType.fields,
            contains(source),
            reason: '${field.wireName} 指向了 Lapis 卡型里不存在的字段 $source',
          );
        }
      }
    });

    test('来源字段真的出现在对应模板里', () {
      // 名字像不算数：字段必须真被 front/back 模板引用，否则改映射对这块没影响。
      const String templates = '${LapisNoteType.front}${LapisNoteType.back}';
      for (final LapisVisualField field in LapisVisualField.values) {
        for (final String source in lapisVisualFieldSources(field)) {
          expect(
            templates,
            contains(source),
            reason: '${field.wireName} 的来源 $source 未被任何模板引用',
          );
        }
      }
    });

    test('专属释义块各自只认自己的字段；模板自绘的区域没有字段', () {
      expect(
        lapisVisualFieldSources(LapisVisualField.selectedDefinition),
        <String>['SelectionText'],
      );
      expect(
        lapisVisualFieldSources(LapisVisualField.primaryDefinition),
        <String>['MainDefinition'],
      );
      expect(
        lapisVisualFieldSources(LapisVisualField.glossaries),
        <String>['Glossary'],
      );
      // `.def-info` 是模板写死的计数标签，没有字段可改。
      expect(lapisVisualFieldSources(LapisVisualField.definitionInfo), isEmpty);
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
