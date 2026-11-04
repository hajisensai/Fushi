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

  group('「原画」（uaBRMzK_WM）', () {
    test('互联单列「原画」（它的自动在外网会转码）', () {
      expect(_backend().offersOriginalQuality, isTrue);
    });

    test('选「原画」→ 不报档位，无视自适应与公网起点', () {
      final InterconnectSyncBackend backend = _backend()
        ..qualityPresetIndex = kRemoteVideoQualityOriginal
        ..adaptiveQualityIndex = 4;
      expect(
        backend.effectiveQualityPreset(hostUrl: 'https://fushi.example.com'),
        isNull,
      );
    });

    test('「原画」哨兵与「自动」不同、且不落在档位下标里', () {
      expect(kRemoteVideoQualityOriginal, isNot(kRemoteVideoQualityAuto));
      expect(kRemoteVideoQualityOriginal, lessThan(0));
    });
  });

  group('自动档起点：链路带宽对源码率', () {
    int start({bool lan = false, int? link, int? source}) =>
        resolveInterconnectAutoStartIndex(
          privateNetworkHost: lan,
          linkBitsPerSecond: link,
          sourceBitrate: source,
        );

    test('字面量局域网 → 原画，不看带宽', () {
      expect(start(lan: true), -1);
      expect(start(lan: true, link: 1000, source: 40000000), -1);
    });

    test('没测成 → 旧的保守起点（中档）', () {
      expect(start(), kInterconnectAutoQualityPresetIndex);
      expect(start(source: 5000000), kInterconnectAutoQualityPresetIndex);
    });

    test('经域名 / 公网 IPv6 回家：带宽够 BD 原盘 → 原画', () {
      // 40 Mbps 原盘，千兆内网实测 300 Mbps。
      expect(start(link: 300000000, source: 40000000), -1);
    });

    test('带宽够码率但没有 1.5 倍余量 → 不给原画，取撑得住的最高档', () {
      // 40 Mbps 原盘 / 50 Mbps 链路：50 < 60，原画会卡；8 Mbps × 1.5 = 12 ≤ 50。
      expect(start(link: 50000000, source: 40000000), 0);
    });

    test('低码率源在中速链路上直接原画（比转码更清楚也更省 host）', () {
      // 3 Mbps 的番剧 / 4G 实测 6 Mbps：6 ≥ 4.5。
      expect(start(link: 6000000, source: 3000000), -1);
    });

    test('源码率未知不自动给原画', () {
      expect(start(link: 300000000), 0);
    });

    test('按带宽逐档挑：档位码率 × 1.5 ≤ 带宽的最高档', () {
      expect(start(link: 7000000, source: 40000000), 1); // 4 Mbps 档
      expect(start(link: 3500000, source: 40000000), 2); // 2 Mbps 档
      expect(start(link: 1600000, source: 40000000), 3); // 1 Mbps 档
      expect(start(link: 950000, source: 40000000), 4); // 0.6 Mbps 档
    });

    test('一档都撑不住 → 最低档', () {
      expect(
        start(link: 100000, source: 40000000),
        kInterconnectQualityPresets.length - 1,
      );
    });
  });

  group('链路探测样本折算', () {
    test('够量的样本按首字节起算的时长折算', () {
      expect(
        interconnectLinkBitsPerSecond(
          bytes: 1000000,
          elapsed: const Duration(seconds: 1),
          reachedEnd: false,
        ),
        8000000,
      );
    });

    test('样本太小（全是慢启动）不作数，除非整个文件已读完', () {
      expect(
        interconnectLinkBitsPerSecond(
          bytes: 1000,
          elapsed: const Duration(milliseconds: 10),
          reachedEnd: false,
        ),
        isNull,
      );
      expect(
        interconnectLinkBitsPerSecond(
          bytes: 1000,
          elapsed: const Duration(milliseconds: 10),
          reachedEnd: true,
        ),
        800000,
      );
    });

    test('零字节 / 零时长不崩', () {
      expect(
        interconnectLinkBitsPerSecond(
          bytes: 0,
          elapsed: Duration.zero,
          reachedEnd: true,
        ),
        isNull,
      );
      expect(
        interconnectLinkBitsPerSecond(
          bytes: 500,
          elapsed: Duration.zero,
          reachedEnd: true,
        ),
        4000000,
        reason: '时长按 1 ms 下限折算',
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
