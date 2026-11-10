import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/debug_pulse_panel.dart';
import 'package:fushi/src/updates/debug_pulse_service.dart';
import 'package:fushi_engine/updates/debug_pulse.dart';

/// 更新中心「应用新版」域顶部的调试版流水线面板：调试版用户一眼看到自己装的
/// 是哪个、后面出了哪些包、还有哪些 PR 没进包、自己平台的下一个包在干什么。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, Object?> platforms(String windows) => <String, Object?>{
    'android': <String, Object?>{'state': 'ok'},
    'windows': <String, Object?>{'state': windows},
    'macos': <String, Object?>{'state': 'ok'},
    'ios': <String, Object?>{'state': 'ok'},
  };

  final String body = jsonEncode(<String, Object?>{
    'schema': 1,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'repo': 'hajisensai/Fushi',
    'builds': <Object?>[
      <String, Object?>{
        'seq': 25034,
        'version': '3.3.0',
        'sha': 'a' * 40,
        'prs': <int>[3101],
        'platforms': platforms('ok'),
      },
      <String, Object?>{
        'seq': 25010,
        'version': '3.3.0',
        'sha': 'b' * 40,
        'prs': <int>[3090],
        'platforms': platforms('superseded'),
      },
    ],
    'pending': <String, Object?>{
      'headSha': 'f' * 40,
      'headSeq': 25048,
      'prs': <int>[3120],
      'platforms': platforms('building'),
    },
    'prs': <String, Object?>{
      '3101': <String, Object?>{
        'number': 3101,
        'title': 'feat(server): redesign the admin WebUI',
      },
      '3090': <String, Object?>{'number': 3090, 'title': 'fix: old bug'},
      '3120': <String, Object?>{'number': 3120, 'title': 'perf: faster import'},
    },
  });

  Widget host(DebugPulsePanel panel) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: panel)),
  );

  testWidgets('装的是旧包：标出新包数、更新按钮指向本平台最新可用包、新包默认展开', (WidgetTester tester) async {
    int updates = 0;
    await tester.pumpWidget(
      host(
        DebugPulsePanel(
          service: DebugPulseService(fetchBody: () async => body),
          installedSeq: 25010,
          platform: DebugPulsePlatform.windows,
          onUpdate: () => updates++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.updates_pulse_newer(builds: 1, prs: 1)), findsOneWidget);
    expect(find.text(t.updates_pulse_installed_tag), findsOneWidget);
    expect(find.text(t.updates_pulse_new_tag), findsOneWidget);
    // 新包展开：去掉前缀的标题、scope 胶囊；旧包（已装）收起。
    expect(find.text('redesign the admin WebUI'), findsOneWidget);
    expect(find.text('server'), findsOneWidget);
    expect(find.text('old bug'), findsNothing);
    // 已装的那个包 Windows 被顶掉过，标出来；正常出包的不标。
    expect(
      find.text('Windows ${t.updates_pulse_state_superseded}'),
      findsOneWidget,
    );
    // 四个平台都列出来：每个包 + 还没进包各一组。
    expect(
      find.byKey(const ValueKey<String>('debug_pulse_platform_android')),
      findsNWidgets(3),
    );
    expect(
      find.text('Android ${t.updates_pulse_state_superseded}'),
      findsNothing,
    );
    // 还没进包：本平台下一个包在构建。
    expect(find.text(t.updates_pulse_pending_badge), findsOneWidget);
    expect(find.text('faster import'), findsOneWidget);
    expect(
      find.text('Windows ${t.updates_pulse_state_building}'),
      findsOneWidget,
    );

    await tester.tap(
      find.text(t.updates_pulse_update_to(build: 'debug.25034')),
    );
    expect(updates, 1);
  });

  testWidgets('点包标题行展开 / 收起', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        DebugPulsePanel(
          service: DebugPulseService(fetchBody: () async => body),
          installedSeq: 25034,
          platform: DebugPulsePlatform.android,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.updates_pulse_up_to_date), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('debug_pulse_update')),
      findsNothing,
      reason: '已是最新不给更新按钮',
    );
    expect(find.text('old bug'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('debug_pulse_build_25010')),
    );
    await tester.pumpAndSettle();
    expect(find.text('old bug'), findsOneWidget);
  });

  testWidgets('不是调试版：不标新旧、不给更新按钮', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        DebugPulsePanel(
          service: DebugPulseService(fetchBody: () async => body),
          installedSeq: null,
          platform: DebugPulsePlatform.windows,
          onUpdate: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.updates_pulse_not_debug), findsOneWidget);
    expect(find.text(t.updates_pulse_new_tag), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('debug_pulse_update')),
      findsNothing,
    );
  });

  testWidgets('本机平台没有调试包（Linux 等）：不给更新按钮', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        DebugPulsePanel(
          service: DebugPulseService(fetchBody: () async => body),
          installedSeq: 25010,
          platform: null,
          onUpdate: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 仍如实告诉用户后面出了新包，只是没有本机能装的那一个。
    expect(find.text(t.updates_pulse_new_tag), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('debug_pulse_update')),
      findsNothing,
    );
  });

  testWidgets('拉取失败：说失败，不崩', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        DebugPulsePanel(
          service: DebugPulseService(fetchBody: () async => null),
          installedSeq: 25010,
          platform: DebugPulsePlatform.windows,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.updates_pulse_load_failed), findsOneWidget);
  });
}
