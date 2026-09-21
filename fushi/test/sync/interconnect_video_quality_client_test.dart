import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/interconnect_video_quality.dart';
import 'package:fushi/src/sync/remote_video_client.dart';

InterconnectSyncBackend _backend() =>
    InterconnectSyncBackend.withProbe((String _, String __) async => true);

void main() {
  group('档位菜单可见性', () {
    test('host 没说自己支持转码 → 一档都不给（老 host / 移动端 host）', () {
      final InterconnectSyncBackend backend = _backend();
      expect(backend.qualityPresets, isEmpty);
    });

    test('host 自报支持 → 给出完整档位表', () {
      final InterconnectSyncBackend backend = _backend()
        ..hostTranscodeAvailableForTesting = true;
      expect(backend.qualityPresets, kInterconnectQualityPresets);
      expect(backend.qualityPresets.length, 5);
    });

    test('互联实现了画质能力接口（播放页据此显示画质菜单）', () {
      expect(_backend(), isA<RemoteVideoQualityLimit>());
    });
  });

  group('当次取流用哪一档', () {
    test('用户显式选档 → 就用那档，不受自适应与起点判据影响', () {
      final InterconnectSyncBackend backend = _backend()
        ..qualityPresetIndex = 3
        ..adaptiveQualityIndex = 0;
      expect(
        backend.effectiveQualityPreset(hostUrl: 'http://192.168.1.8:15001'),
        kInterconnectQualityPresets[3],
      );
    });

    test('自动档 + 自适应已定档 → 用自适应那档', () {
      final InterconnectSyncBackend backend = _backend()
        ..qualityPresetIndex = -1
        ..adaptiveQualityIndex = 4;
      expect(
        backend.effectiveQualityPreset(hostUrl: 'http://203.0.113.9:15001'),
        kInterconnectQualityPresets[4],
      );
    });

    test('自适应判定原画 → 不报档位（host 走原文件直传）', () {
      final InterconnectSyncBackend backend = _backend()
        ..qualityPresetIndex = -1
        ..adaptiveQualityIndex = -1;
      expect(
        backend.effectiveQualityPreset(hostUrl: 'http://203.0.113.9:15001'),
        isNull,
      );
    });

    test('自动档 + 自适应还没定 → 落到起点判据', () {
      final InterconnectSyncBackend lan = _backend()..qualityPresetIndex = -1;
      expect(
        lan.effectiveQualityPreset(hostUrl: 'http://192.168.1.8:15001'),
        isNull,
        reason: '局域网起点是原画',
      );

      final InterconnectSyncBackend wan = _backend()..qualityPresetIndex = -1;
      expect(
        wan.effectiveQualityPreset(hostUrl: 'https://fushi.example.com'),
        kInterconnectQualityPresets[kInterconnectAutoQualityPresetIndex],
        reason: '走公网的起点是中档',
      );
    });

    test('下标越界不崩，退回起点判据', () {
      final InterconnectSyncBackend backend = _backend()
        ..qualityPresetIndex = 99
        ..adaptiveQualityIndex = 99;
      expect(
        backend.effectiveQualityPreset(hostUrl: 'http://192.168.1.8:15001'),
        isNull,
      );
    });
  });

  group('自动档起点下标', () {
    test('局域网 = -1（原画）；公网 = 中档下标', () {
      final InterconnectSyncBackend backend = _backend();
      expect(
        backend.resolveAutoStartIndex(hostUrl: 'http://10.1.2.3:15001'),
        -1,
      );
      expect(
        backend.resolveAutoStartIndex(hostUrl: 'http://203.0.113.9:15001'),
        kInterconnectAutoQualityPresetIndex,
      );
    });
  });

  group('档位表本身', () {
    test('按画质从高到低排，码率严格递减', () {
      for (int i = 1; i < kInterconnectQualityPresets.length; i++) {
        expect(
          kInterconnectQualityPresets[i].maxBitrate,
          lessThan(kInterconnectQualityPresets[i - 1].maxBitrate),
          reason: '第 $i 档的码率必须低于前一档',
        );
        expect(
          kInterconnectQualityPresets[i].maxWidth,
          lessThanOrEqualTo(kInterconnectQualityPresets[i - 1].maxWidth),
        );
      }
    });

    test('每档都有正的宽度与码率（0 在 host 侧是「不限」，档位里不该出现）', () {
      for (final MediaServerQualityPreset p in kInterconnectQualityPresets) {
        expect(p.maxWidth, greaterThan(0), reason: p.label);
        expect(p.maxBitrate, greaterThan(0), reason: p.label);
        expect(p.label.trim(), isNotEmpty);
      }
    });

    test('最高档比 Jellyfin 那套低——这边要解决的是手机网络', () {
      expect(kInterconnectQualityPresets.first.maxBitrate, lessThan(20000000));
    });
  });
}
