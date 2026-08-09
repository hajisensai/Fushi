// TODO-2481：下载任务行显示格式化纯函数 —— ETA / 分享率 / 状态映射。
//
// 边界是主角：零速度、未知剩余（-1）、已完成（0）、零分母、超上限估算、
// 未知状态词。这些分支一旦回归，UI 会显示「ETA ∞」「NaN」或裸英文状态词。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/torrent_task_display.dart';

void main() {
  group('torrentDisplayStatusFor', () {
    test('qb 下载词族', () {
      expect(torrentDisplayStatusFor('downloading'),
          TorrentDisplayStatus.downloading);
      expect(torrentDisplayStatusFor('forcedDL'),
          TorrentDisplayStatus.downloading);
      expect(
          torrentDisplayStatusFor('stalledDL'), TorrentDisplayStatus.stalled);
      expect(torrentDisplayStatusFor('queuedDL'), TorrentDisplayStatus.queued);
      expect(torrentDisplayStatusFor('metaDL'),
          TorrentDisplayStatus.fetchingMetadata);
    });

    test('qb 做种/完成词族', () {
      expect(
          torrentDisplayStatusFor('uploading'), TorrentDisplayStatus.seeding);
      expect(
          torrentDisplayStatusFor('stalledUP'), TorrentDisplayStatus.seeding);
      expect(torrentDisplayStatusFor('forcedUP'), TorrentDisplayStatus.seeding);
      expect(torrentDisplayStatusFor('queuedUP'), TorrentDisplayStatus.queued);
      expect(
          torrentDisplayStatusFor('checkingUP'), TorrentDisplayStatus.checking);
      expect(torrentDisplayStatusFor('moving'), TorrentDisplayStatus.moving);
    });

    test('暂停词族：qb 4.x paused* 与 qb 5.x stopped* 同义', () {
      for (final String s in <String>[
        'pausedDL',
        'pausedUP',
        'stoppedDL',
        'stoppedUP',
      ]) {
        expect(torrentDisplayStatusFor(s), TorrentDisplayStatus.paused,
            reason: s);
      }
    });

    test('内置引擎词族（native state_label 全集）', () {
      expect(torrentDisplayStatusFor('metadata'),
          TorrentDisplayStatus.fetchingMetadata);
      expect(
          torrentDisplayStatusFor('checking'), TorrentDisplayStatus.checking);
      expect(torrentDisplayStatusFor('downloading'),
          TorrentDisplayStatus.downloading);
      expect(
          torrentDisplayStatusFor('finished'), TorrentDisplayStatus.completed);
      expect(torrentDisplayStatusFor('seeding'), TorrentDisplayStatus.seeding);
      expect(torrentDisplayStatusFor('error'), TorrentDisplayStatus.error);
    });

    test('错误词族与未知词', () {
      expect(
          torrentDisplayStatusFor('missingFiles'), TorrentDisplayStatus.error);
      expect(
          torrentDisplayStatusFor('allocating'), TorrentDisplayStatus.checking);
      expect(torrentDisplayStatusFor(''), TorrentDisplayStatus.unknown);
      expect(torrentDisplayStatusFor('someFutureState'),
          TorrentDisplayStatus.unknown);
    });
  });

  group('formatTorrentEta', () {
    test('速度为 0 不显示（除零 + 「卡住」由速度段表达）', () {
      expect(formatTorrentEta(amountLeft: 1024, downRateBps: 0), isNull);
      expect(formatTorrentEta(amountLeft: 1024, downRateBps: -1), isNull);
    });

    test('剩余未知（-1）或已完成（0）不显示', () {
      expect(formatTorrentEta(amountLeft: -1, downRateBps: 100), isNull);
      expect(formatTorrentEta(amountLeft: 0, downRateBps: 100), isNull);
    });

    test('常规估算：向上取整', () {
      // 1000 / 100 = 10s。
      expect(formatTorrentEta(amountLeft: 1000, downRateBps: 100), '10s');
      // 1001 / 100 = 10.01 → 11s（宁多勿少）。
      expect(formatTorrentEta(amountLeft: 1001, downRateBps: 100), '11s');
    });

    test('超过 100 天上限不显示（估算只剩噪声）', () {
      final int capSeconds = kTorrentEtaDisplayCap.inSeconds;
      expect(
        formatTorrentEta(amountLeft: capSeconds, downRateBps: 1),
        isNotNull,
      );
      expect(
        formatTorrentEta(amountLeft: capSeconds + 1, downRateBps: 1),
        isNull,
      );
    });
  });

  group('formatCompactDuration', () {
    test('最高两级单位，次级补零', () {
      expect(formatCompactDuration(Duration.zero), '0s');
      expect(formatCompactDuration(const Duration(seconds: 45)), '45s');
      expect(formatCompactDuration(const Duration(minutes: 12, seconds: 34)),
          '12m34s');
      expect(
          formatCompactDuration(const Duration(hours: 1, minutes: 2)), '1h02m');
      expect(formatCompactDuration(const Duration(days: 2, hours: 7)), '2d07h');
    });

    test('负时长按 0 处理', () {
      expect(formatCompactDuration(const Duration(seconds: -5)), '0s');
    });
  });

  group('formatShareRatio', () {
    test('分母 0 / 负数不显示', () {
      expect(formatShareRatio(uploadedBytes: 100, downloadedBytes: 0), isNull);
      expect(formatShareRatio(uploadedBytes: 100, downloadedBytes: -1), isNull);
    });

    test('两位小数（qb 同款）', () {
      expect(formatShareRatio(uploadedBytes: 35, downloadedBytes: 100), '0.35');
      expect(formatShareRatio(uploadedBytes: 0, downloadedBytes: 100), '0.00');
      expect(
          formatShareRatio(uploadedBytes: 300, downloadedBytes: 100), '3.00');
    });
  });
}
