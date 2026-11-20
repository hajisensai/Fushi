/// 「下载后端 = 互联设备」的配置与身份：编解码往返、不受本平台引擎能力影响、
/// 配置档身份跟着那台 host 而不是某一条地址走（路径映射按身份绑定）。
library;

import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:test/test.dart';

void main() {
  const QbConnectionConfig remote = QbConnectionConfig(
    backend: QbConnectionConfig.backendFushiHost,
    remoteHostId: 'vm-host-1',
    remoteHostUrl: 'https://192.168.1.41:8766',
  );

  test('编解码往返保留后端与 host', () {
    final QbConnectionConfig decoded = decodeQbConnectionConfig(
      encodeQbConnectionConfig(remote),
    )!;
    expect(decoded.backend, QbConnectionConfig.backendFushiHost);
    expect(decoded.remoteHostId, 'vm-host-1');
    expect(decoded.remoteHostUrl, 'https://192.168.1.41:8766');
  });

  test('没有内置引擎的平台也照样解析成互联设备（不被规约回 qb）', () {
    expect(
      remote.resolveBackend(embeddedSupported: false),
      QbConnectionConfig.backendFushiHost,
    );
    expect(
      remote.resolveBackend(embeddedSupported: true),
      QbConnectionConfig.backendFushiHost,
    );
  });

  test('没选设备 = 未配置', () {
    expect(remote.isConfigured, isTrue);
    expect(
      const QbConnectionConfig(
        backend: QbConnectionConfig.backendFushiHost,
      ).isConfigured,
      isFalse,
    );
  });

  test('身份按 hostId：同一台 host 换地址不是换了下载器', () {
    VideoDownloadBackendIdentity identityOf(QbConnectionConfig c) =>
        buildVideoDownloadBackendIdentity(
          config: c,
          resolvedBackend: QbConnectionConfig.backendFushiHost,
          embeddedInstallationId: '',
        );
    final VideoDownloadBackendIdentity a = identityOf(remote);
    final VideoDownloadBackendIdentity moved = identityOf(
      remote.copyWith(remoteHostUrl: 'p2p://node-xyz'),
    );
    final VideoDownloadBackendIdentity other = identityOf(
      remote.copyWith(remoteHostId: 'another-host'),
    );
    expect(a.kind, QbConnectionConfig.backendFushiHost);
    expect(a.matches(moved), isTrue);
    expect(a.matches(other), isFalse);
    expect(
      () => identityOf(
        const QbConnectionConfig(backend: QbConnectionConfig.backendFushiHost),
      ),
      throwsArgumentError,
    );
  });
}
