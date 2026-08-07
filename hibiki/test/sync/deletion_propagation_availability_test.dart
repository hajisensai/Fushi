/// TODO-2470 死角②：没配同步后端时勾「从所有设备删除」静默无效。
///
/// 根因：勾选框的存在被硬编码成恒真，与「本机到底有没有传播通道」无关。一个后端都没配
/// 时勾上它，墓碑写进本地表、`remotePublishedAt` 永远 0、无人发布——用户以为删干净了，
/// 实际只删了本机，全程零提示。
///
/// 修复的判据是 [hasDeletionPropagationChannel]。本文件盯住它的真值表 + 两条硬约束：
/// **零网络**（跑在弹窗弹出前的 UI 路径上）、**「配置过」而非「此刻连得上」**（离线删东西
/// 时墓碑留在本地等下次发布，是正确行为，不该把选项藏起来）。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/deletion_propagation_availability.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

void main() {
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() {
    db = _memDb();
    repo = SyncRepository(db);
  });
  tearDown(() => db.close());

  group('TODO-2470 死角② 删除传播通道判据', () {
    test('全新装、零配置 → 无通道（那个勾选框兑现不了，不该摆出来）', () async {
      expect(await hasDeletionPropagationChannel(repo), isFalse);
    });

    test('配了 WebDAV 地址 → 有通道', () async {
      await repo.setBackendType(SyncBackendType.webDav);
      await repo.setWebDavUrl('https://dav.example.com/hibiki');

      expect(await hasDeletionPropagationChannel(repo), isTrue);
    });

    test('选了 WebDAV 但地址空 → 仍无通道（选中 ≠ 配置好）', () async {
      await repo.setBackendType(SyncBackendType.webDav);

      expect(await hasDeletionPropagationChannel(repo), isFalse,
          reason: 'getBackendType 缺省就返回一个值，光看它会把所有新装都误判成有通道');
    });

    test('互联启用 + 填了对端地址 → 有通道', () async {
      await repo.setInterconnectEnabled(true);
      await repo.setHibikiClientUrls(
          <FushiClientUrl>[FushiClientUrl(url: 'https://192.168.1.7:8443')]);

      expect(await hasDeletionPropagationChannel(repo), isTrue);
    });

    test('填了对端地址但互联没启用 → 无通道（通道枚举本就不含它）', () async {
      await repo.setHibikiClientUrls(
          <FushiClientUrl>[FushiClientUrl(url: 'https://192.168.1.7:8443')]);

      expect(await hasDeletionPropagationChannel(repo), isFalse);
    });

    test('本机做 host + 有已配对对端 → 有通道（对端会来读走本机墓碑）', () async {
      await repo.setInterconnectEnabled(true);
      await repo.setServerEnabled(true);
      await db.upsertPairedPeer(FushiPairedPeersCompanion.insert(
        peerId: 'peer-1',
        token: 't',
        pairedAtMs: 0,
      ));

      expect(await hasDeletionPropagationChannel(repo), isTrue,
          reason: '互联是双向的：host 侧删除经 /api/tombstones 被 client 消费');
    });

    test('开了 host 但一个对端都没配对 → 无通道', () async {
      await repo.setInterconnectEnabled(true);
      await repo.setServerEnabled(true);

      expect(await hasDeletionPropagationChannel(repo), isFalse);
    });

    test('Google Drive 同步跑过一次（有 rootFolderId）→ 有通道', () async {
      await repo.setBackendType(SyncBackendType.googleDrive);
      await repo.setRootFolderId('folder-abc/');

      expect(await hasDeletionPropagationChannel(repo), isTrue);
    });
  });

  group('hasStoredBackendConfig 逐后端', () {
    test('七个后端在零配置下一律 false（新增后端漏表态会在此暴露）', () async {
      for (final SyncBackendType type in SyncBackendType.values) {
        expect(await repo.hasStoredBackendConfig(type), isFalse,
            reason: '$type 在零配置下不该自称已配置');
      }
    });

    test('FTP / SFTP / Dropbox / OneDrive 各自的配置键都被认', () async {
      await repo.setFtpHost('ftp.example.com');
      expect(await repo.hasStoredBackendConfig(SyncBackendType.ftp), isTrue);

      await repo.setSftpHost('sftp.example.com');
      expect(await repo.hasStoredBackendConfig(SyncBackendType.sftp), isTrue);

      await repo.setDropboxToken('tok');
      expect(
          await repo.hasStoredBackendConfig(SyncBackendType.dropbox), isTrue);

      await repo.setOneDriveToken('tok');
      expect(
          await repo.hasStoredBackendConfig(SyncBackendType.oneDrive), isTrue);
    });
  });
}
