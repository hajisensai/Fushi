import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import 'temp_dir_cleanup.dart';

/// PR#914 阻塞①：存量用户显式关掉的「同步统计」不得被新键的默认值静默复位。
///
/// `sync.statistics`（pref `sync_stats_enabled`）是**无 visible 门控、文案就叫
/// 「同步统计」**的用户可见开关。互联的聚合同步（统计族 + 收藏族）此前完全由它代管，
/// 所以「把它关掉」= 用户已明示「别把我的统计/收藏推给对端、也别把对端的折回来」。
///
/// PR#914 给互联拆出 `interconnect_sync_stats` / `interconnect_sync_favorites` 两个
/// 新键。若新键**硬编码默认 true**，升级后新键无行 → 解析成 true → 下一轮互联 sweep
/// 就把阅读/观看统计、查词制卡计数、收藏词与收藏句推给对端并把对端的折回本地，用户
/// 零操作、零提示 —— never break userspace 被打穿。
///
/// 本文件锁死的不变式：**新键缺行时继承旧键当前值**，只有用户真的动过新开关才用新值。
/// 断言用到的关键字面量（改名要同步改这里）：
///   pref key `sync_stats_enabled` / `interconnect_sync_stats` /
///   `interconnect_sync_favorites`
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pr914_ic_stats_');
    final String dbDir = '${tmp.path}${Platform.pathSeparator}db';
    Directory(dbDir).createSync(recursive: true);
    db = FushiDatabase(dbDir);
    repo = SyncRepository(db);
  });

  tearDown(() async {
    await db.close();
    await cleanupTempDir(tmp);
  });

  test('存量库：旧键 sync_stats_enabled=false + 新键缺失 → 互联侧必须解析成 false', () async {
    // 存量用户当年在设置页把「同步统计」关掉了；互联那两个新键那时还不存在。
    await repo.setSyncStatsEnabled(false);
    expect(await db.getPref('interconnect_sync_stats'), isNull,
        reason: '前提：新键真的没有行，走的就是升级后的第一次读');
    expect(await db.getPref('interconnect_sync_favorites'), isNull);

    expect(await repo.isInterconnectSyncStatsEnabled(), isFalse,
        reason: '关过「同步统计」的存量用户升级后不得被默认值复位成「又在同步」');
    expect(await repo.isInterconnectSyncFavoritesEnabled(), isFalse,
        reason: '收藏词/收藏句拆开关前也归 sync_stats_enabled 管，同样继承');

    // 真正的消费方（互联通道的分资产门控）也必须看到 false，否则 sweep 照传不误。
    final ChannelSyncFlags ic =
        await resolveChannelSyncFlags(repo, isInterconnect: true);
    expect(ic.syncStats, isFalse);
    expect(ic.syncFavorites, isFalse);
  });

  test('全新用户：两边都没写过 → 仍是默认开（旧键自身默认 true）', () async {
    expect(await db.getPref('sync_stats_enabled'), isNull);
    expect(await repo.isInterconnectSyncStatsEnabled(), isTrue);
    expect(await repo.isInterconnectSyncFavoritesEnabled(), isTrue);
  });

  test('旧键关着，但用户显式打开了互联新开关 → 用新值（新键有行就赢）', () async {
    await repo.setSyncStatsEnabled(false);
    await repo.setInterconnectSyncStatsEnabled(true);

    expect(await repo.isInterconnectSyncStatsEnabled(), isTrue,
        reason: '用户真的动过新开关，继承逻辑必须让位');
    expect(await repo.isInterconnectSyncFavoritesEnabled(), isFalse,
        reason: '另一族没被动过，仍继承旧键');
    expect(await repo.isSyncStatsEnabled(), isFalse, reason: '互联侧的选择不得回写云备份开关');
  });

  test('旧键开着，用户显式关掉互联新开关 → 关（新值不被旧键盖掉）', () async {
    await repo.setSyncStatsEnabled(true);
    await repo.setInterconnectSyncStatsEnabled(false);
    await repo.setInterconnectSyncFavoritesEnabled(false);

    final ChannelSyncFlags ic =
        await resolveChannelSyncFlags(repo, isInterconnect: true);
    final ChannelSyncFlags cloud =
        await resolveChannelSyncFlags(repo, isInterconnect: false);
    expect(ic.syncStats, isFalse);
    expect(ic.syncFavorites, isFalse);
    expect(cloud.syncStats, isTrue, reason: '云通道读自己的键，不受互联开关影响');
  });
}
