import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/mpv_cache_snapshot.dart';
import 'package:fushi/src/mining/video_online_mining_mode.dart';

void main() {
  group('parseMpvSeekableRanges', () {
    test('解析 mpv 0.41 实测的 demuxer-cache-state 字符串', () {
      const String raw =
          '{"cache-end":89.983667,"reader-pts":48.276667,'
          '"cache-duration":41.707000,"eof":true,"underrun":false,'
          '"idle":true,"total-bytes":41758192,"fw-bytes":24300512,'
          '"ts-per-stream":[{"type":"video","cache-duration":44.000000}],'
          '"bof-cached":false,"eof-cached":true,'
          '"seekable-ranges":[{"start":15.000000,"end":89.983667}]}';
      final List<MpvSeekableRange> ranges = parseMpvSeekableRanges(raw);
      expect(ranges, hasLength(1));
      expect(ranges.single.start, 15.0);
      expect(ranges.single.end, 89.983667);
    });

    test('空串 / 非 JSON / 缺字段 / 反向区间 → 没有缓冲', () {
      expect(parseMpvSeekableRanges(''), isEmpty);
      expect(parseMpvSeekableRanges('no'), isEmpty);
      expect(parseMpvSeekableRanges('{"cache-end":1}'), isEmpty);
      expect(
        parseMpvSeekableRanges('{"seekable-ranges":[{"start":5,"end":2}]}'),
        isEmpty,
      );
    });
  });

  group('planMpvCacheDump', () {
    const List<MpvSeekableRange> ranges = <MpvSeekableRange>[
      MpvSeekableRange(start: 0, end: 20),
      MpvSeekableRange(start: 30.021, end: 60),
    ];

    test('从包含该句的缓冲段起点落盘，文件 0 点 = 段起点', () {
      final MpvCacheDumpDecision d = planMpvCacheDump(
        ranges: ranges,
        startMs: 41300,
        endMs: 43100,
      );
      expect(d.waitForTail, isFalse);
      expect(d.plan!.dumpStart, 30.021);
      expect(d.plan!.zeroMs, 30021);
      expect(d.plan!.dumpEnd, closeTo(43.6, 1e-9));
    });

    test('尾部余量夹到缓冲末尾', () {
      final MpvCacheDumpDecision d = planMpvCacheDump(
        ranges: ranges,
        startMs: 58000,
        endMs: 59800,
      );
      expect(d.plan!.dumpEnd, 60);
    });

    test('起点在缓冲里、句尾还没下载到 → 等', () {
      final MpvCacheDumpDecision d = planMpvCacheDump(
        ranges: ranges,
        startMs: 58000,
        endMs: 61000,
      );
      expect(d.plan, isNull);
      expect(d.waitForTail, isTrue);
    });

    test('起点不在任何缓冲段（被挤掉 / 跳过的空洞）→ 放弃', () {
      for (final int start in <int>[25000, 70000]) {
        final MpvCacheDumpDecision d = planMpvCacheDump(
          ranges: ranges,
          startMs: start,
          endMs: start + 1000,
        );
        expect(d.plan, isNull);
        expect(d.waitForTail, isFalse);
      }
    });

    test('空区间不落盘', () {
      final MpvCacheDumpDecision d = planMpvCacheDump(
        ranges: ranges,
        startMs: 5000,
        endMs: 5000,
      );
      expect(d.plan, isNull);
      expect(d.waitForTail, isFalse);
    });

    test('命令参数：秒数固定 6 位小数，不出科学计数法', () {
      const MpvCacheDumpPlan plan = MpvCacheDumpPlan(
        dumpStart: 0.0000001,
        dumpEnd: 43.6,
        zeroMs: 0,
      );
      expect(mpvDumpCacheCommand(plan, '/tmp/a.mkv'), <String>[
        'dump-cache',
        '0.000000',
        '43.600000',
        '/tmp/a.mkv',
      ]);
    });
  });

  group('resolveVideoOnlineMiningMode', () {
    VideoOnlineMiningMode resolve(
      String? source, {
      VideoOnlineMiningMode preferred = VideoOnlineMiningMode.deferred,
      bool overwrite = false,
      bool review = false,
    }) => resolveVideoOnlineMiningMode(
      preferred: preferred,
      mediaSource: source,
      overwrite: overwrite,
      sourceReview: review,
    );

    test('网络流按偏好', () {
      expect(
        resolve('https://emby/Videos/1/stream'),
        VideoOnlineMiningMode.deferred,
      );
      expect(
        resolve(
          'http://127.0.0.1:1234/relay',
          preferred: VideoOnlineMiningMode.background,
        ),
        VideoOnlineMiningMode.background,
      );
    });

    test('本地文件 / 无源恒等待（本来就秒出，保留最新可改）', () {
      expect(resolve(r'D:\anime\01.mkv'), VideoOnlineMiningMode.wait);
      expect(resolve('file:///anime/01.mkv'), VideoOnlineMiningMode.wait);
      expect(resolve(null), VideoOnlineMiningMode.wait);
    });

    test('覆盖已有卡 / 回看会话恒等待', () {
      expect(
        resolve('https://emby/x', overwrite: true),
        VideoOnlineMiningMode.wait,
      );
      expect(
        resolve('https://emby/x', review: true),
        VideoOnlineMiningMode.wait,
      );
    });

    test('偏好解析：未知值回退后台', () {
      expect(
        VideoOnlineMiningMode.fromWireName(null),
        VideoOnlineMiningMode.background,
      );
      expect(
        VideoOnlineMiningMode.fromWireName('bogus'),
        VideoOnlineMiningMode.background,
      );
      expect(
        VideoOnlineMiningMode.fromWireName('deferred'),
        VideoOnlineMiningMode.deferred,
      );
    });
  });
}
