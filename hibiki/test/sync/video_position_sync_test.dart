import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';

/// TODO-653 视频播放进度跨设备同步——冲突解决纯函数守卫。
///
/// [resolveVideoPositionSync] 是 host PUT 端点与 client 恢复共用的「取较新时间戳」
/// last-write-wins 仲裁，与有声书进度的 `SyncManager._determineSyncDirection` 同范式
/// （取较新者；时间戳相等时取较大位置，"看得更远者胜"）。
void main() {
  group('resolveVideoPositionSync', () {
    test('较新远端时间戳胜出（跨设备：B 设备恢复到 A 的进度）', () {
      final ({int positionMs, int updatedAtMs}) r = resolveVideoPositionSync(
        localPositionMs: 120000,
        localUpdatedAtMs: 1000,
        remotePositionMs: 600000,
        remoteUpdatedAtMs: 2000,
      );
      expect(r.positionMs, 600000);
      expect(r.updatedAtMs, 2000);
    });

    test('较新本地时间戳胜出（旧 host 不回退本端新进度）', () {
      final ({int positionMs, int updatedAtMs}) r = resolveVideoPositionSync(
        localPositionMs: 900000,
        localUpdatedAtMs: 3000,
        remotePositionMs: 600000,
        remoteUpdatedAtMs: 2000,
      );
      expect(r.positionMs, 900000);
      expect(r.updatedAtMs, 3000);
    });

    test('时间戳相等时取较大位置（看得更远者胜）', () {
      final ({int positionMs, int updatedAtMs}) r = resolveVideoPositionSync(
        localPositionMs: 300000,
        localUpdatedAtMs: 5000,
        remotePositionMs: 700000,
        remoteUpdatedAtMs: 5000,
      );
      expect(r.positionMs, 700000);
      expect(r.updatedAtMs, 5000);
    });

    test('两侧都无记录（0/0）返回较大位置（默认 0）', () {
      final ({int positionMs, int updatedAtMs}) r = resolveVideoPositionSync(
        localPositionMs: 0,
        localUpdatedAtMs: 0,
        remotePositionMs: 0,
        remoteUpdatedAtMs: 0,
      );
      expect(r.positionMs, 0);
      expect(r.updatedAtMs, 0);
    });

    test('本地有进度、远端无记录：本地胜出（首次跨设备前不被 0 抹掉）', () {
      final ({int positionMs, int updatedAtMs}) r = resolveVideoPositionSync(
        localPositionMs: 450000,
        localUpdatedAtMs: 1700000000000,
        remotePositionMs: 0,
        remoteUpdatedAtMs: 0,
      );
      expect(r.positionMs, 450000);
      expect(r.updatedAtMs, 1700000000000);
    });

    test('远端有进度、本地无记录：远端胜出（新装设备拉到 host 进度）', () {
      final ({int positionMs, int updatedAtMs}) r = resolveVideoPositionSync(
        localPositionMs: 0,
        localUpdatedAtMs: 0,
        remotePositionMs: 360000,
        remoteUpdatedAtMs: 1700000000000,
      );
      expect(r.positionMs, 360000);
      expect(r.updatedAtMs, 1700000000000);
    });
  });

  group('video position prefs key 单一真相源', () {
    test('位置 key 与 video_hibiki_page _remotePositionPrefKey 同公式', () {
      expect(
        videoRemotePositionPrefKey('video/sample'),
        'video_remote_position_video/sample',
      );
    });

    test('时间戳 key 公式稳定', () {
      expect(
        videoRemotePositionAtPrefKey('video/sample'),
        'video_remote_position_at_video/sample',
      );
    });
  });
}
