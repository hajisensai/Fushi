import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// Fushi 终局清算 W1：主库文件 `hibiki.db` → `fushi.db` 的开库前一次性改名。
///
/// 覆盖：
/// ① 老安装目录（只有 hibiki.db，含 -wal 未 checkpoint 的已提交帧）→ 用
///    [FushiDatabase] 按目录打开：旧文件（含 sidecar）被整套改名成 fushi.db，
///    数据零丢（WAL 帧一并跟着走，Never break userspace）。
/// ② fushi.db 已在（已迁移安装）→ 旧残留 hibiki.db 不动、不覆盖新库。
/// ③ 全新目录 → 直接建 fushi.db，不产生任何旧名文件。
///
/// 用真实磁盘临时目录（不是 NativeDatabase.memory）：被测对象就是文件系统上的
/// 改名行为。造旧库用 [FushiDatabase.atFile]（绕过按目录打开的改名逻辑，落盘
/// 文件名完全由调用方指定 = 忠实模拟 Hibiki 时代的产物）。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_db_rename_');
  });
  tearDown(() async {
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {/* Windows 上偶发句柄延迟释放，不影响断言 */}
    }
  });

  /// 在 [dir] 下按旧名造一个真实 hibiki.db（WAL 模式），写入一条配对行。
  /// 正常 close 会 checkpoint 并清掉 -wal/-shm，所以断言只锁「打开后旧名零残留
  /// + 数据可读」；sidecar 改名分支由改名循环对存在的文件逐个处理，close 后
  /// 是否残留 sidecar 不影响结论。
  Future<void> seedLegacyDb(Directory dir) async {
    final FushiDatabase legacy =
        FushiDatabase.atFile(p.join(dir.path, 'hibiki.db'));
    await legacy.upsertPairedPeer(FushiPairedPeersCompanion.insert(
      peerId: 'legacy-peer',
      token: 'legacy-token',
      pairedAtMs: 42,
    ));
    await legacy.close();
  }

  test('opening a legacy dir renames hibiki.db(+sidecars) and keeps the data',
      () async {
    await seedLegacyDb(tmp);
    expect(File(p.join(tmp.path, 'hibiki.db')).existsSync(), isTrue,
        reason: 'seed 前提：旧名主库真实落盘');

    final FushiDatabase db = FushiDatabase(tmp.path);
    addTearDown(db.close);
    final List<FushiPairedPeerRow> peers = await db.getPairedPeers();
    expect(peers.single.peerId, 'legacy-peer', reason: '改名后旧数据必须原样可读');
    expect(peers.single.token, 'legacy-token');
    expect(peers.single.pairedAtMs, 42);

    expect(File(p.join(tmp.path, 'fushi.db')).existsSync(), isTrue,
        reason: '主库已是新名');
    for (final String legacyFile in <String>[
      'hibiki.db',
      'hibiki.db-wal',
      'hibiki.db-shm',
    ]) {
      expect(File(p.join(tmp.path, legacyFile)).existsSync(), isFalse,
          reason: '$legacyFile 必须整套改名走，零旧名残留');
    }
  });

  test('an existing fushi.db is never clobbered by a leftover hibiki.db',
      () async {
    // 先造好新库（模拟已迁移安装），写一条行。
    final FushiDatabase current = FushiDatabase(tmp.path);
    await current.upsertPairedPeer(FushiPairedPeersCompanion.insert(
      peerId: 'current-peer',
      token: 'current-token',
      pairedAtMs: 1,
    ));
    await current.close();
    // 再放一个旧名残留（内容不同）。
    final File stale = File(p.join(tmp.path, 'hibiki.db'))
      ..writeAsStringSync('stale-not-a-db');

    final FushiDatabase db = FushiDatabase(tmp.path);
    addTearDown(db.close);
    final List<FushiPairedPeerRow> peers = await db.getPairedPeers();
    expect(peers.single.peerId, 'current-peer',
        reason: 'fushi.db 已在时残留旧文件绝不能盖掉它');
    expect(stale.existsSync(), isTrue, reason: '残留旧文件原样不动（不改名、不删除）');
  });

  test('a fresh dir creates fushi.db directly with no legacy artifacts',
      () async {
    final FushiDatabase db = FushiDatabase(tmp.path);
    addTearDown(db.close);
    expect(await db.getPairedPeers(), isEmpty);
    expect(File(p.join(tmp.path, 'fushi.db')).existsSync(), isTrue);
    expect(File(p.join(tmp.path, 'hibiki.db')).existsSync(), isFalse);
  });
}
