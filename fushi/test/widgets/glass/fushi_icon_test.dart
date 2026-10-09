import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_icon_map.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

Widget _host(Widget child, {required bool glass}) {
  return MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[
        FushiGlassTheme(FushiGlassMaterial.liquid, glassDesign: glass),
      ],
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

Icon _renderedIcon(WidgetTester tester) => tester.widget<Icon>(
  find.descendant(of: find.byType(FushiIcon), matching: find.byType(Icon)),
);

void main() {
  testWidgets('MD3 下原样透传 Icon，字形与参数不变', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        const FushiIcon(
          Icons.close,
          size: 31,
          color: Color(0xFF123456),
          semanticLabel: 'x',
          fill: 0.5,
          weight: 300,
        ),
        glass: false,
      ),
    );
    final Icon icon = _renderedIcon(tester);
    expect(icon.icon, Icons.close);
    expect(icon.size, 31);
    expect(icon.color, const Color(0xFF123456));
    expect(icon.semanticLabel, 'x');
    expect(icon.fill, 0.5);
    expect(icon.weight, 300);
  });

  testWidgets('玻璃设计系统下映射到 CupertinoIcons', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const FushiIcon(Icons.close, size: 20), glass: true),
    );
    final Icon icon = _renderedIcon(tester);
    expect(icon.icon, CupertinoIcons.xmark);
    expect(icon.size, 20);
  });

  testWidgets('filled 映射到 _fill、outlined 映射到线框', (WidgetTester tester) async {
    expect(fushiAppleIcon(Icons.home), CupertinoIcons.house_fill);
    expect(fushiAppleIcon(Icons.home_outlined), CupertinoIcons.house);
    expect(fushiAppleIcon(Icons.star), CupertinoIcons.star_fill);
    expect(fushiAppleIcon(Icons.star_border), CupertinoIcons.star);
  });

  testWidgets('未映射图标在玻璃下保持原样', (WidgetTester tester) async {
    // fingerprint 没有语义对应的 SF 图标，刻意不收录。
    expect(
      kFushiAppleIconMap.containsKey(Icons.fingerprint.codePoint),
      isFalse,
    );
    await tester.pumpWidget(
      _host(const FushiIcon(Icons.fingerprint), glass: true),
    );
    expect(_renderedIcon(tester).icon, Icons.fingerprint);
  });

  test('非 MaterialIcons 字体与 null 原样返回', () {
    expect(fushiAppleIcon(null), isNull);
    expect(fushiAppleIcon(CupertinoIcons.add), CupertinoIcons.add);
    // codePoint 撞上表里的 key 但字体不是 MaterialIcons：不映射。
    const IconData custom = IconData(0xe16a, fontFamily: 'Custom');
    expect(fushiAppleIcon(custom), same(custom));
  });

  test('const 构造可用', () {
    // 测试默认开 track-widget-creation，不同调用点的 const widget 带不同位置参数，
    // 所以用同一调用点比较规范化。能编译过本身就证明了 const 构造。
    FushiIcon make() => const FushiIcon(Icons.add, size: 12);
    expect(identical(make(), make()), isTrue);
  });

  test('映射表的 value 全是 CupertinoIcons，key 无重复', () {
    for (final IconData value in kFushiAppleIconMap.values) {
      expect(value.fontFamily, 'CupertinoIcons');
      expect(value.fontPackage, 'cupertino_icons');
    }
    final String source = File(
      'lib/src/utils/components/glass/fushi_apple_icon_map.dart',
    ).readAsStringSync();
    final List<String> keys = RegExp(r'^\s*(0x[0-9a-fA-F]+):', multiLine: true)
        .allMatches(source)
        .map((RegExpMatch m) => m.group(1)!.toLowerCase())
        .toList();
    expect(keys.length, kFushiAppleIconMap.length);
    expect(keys.toSet().length, keys.length);
  });
}
