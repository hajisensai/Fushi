import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_dialog.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:material_ui/material_ui.dart';

import 'advanced_mining_test_host.dart';

/// 反馈 -K86qlwBg6：「高级制卡」里显示 / 编辑卡片字段，编辑后的值随本次制卡发出。
///
/// 钉住：① 显示中的字段一字段一输入框，填了的进 [MiningRequestOverrides.fieldValues]、
/// 留空的不进（= 照映射自动生成）；② 「选择字段」胶囊切换显示并记住选择，隐藏的字段
/// 即使填过也不发（所见即所得）；③ 焦点在字段输入框里时 `[` / `]` 是要打的字，不触发
/// 增减句子；④ 「恢复默认」清空手改；⑤ 窄屏折叠成摘要行。
void main() {
  late FakeAdvancedMiningHost host;
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

  setUp(() => host = FakeAdvancedMiningHost());

  Future<void> open(
    WidgetTester tester,
    AdvancedMiningCapabilities caps, {
    Size size = const Size(1400, 900),
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    FushiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => Center(
              child: TextButton(
                onPressed: () => unawaited(
                  showAdvancedMiningDialog(context: ctx, capabilities: caps),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // 预填还在生成：加载条是无限动画，pumpAndSettle 永远等不到静止。
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
  }

  AdvancedMiningCapabilities videoWithFields({
    Set<String> visible = const <String>{'MainDefinition'},
  }) => host.capabilities(
    deck: host.deck(),
    fields: host.fields(visible: visible),
    sentence: host.sentence(),
    audio: host.audio(),
    video: host.video(),
  );

  Finder fieldInput(String name) => find.byWidgetPredicate(
    (Widget w) => w is TextField && w.decoration?.labelText == name,
  );

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(
      find.text(t.popup_advanced_mining_confirm_to_deck(deck: '日语::挖矿')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('显示中的字段可编辑，填了的随制卡发出', (WidgetTester tester) async {
    await open(tester, videoWithFields());
    expect(find.text(t.popup_advanced_mining_fields_section), findsOneWidget);
    expect(fieldInput('MainDefinition'), findsOneWidget);
    expect(fieldInput('Sentence'), findsNothing);
    await tester.enterText(fieldInput('MainDefinition'), 'ねこ：小型の家畜');
    await tester.pump();
    await confirm(tester);
    expect(host.confirms.single.fieldValues, <String, String>{
      'MainDefinition': 'ねこ：小型の家畜',
    });
  });

  testWidgets('留空 = 照映射自动生成：不写字段覆盖', (WidgetTester tester) async {
    await open(tester, videoWithFields());
    await confirm(tester);
    expect(host.confirms.single.fieldValues, isEmpty);
    expect(host.confirms.single.isEmpty, isTrue);
  });

  testWidgets('选择字段：切换显示并记住；隐藏的字段填过也不发', (WidgetTester tester) async {
    await open(tester, videoWithFields());
    await tester.enterText(fieldInput('MainDefinition'), '直した');
    await tester.pump();

    await tester.tap(find.byTooltip(t.popup_advanced_mining_fields_choose));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('advanced-mining-field-chip-Sentence')),
    );
    await tester.pumpAndSettle();
    expect(host.setVisibleFieldsCalls.last, <String>{
      'MainDefinition',
      'Sentence',
    });
    expect(fieldInput('Sentence'), findsOneWidget);
    await tester.enterText(fieldInput('Sentence'), '手で直した例文。');
    await tester.pump();

    final Finder mainChip = find.byKey(
      const ValueKey<String>('advanced-mining-field-chip-MainDefinition'),
    );
    // 右栏是滚动区：多出一个输入框后胶囊可能被挤到可视区外。
    await tester.ensureVisible(mainChip);
    await tester.pumpAndSettle();
    await tester.tap(mainChip);
    await tester.pumpAndSettle();
    expect(host.setVisibleFieldsCalls.last, <String>{'Sentence'});
    expect(fieldInput('MainDefinition'), findsNothing);

    await confirm(tester);
    expect(host.confirms.single.fieldValues, <String, String>{
      'Sentence': '手で直した例文。',
    });
  });

  testWidgets('一个字段都没选：直接给出选择胶囊与提示', (WidgetTester tester) async {
    await open(tester, videoWithFields(visible: const <String>{}));
    expect(find.text(t.popup_advanced_mining_fields_empty), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('advanced-mining-field-chip-Sentence')),
      findsOneWidget,
    );
  });

  testWidgets('焦点在字段输入框里：方括号打进字段，不增减句子', (WidgetTester tester) async {
    await open(tester, videoWithFields());
    await tester.tap(fieldInput('MainDefinition'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pumpAndSettle();
    expect(host.setContextCalls, isEmpty);
  });

  testWidgets('恢复默认：清空手改的字段', (WidgetTester tester) async {
    await open(tester, videoWithFields());
    await tester.enterText(fieldInput('MainDefinition'), '直した');
    await tester.pump();
    await tester.tap(find.text(t.popup_advanced_mining_reset));
    await tester.pumpAndSettle();
    await confirm(tester);
    expect(host.confirms.single.fieldValues, isEmpty);
  });

  testWidgets('窄屏：卡片字段折叠成摘要行，点开就地编辑', (WidgetTester tester) async {
    await open(tester, videoWithFields(), size: const Size(700, 900));
    expect(fieldInput('MainDefinition'), findsNothing);
    expect(find.text('MainDefinition'), findsOneWidget);
    await tester.tap(find.text(t.popup_advanced_mining_fields_section));
    await tester.pumpAndSettle();
    expect(fieldInput('MainDefinition'), findsOneWidget);
  });

  group('预填（与落卡同一条管线渲染出的值）', () {
    const String gloss = '<ol><li>cat</li></ol>';

    /// 记录每次预填请求收到的句子；按句子回一份「管线渲染结果」。
    final List<String?> previewSentences = <String?>[];
    setUp(previewSentences.clear);

    Future<Map<String, String>?> pipeline(String? sentence) async {
      previewSentences.add(sentence);
      return <String, String>{
        'Expression': '猫',
        'Sentence': sentence ?? '',
        'MainDefinition': gloss,
        'Picture': '',
      };
    }

    AdvancedMiningCapabilities withPreview(
      AdvancedMiningFieldPreview preview, {
      Set<String> visible = const <String>{'MainDefinition', 'Sentence'},
    }) => host.capabilities(
      deck: host.deck(),
      fields: host.fields(visible: visible, preview: preview),
      sentence: host.sentence(),
      audio: host.audio(),
      video: host.video(),
    );

    String inputText(WidgetTester tester, String name) =>
        tester.widget<TextField>(fieldInput(name)).controller!.text;

    testWidgets('输入框预填管线值；什么都不改直接确认 = 不写任何字段覆盖', (WidgetTester tester) async {
      await open(tester, withPreview(pipeline));
      expect(inputText(tester, 'MainDefinition'), gloss);
      // 句子取对话框句子分区合成的那句（与宿主 composeText 同口径），不是 null。
      expect(previewSentences, isNotEmpty);
      expect(previewSentences.last, isNotNull);
      expect(inputText(tester, 'Sentence'), previewSentences.last);
      await confirm(tester);
      expect(host.confirms.single.fieldValues, isEmpty);
    });

    testWidgets('只提交改过的字段（源码视图：HTML 原样）', (WidgetTester tester) async {
      await open(tester, withPreview(pipeline));
      const String edited = '<ol><li>cat (pet)</li></ol>';
      await tester.enterText(fieldInput('MainDefinition'), edited);
      await tester.pump();
      await confirm(tester);
      expect(host.confirms.single.fieldValues, <String, String>{
        'MainDefinition': edited,
      });
    });

    testWidgets('改回预填值 = 没改；清空 = 自动生成', (WidgetTester tester) async {
      await open(tester, withPreview(pipeline));
      await tester.enterText(fieldInput('MainDefinition'), 'x');
      await tester.pump();
      await tester.enterText(fieldInput('MainDefinition'), gloss);
      await tester.pump();
      await tester.enterText(fieldInput('Sentence'), '');
      await tester.pump();
      await confirm(tester);
      expect(host.confirms.single.fieldValues, isEmpty);
    });

    testWidgets('加减句子后重新预填：没改的句子跟着变，改过的不动', (WidgetTester tester) async {
      await open(tester, withPreview(pipeline));
      final String before = inputText(tester, 'Sentence');
      await tester.enterText(fieldInput('MainDefinition'), '手で直した');
      await tester.pump();
      await tester.tap(find.text(t.popup_ctx_prev_plus));
      await tester.pumpAndSettle();
      expect(host.setContextCalls.last, <int>[2, 1]);
      final String after = inputText(tester, 'Sentence');
      expect(after, isNot(before));
      expect(after, previewSentences.last);
      expect(inputText(tester, 'MainDefinition'), '手で直した');
    });

    testWidgets('预填生成中有加载态；生成完成后填入', (WidgetTester tester) async {
      final Completer<Map<String, String>?> gate =
          Completer<Map<String, String>?>();
      await open(
        tester,
        withPreview(
          (String? _) => gate.future,
          visible: const <String>{'MainDefinition'},
        ),
        settle: false,
      );
      expect(find.text(t.popup_advanced_mining_fields_loading), findsOneWidget);
      expect(inputText(tester, 'MainDefinition'), '');
      gate.complete(<String, String>{'MainDefinition': gloss});
      await tester.pumpAndSettle();
      expect(find.text(t.popup_advanced_mining_fields_loading), findsNothing);
      expect(inputText(tester, 'MainDefinition'), gloss);
    });

    testWidgets('生成中先手改的字段，预填到达后不被覆盖', (WidgetTester tester) async {
      final Completer<Map<String, String>?> gate =
          Completer<Map<String, String>?>();
      await open(
        tester,
        withPreview(
          (String? _) => gate.future,
          visible: const <String>{'MainDefinition'},
        ),
        settle: false,
      );
      await tester.enterText(fieldInput('MainDefinition'), '先写的');
      await tester.pump();
      gate.complete(<String, String>{'MainDefinition': gloss});
      await tester.pumpAndSettle();
      expect(inputText(tester, 'MainDefinition'), '先写的');
      await confirm(tester);
      expect(host.confirms.single.fieldValues, <String, String>{
        'MainDefinition': '先写的',
      });
    });

    testWidgets('生成失败：空输入框 + 提示，对话框照常可确认', (WidgetTester tester) async {
      await open(
        tester,
        withPreview(
          (String? _) async => throw StateError('mapping broken'),
          visible: const <String>{'MainDefinition'},
        ),
      );
      expect(
        find.text(t.popup_advanced_mining_fields_preview_failed),
        findsOneWidget,
      );
      expect(inputText(tester, 'MainDefinition'), '');
      await confirm(tester);
      expect(host.confirms.single.isEmpty, isTrue);
    });

    testWidgets('落卡时才生成的字段只读，不给输入框、不提交', (WidgetTester tester) async {
      await open(
        tester,
        withPreview(pipeline, visible: const <String>{'Picture'}),
      );
      expect(fieldInput('Picture'), findsNothing);
      expect(
        find.textContaining(t.popup_advanced_mining_fields_generated),
        findsOneWidget,
      );
      await confirm(tester);
      expect(host.confirms.single.fieldValues, isEmpty);
    });

    testWidgets('长释义可展开成大编辑框', (WidgetTester tester) async {
      await open(
        tester,
        withPreview(pipeline, visible: const <String>{'MainDefinition'}),
      );
      expect(
        tester.widget<TextField>(fieldInput('MainDefinition')).maxLines,
        4,
      );
      await tester.tap(find.byTooltip(t.popup_advanced_mining_fields_expand));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(fieldInput('MainDefinition')).maxLines,
        20,
      );
    });
  });
}
