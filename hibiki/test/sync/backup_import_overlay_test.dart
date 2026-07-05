// TODO-1151：本地备份「导入/恢复」无反馈 + 突然退出误以为失败的修复守卫。
//
// 旧行为：导入期只有设置行 24px 小圈；成功后延迟 500ms 直接 exit(0)/FlutterExitApp，
// 用户看到 app「突然消失」误以为失败。
//
// 修复（镜像 TODO-959 数据根迁移遮罩）：
//   ① 导入执行期把根 widget 切到全屏「正在导入备份，请勿关闭」遮罩 + 进度条；
//   ② 结束后切到「导入完成 → 立即重启」确认视图，由用户点按后再退出。
//
// 本文件：widget 测试断言两阶段 UI（导入期遮罩 / 退出前确认按钮）+ 源码守卫锁住接线。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/app_model.dart' show BackupImportPhase;
import 'package:hibiki/src/sync/backup_import_overlay_view.dart';

void main() {
  group('BackupImportOverlayView（修①/修②：两阶段遮罩）', () {
    testWidgets('running：明确「正在导入备份/请勿关闭」文案 + 进度条，无重启按钮',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            ),
            home: BackupImportOverlayView(
              phase: BackupImportPhase.running,
              onRestart: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      // 导入期明确告知用户在导入——这正是旧版 24px 小圈缺的语义。
      expect(find.text(t.backup_import_overlay_title), findsOneWidget);
      expect(find.text(t.backup_import_overlay_warning), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // 导入尚未结束，不得出现「立即重启」确认按钮。
      expect(find.text(t.backup_import_restart_button), findsNothing);

      // 背景非纯黑（消除「app 突然黑屏消失」的观感）。
      final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, isNotNull);
      expect(scaffold.backgroundColor, isNot(equals(Colors.black)));
    });

    testWidgets('done：显示结果文案 + 「立即重启」确认按钮；点按触发 onRestart（不自动退出）',
        (WidgetTester tester) async {
      int restarts = 0;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
            ),
            home: BackupImportOverlayView(
              phase: BackupImportPhase.done,
              message: t.backup_import_success,
              onRestart: () => restarts++,
            ),
          ),
        ),
      );
      await tester.pump();

      // 结束态：结果文案 + 明确的「立即重启」确认按钮，而非旧版「延迟后突然退出」。
      expect(find.text(t.backup_import_success), findsOneWidget);
      expect(find.text(t.backup_import_restart_button), findsOneWidget);
      // running 期的进度条已消失。
      expect(find.byType(LinearProgressIndicator), findsNothing);

      // 退出必须由用户点按驱动：点按前不退出，点按后恰好触发一次。
      expect(restarts, 0);
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(restarts, 1);
    });

    testWidgets('failed：红色 error_outline 错误图标（非绿✓）+ 失败文案 + 重启按钮',
        (WidgetTester tester) async {
      // TODO-1183 根治「导入失败却显绿✓成功」：failed 态必须画错误图标而非成功勾。
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
            ),
            home: BackupImportOverlayView(
              phase: BackupImportPhase.failed,
              message: 'Backup import failed: out of memory',
              onRestart: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(find.text('Backup import failed: out of memory'), findsOneWidget);
      // DB 已关闭，失败也必须给「立即重启」出口。
      expect(find.text(t.backup_import_restart_button), findsOneWidget);
      // running 期的进度条已消失。
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('running：progress 有值 → 确定进度条（value 非空且跟随更新）',
        (WidgetTester tester) async {
      // TODO-1183：后台解压 isolate 经 SendPort 回报字节 → 确定进度，不再「卡死」。
      final ValueNotifier<double> progress = ValueNotifier<double>(0.42);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            ),
            home: BackupImportOverlayView(
              phase: BackupImportPhase.running,
              progress: progress,
              onRestart: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      final LinearProgressIndicator bar =
          tester.widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator));
      expect(bar.value, isNotNull);
      expect(bar.value, closeTo(0.42, 1e-9));

      // 进度推进只重建进度条（ValueListenableBuilder），值跟随更新。
      progress.value = 0.87;
      await tester.pump();
      final LinearProgressIndicator bar2 =
          tester.widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator));
      expect(bar2.value, closeTo(0.87, 1e-9));
    });
  });

  group('源码守卫 (TODO-1151)', () {
    File readSource(String rel) {
      final File f = File(rel);
      expect(f.existsSync(), isTrue, reason: 'missing source file: $rel');
      return f;
    }

    test('main.dart：备份导入遮罩分支在裸 loading 分支之前，且渲染专用视图', () {
      final String src = readSource('lib/main.dart').readAsStringSync();
      final int backupIdx = src.indexOf('appModel.backupImportActive');
      final int loadingIdx = src.indexOf('if (!appModel.isInitialised)');
      expect(backupIdx, greaterThan(0), reason: '根 widget 必须有备份导入遮罩分支');
      expect(loadingIdx, greaterThan(0));
      expect(backupIdx, lessThan(loadingIdx),
          reason: '导入遮罩必须在裸 loading 分支之前命中，否则导入期回退近黑屏');
      expect(src.contains('BackupImportOverlayView('), isTrue);
      // 退出由确认视图按钮驱动（onRestart 注入 backupImportRestart）。
      expect(src.contains('onRestart: backupImportRestart'), isTrue);
    });

    test('backup.part：先 beginBackupImport 再 closeDatabase（遮罩→关库顺序）', () {
      final String src =
          readSource('lib/src/sync/sync_settings_schema/backup.part.dart')
              .readAsStringSync();
      final int beginIdx = src.indexOf('appModel.beginBackupImport()');
      final int closeIdx = src.indexOf('await appModel.closeDatabase()');
      expect(beginIdx, greaterThan(0), reason: '必须先把导入遮罩顶上来');
      expect(closeIdx, greaterThan(0));
      expect(beginIdx, lessThan(closeIdx),
          reason: 'beginBackupImport 必须在 closeDatabase 之前，否则导入期回退裸 loading');
    });

    test(
        'backup.part：成功走 completeBackupImport / 失败走 failBackupImport；删除旧的 500ms 自动退出',
        () {
      final String src =
          readSource('lib/src/sync/sync_settings_schema/backup.part.dart')
              .readAsStringSync();
      // 成功与失败两条路径都切到确认视图（TODO-1183：失败走 failed 态而非绿✓）。
      expect(
          src.contains('completeBackupImport(t.backup_import_success)'), isTrue,
          reason: '导入成功必须切到确认视图，而非直接退出');
      expect(src.contains('failBackupImport('), isTrue,
          reason: '导入失败必须切 failed 态（根治「失败显绿✓」，TODO-1183）');
      expect(src.contains('t.backup_import_failed('), isTrue);
      // _import 里不得再有「延迟 500ms 后自动退出」的旧逻辑。
      final int importIdx = src.indexOf('Future<void> _import()');
      final int nextTop =
          src.indexOf('Future<_BackupImportChoice?>', importIdx);
      final String importBody = src.substring(importIdx, nextTop);
      expect(
        importBody.contains('Duration(milliseconds: 500)'),
        isFalse,
        reason: '导入完成不得再「延迟 500ms 后突然 exit」——那会让用户以为失败',
      );
      expect(importBody.contains('exit(0)'), isFalse,
          reason: '_import 里不得直接 exit(0)，退出改由确认视图按钮驱动');
    });

    test('backup.part：backupImportRestart 保留原平台退出分支（never-break）', () {
      final String src =
          readSource('lib/src/sync/sync_settings_schema/backup.part.dart')
              .readAsStringSync();
      final int fnIdx = src.indexOf('void backupImportRestart()');
      expect(fnIdx, greaterThan(0), reason: '必须有供确认按钮调用的退出函数');
      final String fnBody = src.substring(fnIdx, fnIdx + 200);
      expect(fnBody.contains('FlutterExitApp.exitApp()'), isTrue);
      expect(fnBody.contains('exit(0)'), isTrue);
    });
  });
}
