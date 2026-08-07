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
  late HibikiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ic_upload_toggles_');
    final String dbDir = p.join(tmp.path, 'db');
    Directory(dbDir).createSync(recursive: true);
    db = HibikiDatabase(dbDir);
    repo = SyncRepository(db);
  });

  tearDown(() async {
    await db.close();
    await cleanupTempDir(tmp);
  });

  test('互联专属上传开关默认全关，云备份内容开关全开也不上传给互联（BUG-988）', () async {
    // 云备份内容开关全开（模拟用户为云备份开启）。
    await repo.setSyncContentEnabled(true);
    await repo.setSyncDictionaryEnabled(true);
    await repo.setSyncAudioBookFilesEnabled(true);
    await repo.setSyncVideoFilesEnabled(true);

    // 云通道：读共享开关 → 全 true。
    final ChannelSyncFlags cloud =
        await resolveChannelSyncFlags(repo, isInterconnect: false);
    expect(cloud.syncContent, isTrue);
    expect(cloud.syncDictionary, isTrue);
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

  test('位置/统计/本地音频不区分通道（轻量进度共享，跨设备续读是互联本意）', () async {
    await repo.setSyncStatsEnabled(false);
    await repo.setSyncLocalAudioEnabled(true);

    final ChannelSyncFlags ic =
        await resolveChannelSyncFlags(repo, isInterconnect: true);
    final ChannelSyncFlags cloud =
        await resolveChannelSyncFlags(repo, isInterconnect: false);

    expect(ic.syncStats, cloud.syncStats);
    expect(ic.syncStats, isFalse);
    expect(ic.syncLocalAudio, cloud.syncLocalAudio);
    expect(ic.syncLocalAudio, isTrue);
    // 有声书播放位置恒同步（isSyncAudioBookEnabled 恒 true）——两通道一致。
    expect(ic.syncAudioBookPosition, isTrue);
    expect(cloud.syncAudioBookPosition, isTrue);
  });
}
