import 'package:fushi_engine/srs/srs_remote_generation.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:test/test.dart';

void main() {
  group('主机的代按能力位判定', () {
    test('只认字面 true；声明了 V2 就是 v2（V1 拒绝桩不影响）', () {
      expect(
        srsRemoteHostGenerationOf(const <Object?, Object?>{}),
        SrsRemoteHostGeneration.none,
      );
      expect(
        srsRemoteHostGenerationOf(const <Object?, Object?>{
          kSrsRemoteStoreCapability: 'true',
          kSrsRemoteStoreCapabilityV2: 1,
        }),
        SrsRemoteHostGeneration.none,
      );
      expect(
        srsRemoteHostGenerationOf(const <Object?, Object?>{
          kSrsRemoteStoreCapability: true,
        }),
        SrsRemoteHostGeneration.v1Only,
      );
      expect(
        srsRemoteHostGenerationOf(const <Object?, Object?>{
          kSrsRemoteStoreCapability: true,
          kSrsRemoteStoreCapabilityV2: true,
        }),
        SrsRemoteHostGeneration.v2,
      );
      expect(
        srsRemoteHostGenerationOf(const <Object?, Object?>{
          kSrsRemoteStoreCapabilityV2: true,
        }),
        SrsRemoteHostGeneration.v2,
      );
    });

    test('能力位与前缀的字面值（线上契约，改了旧版本就认不出）', () {
      expect(kSrsRemoteStoreCapability, 'srsRemoteStoreV1');
      expect(kSrsRemoteStoreCapabilityV2, 'srsRemoteStoreV2');
      expect(kSrsRemoteStoreV2PathPrefix, '/api/srs/remote2/');
      expect(kSrsRemoteGenerationKey, 'g');
      expect(kSrsRemoteStoreV2Generation, 4);
      // 路由按 startsWith 分派：V2 前缀不能落进 V1 前缀，旧主机才会对 V2 请求回 404。
      expect(
        kSrsRemoteStoreV2PathPrefix.startsWith(kSrsRemoteStorePathPrefix),
        isFalse,
      );
      expect(
        kSrsRemoteStorePathPrefix.startsWith(kSrsRemoteStoreV2PathPrefix),
        isFalse,
      );
    });
  });

  group('本机线格式 × 主机代的配对', () {
    test('本机这个构建说 V2（G10-2）：只声明 V1 的旧主机判「主机需要升级」，新主机照常连', () {
      expect(kSrsRemoteClientWire, SrsRemoteWireVersion.v2);
      expect(
        srsRemoteHostCompat(SrsRemoteHostGeneration.v1Only),
        SrsRemoteHostCompat.hostNeedsUpgrade,
      );
      expect(
        srsRemoteHostCompat(SrsRemoteHostGeneration.v2),
        SrsRemoteHostCompat.ready,
      );
    });

    test('全表', () {
      const Map<
        (SrsRemoteHostGeneration, SrsRemoteWireVersion),
        SrsRemoteHostCompat
      >
      want =
          <
            (SrsRemoteHostGeneration, SrsRemoteWireVersion),
            SrsRemoteHostCompat
          >{
            (SrsRemoteHostGeneration.none, SrsRemoteWireVersion.v1):
                SrsRemoteHostCompat.unavailable,
            (SrsRemoteHostGeneration.none, SrsRemoteWireVersion.v2):
                SrsRemoteHostCompat.unavailable,
            (SrsRemoteHostGeneration.v1Only, SrsRemoteWireVersion.v1):
                SrsRemoteHostCompat.ready,
            (SrsRemoteHostGeneration.v1Only, SrsRemoteWireVersion.v2):
                SrsRemoteHostCompat.hostNeedsUpgrade,
            (SrsRemoteHostGeneration.v2, SrsRemoteWireVersion.v1):
                SrsRemoteHostCompat.clientNeedsUpgrade,
            (SrsRemoteHostGeneration.v2, SrsRemoteWireVersion.v2):
                SrsRemoteHostCompat.ready,
          };
      for (final SrsRemoteHostGeneration host
          in SrsRemoteHostGeneration.values) {
        for (final SrsRemoteWireVersion client in SrsRemoteWireVersion.values) {
          expect(
            srsRemoteHostCompat(host, client: client),
            want[(host, client)],
            reason: '$host × $client',
          );
        }
      }
    });
  });

  group('机读码', () {
    test('字面值与 HTTP 状态', () {
      expect(SrsRemoteStoreError.upgradeRequired, 'upgrade_required');
      expect(SrsRemoteStoreError.migrating, 'migrating');
      expect(SrsRemoteStoreError.migrationFailed, 'migration_failed');
      expect(kSrsRemoteV1RefusedOnGen4.status, 426);
      expect(
        kSrsRemoteV1RefusedOnGen4.code,
        SrsRemoteStoreError.upgradeRequired,
      );
    });

    test('V2 请求体的代号：只有 4 放行，其余一律 426 upgrade_required', () {
      expect(srsRemoteV2GenerationError(4), isNull);
      for (final Object? g in <Object?>[null, 3, 5, '4', 4.0, -1]) {
        final SrsRemoteStoreError? e = srsRemoteV2GenerationError(g);
        expect(e, isNotNull, reason: '$g');
        expect((e!.status, e.code), (426, SrsRemoteStoreError.upgradeRequired));
      }
    });
  });
}
