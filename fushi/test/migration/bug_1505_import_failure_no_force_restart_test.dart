import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1505 守卫：迁移导入失败时，**页面不许被强制重启带走**，失败原因必须落盘，
/// 且关库之前必须把后台写手停掉。
///
/// 用户现场（真机 CPH2747，Fushi 1.4.0-debug.10363）三个事实：
/// 1. 「导入的时候报错了，然后一下就退出了页面」——失败路径 `failBackupImport()` 之后
///    补了 `delay(2s)` + `backupImportRestart()`，直接换进程。而遮罩的失败态本来就
///    设计成「不自动、由用户读完原因手点」（main.dart 的 BackupImportOverlayView 注释），
///    这里把设计覆盖掉了。
/// 2. 设置→系统→诊断里「错误日志 (0)」——`ErrorLogService.log()` 的落盘是
///    fire-and-forget 串行链，强制重启把在途写入一起带走，所以那句号称「必须落日志」
///    的修复实际从未生效。必须 await `pendingFileWrite`。
/// 3. 当天日志里 8 条 drift `connection was closed`，全来自
///    `VideoDownloadPipelineService._drain`——`closeDatabase()` 只关连接、不停任何人，
///    合并导入正在直接操作同一个库文件时还放着第二个写手在跑。
void main() {
  final String importPage = File(
    'lib/src/pages/implementations/migration_import_page.dart',
  ).readAsStringSync();
  final String appModel =
      File('lib/src/models/app_model.dart').readAsStringSync();

  group('BUG-1505 导入失败不再强制重启', () {
    test('两条失败路径都不再自动重启（成功路径保留）', () {
      // 失败分支的标志句：countProblems / catch。两处都不许再出现 backupImportRestart。
      final int catchIndex = importPage.indexOf('} catch (e, st) {');
      expect(catchIndex, isNot(-1));
      final String catchBlock = importPage.substring(catchIndex);
      expect(catchBlock.contains('backupImportRestart'), isFalse,
          reason: '失败要停在遮罩上让用户读完原因，重启由他手点');

      final int countsIndex = importPage.indexOf('countProblems.isNotEmpty');
      expect(countsIndex, isNot(-1));
      // 切片终点用**代码符号**而不是中文注释：上一版拿「校验通过」这句注释当锚点，
      // BUG-1510 顺手改了那行注释，守卫就 indexOf 返回 -1 直接炸。
      final int countsEnd =
          importPage.indexOf('MigrationImporter.writeCompletionPrefs(');
      expect(countsEnd, greaterThan(countsIndex));
      final String countsBlock = importPage.substring(countsIndex, countsEnd);
      expect(countsBlock.contains('backupImportRestart'), isFalse,
          reason: '行数校验失败同理：不许把页面和原因一起带走');

      // 成功路径仍自动重启（DB 已关，且没有要读的东西）。
      expect(importPage, contains('completeBackupImport'));
      expect(importPage, contains('await backupImportRestart(appModel)'),
          reason: '成功路径的自动重启是刻意保留的，别一起删掉');
    });

    test('失败原因必须 await 落盘，否则重启后「错误日志 (0)」', () {
      expect(importPage, contains('await ErrorLogService.instance.flush()'),
          reason: 'log() 只是把 append 挂进 fire-and-forget 链，不 await 就会随进程消失');
      // 两条失败路径各一次。
      final int occurrences = 'await ErrorLogService.instance.flush()'
          .allMatches(importPage)
          .length;
      expect(occurrences, greaterThanOrEqualTo(2),
          reason: 'verifyCounts 与 catch 两条失败路径都要等落盘');
    });
  });

  group('BUG-1505 关库前停后台写手', () {
    test('closeDatabase 在 close() 之前先 quiesce', () {
      // 断言必须收在 closeDatabase **方法体内**：变异实测发现，跨方法找下一处
      // `await _database.close();` 会匹配到 closeForPopup 那句，于是把顺序颠倒过来
      // 守卫照样绿——这条断言本身就是被变异测试咬出来的洞。
      final int start =
          appModel.indexOf('Future<void> closeDatabase() async {');
      expect(start, isNot(-1));
      final int end = appModel.indexOf('\n  }', start);
      expect(end, greaterThan(start));
      final String body = appModel.substring(start, end);

      final int quiesce =
          body.indexOf('await quiesceBackgroundDatabaseWriters();');
      expect(quiesce, isNot(-1),
          reason: 'closeDatabase 只关连接不停任何人，下载流水线会继续撞已关闭的 drift 连接');
      final int close = body.indexOf('await _database.close();');
      expect(close, isNot(-1));
      expect(close, greaterThan(quiesce), reason: '必须先停写手再关库——反过来等于没停');
    });

    test('quiesce 覆盖会后台写库的下载/订阅/漫画队列', () {
      final int start = appModel
          .indexOf('Future<void> quiesceBackgroundDatabaseWriters() async {');
      expect(start, isNot(-1));
      final String body = appModel.substring(start, start + 600);
      expect(body, contains('_animeDownloadService?.stop()'));
      expect(body, contains('_animeDownloadSubscriptionService?.stop()'));
      expect(body, contains('_disposeVideoDownloadPipelineRuntime()'),
          reason: '用户日志里的 8 条 connection-closed 就来自这个流水线');
    });
  });
}
