import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiFallbackTheme;
import 'package:fushi/src/pages/implementations/restore_point_rollback_panel.dart';

/// 降级屏 / 主库损坏屏上的「恢复更新前的数据」：没有还原点不显示；选一项 → 确认 →
/// 换库 → 重启；换库失败显示原因、不重启。全程焦点驱动（Enter）。
void main() {
  final RestorePoint point = RestorePoint(
    id: '20261125-142530-123-fushi-pre_update',
    directory: '/nowhere/restore_points/20261125-142530-123-fushi-pre_update',
    kind: RestorePointKind.preUpdate,
    database: RestorePointDatabase.fushi,
    createdAtMs: DateTime.utc(2026, 11, 25, 14, 25, 30).millisecondsSinceEpoch,
    fromSchema: 179,
    toSchema: 180,
    files: const <RestorePointFile>[
      RestorePointFile(name: 'fushi.db', size: 2048),
    ],
  );

  Future<void> pumpPanel(
    WidgetTester tester, {
    required List<RestorePoint> points,
    required Future<void> Function(RestorePoint) onRollback,
    required Future<void> Function() onRestart,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildFushiFallbackTheme(Brightness.light),
          home: Scaffold(
            body: Center(
              child: SingleChildScrollView(
                child: RestorePointRollbackPanel(
                  loadPoints: () => points,
                  companionOf: (_) => null,
                  onRollback: onRollback,
                  onRestart: onRestart,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pressEnter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  testWidgets('没有可用的还原点：整块不显示', (WidgetTester tester) async {
    await pumpPanel(
      tester,
      points: const <RestorePoint>[],
      onRollback: (_) async {},
      onRestart: () async {},
    );
    expect(
      find.byKey(const ValueKey<String>('restore_point_rollback_panel')),
      findsNothing,
    );
  });

  testWidgets('选一项 → 确认 → 换库 → 重启', (WidgetTester tester) async {
    final List<RestorePoint> rolledBack = <RestorePoint>[];
    int restarts = 0;
    await pumpPanel(
      tester,
      points: <RestorePoint>[point],
      onRollback: (RestorePoint p) async => rolledBack.add(p),
      onRestart: () async => restarts++,
    );
    expect(find.text(t.db_restore_point_rollback_title), findsOneWidget);
    expect(
      find.text(
        t.db_restore_point_item_title(date: restorePointDisplayDate(point)),
      ),
      findsOneWidget,
    );

    // 第一项自动拿焦点：Enter 打开确认框，确认键自动拿焦点，再 Enter 确认。
    await pressEnter(tester);
    expect(find.text(t.db_restore_point_confirm_body), findsOneWidget);
    await pressEnter(tester);

    expect(rolledBack, <RestorePoint>[point]);
    expect(restarts, 1);
  });

  testWidgets('换库失败：显示原因、不重启', (WidgetTester tester) async {
    int restarts = 0;
    await pumpPanel(
      tester,
      points: <RestorePoint>[point],
      onRollback: (_) async => throw StateError('file is locked'),
      onRestart: () async => restarts++,
    );
    await pressEnter(tester);
    await pressEnter(tester);

    expect(find.textContaining('file is locked'), findsOneWidget);
    expect(restarts, 0);
  });
}
