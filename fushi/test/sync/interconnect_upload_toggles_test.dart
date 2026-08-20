import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-988：互联解耦(PR#223)后，互联通道复用云备份的共享 sync_*_enabled 开关——用户
/// 一开「启用互联」连接，内容就跟着自动上传给对端，失去「只对互联单独控制上不上传」的
/// 能力。修复：互联通道的「重内容」四类（书籍/词典/有声书文件/视频文件）改读互联专属
/// 上传开关（默认关），与云备份共享开关解耦。[resolveChannelSyncFlags] 是路由的纯函数
/// 落点，本测试直接验它。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ic_upload_toggles_');
    final String dbDir = p.join(tmp.path, 'db');
    Directory(dbDir).createSync(recursive: true);
    db = FushiDatabase(dbDir);
    repo = SyncRepository(db);
  });

  tearDown(() async {
    await db.close();
    await cleanupTempDir(tmp);
  });

  test('互联专属上传开关默认全关，云备份内容开关全开也不上传给互联（BUG-988）', () async {
    // 云备份内容开关全开（模拟用户为云备份开启）。词典**已没有**云侧开关：那一侧
    // 改成了设置页的显式上传 / 下载动作，云通道恒不自动同步词典。
    await repo.setSyncContentEnabled(true);
    await repo.setSyncAudioBookFilesEnabled(true);
    await repo.setSyncVideoFilesEnabled(true);

    // 云通道：读共享开关 → 全 true（词典除外，见上）。
    final ChannelSyncFlags cloud =
        await resolveChannelSyncFlags(repo, isInterconnect: false);
    expect(cloud.syncContent, isTrue);
    expect(cloud.syncDictionary, isFalse, reason: '云通道不再自动同步词典（改成显式上传 / 下载）');
    expect(cloud.syncAudioBookFiles, isTrue);
    expect(cloud.syncVideoFiles, isTrue);

    // 互联通道：读互联专属开关（默认全关）→ 云开着也不会上传给互联对端。核心修复。
    final ChannelSyncFlags ic =
        await resolveChannelSyncFlags(repo, isInterconnect: true);
    expect(ic.syncContent, isFalse, reason: '云开着也不该自动上传书给互联对端');
    expect(ic.syncDictionary, isFalse);
    expect(ic.syncAudioBookFiles, isFalse);
    expect(ic.syncVideoFiles, isFalse);
  });

  test('打开互联专属上传开关只影响互联通道，不动云通道（BUG-988）', () async {
    await repo.setInterconnectSyncContentEnabled(true);
    await repo.setInterconnectSyncDictionaryEnabled(true);
    // 云备份内容开关保持默认关。

    final ChannelSyncFlags ic =
        await resolveChannelSyncFlags(repo, isInterconnect: true);
    expect(ic.syncContent, isTrue);
    expect(ic.syncDictionary, isTrue);
    expect(ic.syncVideoFiles, isFalse, reason: '未开的类仍不传');

    final ChannelSyncFlags cloud =
        await resolveChannelSyncFlags(repo, isInterconnect: false);
    expect(cloud.syncContent, isFalse, reason: '云通道不受互联专属开关影响');
    expect(cloud.syncDictionary, isFalse);
  });

  test('位置不区分通道（轻量进度共享，跨设备续读是互联本意）', () async {
    final ChannelSyncFlags ic =
        await resolveChannelSyncFlags(repo, isInterconnect: true);
    final ChannelSyncFlags cloud =
        await resolveChannelSyncFlags(repo, isInterconnect: false);

    // 有声书播放位置恒同步（isSyncAudioBookEnabled 恒 true）——两通道一致。
    expect(ic.syncAudioBookPosition, isTrue);
    expect(cloud.syncAudioBookPosition, isTrue);
  });

  // 本地音频源数据库曾经也在 ChannelSyncFlags 里（不分通道的一个开关）。它现在**根本
  // 不在自动同步里**：既没有开关，也不在任何一条通道的 flags 上，只能由设置页的显式
  // 上传 / 下载动作搬。这条守卫钉住「它没被悄悄塞回自动 sweep」。
  test('本地音频源数据库不再是任何通道的自动同步维度', () {
    final String src =
        File('lib/src/sync/sync_auto_trigger.dart').readAsStringSync();
    expect(src.contains('syncLocalAudio:'), isFalse,
        reason: 'ChannelSyncFlags 不得再带本地音频维度');
    expect(src.contains('isSyncLocalAudioEnabled'), isFalse,
        reason: '本地音频同步开关已删除，不得再有读取方');
  });

  // 统计/收藏此前跟着云备份的 sync_stats_enabled 一刀切（上面那条测试的原始形态就
  // 断言过「统计不区分通道」）。互联页现在各有一个开关，与四个上传开关同一纪律：
  // 互联的事互联自己决定。**但**这两个新键与那四个不同——它们有旧开关，所以缺行时
  // 继承旧值而不是硬编码默认（PR#914 阻塞①，守卫见
  // pr914_interconnect_stats_migration_test.dart）。
  test('统计/收藏分通道：用户显式开了互联开关时，云关掉不牵连互联', () async {
    await repo.setSyncStatsEnabled(false);
    // 用户真的动过互联那两个开关 —— 只有这时新值才该压过旧键。
    await repo.setInterconnectSyncStatsEnabled(true);
    await repo.setInterconnectSyncFavoritesEnabled(true);

    final ChannelSyncFlags ic =
        await resolveChannelSyncFlags(repo, isInterconnect: true);
    final ChannelSyncFlags cloud =
        await resolveChannelSyncFlags(repo, isInterconnect: false);

    expect(cloud.syncStats, isFalse);
    expect(cloud.syncFavorites, isFalse, reason: '云侧两族仍同源，行为逐字节不变');
    expect(ic.syncStats, isTrue, reason: '互联读自己的键');
    expect(ic.syncFavorites, isTrue);
  });

  test('存量不变式：云的「同步统计」关着且互联新键从没写过 → 互联侧也是关的', () async {
    await repo.setSyncStatsEnabled(false);

    final ChannelSyncFlags ic =
        await resolveChannelSyncFlags(repo, isInterconnect: true);

    expect(ic.syncStats, isFalse,
        reason: '新键硬编码默认 true 会让关过统计的存量用户升级后被静默复位（PR#914 ①）');
    expect(ic.syncFavorites, isFalse);
  });

  test('关互联的共享统计不牵连共享收藏，也不牵连云通道', () async {
    await repo.setInterconnectSyncStatsEnabled(false);

    final ChannelSyncFlags ic =
        await resolveChannelSyncFlags(repo, isInterconnect: true);
    final ChannelSyncFlags cloud =
        await resolveChannelSyncFlags(repo, isInterconnect: false);

    expect(ic.syncStats, isFalse);
    expect(ic.syncFavorites, isTrue, reason: '两个开关互相独立');
    expect(cloud.syncStats, isTrue, reason: '云通道读 sync_stats_enabled，默认开启');
  });
}
