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
    await tester.pumpAndSettle();
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
}
