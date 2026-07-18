// 阶段2：QbConnectionConfig 的 backend 字段 codec / 向后兼容 / isConfigured。

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';

void main() {
  test('backend defaults to qbittorrent', () {
    const QbConnectionConfig config = QbConnectionConfig();
    expect(config.backend, QbConnectionConfig.backendQbittorrent);
  });

  test('legacy JSON without backend field decodes as qbittorrent', () {
    // 阶段1 之前写下的配置没有 backend 字段：向后兼容回退 qb。
    final QbConnectionConfig? config = decodeQbConnectionConfig(
        '{"baseUrl":"http://127.0.0.1:8080","username":"u","password":"p"}');
    expect(config, isNotNull);
    expect(config!.backend, QbConnectionConfig.backendQbittorrent);
    expect(config.baseUrl, 'http://127.0.0.1:8080');
  });

  test('embedded backend round-trips through encode/decode', () {
    const QbConnectionConfig original = QbConnectionConfig(
      backend: QbConnectionConfig.backendEmbedded,
      category: 'hibiki-anime',
    );
    final QbConnectionConfig? decoded =
        decodeQbConnectionConfig(encodeQbConnectionConfig(original));
    expect(decoded, isNotNull);
    expect(decoded!.backend, QbConnectionConfig.backendEmbedded);
    expect(decoded.category, 'hibiki-anime');
  });

  test('unknown backend value falls back to qbittorrent', () {
    final QbConnectionConfig? config =
        decodeQbConnectionConfig('{"backend":"bogus","baseUrl":"x"}');
    expect(config!.backend, QbConnectionConfig.backendQbittorrent);
  });

  test('isConfigured: embedded needs no url, qb needs a url', () {
    // 内置引擎无连接参数：恒已配置。
    const QbConnectionConfig embedded =
        QbConnectionConfig(backend: QbConnectionConfig.backendEmbedded);
    expect(embedded.isConfigured, isTrue);
    // 外接 qb：URL 空 = 未配置。
    const QbConnectionConfig qbEmpty = QbConnectionConfig();
    expect(qbEmpty.isConfigured, isFalse);
    const QbConnectionConfig qbSet =
        QbConnectionConfig(baseUrl: 'http://127.0.0.1:8080');
    expect(qbSet.isConfigured, isTrue);
  });

  test('copyWith preserves backend when not overridden', () {
    const QbConnectionConfig base =
        QbConnectionConfig(backend: QbConnectionConfig.backendEmbedded);
    final QbConnectionConfig next = base.copyWith(category: 'x');
    expect(next.backend, QbConnectionConfig.backendEmbedded);
    final QbConnectionConfig switched =
        base.copyWith(backend: QbConnectionConfig.backendQbittorrent);
    expect(switched.backend, QbConnectionConfig.backendQbittorrent);
  });
}
