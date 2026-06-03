import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/dictionary_settings_dialog_page.dart';

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('local audio DBs expose reorder controls and can be reordered', (
    tester,
  ) async {
    final List<AudioSourceConfig> twoLocal = <AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'android.db', path: '/a.db'),
      AudioSourceConfig.localAudio(label: 'cc-switch.sql', path: '/b.db'),
    ];

    await tester.pumpWidget(_host(AudioSourcesDialog(
      sources: twoLocal,
      onSave: (_) {},
    )));
    await tester.pumpAndSettle();

    // 两个本地库行都渲染出来,且本地组提供「上移」重排控件(此前缺口:只读列表)。
    expect(find.text('android.db'), findsOneWidget);
    expect(find.text('cc-switch.sql'), findsOneWidget);
    final Finder moveUp = find.byIcon(Icons.keyboard_arrow_up);
    expect(moveUp, findsWidgets,
        reason: 'local audio rows must expose a move-up control');

    double topOf(String label) => tester.getTopLeft(find.text(label)).dy;
    expect(topOf('android.db'), lessThan(topOf('cc-switch.sql')),
        reason: 'initial order: android.db above cc-switch.sql');

    // 第二个库(cc-switch.sql)的「上移」按钮(最后一个,因 index 0 的上移禁用)。
    await tester.tap(moveUp.last);
    await tester.pumpAndSettle();

    // 重排生效:cc-switch.sql 现在排在 android.db 之上 = 优先级提高。
    expect(topOf('cc-switch.sql'), lessThan(topOf('android.db')),
        reason: 'move-up reorders the local DB priority (UI gap fixed)');
  });
}
