import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/settings/settings_schema_fields.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Fushi API 密钥行：行尾「复制」按钮复制明文（遮蔽态也是）；值被别处改写（「生成
/// 密钥」播种）时输入框跟着刷新——此前只在 initState 读一次初值，播种后仍显示空。
void main() {
  testWidgets('copyable：遮蔽态复制明文', (WidgetTester tester) async {
    final List<String> clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsSecretField(
            title: 'Fushi API key',
            icon: null,
            initialValue: 'secret-key',
            obscureText: true,
            revealToggle: true,
            copyable: true,
            onChanged: (String _) async {},
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(FushiIcons.copy));
    await tester.pump();
    expect(clipboard, <String>['secret-key']);
  });

  testWidgets('不带 copyable 时没有复制按钮', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsSecretField(
            title: 'Plain',
            icon: null,
            initialValue: 'v',
            onChanged: (String _) async {},
          ),
        ),
      ),
    );
    expect(find.byIcon(FushiIcons.copy), findsNothing);
  });

  testWidgets('外部改写值时回填输入框', (WidgetTester tester) async {
    String value = '';
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              rebuild = setState;
              return SettingsSecretField(
                title: 'Fushi API key',
                icon: null,
                initialValue: value,
                onChanged: (String _) async {},
              );
            },
          ),
        ),
      ),
    );
    expect(find.widgetWithText(TextField, 'seeded'), findsNothing);

    rebuild(() => value = 'seeded');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'seeded',
    );
  });

  testWidgets('防抖未落（用户还在输入）时不被外部值覆盖', (WidgetTester tester) async {
    String value = 'a';
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              rebuild = setState;
              return SettingsSecretField(
                title: 'Key',
                icon: null,
                initialValue: value,
                onChanged: (String _) async {},
              );
            },
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'typing');
    rebuild(() => value = 'external');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'typing',
    );
    // 冲刷防抖计时器，避免挂起的 Timer 让测试收尾报错。
    await tester.pump(const Duration(seconds: 1));
  });
}
