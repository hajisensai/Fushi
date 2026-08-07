// 自定义区域纯函数层的守卫。
//
// 区域是「把已有字段摆到模板的另一个位置」，真相源在 Hibiki 侧、模板是产物，
// 所以这里盯的是三件事：锚点还在不在、无区域时零改动、以及拼进 handlebar 的
// 字段名有没有被当成注入边界处理。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 预览背面 mock（含区域插入后的结果）——锚点必须在它里面也唯一，否则「预览里
/// 位置对、真卡上位置不对」。
String _previewBack(List<LapisCustomBlock> blocks) {
  final String html = buildLapisStylePreviewHtml(
    css: '',
    selectedField: LapisVisualField.expression,
    showBack: true,
    darkMode: false,
    blocks: blocks,
  );
  final int start = html.indexOf('data-side="back"');
  final int end = html.indexOf('</section>', start);
  expect(start, greaterThanOrEqualTo(0));
  return html.substring(start, end);
}

void main() {
  group('锚点', () {
    test('每个锚串在 vendored 背面模板里恰好出现一次', () {
      for (final LapisBlockAnchor anchor in LapisBlockAnchor.values) {
        expect(
          anchor.anchorText.allMatches(LapisNoteType.back).length,
          1,
          reason: '${anchor.wireName} 的锚串 "${anchor.anchorText}" 在背面模板里'
              '不是恰好一处——插入点会跑偏或整个区域被丢掉',
        );
      }
    });

    test('每个锚串在预览背面里也恰好出现一次', () {
      final String preview = _previewBack(const <LapisCustomBlock>[]);
      for (final LapisBlockAnchor anchor in LapisBlockAnchor.values) {
        expect(
          anchor.anchorText.allMatches(preview).length,
          1,
          reason: '${anchor.wireName} 的锚串在预览 mock 里不是恰好一处',
        );
      }
    });

    test('例句锚串不会误命中 sentence-alt', () {
      // `<div class="sentence"` 与 `<div class="sentence-alt"` 是两个锚点，
      // 前者若少了收尾引号就会同时命中后者，两个位置合并成一个。
      expect(
        LapisBlockAnchor.aboveSentence.anchorText,
        isNot(contains('sentence-alt')),
      );
      expect(
        '<div class="sentence-alt" data-x>'
            .contains(LapisBlockAnchor.aboveSentence.anchorText),
        isFalse,
      );
    });

    test('锚串找不到时抛错，不静默丢掉区域', () {
      expect(
        () => insertLapisBlocksIntoBackHtml(
          '<div>没有任何锚点的模板</div>',
          const <LapisCustomBlock>[
            LapisCustomBlock(
              id: 'b1',
              anchor: LapisBlockAnchor.bottom,
              fields: <String>['Frequency'],
            ),
          ],
          renderBlock: buildLapisBlockHtml,
        ),
        throwsStateError,
      );
    });
  });

  group('背面模板组合', () {
    test('无区域时逐字节等于 vendored 基线', () {
      // 没用这个功能的用户，推送的模板必须与出厂完全一致（零破坏）。
      expect(
        composeLapisBackTemplate(const <LapisCustomBlock>[]),
        LapisNoteType.back,
      );
    });

    test('区域插在锚点该在的一侧', () {
      final String back = composeLapisBackTemplate(const <LapisCustomBlock>[
        LapisCustomBlock(
          id: 'b1',
          anchor: LapisBlockAnchor.bottom,
          fields: <String>['MiscInfo'],
        ),
      ]);
      final int block = back.indexOf('data-hibiki-block="b1"');
      final int mainEnd = back.indexOf('</main>');
      expect(block, greaterThanOrEqualTo(0));
      expect(block, lessThan(mainEnd), reason: 'bottom 区域跑到 </main> 外面了');

      final String top = composeLapisBackTemplate(const <LapisCustomBlock>[
        LapisCustomBlock(
          id: 'b1',
          anchor: LapisBlockAnchor.top,
          fields: <String>['MiscInfo'],
        ),
      ]);
      expect(
        top.indexOf('data-hibiki-block="b1"'),
        greaterThan(top.indexOf('<main>')),
        reason: 'top 是 insertAfter，必须落在 <main> 之后',
      );
      expect(
        top.indexOf('data-hibiki-block="b1"'),
        lessThan(top.indexOf('class="def-header"')),
      );
    });

    test('字段用条件块包裹，空字段不会在卡上留空块', () {
      final String html = buildLapisBlockHtml(const LapisCustomBlock(
        id: 'b1',
        anchor: LapisBlockAnchor.bottom,
        fields: <String>['Frequency', 'MiscInfo'],
      ));
      expect(html, contains('{{#Frequency}}'));
      expect(html, contains('{{Frequency}}'));
      expect(html, contains('{{/Frequency}}'));
      expect(html, contains('{{#MiscInfo}}'));
      // 块内不留缩进空白，否则 `:empty` 兜不住（有文本节点就不算空）。
      expect(html, isNot(contains('\n')));
      expect(lapisBlocksBaseCss, contains('.hibiki-block:empty'));
    });

    test('非法字段名与非法 id 不会被拼进模板', () {
      // 字段名原样进 handlebar，是注入边界：`}}` 漏过去就能改写模板结构。
      expect(isValidLapisBlockFieldName('Expression'), isTrue);
      expect(isValidLapisBlockFieldName('a}}<script>'), isFalse);
      expect(isValidLapisBlockFieldName('has space'), isFalse);
      expect(isValidLapisBlockId('b12'), isTrue);
      expect(isValidLapisBlockId('b1"]'), isFalse);

      final String html = buildLapisBlockHtml(const LapisCustomBlock(
        id: 'b1',
        anchor: LapisBlockAnchor.bottom,
        fields: <String>['Frequency', 'evil}}<script>'],
      ));
      expect(html, contains('{{#Frequency}}'));
      expect(html, isNot(contains('script')));

      // 反序列化侧同样拦：坏 id 整条丢弃，坏字段名只丢那个字段。
      expect(
        LapisCustomBlock.fromJson(<String, dynamic>{
          'id': 'b1"]',
          'anchor': 'bottom',
          'fields': <String>['Frequency'],
        }),
        isNull,
      );
      expect(
        LapisCustomBlock.fromJson(<String, dynamic>{
          'id': 'b1',
          'anchor': 'bottom',
          'fields': <String>['Frequency', 'bad name'],
        })?.fields,
        <String>['Frequency'],
      );
    });
  });

  group('以用户自己的 Lapis 为基线', () {
    /// 一份「不是 Hibiki 内置那版」的用户模板：换了字体、结构也不同。
    const String userBack = '<div id="lapis" lang="ja">\n'
        '    <main>\n'
        '        <div class="def-header">用户自己的头部</div>\n'
        '        <div class="sentence">用户自己的例句块</div>\n'
        '        <div class="def-info">1/?</div>\n'
        '        <div class="main-def">用户自己的释义框</div>\n'
        '        <div class="sentence-alt">备用位置</div>\n'
        '    </main>\n'
        '</div>';

    test('strip 与 insert 严格互逆（不吃掉原文缩进）', () {
      // 不互逆的话，「Anki 端就是基线」判不出来，第一次加区域会被误判成手改。
      const List<LapisCustomBlock> blocks = <LapisCustomBlock>[
        LapisCustomBlock(
          id: 'b1',
          anchor: LapisBlockAnchor.aboveSentence,
          fields: <String>['Frequency'],
        ),
        LapisCustomBlock(
          id: 'b2',
          anchor: LapisBlockAnchor.bottom,
          fields: <String>['MiscInfo'],
        ),
      ];
      for (final String base in <String>[userBack, LapisNoteType.back]) {
        final String inserted = insertLapisBlocksIntoBackHtml(
          base,
          blocks,
          renderBlock: buildLapisBlockHtml,
        );
        expect(inserted, isNot(base));
        expect(
          stripLapisBlocksSections(inserted),
          base,
          reason: 'strip(insert(x)) 必须逐字节等于 x',
        );
      }
    });

    test('无区域时推送内容逐字节等于用户自己的模板', () {
      // 没用这个功能的用户，Apply 不该让他的模板有任何变化。
      expect(
        composeLapisBackTemplate(
          const <LapisCustomBlock>[],
          baseBack: userBack,
        ),
        userBack,
      );
    });

    test('区域插进用户自己的模板，不换成 vendored 那份', () {
      final String back = composeLapisBackTemplate(
        const <LapisCustomBlock>[
          LapisCustomBlock(
            id: 'b1',
            anchor: LapisBlockAnchor.bottom,
            fields: <String>['MiscInfo'],
          ),
        ],
        baseBack: userBack,
      );
      expect(back, contains('用户自己的释义框'));
      expect(back, contains('data-hibiki-block="b1"'));
      // 病根守卫：用户的模板不得被 Hibiki 内置副本顶掉。
      expect(back, isNot(contains('def-image')));
    });

    test('重复 Apply 不会把区域越叠越多', () {
      const List<LapisCustomBlock> blocks = <LapisCustomBlock>[
        LapisCustomBlock(
          id: 'b1',
          anchor: LapisBlockAnchor.bottom,
          fields: <String>['MiscInfo'],
        ),
      ];
      final String once = composeLapisBackTemplate(blocks, baseBack: userBack);
      // 第二次 Apply 的基线是 Anki 端现有内容（已经含上一轮的区段）。
      final String twice = composeLapisBackTemplate(blocks, baseBack: once);
      expect(twice, once);
      expect(
        lapisBlocksBeginMarker.allMatches(twice).length,
        1,
        reason: '每 Apply 一次多叠一份区域 = 用户看到的「多出来一行」',
      );
    });

    test('CSS 侧同样叠加：用户的字体不被顶掉', () {
      const String userCss = ':root { --font-serif: "我的字体"; }\n'
          '.card { color: #abcdef; }';
      final String composed = composeLapisCssOnBase(
        baseCss: userCss,
        fontScalePercent: 125,
        customCss: '.mine { color: red; }',
      );
      expect(composed, startsWith(userCss));
      expect(composed, contains('我的字体'));
      expect(composed, contains('.mine { color: red; }'));
      // 剥掉我们那段就回到他原本那份，逐字节。
      expect(stripLapisUserSection(composed), userCss);
    });

    test('没有客制化时 CSS 逐字节等于用户原本那份', () {
      const String userCss = ':root { --font-serif: "我的字体"; }';
      expect(
        composeLapisCssOnBase(
          baseCss: userCss,
          fontScalePercent: 100,
          customCss: '',
        ),
        userCss,
      );
    });

    test('从没被 Hibiki 写过的 CSS，strip 后原样返回', () {
      const String pristine = '.card { font-family: "别的字体"; }';
      expect(stripLapisUserSection(pristine), pristine);
    });

    test('正面模板永不参与写入：只换目标卡的背面，其余原样', () {
      final AnkiNoteTypeDefinition def = AnkiNoteTypeDefinition(
        name: LapisNoteType.modelName,
        fields: LapisNoteType.fields,
        css: 'x',
        templates: const <AnkiCardTemplate>[
          AnkiCardTemplate(
            name: LapisNoteType.cardName,
            front: '用户自己的正面',
            back: '旧背面',
          ),
          AnkiCardTemplate(
            name: 'Card 2',
            front: '第二张正面',
            back: '第二张背面',
          ),
        ],
      );
      final List<AnkiCardTemplate> out = lapisTemplatesWithBack(def, '新背面');
      expect(out.length, 2);
      expect(out[0].back, '新背面');
      // 正面推 vendored 就是又一次「用内置副本顶掉用户的东西」。
      expect(out[0].front, '用户自己的正面');
      expect(out[1].front, '第二张正面');
      expect(out[1].back, '第二张背面');
    });

    test('多张卡模板不再被判成 foreignEdit', () {
      // 用户给 Lapis 加过第二张卡模板不是我们该拦的事。
      final AnkiNoteTypeDefinition def = AnkiNoteTypeDefinition(
        name: LapisNoteType.modelName,
        fields: LapisNoteType.fields,
        css: 'x',
        templates: const <AnkiCardTemplate>[
          AnkiCardTemplate(
            name: LapisNoteType.cardName,
            front: 'f',
            back: userBack,
          ),
          AnkiCardTemplate(name: 'Card 2', front: 'f2', back: 'b2'),
        ],
      );
      expect(
        decideLapisTemplateAction(
          def: def,
          expectedBack: userBack,
          lastAppliedSha: null,
        ),
        LapisStylingDecision.upToDate,
      );
    });
  });

  group('序列化', () {
    test('往返保留位置、字段与样式', () {
      const List<LapisCustomBlock> blocks = <LapisCustomBlock>[
        LapisCustomBlock(
          id: 'b1',
          anchor: LapisBlockAnchor.top,
          fields: <String>['Frequency'],
          rule: LapisVisualRule(bold: true, colorHex: '#123456'),
        ),
        LapisCustomBlock(
          id: 'b2',
          anchor: LapisBlockAnchor.bottom,
          fields: <String>['MiscInfo'],
        ),
      ];
      final List<LapisCustomBlock> round =
          lapisBlocksFromJson(lapisBlocksToJson(blocks));
      expect(round.length, 2);
      expect(round[0].anchor, LapisBlockAnchor.top);
      expect(round[0].rule.bold, isTrue);
      expect(round[0].rule.colorHex, '#123456');
      expect(round[1].id, 'b2');
      expect(round[1].rule.isDefault, isTrue);
    });

    test('坏条目逐条丢弃，不让整份区域消失', () {
      final List<LapisCustomBlock> parsed = lapisBlocksFromJson(<Object?>[
        <String, dynamic>{
          'id': 'b1',
          'anchor': 'bottom',
          'fields': <String>['MiscInfo'],
        },
        <String, dynamic>{'id': 'b2', 'anchor': '不存在的锚点'},
        'garbage',
      ]);
      expect(parsed.map((LapisCustomBlock b) => b.id), <String>['b1']);
    });

    test('AnkiSettings 往返保留区域与模板指纹；老配置解析成空', () {
      const AnkiSettings fresh = AnkiSettings();
      expect(fresh.lapisCustomBlocks, isEmpty);
      expect(fresh.lapisAppliedTemplateSha, isNull);

      final AnkiSettings set = fresh.copyWith(
        lapisCustomBlocks: const <LapisCustomBlock>[
          LapisCustomBlock(
            id: 'b1',
            anchor: LapisBlockAnchor.aboveSentence,
            fields: <String>['Frequency'],
          ),
        ],
        lapisAppliedTemplateSha: 'abc',
      );
      final AnkiSettings round = AnkiSettings.fromJson(set.toJson());
      expect(round.lapisCustomBlocks.single.id, 'b1');
      expect(
        round.lapisCustomBlocks.single.anchor,
        LapisBlockAnchor.aboveSentence,
      );
      expect(round.lapisAppliedTemplateSha, 'abc');

      // 老装置升级上来（JSON 里没有这两个键）：区域为空、指纹为 null，
      // 行为与从没用过这个功能完全一致。
      final AnkiSettings legacy =
          AnkiSettings.fromJson(<String, dynamic>{'tags': 'a'});
      expect(legacy.lapisCustomBlocks, isEmpty);
      expect(legacy.lapisAppliedTemplateSha, isNull);
    });

    test('id 不复用已删编号', () {
      const List<LapisCustomBlock> blocks = <LapisCustomBlock>[
        LapisCustomBlock(
          id: 'b3',
          anchor: LapisBlockAnchor.top,
          fields: <String>[],
        ),
      ];
      // 复用编号会让上一个 b4 遗留的 CSS 规则落到新区域头上。
      expect(nextLapisBlockId(blocks), 'b4');
      expect(nextLapisBlockId(const <LapisCustomBlock>[]), 'b1');
    });
  });

  group('区域样式', () {
    test('复用字段那一套声明生成，不另起炉灶', () {
      const LapisCustomBlock block = LapisCustomBlock(
        id: 'b1',
        anchor: LapisBlockAnchor.bottom,
        fields: <String>['MiscInfo'],
        rule: LapisVisualRule(
          bold: true,
          colorHex: '#123456',
          borderWidthPx: 2,
          paddingPx: 8,
        ),
      );
      final String css =
          buildLapisBlocksCss(<LapisCustomBlock>[block]).join('\n');
      expect(css, contains(lapisBlockSelector('b1')));
      for (final String declaration in lapisVisualDeclarations(block.rule)) {
        expect(css, contains(declaration.trim()));
      }
    });

    test('无区域不产出任何 CSS', () {
      expect(buildLapisBlocksCss(const <LapisCustomBlock>[]), isEmpty);
    });

    test('区域样式随区域一起走，不进 CONFIG（删区域不留孤儿规则）', () {
      const LapisCustomBlock block = LapisCustomBlock(
        id: 'b1',
        anchor: LapisBlockAnchor.bottom,
        fields: <String>['MiscInfo'],
        rule: LapisVisualRule(bold: true),
      );
      final String withBlock = composeLapisVisualStyleSheet(
        freeformCss: '',
        rules: const <LapisVisualField, LapisVisualRule>{},
        extraManagedCss: buildLapisBlocksCss(<LapisCustomBlock>[block]),
      );
      expect(withBlock, contains(lapisBlockSelector('b1')));
      // CONFIG 只记可回读的真相源；区域样式是派生物，写进去就成了双真相源
      // （删区域时得记着回来清理，必然漏）。只查 CONFIG 那一行——selector 里
      // 本来就带 id，拿整份文本断言等于没断言。
      final RegExpMatch? config = RegExp(
        r'/\* HIBIKI-LAPIS-VISUAL-CONFIG (.*?) \*/',
        dotAll: true,
      ).firstMatch(withBlock);
      expect(config, isNotNull);
      expect(config!.group(1), isNot(contains('b1')));

      // 删掉区域后重新组合：规则一起消失，不需要任何清理动作。
      final String without = composeLapisVisualStyleSheet(
        freeformCss: '',
        rules: const <LapisVisualField, LapisVisualRule>{},
        extraManagedCss: buildLapisBlocksCss(const <LapisCustomBlock>[]),
      );
      expect(without, isNot(contains('hibiki-block')));
      expect(without, isEmpty);
    });
  });

  group('模板漂移判定', () {
    AnkiNoteTypeDefinition def(String back, {String? name}) =>
        AnkiNoteTypeDefinition(
          name: LapisNoteType.modelName,
          fields: LapisNoteType.fields,
          css: LapisNoteType.template.css,
          templates: <AnkiCardTemplate>[
            AnkiCardTemplate(
              name: name ?? LapisNoteType.cardName,
              front: LapisNoteType.front,
              back: back,
            ),
          ],
        );

    test('与期望一致 = upToDate', () {
      expect(
        decideLapisTemplateAction(
          def: def(LapisNoteType.back),
          expectedBack: LapisNoteType.back,
          lastAppliedSha: null,
        ),
        LapisStylingDecision.upToDate,
      );
    });

    test('出厂态可安全更新（第一次加区域）', () {
      final String expected = composeLapisBackTemplate(const <LapisCustomBlock>[
        LapisCustomBlock(
          id: 'b1',
          anchor: LapisBlockAnchor.bottom,
          fields: <String>['MiscInfo'],
        ),
      ]);
      expect(
        decideLapisTemplateAction(
          def: def(LapisNoteType.back),
          expectedBack: expected,
          lastAppliedSha: null,
        ),
        LapisStylingDecision.safeUpdate,
      );
    });

    test('认得自己上次写的内容 = safeUpdate', () {
      const String mine = 'MINE';
      expect(
        decideLapisTemplateAction(
          def: def(mine),
          expectedBack: LapisNoteType.back,
          lastAppliedSha: lapisCssSha256(normalizeCssForCompare(mine)),
        ),
        LapisStylingDecision.safeUpdate,
      );
    });

    test('来历不明的模板 = foreignEdit，不得静默覆盖', () {
      expect(
        decideLapisTemplateAction(
          def: def('用户自己在 Anki 里改过的模板'),
          expectedBack: LapisNoteType.back,
          lastAppliedSha: null,
        ),
        LapisStylingDecision.foreignEdit,
      );
    });

    test('卡模板被改名或多出一张 = foreignEdit', () {
      // 结构已经不是我们认识的样子，只有用户显式确认才可以覆盖。
      expect(
        decideLapisTemplateAction(
          def: def(LapisNoteType.back, name: 'Card 2'),
          expectedBack: LapisNoteType.back,
          lastAppliedSha: null,
        ),
        LapisStylingDecision.foreignEdit,
      );
    });

    test('模板指纹与 CSS 指纹互不背书', () {
      // 拿 CSS 的指纹去认模板，等于让样式给模板背书——模板写坏是卡片内容不
      // 显示，比样式写坏严重一个量级。
      const String mine = 'MINE';
      expect(
        decideLapisTemplateAction(
          def: def(mine),
          expectedBack: LapisNoteType.back,
          lastAppliedSha: lapisCssSha256(LapisNoteType.template.css),
        ),
        LapisStylingDecision.foreignEdit,
      );
    });
  });

  group('预览', () {
    test('区域在预览里渲染并可点选', () {
      final String preview = _previewBack(const <LapisCustomBlock>[
        LapisCustomBlock(
          id: 'b1',
          anchor: LapisBlockAnchor.bottom,
          fields: <String>['Frequency'],
        ),
      ]);
      expect(preview, contains('data-hibiki-block="b1"'));
      expect(preview, contains('data-hibiki-lapis-targets="block-b1"'));
      // 示例内容而不是 handlebar：预览里不该出现 mustache。
      expect(preview, contains('1320'));
      expect(preview, isNot(contains('{{')));
    });

    test('空区域在预览里看得见（真卡上才隐藏）', () {
      // 否则「添加区域」之后屏幕上什么都没有，用户既选不中也不知道它在哪。
      final String preview = _previewBack(const <LapisCustomBlock>[
        LapisCustomBlock(
          id: 'b1',
          anchor: LapisBlockAnchor.top,
          fields: <String>[],
        ),
      ]);
      expect(preview, contains('data-hibiki-block="b1"'));
      expect(preview, contains('hibiki-preview-block-empty'));
    });

    test('预览区域与真模板结构同形（样式 selector 才准）', () {
      const LapisCustomBlock block = LapisCustomBlock(
        id: 'b1',
        anchor: LapisBlockAnchor.bottom,
        fields: <String>['Frequency'],
      );
      final String preview = _previewBack(<LapisCustomBlock>[block]);
      final String real = buildLapisBlockHtml(block);
      for (final String anchor in <String>[
        'class="hibiki-block"',
        'data-hibiki-block="b1"',
        'class="hibiki-block-field"',
        'data-hibiki-field="Frequency"',
      ]) {
        expect(real, contains(anchor));
        expect(preview, contains(anchor), reason: '预览与真模板结构漂开：$anchor');
      }
    });

    test('区域目标名与字段 wireName 不撞', () {
      expect(lapisBlockIdFromPreviewTarget('block-b1'), 'b1');
      for (final LapisVisualField field in LapisVisualField.values) {
        expect(
          lapisBlockIdFromPreviewTarget(field.wireName),
          isNull,
          reason: '${field.wireName} 会被误解析成区域 id',
        );
      }
    });
  });
}
