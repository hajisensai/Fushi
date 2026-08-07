// 阶段2：QbConnectionConfig 的 backend 字段 codec / 向后兼容 / isConfigured。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/anime_download_config.dart';

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

  test('显式 backend 按平台能力规约：无内置引擎的平台连 embedded 也降级 qb (BUG-1207)', () {
    // 契约变更（原断言「explicit backends resolve to themselves regardless of
    // platform」）：移动端从不构建也从不打包 libhibiki_torrent_ffi.so，原样放行
    // embedded 只会让设置页谎报「正在用内置引擎」、并暴露一个没有任何人读取的
    // 下载目录，运行时再静默回退外接 qb。
    // 存储层不受影响——backend 字段仍原样存 embedded（见下面的 round-trip 用例），
    // 规约只发生在 resolveBackend 这一处，桌面重新可用时旧配置自动复原。
    const QbConnectionConfig emb =
        QbConnectionConfig(backend: QbConnectionConfig.backendEmbedded);
    expect(emb.resolveBackend(isDesktop: false),
        QbConnectionConfig.backendQbittorrent);
    expect(emb.resolveBackend(isDesktop: true),
        QbConnectionConfig.backendEmbedded);
    const QbConnectionConfig qb =
        QbConnectionConfig(backend: QbConnectionConfig.backendQbittorrent);
    expect(qb.resolveBackend(isDesktop: true),
        QbConnectionConfig.backendQbittorrent);
    expect(qb.resolveBackend(isDesktop: false),
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

  test('session/anti-leech 字段默认值合理（发现开关默认开、加密首选、反吸血开）', () {
    const QbConnectionConfig d = QbConnectionConfig();
    expect(d.listenPort, 0);
    expect(d.enableDht, isTrue);
    expect(d.enableLsd, isTrue);
    expect(d.enableUpnp, isTrue);
    expect(d.enableNatpmp, isTrue);
    expect(d.encryptionMode, QbConnectionConfig.encryptionPrefer);
    expect(d.anonymousMode, isFalse);
    expect(d.maxActiveDownloads, 0);
    expect(d.maxActiveSeeds, 0);
    expect(d.maxUploadSlots, 0);
    expect(d.antiLeechEnabled, isTrue);
    expect(d.banProgressCheat, isFalse);
    expect(d.banRelativeProgressCheat, isFalse);
    expect(d.maxIpPortCount, 0);
    expect(d.banTimeMinutes, 0);
  });

  test('session/anti-leech 字段 round-trip', () {
    const QbConnectionConfig o = QbConnectionConfig(
      listenPort: 51413,
      enableDht: false,
      enableLsd: false,
      enableUpnp: false,
      enableNatpmp: false,
      encryptionMode: QbConnectionConfig.encryptionForced,
      anonymousMode: true,
      maxActiveDownloads: 5,
      maxActiveSeeds: 3,
      maxUploadSlots: 8,
      antiLeechEnabled: false,
      banProgressCheat: true,
      banRelativeProgressCheat: true,
      maxIpPortCount: 4,
      banTimeMinutes: 120,
    );
    final QbConnectionConfig r =
        decodeQbConnectionConfig(encodeQbConnectionConfig(o))!;
    expect(r.listenPort, 51413);
    expect(r.enableDht, isFalse);
    expect(r.encryptionMode, QbConnectionConfig.encryptionForced);
    expect(r.anonymousMode, isTrue);
    expect(r.maxActiveDownloads, 5);
    expect(r.maxActiveSeeds, 3);
    expect(r.maxUploadSlots, 8);
    expect(r.antiLeechEnabled, isFalse);
    expect(r.banProgressCheat, isTrue);
    expect(r.banRelativeProgressCheat, isTrue);
    expect(r.maxIpPortCount, 4);
    expect(r.banTimeMinutes, 120);
  });

  test('老 JSON 缺 session 字段：发现开关回落 true、反吸血回落 on、加密首选', () {
    final QbConnectionConfig c =
        decodeQbConnectionConfig('{"backend":"embedded"}')!;
    expect(c.enableDht, isTrue);
    expect(c.enableLsd, isTrue);
    expect(c.enableUpnp, isTrue);
    expect(c.enableNatpmp, isTrue);
    expect(c.antiLeechEnabled, isTrue);
    expect(c.encryptionMode, QbConnectionConfig.encryptionPrefer);
    expect(c.anonymousMode, isFalse);
    // 越界加密值 → 首选。
    expect(decodeQbConnectionConfig('{"encryptionMode":9}')!.encryptionMode,
        QbConnectionConfig.encryptionPrefer);
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

  group('limitLocalPeers（限速也作用于局域网）', () {
    test('默认关：新配置不改变历史行为', () {
      const QbConnectionConfig config = QbConnectionConfig();
      expect(config.limitLocalPeers, isFalse);
    });

    test('老配置缺字段 → false（绝不因升级改变既有用户的限速行为）', () {
      final QbConnectionConfig? config = decodeQbConnectionConfig(
          '{"backend":"embedded","downloadLimitKbps":512}');
      expect(config, isNotNull);
      expect(config!.limitLocalPeers, isFalse);
      expect(config.downloadLimitKbps, 512);
    });

    test('true 能 round-trip 过 encode/decode', () {
      const QbConnectionConfig original = QbConnectionConfig(
        backend: QbConnectionConfig.backendEmbedded,
        downloadLimitKbps: 512,
        limitLocalPeers: true,
      );
      final QbConnectionConfig decoded =
          decodeQbConnectionConfig(encodeQbConnectionConfig(original))!;
      expect(decoded.limitLocalPeers, isTrue);
      expect(decoded.downloadLimitKbps, 512);
    });

    test('copyWith 能双向翻转', () {
      const QbConnectionConfig off = QbConnectionConfig();
      expect(off.copyWith(limitLocalPeers: true).limitLocalPeers, isTrue);
      expect(
          off
              .copyWith(limitLocalPeers: true)
              .copyWith(limitLocalPeers: false)
              .limitLocalPeers,
          isFalse);
    });

    test('非布尔垃圾值 → false（与 uploadEnabled 同样的容错）', () {
      final QbConnectionConfig? config =
          decodeQbConnectionConfig('{"limitLocalPeers":"yes"}');
      expect(config?.limitLocalPeers, isFalse);
    });
  });
}
