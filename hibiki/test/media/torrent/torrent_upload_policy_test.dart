// 上传/做种策略纯函数：默认关上传、开启后做种时长/分享率上限截停。

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/torrent_upload_policy.dart';

TorrentUploadMetrics _m({
  bool seeding = true,
  int uploaded = 0,
  int downloaded = 1000,
  int elapsedMs = 0,
}) =>
    TorrentUploadMetrics(
      isSeeding: seeding,
      uploaded: uploaded,
      downloaded: downloaded,
      seedingElapsedMs: elapsedMs,
    );

void main() {
  test('upload disabled by default → never allow upload', () {
    const QbConnectionConfig off = QbConnectionConfig();
    expect(off.uploadEnabled, isFalse);
    // 无论下载还是做种阶段，一律不上传。
    expect(shouldAllowUpload(off, _m(seeding: false)), isFalse);
    expect(shouldAllowUpload(off, _m(seeding: true)), isFalse);
  });

  test('upload enabled with no limits → always allow', () {
    const QbConnectionConfig on = QbConnectionConfig(uploadEnabled: true);
    expect(shouldAllowUpload(on, _m(seeding: false)), isTrue);
    expect(shouldAllowUpload(on, _m(uploaded: 999999, downloaded: 1)), isTrue);
  });

  group('seed time limit', () {
    const QbConnectionConfig cfg = QbConnectionConfig(
      uploadEnabled: true,
      seedTimeLimitMinutes: 60,
    );

    test('below limit → allow', () {
      expect(shouldAllowUpload(cfg, _m(elapsedMs: 59 * 60 * 1000)), isTrue);
    });

    test('at/above limit → stop', () {
      expect(shouldAllowUpload(cfg, _m(elapsedMs: 60 * 60 * 1000)), isFalse);
      expect(shouldAllowUpload(cfg, _m(elapsedMs: 120 * 60 * 1000)), isFalse);
    });

    test('time limit only applies while seeding, not during download', () {
      // 下载阶段（未做种）即便 elapsed 很大也允许上传（换下载速度）。
      expect(
          shouldAllowUpload(
              cfg, _m(seeding: false, elapsedMs: 999 * 60 * 1000)),
          isTrue);
    });
  });

  group('seed ratio limit', () {
    const QbConnectionConfig cfg = QbConnectionConfig(
      uploadEnabled: true,
      seedRatioLimit: 2.0,
    );

    test('below ratio → allow', () {
      expect(
          shouldAllowUpload(cfg, _m(uploaded: 1000, downloaded: 1000)), isTrue);
    });

    test('at/above ratio → stop', () {
      expect(shouldAllowUpload(cfg, _m(uploaded: 2000, downloaded: 1000)),
          isFalse);
      expect(shouldAllowUpload(cfg, _m(uploaded: 5000, downloaded: 1000)),
          isFalse);
    });

    test('downloaded==0 → ratio undefined, do not stop on ratio', () {
      expect(shouldAllowUpload(cfg, _m(uploaded: 5000, downloaded: 0)), isTrue);
    });
  });

  test('either limit hit stops upload (time OR ratio)', () {
    const QbConnectionConfig cfg = QbConnectionConfig(
      uploadEnabled: true,
      seedTimeLimitMinutes: 60,
      seedRatioLimit: 2.0,
    );
    // 时长未到但分享率超 → 停。
    expect(
        shouldAllowUpload(
            cfg, _m(uploaded: 3000, downloaded: 1000, elapsedMs: 0)),
        isFalse);
    // 分享率未到但时长超 → 停。
    expect(
        shouldAllowUpload(
            cfg, _m(uploaded: 0, downloaded: 1000, elapsedMs: 61 * 60 * 1000)),
        isFalse);
    // 两者都未到 → 允许。
    expect(
        shouldAllowUpload(cfg,
            _m(uploaded: 500, downloaded: 1000, elapsedMs: 10 * 60 * 1000)),
        isTrue);
  });
}
