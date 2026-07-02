// TODO-959：数据迁移黑屏修复的 widget + 源码守卫测试。
//
// 黑屏两机制：
//   (A) 搬移中：迁移引擎 closeDatabase() 置 isInitialised=false → 根 widget 回退到裸
//       loading（背景 _savedSplashColor 可能 null/深色 → 近黑 + 转圈）。
//   (B) 重启后：detached 新进程不抢前台 → 短暂黑/不可见窗口。
//
// widget 测试覆盖 (A)：迁移遮罩视图渲染明确文案 + 进度条，背景非 null 非纯黑。
// 源码守卫覆盖：① 根 widget 在 loading 分支之前命中迁移遮罩分支；② 所有 loading/error/
// migration 背景都有 `?? cs.` 兜底（防回归纯黑）；③ 设置项先 begin 遮罩再 migrate +
// 线程 onProgress；④ 重启带前台标志 + main.dart 消费它做 show()/focus()。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/storage/data_root_migration_view.dart';

void main() {
  group('DataRootMigrationView (TODO-959 机制A：搬移中遮罩)', () {
    testWidgets('渲染「请勿关闭」文案 + 不确定进度条；背景非纯黑（无 splash 时回退 surface）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            ),
            home:
                const DataRootMigrationView(), // progress=null, background=null
          ),
        ),
      );
      await tester.pump();

      // 明确告知用户「不要关闭」——这正是裸 loading 缺的语义。
      expect(find.text(t.data_storage_migrate_overlay_title), findsOneWidget);
      expect(find.text(t.data_storage_migrate_overlay_warning), findsOneWidget);
      // 有进度条。progress=null → 不确定进度（value 为 null）。
      final LinearProgressIndicator bar =
          tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, isNull);

      // 背景非 null 且非纯黑（修复的核心：消除「真黑底」）。
      final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, isNotNull);
      expect(scaffold.backgroundColor, isNot(equals(const Color(0xFF000000))));
      expect(scaffold.backgroundColor, isNot(equals(Colors.black)));
    });

    testWidgets('有进度时显示确定进度条 + 文件计数文案', (WidgetTester tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
            ),
            home: const DataRootMigrationView(
              progress: (copied: 3, total: 10),
              background: Color(0xFF223344),
            ),
          ),
        ),
      );
      await tester.pump();

      final LinearProgressIndicator bar =
          tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.3, 1e-9));

      // 给定的 splash 背景被尊重（非回退）。
      final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, equals(const Color(0xFF223344)));
    });
  });

  group('源码守卫 (TODO-959)', () {
    File readSource(String rel) {
      final File f = File(rel);
      expect(f.existsSync(), isTrue, reason: 'missing source file: $rel');
      return f;
    }

    test('main.dart：迁移遮罩分支在裸 loading 分支之前', () {
      final String src = readSource('lib/main.dart').readAsStringSync();
      final int migrateIdx = src.indexOf('appModel.dataRootMigrationActive');
      final int loadingIdx = src.indexOf('if (!appModel.isInitialised)');
      expect(migrateIdx, greaterThan(0), reason: '根 widget 必须有迁移遮罩分支');
      expect(loadingIdx, greaterThan(0));
      expect(migrateIdx, lessThan(loadingIdx),
          reason: '迁移遮罩必须在裸 loading 分支之前命中，否则迁移期回退近黑屏');
      // 迁移分支渲染独立遮罩视图。
      expect(src.contains('DataRootMigrationView('), isTrue);
    });

    test('main.dart：所有 splash 背景都有 ?? cs. 兜底（防纯黑回归）', () {
      final String src = readSource('lib/main.dart').readAsStringSync();
      // 不允许出现裸 `backgroundColor: _savedSplashColor,`（无兜底）。
      expect(
        src.contains('backgroundColor: _savedSplashColor,'),
        isFalse,
        reason: 'loading/error 分支的 _savedSplashColor 必须 ?? cs.xxx 兜底',
      );
    });

    test('main.dart：重启标志 → 主窗口 show()/focus() 抢前台（机制B）', () {
      final String src = readSource('lib/main.dart').readAsStringSync();
      expect(src.contains('DesktopLifecycleService.restartMarkerArg'), isTrue);
      expect(src.contains('windowManager.show()'), isTrue);
      expect(src.contains('windowManager.focus()'), isTrue);
    });

    test('desktop_lifecycle_service：重启给新进程带上前台标志', () {
      final String src =
          readSource('lib/src/platform/desktop/desktop_lifecycle_service.dart')
              .readAsStringSync();
      expect(src.contains('restartMarkerArg'), isTrue);
      // 标志被实际加进 Process.start 的 args。
      expect(src.contains('restartMarkerArg,'), isTrue);
    });

    test('data_root.part：先 begin 遮罩再 migrate，并线程 onProgress', () {
      final String src =
          readSource('lib/src/sync/sync_settings_schema/data_root.part.dart')
              .readAsStringSync();
      final int beginIdx = src.indexOf('beginDataRootMigration()');
      final int migrateIdx = src.indexOf('DataRootMigrator().migrate(');
      expect(beginIdx, greaterThan(0), reason: '必须先把遮罩顶上来（顺序铁律：遮罩→关库→搬文件）');
      expect(migrateIdx, greaterThan(0));
      expect(beginIdx, lessThan(migrateIdx),
          reason: 'beginDataRootMigration 必须在 migrate 之前调用');
      // onProgress 回灌进度到遮罩。
      expect(src.contains('updateDataRootMigrationProgress('), isTrue);
      expect(src.contains('onProgress:'), isTrue);
    });

    test('data_root.part：迁移失败同步写错误日志再重启', () {
      final String src =
          readSource('lib/src/sync/sync_settings_schema/data_root.part.dart')
              .readAsStringSync();
      final int logIdx = src.indexOf("logFatal('DataRootMigration.migrate'");
      final int recoverIdx = src.indexOf('_recoverAfterFailedMigration(');
      expect(logIdx, greaterThan(0), reason: '迁移失败必须同步落错误日志');
      expect(recoverIdx, greaterThan(logIdx),
          reason: '错误日志必须在自动重启前落盘，否则失败原因会消失');
    });
  });
}
