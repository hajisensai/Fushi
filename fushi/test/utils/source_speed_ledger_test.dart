import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/download_plan.dart';
import 'package:fushi/src/utils/misc/source_speed_ledger.dart';

/// 三家来源，url 按字典序递增——定序的兜底规则会先挑 a，所以「摊开」「择快」这类
/// 断言只要看到 b/c 被选中，就一定是策略起了作用，而不是兜底顺序碰巧对了。
const DownloadSource a = DownloadSource(url: 'https://a.example/part');
const DownloadSource b = DownloadSource(url: 'https://b.example/part');
const DownloadSource c = DownloadSource(url: 'https://c.example/part');
const List<DownloadSource> all = <DownloadSource>[a, b, c];

/// 一次「取片并跑完」：pick → 记录 → release。
String runOnce(
  SourceSpeedLedger ledger, {
  required Map<String, double> bytesPerSecond,
  int bytes = 8 << 20,
  int perSourceLimit = 3,
  DateTime? now,
}) {
  final DownloadSource picked =
      ledger.pick(all, perSourceLimit: perSourceLimit, now: now);
  final double speed = bytesPerSecond[picked.url]!;
  ledger.recordSuccess(
    picked.url,
    bytes: bytes,
    elapsed: Duration(microseconds: (bytes / speed * 1e6).round()),
    now: now,
  );
  ledger.release(picked.url);
  return picked.url;
}

void main() {
  group('冷启动', () {
    test('每家都先拿到一次探测，不会全压在字典序第一家', () {
      final SourceSpeedLedger ledger = SourceSpeedLedger();
      final List<String> picked = <String>[
        for (int i = 0; i < 3; i++)
          runOnce(ledger, bytesPerSecond: <String, double>{
            a.url: 1e6,
            b.url: 1e6,
            c.url: 1e6,
          }),
      ];
      expect(picked.toSet(), <String>{a.url, b.url, c.url});
    });

    test('样本小到全被丢弃时，摊开仍然成立', () {
      // 回归点：摊开若以「有没有速度样本」为准，样本一旦全被 minSampleBytes 丢掉，
      // 每家就永远算「没测过」，兜底的 url 定序会把所有片钉在 a 上。
      final SourceSpeedLedger ledger =
          SourceSpeedLedger(minSampleBytes: 1 << 20);
      final List<String> picked = <String>[
        for (int i = 0; i < 3; i++)
          runOnce(
            ledger,
            bytes: 1024,
            bytesPerSecond: <String, double>{
              a.url: 1e6,
              b.url: 1e6,
              c.url: 1e6,
            },
          ),
      ];
      expect(ledger.speedOf(a.url), isNull, reason: '小样本不该记进吞吐');
      expect(picked.toSet(), <String>{a.url, b.url, c.url});
    });
  });

  group('择快', () {
    test('测完一轮之后，片都派给最快的那家', () {
      final SourceSpeedLedger ledger = SourceSpeedLedger();
      final Map<String, double> speeds = <String, double>{
        a.url: 1e6,
        b.url: 1e6,
        c.url: 9e6, // c 最快，且它的 url 排在最后
      };
      // 前三次是探测；之后应该稳定落在 c。
      for (int i = 0; i < 3; i++) {
        runOnce(ledger, bytesPerSecond: speeds);
      }
      final List<String> steady = <String>[
        for (int i = 0; i < 5; i++) runOnce(ledger, bytesPerSecond: speeds),
      ];
      expect(steady, everyElement(c.url));
      expect(ledger.speedOf(c.url)! > ledger.speedOf(a.url)!, isTrue);
    });

    test('最快的一家在飞到顶就退给次快的', () {
      final SourceSpeedLedger ledger = SourceSpeedLedger();
      final Map<String, double> speeds = <String, double>{
        a.url: 5e6,
        b.url: 1e6,
        c.url: 9e6,
      };
      for (int i = 0; i < 3; i++) {
        runOnce(ledger, bytesPerSecond: speeds);
      }
      // 不 release，占住名额。
      final DownloadSource first = ledger.pick(all, perSourceLimit: 1);
      final DownloadSource second = ledger.pick(all, perSourceLimit: 1);
      final DownloadSource third = ledger.pick(all, perSourceLimit: 1);
      expect(first.url, c.url, reason: '最快的先上');
      expect(second.url, a.url, reason: 'c 到顶，退给次快的 a');
      expect(third.url, b.url, reason: 'a 也到顶，只剩 b');
    });

    test('样本过期后那家重新拿到探测机会', () {
      final SourceSpeedLedger ledger =
          SourceSpeedLedger(probeAfter: const Duration(minutes: 2));
      final DateTime t0 = DateTime(2026, 8, 30, 12);
      final Map<String, double> speeds = <String, double>{
        a.url: 9e6,
        b.url: 1e6,
        c.url: 1e6,
      };
      // 前三次探测各一次，之后都落在最快的 a 上——a 的"试过次数"因此远高于 b/c。
      for (int i = 0; i < 8; i++) {
        runOnce(ledger, bytesPerSecond: speeds, now: t0);
      }
      expect(
        ledger.pick(all, perSourceLimit: 3, now: t0).url,
        a.url,
        reason: '刚测完，选最快的 a',
      );
      ledger.release(a.url);
      // 十分钟后样本全过期，重新进入探测：按试过次数排，轮到被冷落的 b/c——
      // 开局慢的来源不能被永久打入冷宫。
      final DateTime later = t0.add(const Duration(minutes: 10));
      expect(
        ledger.pick(all, perSourceLimit: 3, now: later).url,
        isNot(a.url),
      );
    });
  });

  group('失败冷却', () {
    test('失败的来源冷却期内不再派片，冷却结束后回来', () {
      final SourceSpeedLedger ledger = SourceSpeedLedger();
      final DateTime t0 = DateTime(2026, 8, 30, 12);
      final Map<String, double> speeds = <String, double>{
        a.url: 1e6,
        b.url: 1e6,
        c.url: 9e6,
      };
      for (int i = 0; i < 3; i++) {
        runOnce(ledger, bytesPerSecond: speeds, now: t0);
      }
      ledger.recordFailure(c.url, now: t0);
      expect(ledger.isCoolingDown(c.url, now: t0), isTrue);

      // 最快的那家挂了，别的片不该继续撞上去。
      final DownloadSource duringCooldown =
          ledger.pick(all, perSourceLimit: 3, now: t0);
      expect(duringCooldown.url, isNot(c.url));
      ledger.release(duringCooldown.url);

      final DateTime after = t0.add(const Duration(seconds: 5));
      expect(ledger.isCoolingDown(c.url, now: after), isFalse);
      expect(ledger.pick(all, perSourceLimit: 3, now: after).url, c.url);
    });

    test('连续失败退避加长但不超过上限', () {
      final SourceSpeedLedger ledger =
          SourceSpeedLedger(maxCooldown: const Duration(seconds: 4));
      final DateTime t0 = DateTime(2026, 8, 30, 12);
      ledger.recordFailure(a.url, now: t0);
      expect(
        ledger.isCoolingDown(a.url, now: t0.add(const Duration(seconds: 2))),
        isFalse,
        reason: '第一次失败退避 1s',
      );
      for (int i = 0; i < 5; i++) {
        ledger.recordFailure(a.url, now: t0);
      }
      expect(
        ledger.isCoolingDown(a.url, now: t0.add(const Duration(seconds: 3))),
        isTrue,
      );
      expect(
        ledger.isCoolingDown(a.url, now: t0.add(const Duration(seconds: 5))),
        isFalse,
        reason: '退避封顶在 maxCooldown',
      );
    });

    test('全部来源都在冷却时仍然给得出一个，不会把片饿死', () {
      final SourceSpeedLedger ledger = SourceSpeedLedger();
      final DateTime t0 = DateTime(2026, 8, 30, 12);
      for (final DownloadSource s in all) {
        ledger.recordFailure(s.url, now: t0);
      }
      expect(
        () => ledger.pick(all, perSourceLimit: 3, now: t0),
        returnsNormally,
      );
    });
  });

  test('exclude 把候选排空时回退到全表，而不是无源可下', () {
    final SourceSpeedLedger ledger = SourceSpeedLedger();
    final DownloadSource picked = ledger.pick(
      all,
      perSourceLimit: 3,
      exclude: <String>{a.url, b.url, c.url},
    );
    expect(all.map((DownloadSource s) => s.url), contains(picked.url));
  });

  test('release 不会把在飞数减成负数', () {
    final SourceSpeedLedger ledger = SourceSpeedLedger();
    ledger.release(a.url);
    ledger.release(a.url);
    expect(ledger.inFlightOf(a.url), 0);
    ledger.pick(all, perSourceLimit: 3);
    expect(ledger.inFlightOf(a.url), 1);
  });

  group('perSourceLimitFor', () {
    test('单来源时就是全部并发', () {
      expect(
        SourceSpeedLedger.perSourceLimitFor(concurrency: 4, sourceCount: 1),
        4,
      );
    });

    test('多来源时快的那家多拿，但每家至少留得下一条', () {
      // 4 并发 2 来源：快的 3、慢的 1。若不封顶就是 4，慢的那家一条都排不进去，
      // 它的带宽和新样本一起没了。
      expect(
        SourceSpeedLedger.perSourceLimitFor(concurrency: 4, sourceCount: 2),
        3,
      );
      expect(
        SourceSpeedLedger.perSourceLimitFor(concurrency: 4, sourceCount: 3),
        2,
      );
      expect(
        SourceSpeedLedger.perSourceLimitFor(concurrency: 8, sourceCount: 3),
        6,
      );
    });

    test('并发少于来源数时每家一条', () {
      expect(
        SourceSpeedLedger.perSourceLimitFor(concurrency: 1, sourceCount: 3),
        1,
      );
    });
  });
}
