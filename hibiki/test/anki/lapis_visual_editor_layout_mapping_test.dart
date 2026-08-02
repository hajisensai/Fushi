// 可视化编辑器三项新能力的行为守卫：区块位置、字段映射、任意取色。
//
// 都走真实页面：装载 → 交互 → 点保存 → 断言弹回的 [LapisVisualEditorResult]。
// 纯函数层（位置 CSS 生成 / 字段来源真相源）的守卫在
// packages/hibiki_anki/test/lapis_styling_test.dart。
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/anki/lapis_style_editor_page.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

import 'lapis_style_editor_harness.dart';

/// 展开某个 [ExpansionTile] 并等动画结束。
Future<void> _expand(WidgetTester tester, String title) async {
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

void main() {
  group('区块位置', () {
    testWidgets('选了例句位置后保存，托管区段带上桌面+移动端变量', (WidgetTester tester) async {
      useWideWindow(tester);

      final LapisVisualEditorResult? result = await openEditorAndSave(
        tester,
        initialCustomCss: '',
        interact: (WidgetTester tester) async {
          await _expand(tester, t.anki_lapis_visual_layout);
          await tester.tap(
            find.text(t.anki_lapis_visual_layout_sentence),
          );
          await tester.pumpAndSettle();
          await tester
              .tap(find.text(t.anki_lapis_visual_layout_sentence_below).last);
          await tester.pumpAndSettle();
        },
      );

      expect(result, isNotNull);
      expect(result!.customCss, contains('--sentence-position: "below";'));
      expect(
        result.customCss,
        contains('--mobile-sentence-position: "below";'),
      );
      // 位置存进托管区段的 CONFIG，重开页面能回读。
      expect(
        splitLapisVisualStyleSheet(result.customCss).layout.sentencePosition,
        LapisSentencePosition.below,
      );
    });

    testWidgets('只改位置也能让保存按钮亮起来', (WidgetTester tester) async {
      useWideWindow(tester);
      // interact 里不碰任何字段样式；保存按钮若不认位置改动，这里点不动、
      // openEditorAndSave 会拿回 null。
      final LapisVisualEditorResult? result = await openEditorAndSave(
        tester,
        initialCustomCss: '',
        interact: (WidgetTester tester) async {
          await _expand(tester, t.anki_lapis_visual_layout);
          await tester.tap(find.text(t.anki_lapis_visual_layout_picture));
          await tester.pumpAndSettle();
          await tester
              .tap(find.text(t.anki_lapis_visual_layout_picture_left).last);
          await tester.pumpAndSettle();
        },
      );

      expect(result, isNotNull);
      expect(
        splitLapisVisualStyleSheet(result!.customCss).layout.picturePosition,
        LapisPicturePosition.left,
      );
    });

    testWidgets('已有位置的 CSS 打开后不被保存动作丢掉', (WidgetTester tester) async {
      useWideWindow(tester);

      final String stored = composeLapisVisualStyleSheet(
        freeformCss: '',
        rules: const <LapisVisualField, LapisVisualRule>{},
        layout: const LapisVisualLayout(
          audioButtonsPosition: LapisAudioButtonsPosition.alt,
        ),
      );
      final LapisVisualEditorResult? result = await openEditorAndSave(
        tester,
        initialCustomCss: stored,
      );

      expect(
        splitLapisVisualStyleSheet(result!.customCss)
            .layout
            .audioButtonsPosition,
        LapisAudioButtonsPosition.alt,
        reason: '打开-保存一轮把已有位置吃掉了',
      );
    });
  });

  group('字段映射', () {
    testWidgets('列出选中区域在当前卡型里真实存在的来源字段', (WidgetTester tester) async {
      useWideWindow(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LapisStyleEditorPage(
            initialCustomCss: '',
            fontScalePercent: 100,
            noteTypeFields: LapisNoteType.fields,
            initialFieldMappings: LapisNoteType.defaultFieldMappings,
            pickHandlebar: (_, __) async => null,
            previewBuilder: (_, __, ___) => const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 默认选中「单词」：来源是 ExpressionFurigana / Expression。
      expect(find.text('Expression'), findsOneWidget);
      expect(find.text('ExpressionFurigana'), findsOneWidget);
      expect(find.text('{expression}'), findsOneWidget);
      // 别的区域的字段不该混进来。
      expect(find.text('Glossary'), findsNothing);

      // 切到「释义列表」后只剩它自己的字段。
      await tester.tap(find.text(t.anki_lapis_visual_field_glossaries));
      await tester.pumpAndSettle();
      expect(find.text('Glossary'), findsOneWidget);
      expect(find.text('Expression'), findsNothing);
    });

    testWidgets('卡型里没有的字段不显示（选的不是 Lapis 时整块空掉）', (WidgetTester tester) async {
      useWideWindow(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LapisStyleEditorPage(
            initialCustomCss: '',
            fontScalePercent: 100,
            // 别人的卡型：字段名完全不同。
            noteTypeFields: const <String>['Front', 'Back'],
            initialFieldMappings: const <String, String>{
              'Front': '{expression}',
            },
            pickHandlebar: (_, __) async => null,
            previewBuilder: (_, __, ___) => const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 整块映射区收起：一条 Lapis 字段行都不该出现，否则映射会写到别人的
      // 卡型头上；也不该拿「这块没有字段」的说法糊弄（那是另一回事）。
      expect(find.text(t.anki_field_mappings), findsNothing);
      expect(find.text('Expression'), findsNothing);
      expect(find.text('ExpressionFurigana'), findsNothing);
      expect(find.text(t.anki_lapis_visual_mapping_none), findsNothing);
    });

    testWidgets('模板自绘、没有字段的区域给出明确说明', (WidgetTester tester) async {
      useWideWindow(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LapisStyleEditorPage(
            initialCustomCss: '',
            fontScalePercent: 100,
            noteTypeFields: LapisNoteType.fields,
            initialFieldMappings: LapisNoteType.defaultFieldMappings,
            pickHandlebar: (_, __) async => null,
            previewBuilder: (_, __, ___) => const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.anki_lapis_visual_target_inside_definition));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.anki_lapis_visual_field_definition_info));
      await tester.pumpAndSettle();

      expect(find.text(t.anki_field_mappings), findsOneWidget);
      expect(find.text(t.anki_lapis_visual_mapping_none), findsOneWidget);
    });

    testWidgets('改过的映射随保存一起回传，且只回传改过的那条', (WidgetTester tester) async {
      useWideWindow(tester);

      final List<String> asked = <String>[];
      final LapisVisualEditorResult? result = await openEditorAndSave(
        tester,
        initialCustomCss: '',
        noteTypeFields: LapisNoteType.fields,
        initialFieldMappings: LapisNoteType.defaultFieldMappings,
        pickHandlebar: (String field, String current) async {
          asked.add(field);
          return '{furigana}';
        },
        interact: (WidgetTester tester) async {
          // 映射行在控件列的滚动区里，默认可能在视口外；直接 tap 会静默 miss。
          await tester.ensureVisible(find.text('Expression'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Expression'));
          await tester.pumpAndSettle();
        },
      );

      expect(asked, <String>['Expression']);
      expect(result, isNotNull);
      expect(result!.fieldMappings, <String, String>{
        'Expression': '{furigana}',
      });
      // 只动映射没动样式，CSS 必须逐字节保持原样（不许顺手写个空托管区段）。
      expect(result.customCss, isEmpty);
    });

    testWidgets('把映射改回原值等于没改，保存按钮重新变灰', (WidgetTester tester) async {
      useWideWindow(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LapisStyleEditorPage(
            initialCustomCss: '',
            fontScalePercent: 100,
            noteTypeFields: LapisNoteType.fields,
            initialFieldMappings: LapisNoteType.defaultFieldMappings,
            // 选回原值。
            pickHandlebar: (_, __) async => '{expression}',
            previewBuilder: (_, __, ___) => const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Expression'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expression'));
      await tester.pumpAndSettle();

      final FilledButton save = tester.widget<FilledButton>(
        find.ancestor(
          of: find.byIcon(Icons.save_outlined),
          matching: find.byType(FilledButton),
        ),
      );
      expect(save.onPressed, isNull, reason: '改回原值仍算 dirty，保存按钮假亮');
    });
  });

  group('自定义区域', () {
    testWidgets('新建区域 → 选字段 → 保存整份回传', (WidgetTester tester) async {
      useWideWindow(tester);

      final LapisVisualEditorResult? result = await openEditorAndSave(
        tester,
        initialCustomCss: '',
        noteTypeFields: LapisNoteType.fields,
        interact: (WidgetTester tester) async {
          await _expand(tester, t.anki_lapis_visual_blocks);
          await tester.tap(find.text(t.anki_lapis_visual_block_add));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('MiscInfo'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('MiscInfo'));
          await tester.pumpAndSettle();
        },
      );

      expect(result, isNotNull);
      expect(result!.blocks.length, 1);
      expect(result.blocks.single.fields, <String>['MiscInfo']);
      // 区域是模板层的东西，不该顺手往 CSS 里写字段规则。
      expect(result.customCss, contains('hibiki-block'));
    });

    testWidgets('删除区域后它的样式一起消失，不留孤儿规则', (WidgetTester tester) async {
      useWideWindow(tester);
      const List<LapisCustomBlock> initial = <LapisCustomBlock>[
        LapisCustomBlock(
          id: 'b1',
          anchor: LapisBlockAnchor.bottom,
          fields: <String>['MiscInfo'],
          rule: LapisVisualRule(bold: true),
        ),
      ];
      final LapisVisualEditorResult? result = await openEditorAndSave(
        tester,
        initialCustomCss: '',
        noteTypeFields: LapisNoteType.fields,
        initialBlocks: initial,
        interact: (WidgetTester tester) async {
          // 已有区域时该折叠区默认就是展开的，不能再点一次（会收起）。
          await tester.tap(find.byIcon(Icons.delete_outline).first);
          await tester.pumpAndSettle();
        },
      );

      expect(result, isNotNull);
      expect(result!.blocks, isEmpty);
      expect(
        result.customCss,
        isNot(contains('data-hibiki-block')),
        reason: '区域删了但它的 CSS 规则还留着（孤儿规则）',
      );
    });

    testWidgets('选中区域时样式控件作用于区域本身，不误改内置字段', (WidgetTester tester) async {
      useWideWindow(tester);
      const List<LapisCustomBlock> initial = <LapisCustomBlock>[
        LapisCustomBlock(
          id: 'b1',
          anchor: LapisBlockAnchor.bottom,
          fields: <String>['MiscInfo'],
        ),
      ];
      final LapisVisualEditorResult? result = await openEditorAndSave(
        tester,
        initialCustomCss: '',
        noteTypeFields: LapisNoteType.fields,
        initialBlocks: initial,
        interact: (WidgetTester tester) async {
          await tester.tap(find.text(t.anki_lapis_visual_block_name(index: 1)));
          await tester.pumpAndSettle();
          // 复用同一个「粗体」开关——区域没有另一套样式 UI。
          await toggleBold(tester);
        },
      );

      expect(result, isNotNull);
      expect(result!.blocks.single.rule.bold, isTrue);
      // 内置字段（默认选中的「单词」）不该被顺带改掉。
      expect(
        splitLapisVisualStyleSheet(result.customCss)
            .ruleFor(LapisVisualField.expression)
            .bold,
        isFalse,
      );
    });
  });

  group('区域内的字段映射', () {
    /// 装一个已选中自定义区域的编辑器。
    Future<void> pumpWithSelectedBlock(
      WidgetTester tester, {
      required List<String> blockFields,
      LapisHandlebarPicker? pickHandlebar,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LapisStyleEditorPage(
            initialCustomCss: '',
            fontScalePercent: 100,
            noteTypeFields: LapisNoteType.fields,
            initialFieldMappings: LapisNoteType.defaultFieldMappings,
            initialBlocks: <LapisCustomBlock>[
              LapisCustomBlock(
                id: 'b1',
                anchor: LapisBlockAnchor.bottom,
                fields: blockFields,
              ),
            ],
            pickHandlebar: pickHandlebar ?? (_, __) async => null,
            previewBuilder: (_, __, ___) => const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.anki_lapis_visual_block_name(index: 1)));
      await tester.pumpAndSettle();
    }

    testWidgets('选中区域时映射区照常在，列的是这个区域选中的字段', (WidgetTester tester) async {
      useWideWindow(tester);
      await pumpWithSelectedBlock(
        tester,
        blockFields: const <String>['Frequency', 'MiscInfo'],
      );

      // 「这块显示哪些字段」与「这些字段各装什么」是正交的两层，必须同时可见。
      expect(find.text(t.anki_lapis_visual_block_fields), findsOneWidget);
      expect(find.text(t.anki_field_mappings), findsOneWidget);
      // 映射行 = 区域自己选中的字段（chips 里也有同名文本，故用 findsWidgets）。
      expect(find.text('Frequency'), findsWidgets);
      expect(find.text('{frequencies}'), findsOneWidget);
      expect(find.text('{document-title}'), findsOneWidget);
      // 不属于这个区域的字段不该出现映射行。
      expect(find.text('{expression}'), findsNothing);
    });

    testWidgets('区域还没选字段时说「还没选字段」，不谎称模板自绘', (WidgetTester tester) async {
      useWideWindow(tester);
      await pumpWithSelectedBlock(tester, blockFields: const <String>[]);

      expect(find.text(t.anki_lapis_visual_block_no_fields), findsWidgets);
      expect(
        find.text(t.anki_lapis_visual_mapping_none),
        findsNothing,
        reason: '区域「还没挑字段」被说成「模板自绘、没有字段」，用户会以为坏了',
      );
    });

    testWidgets('在区域里改映射同样随保存回传', (WidgetTester tester) async {
      useWideWindow(tester);
      final List<String> asked = <String>[];
      final LapisVisualEditorResult? result = await openEditorAndSave(
        tester,
        initialCustomCss: '',
        noteTypeFields: LapisNoteType.fields,
        initialFieldMappings: LapisNoteType.defaultFieldMappings,
        initialBlocks: const <LapisCustomBlock>[
          LapisCustomBlock(
            id: 'b1',
            anchor: LapisBlockAnchor.bottom,
            fields: <String>['MiscInfo'],
          ),
        ],
        pickHandlebar: (String field, String current) async {
          asked.add(field);
          return '{frequencies}';
        },
        interact: (WidgetTester tester) async {
          await tester.tap(find.text(t.anki_lapis_visual_block_name(index: 1)));
          await tester.pumpAndSettle();
          // 映射行在滚动区里，先滚过去再点，否则 tap 静默 miss。
          final Finder row = find.text('{document-title}');
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          await tester.tap(row);
          await tester.pumpAndSettle();
        },
      );

      expect(asked, <String>['MiscInfo']);
      expect(result, isNotNull);
      expect(result!.fieldMappings, <String, String>{
        'MiscInfo': '{frequencies}',
      });
    });
  });

  group('调色板', () {
    testWidgets('文字颜色能取预设之外的任意色并写进 CSS', (WidgetTester tester) async {
      useWideWindow(tester);

      final LapisVisualEditorResult? result = await openEditorAndSave(
        tester,
        initialCustomCss: '',
        interact: (WidgetTester tester) async {
          // 文字颜色那一行的取色器入口（第一个调色板图标）。
          await tester.tap(find.byIcon(Icons.palette_outlined).first);
          await tester.pumpAndSettle();
          expect(find.byType(ColorPicker), findsOneWidget);
          await tester.tap(find.text(t.dialog_ok));
          await tester.pumpAndSettle();
        },
      );

      expect(result, isNotNull);
      final LapisVisualRule rule = splitLapisVisualStyleSheet(
        result!.customCss,
      ).ruleFor(LapisVisualField.expression);
      expect(rule.colorHex, isNotNull);
      // 大写 #RRGGBB 是硬要求：回读时统一大写，取色器吐小写会让同一个颜色
      // 在「选中判定」和「是否 dirty」上判成两个值。
      expect(RegExp(r'^#[0-9A-F]{6}$').hasMatch(rule.colorHex!), isTrue);
      expect(result.customCss, contains('color: ${rule.colorHex} !important;'));
    });

    testWidgets('取色对话框点取消不改颜色', (WidgetTester tester) async {
      useWideWindow(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LapisStyleEditorPage(
            initialCustomCss: '',
            fontScalePercent: 100,
            previewBuilder: (_, __, ___) => const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.palette_outlined).first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(t.dialog_cancel),
        ),
      );
      await tester.pumpAndSettle();

      final FilledButton save = tester.widget<FilledButton>(
        find.ancestor(
          of: find.byIcon(Icons.save_outlined),
          matching: find.byType(FilledButton),
        ),
      );
      expect(save.onPressed, isNull, reason: '取消取色仍写了颜色');
    });

    testWidgets('自定义色在色板上单独占一颗，不会选完就消失', (WidgetTester tester) async {
      useWideWindow(tester);
      final String stored = composeLapisVisualStyleSheet(
        freeformCss: '',
        rules: const <LapisVisualField, LapisVisualRule>{
          // 预设之外的颜色。
          LapisVisualField.expression: LapisVisualRule(colorHex: '#123456'),
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LapisStyleEditorPage(
            initialCustomCss: stored,
            fontScalePercent: 100,
            previewBuilder: (_, __, ___) => const SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('#123456'),
        findsOneWidget,
        reason: '自定义色没有出现在色板上，用户看不出选中的是什么',
      );
    });
  });
}
