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
      final int start = appModel
          .indexOf('Future<void> closeDatabase({Duration? pipelineDrainTimeout})');
      expect(start, isNot(-1));
      final int end = appModel.indexOf('\n  }', start);
      expect(end, greaterThan(start));
      final String body = appModel.substring(start, end);

      final int quiesce =
          body.indexOf('await quiesceBackgroundDatabaseWriters(');
      expect(quiesce, isNot(-1),
          reason: 'closeDatabase 只关连接不停任何人，下载流水线会继续撞已关闭的 drift 连接');
      final int close = body.indexOf('await _database.close();');
      expect(close, isNot(-1));
      expect(close, greaterThan(quiesce), reason: '必须先停写手再关库——反过来等于没停');
    });

    test('quiesce 覆盖会后台写库的下载/订阅/漫画队列', () {
      final int start = appModel.indexOf(
          'Future<void> quiesceBackgroundDatabaseWriters({');
      expect(start, isNot(-1));
      // 取**完整方法体**。原先是 `substring(start, start + 600)`：函数体本身已占
      // ~500 字符，往里加任何一个新的写手（v95 的规格探测服务就是）都会把
      // `_disposeVideoDownloadPipelineRuntime(` 挤出窗口，守卫报红的却是「没覆盖
      // 流水线」——与真实缺陷无关的假信号。固定字符窗口是会随无关改动漂移的锚点。
      //
      // 结束锚点必须**先跳过命名参数表**再找 `\n  }`：本方法的签名是多行的
      // （`({\n    Duration? pipelineDrainTimeout,\n  }) async {`），直接找 `\n  }`
      // 会命中参数表的收尾，body 只剩签名、每条 contains 都恒假。上面 closeDatabase
      // 那条能直接找是因为它的签名写在一行里。
      final int bodyStart = appModel.indexOf(') async {', start);
      expect(bodyStart, greaterThan(start));
      final int end = appModel.indexOf('\n  }', bodyStart);
      expect(end, greaterThan(bodyStart));
      final String body = appModel.substring(bodyStart, end);
      expect(body, contains('_animeDownloadService?.stop()'));
      expect(body, contains('_animeDownloadSubscriptionService?.stop()'));
      expect(body, contains('_disposeVideoDownloadPipelineRuntime('),
          reason: '用户日志里的 8 条 connection-closed 就来自这个流水线');
    });

    test('管线收尾的上界是可选的：只有退出路径给，迁移路径必须等到真收尾', () {
      // 这是 BUG-1505 的另一半：把上界写死成 stop() 的全局语义，迁移/备份导入/
      // 数据根迁移这三条**也走 closeDatabase** 的路径就会放行一个在飞的 `_process`
      // —— 它随后被 `_videoDownloadBackend?.close()` 抽掉句柄，并在 `_database.close()`
      // 之后继续打已关闭的连接。而它们关库后紧接着要在**文件层**合并/替换整个 DB
      // 目录，那是数据安全问题，不是噪声问题。
      final String pipeline = File(
        'lib/src/media/video/download/video_download_pipeline_service.dart',
      ).readAsStringSync();
      expect(
        pipeline,
        contains('Future<void> stop({Duration? drainTimeout}) async {'),
        reason: '上界必须是可选参数，不能是 stop() 的全局语义',
      );
      expect(
        pipeline,
        contains('Future<void> dispose({Duration? drainTimeout}) async {'),
        reason: 'dispose 要能把「不设上界」传下去',
      );
      // 反向：closeDatabase 自己不得写死上界。
      final int closeAt = appModel.indexOf(
          'Future<void> closeDatabase({Duration? pipelineDrainTimeout})');
      final String closeBody =
          appModel.substring(closeAt, appModel.indexOf('\n  }', closeAt));
      expect(closeBody, isNot(contains('stopDrainTimeout')),
          reason: '上界由调用方给：写死在这里等于所有路径又都被放行了');
    });
  });
}
