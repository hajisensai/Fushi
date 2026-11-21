import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// BUG-4954（反馈 yi6dRmhbVQ）：Layer 0 的探测连接开库成功，随后 drift 后台连接在
/// 首个查询时第二次开库、`setup` 再跑一遍 `PRAGMA journal_mode=WAL`，这一次撞上侧车
/// 类错误（用户日志：macOS 上 SqliteException(2570) IOERR_DELETE）。此前恢复阶梯只包住
/// 探测连接，后台连接的错误原样抛到 app 层成为通用初始化错误，且 drift 远端客户端缓存
/// 了失败的 open，这条连接此后每条查询都报同一个错。
///
/// 用 [debugAfterOpenProbeForTesting] 在「探测关掉之后、后台连接开库之前」往 `-wal`
/// 路径放一个目录（与 wal_recovery_test 同一种真实、跨平台的侧车毒化），确定性地复现
/// 「探测过了、后台连接撞上侧车错误」。守：
/// 1. 主进程：后台连接走同一条恢复阶梯，查询成功、存量数据不丢、先拍快照再删侧车；
/// 2. 弹窗进程：照阶梯规则退避，抛终态 [FushiDatabaseUnrecoverableException]
///    而不是裸的 drift / sqlite 异常，且不删侧车。
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fushi_db_bg_open_');
    dbPath = p.join(tempDir.path, fushiDatabaseFileName);
  });

  tearDown(() {
    debugAfterOpenProbeForTesting = null;
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上连接可能还短暂持有文件句柄；忽略。
      }
    }
  });

  Future<void> seedHealthyDb() async {
    final FushiDatabase db = FushiDatabase(tempDir.path);
    await db.setPref('bug4954_marker', 'kept');
    await db.close();
  }

  /// 探测连接过了之后才毒化 `-wal`，只毒化一次。返回探测钩子被调用的次数。
  List<String> poisonWalAfterProbe() {
    final List<String> calls = <String>[];
    debugAfterOpenProbeForTesting = (String path) {
      calls.add(path);
      if (calls.length == 1) Directory('$path-wal').createSync();
    };
    return calls;
  }

  test('主进程：探测过了、后台连接撞上侧车错误 → 走恢复阶梯，查询成功且数据不丢', () async {
    await seedHealthyDb();
    final List<String> probeCalls = poisonWalAfterProbe();

    final FushiDatabase db = FushiDatabase(tempDir.path);
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });

    expect(await db.getPref('bug4954_marker'), 'kept');
    // 恢复后的连接继续可用（不是缓存住的失败 open）。
    await db.setPref('bug4954_after', 'written');
    expect(await db.getPref('bug4954_after'), 'written');

    expect(probeCalls, <String>[dbPath], reason: '探测连接必须先成功，错误只出在后台连接');
    expect(
      Directory('$dbPath-wal').existsSync(),
      isFalse,
      reason: '主进程的 Layer 2 应已重建侧车',
    );
    expect(
      tempDir.listSync().whereType<File>().any(
        (File f) => f.path.contains('.corrupt-bak-'),
      ),
      isTrue,
      reason: '删侧车前必须先拍 .corrupt-bak 快照',
    );
  });

  test('弹窗进程：后台连接撞上侧车错误 → 终态异常、退避不删侧车', () async {
    await seedHealthyDb();
    final List<String> probeCalls = poisonWalAfterProbe();

    final FushiDatabase popupDb = FushiDatabase(
      tempDir.path,
      isMainProcess: false,
    );
    addTearDown(() async {
      try {
        await popupDb.close();
      } catch (_) {}
    });

    await expectLater(
      popupDb.getPref('bug4954_marker'),
      throwsA(isA<FushiDatabaseUnrecoverableException>()),
      reason: '后台连接的侧车错误也必须进阶梯，不能以裸 sqlite 异常落进通用错误屏',
    );
    expect(probeCalls, <String>[dbPath]);
    expect(
      Directory('$dbPath-wal').existsSync(),
      isTrue,
      reason: ':popup 不得删除不归它管的侧车',
    );
  });
}
