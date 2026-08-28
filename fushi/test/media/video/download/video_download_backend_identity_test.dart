import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';

void main() {
  test('missing embedded runtime is rejected before a job is persisted', () {
    expect(
      () => buildVideoDownloadBackendIdentity(
        config: const QbConnectionConfig(
          backend: QbConnectionConfig.backendEmbedded,
        ),
        resolvedBackend: QbConnectionConfig.backendEmbedded,
        embeddedInstallationId: 'installation-1',
        embeddedAvailable: false,
      ),
      throwsA(
        isA<VideoDownloadBackendUnavailable>().having(
          (VideoDownloadBackendUnavailable error) => error.message,
          'message',
          contains('built-in download engine runtime is missing'),
        ),
      ),
    );
  });

  test('available embedded runtime keeps its installation-bound identity', () {
    final VideoDownloadBackendIdentity identity =
        buildVideoDownloadBackendIdentity(
      config: const QbConnectionConfig(
        backend: QbConnectionConfig.backendEmbedded,
        category: 'fushi',
      ),
      resolvedBackend: QbConnectionConfig.backendEmbedded,
      embeddedInstallationId: 'installation-1',
    );

    expect(identity.kind, QbConnectionConfig.backendEmbedded);
    expect(identity.profileId, 'embedded');
    expect(identity.fingerprint, hasLength(64));
  });

  test('分类不是身份的一部分：改分类不换身份', () {
    // BUG-1879：分类曾是 VideoDownloadBackendIdentity 的字段并参与流水线守卫，
    // 用户改一次分类就把全部在途任务判成「后端换了」。
    VideoDownloadBackendIdentity build(String category) =>
        buildVideoDownloadBackendIdentity(
          config: QbConnectionConfig(
            backend: QbConnectionConfig.backendEmbedded,
            category: category,
          ),
          resolvedBackend: QbConnectionConfig.backendEmbedded,
          embeddedInstallationId: 'installation-1',
        );

    final VideoDownloadBackendIdentity before = build('hibiki');
    final VideoDownloadBackendIdentity after = build('fushi');

    expect(after.fingerprint, before.fingerprint);
    expect(after.profileId, before.profileId);
    expect(after.kind, before.kind);
    expect(after.matches(before), isTrue);
  });

  test('qBittorrent 身份只由地址与账号决定，与分类无关', () {
    VideoDownloadBackendIdentity build(String category) =>
        buildVideoDownloadBackendIdentity(
          config: QbConnectionConfig(
            backend: QbConnectionConfig.backendQbittorrent,
            baseUrl: 'http://127.0.0.1:8080',
            username: 'admin',
            category: category,
          ),
          resolvedBackend: QbConnectionConfig.backendQbittorrent,
          embeddedInstallationId: 'installation-1',
        );

    expect(build('fushi').matches(build('hibiki')), isTrue);
  });

  test('落点带上当前配置的分类，身份仍不含分类', () {
    final VideoDownloadBackendTarget target = buildVideoDownloadBackendTarget(
      config: const QbConnectionConfig(
        backend: QbConnectionConfig.backendEmbedded,
        category: 'fushi',
      ),
      resolvedBackend: QbConnectionConfig.backendEmbedded,
      embeddedInstallationId: 'installation-1',
    );

    expect(target.category, 'fushi');
    expect(target.kind, QbConnectionConfig.backendEmbedded);
    expect(target.profileId, 'embedded');
    expect(target.fingerprint, hasLength(64));
    expect(
      target.identity.matches(
        buildVideoDownloadBackendIdentity(
          config: const QbConnectionConfig(
            backend: QbConnectionConfig.backendEmbedded,
            category: 'another-category',
          ),
          resolvedBackend: QbConnectionConfig.backendEmbedded,
          embeddedInstallationId: 'installation-1',
        ),
      ),
      isTrue,
    );
  });
}
