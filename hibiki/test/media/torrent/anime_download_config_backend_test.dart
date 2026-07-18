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

  test('rate/connection limits round-trip and default to 0 (unlimited)', () {
    const QbConnectionConfig defaults = QbConnectionConfig();
    expect(defaults.downloadLimitKbps, 0);
    expect(defaults.uploadLimitKbps, 0);
    expect(defaults.maxConnections, 0);

    const QbConnectionConfig limited = QbConnectionConfig(
      backend: QbConnectionConfig.backendEmbedded,
      downloadLimitKbps: 2048,
      uploadLimitKbps: 512,
      maxConnections: 100,
    );
    final QbConnectionConfig decoded =
        decodeQbConnectionConfig(encodeQbConnectionConfig(limited))!;
    expect(decoded.downloadLimitKbps, 2048);
    expect(decoded.uploadLimitKbps, 512);
    expect(decoded.maxConnections, 100);
  });

  test('legacy JSON without limit fields decodes to 0', () {
    final QbConnectionConfig decoded =
        decodeQbConnectionConfig('{"backend":"embedded"}')!;
    expect(decoded.downloadLimitKbps, 0);
    expect(decoded.uploadLimitKbps, 0);
    expect(decoded.maxConnections, 0);
  });

  test('negative/garbage limit values clamp to 0', () {
    final QbConnectionConfig decoded = decodeQbConnectionConfig(
        '{"downloadLimitKbps":-5,"uploadLimitKbps":"x","maxConnections":-1}')!;
    expect(decoded.downloadLimitKbps, 0);
    expect(decoded.uploadLimitKbps, 0);
    expect(decoded.maxConnections, 0);
  });

  test('copyWith preserves limits when not overridden', () {
    const QbConnectionConfig base = QbConnectionConfig(
      downloadLimitKbps: 1000,
      maxConnections: 50,
    );
    final QbConnectionConfig next = base.copyWith(uploadLimitKbps: 200);
    expect(next.downloadLimitKbps, 1000);
    expect(next.uploadLimitKbps, 200);
    expect(next.maxConnections, 50);
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
