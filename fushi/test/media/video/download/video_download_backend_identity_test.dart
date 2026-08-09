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
          contains('built-in download engine is unavailable'),
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
    expect(identity.category, 'fushi');
    expect(identity.fingerprint, hasLength(64));
  });
}
