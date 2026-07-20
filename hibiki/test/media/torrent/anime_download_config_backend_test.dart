// 阶段2：QbConnectionConfig 的 backend 字段 codec / 向后兼容 / isConfigured。

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';

void main() {
  test('backend defaults to auto (resolves per platform)', () {
    const QbConnectionConfig config = QbConnectionConfig();
    expect(config.backend, QbConnectionConfig.backendAuto);
    // 桌面 → 内置引擎（开箱即用）；移动端 → 外接 qb。
    expect(config.resolveBackend(isDesktop: true),
        QbConnectionConfig.backendEmbedded);
    expect(config.resolveBackend(isDesktop: false),
        QbConnectionConfig.backendQbittorrent);
  });

  test('explicit backends resolve to themselves regardless of platform', () {
    const QbConnectionConfig emb =
        QbConnectionConfig(backend: QbConnectionConfig.backendEmbedded);
    expect(emb.resolveBackend(isDesktop: false),
        QbConnectionConfig.backendEmbedded);
    const QbConnectionConfig qb =
        QbConnectionConfig(backend: QbConnectionConfig.backendQbittorrent);
    expect(qb.resolveBackend(isDesktop: true),
        QbConnectionConfig.backendQbittorrent);
  });

  test('auto round-trips through encode/decode', () {
    const QbConnectionConfig original = QbConnectionConfig();
    final QbConnectionConfig decoded =
        decodeQbConnectionConfig(encodeQbConnectionConfig(original))!;
    expect(decoded.backend, QbConnectionConfig.backendAuto);
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

  test('legacy no backend + no url decodes as auto (new user default)', () {
    // 全新用户：没配过任何东西 → auto（桌面开箱即用内置引擎）。
    final QbConnectionConfig decoded = decodeQbConnectionConfig('{}')!;
    expect(decoded.backend, QbConnectionConfig.backendAuto);
  });

  test('isConfigured: embedded/auto need no url, explicit qb needs a url', () {
    // 内置引擎/自动无连接参数：恒已配置（开箱即用）。
    const QbConnectionConfig embedded =
        QbConnectionConfig(backend: QbConnectionConfig.backendEmbedded);
    expect(embedded.isConfigured, isTrue);
    const QbConnectionConfig auto = QbConnectionConfig();
    expect(auto.isConfigured, isTrue);
    // 显式外接 qb：URL 空 = 未配置。
    const QbConnectionConfig qbEmpty =
        QbConnectionConfig(backend: QbConnectionConfig.backendQbittorrent);
    expect(qbEmpty.isConfigured, isFalse);
    const QbConnectionConfig qbSet = QbConnectionConfig(
        backend: QbConnectionConfig.backendQbittorrent,
        baseUrl: 'http://127.0.0.1:8080');
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

  test('upload disabled by default; seed limits default to 0 (unlimited)', () {
    const QbConnectionConfig defaults = QbConnectionConfig();
    expect(defaults.uploadEnabled, isFalse);
    expect(defaults.seedTimeLimitMinutes, 0);
    expect(defaults.seedRatioLimit, 0);
  });

  test('upload/seed fields round-trip through encode/decode', () {
    const QbConnectionConfig original = QbConnectionConfig(
      backend: QbConnectionConfig.backendEmbedded,
      uploadEnabled: true,
      seedTimeLimitMinutes: 120,
      seedRatioLimit: 2.5,
      memoryLimitMb: 512,
    );
    final QbConnectionConfig decoded =
        decodeQbConnectionConfig(encodeQbConnectionConfig(original))!;
    expect(decoded.uploadEnabled, isTrue);
    expect(decoded.seedTimeLimitMinutes, 120);
    expect(decoded.seedRatioLimit, 2.5);
    expect(decoded.memoryLimitMb, 512);
  });

  test('memoryLimitMb defaults to 0 (auto); legacy JSON → 0', () {
    expect(const QbConnectionConfig().memoryLimitMb, 0);
    expect(
        decodeQbConnectionConfig('{"backend":"embedded"}')!.memoryLimitMb, 0);
    // 负数/垃圾 clamp 0。
    expect(decodeQbConnectionConfig('{"memoryLimitMb":-9}')!.memoryLimitMb, 0);
  });

  test('legacy JSON without upload fields: upload off, seed limits 0', () {
    // 老配置没有上传字段：开箱即关（尊重带宽/隐私），首用弹窗再征询。
    final QbConnectionConfig decoded =
        decodeQbConnectionConfig('{"backend":"embedded"}')!;
    expect(decoded.uploadEnabled, isFalse);
    expect(decoded.seedTimeLimitMinutes, 0);
    expect(decoded.seedRatioLimit, 0);
  });

  test('negative/garbage seed values clamp to 0', () {
    final QbConnectionConfig decoded = decodeQbConnectionConfig(
        '{"seedTimeLimitMinutes":-30,"seedRatioLimit":"x"}')!;
    expect(decoded.seedTimeLimitMinutes, 0);
    expect(decoded.seedRatioLimit, 0);
    final QbConnectionConfig neg =
        decodeQbConnectionConfig('{"seedRatioLimit":-1.5}')!;
    expect(neg.seedRatioLimit, 0);
  });

  test('copyWith preserves/overrides upload+seed fields', () {
    const QbConnectionConfig base = QbConnectionConfig(
      uploadEnabled: true,
      seedTimeLimitMinutes: 60,
      seedRatioLimit: 1.0,
    );
    final QbConnectionConfig kept = base.copyWith(category: 'x');
    expect(kept.uploadEnabled, isTrue);
    expect(kept.seedTimeLimitMinutes, 60);
    expect(kept.seedRatioLimit, 1.0);
    final QbConnectionConfig off = base.copyWith(uploadEnabled: false);
    expect(off.uploadEnabled, isFalse);
    expect(off.seedTimeLimitMinutes, 60);
  });
}
