// 词典详情「排序」分组：置顶 / 上移 / 下移 / 置底四个按钮各是一个 Tab 停靠点。
//
// 起因（服务器词典场景探针）：「第 n / m 位」那一行带 onTap，设置行在焦点根下是
// 单停靠点、行尾控件被 ExcludeFocus 挡出遍历，Tab 只停在整行上，四个按钮键盘
// 到不了。本机行与服务器行的详情共用这一份分组，两边同病同修。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_manager_panels.dart';
import 'package:material_ui/material_ui.dart';

/// 焦点此刻所在的、离它最近的 `dict-detail-*` 控件 key（按钮在行里，取最内层）。
String? _focusedKey() {
  final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return null;
  String? found;
  focused.visitAncestorElements((Element e) {
    final Key? key = e.widget.key;
    if (key is ValueKey<String> && key.value.startsWith('dict-detail-')) {
      found = key.value;
      return false;
    }
    return true;
  });
  return found;
}

bool _focusInside(String key) => _focusedKey() == key;

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('Tab 依次到达四个排序按钮，Enter 上移一位', (WidgetTester tester) async {
    final List<int> moves = <int>[];
    int prompts = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: FushiFocusRoot(
            child: Scaffold(
              body: SingleChildScrollView(
                child: DictionaryOrderSection(
                  position: 2,
                  count: 4,
                  onMoveTo: moves.add,
                  onMoveToPrompt: () => prompts++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 焦点根启动时把焦点放在第一个目标上；之后每按一次 Tab 记一个停靠点——一个
    // 按钮只该占一次 Tab。
    final List<String?> stops = <String?>[
      if (_focusedKey() case final String start) start,
    ];
    for (int i = 0; i < 8 && !stops.contains('dict-detail-move-to'); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      stops.add(_focusedKey());
    }
    expect(stops, <String?>[
      'dict-detail-move-top',
      'dict-detail-move-up',
      'dict-detail-move-down',
      'dict-detail-move-bottom',
      'dict-detail-move-to',
    ], reason: '「第 n / m 位」行不再吞掉行尾按钮的停靠点');

    // Shift+Tab 退回「上移」，Enter = 上移一位（2 → 1）。
    for (int i = 0; i < 6 && !_focusInside('dict-detail-move-up'); i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
    }
    expect(_focusInside('dict-detail-move-up'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(moves, <int>[1]);
    expect(prompts, 0);
    expect(tester.takeException(), isNull);
  });
}
