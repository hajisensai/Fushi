// BUG-5598：媒体播放会话——网络卷上的整文件哈希据此给所有播放让路：
//  - 活动窗口（touch）到期才结束，续约推迟到期；
//  - 常驻播放器（音乐 / 有声书）在播持有、暂停后留窗口、销毁即结束显式会话；
//  - 互联 host 送播放字节（serveFileWithRange playback: true）读着的期间算会话、读完续窗口，
//    不传 playback 的（封面等）不算；
//  - 转码工作跑的期间算会话、跑完续窗口。
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:fushi_engine/media/media_playback_activity.dart';
import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

void main() {
  group('MediaPlaybackActivity.touch 活动窗口', () {
    test('窗口内续约推迟到期；到期后变闲', () {
      fakeAsync((FakeAsync async) {
        final MediaPlaybackActivity activity = MediaPlaybackActivity(
          now: async.getClock(DateTime(2026)).now,
        );
        bool idle = false;
        activity.touch('a', window: const Duration(seconds: 10));
        expect(activity.isActive, isTrue);
        activity.whenIdle().then((_) => idle = true);
        async.elapse(const Duration(seconds: 8));
        activity.touch('a', window: const Duration(seconds: 10));
        async.elapse(const Duration(seconds: 8));
        expect(idle, isFalse, reason: '续约后从续约时刻重新计时');
        async.elapse(const Duration(seconds: 3));
        expect(idle, isTrue);
        expect(activity.isActive, isFalse);
      });
    });

    test('同 key 续约不叠加会话；不同 key 各自计时', () {
      fakeAsync((FakeAsync async) {
        final MediaPlaybackActivity activity = MediaPlaybackActivity(
          now: async.getClock(DateTime(2026)).now,
        );
        int busy = 0;
        activity.onBecameActive(() => busy++);
        activity
          ..touch('a', window: const Duration(seconds: 5))
          ..touch('a', window: const Duration(seconds: 5))
          ..touch('b', window: const Duration(seconds: 20));
        expect(busy, 1);
        async.elapse(const Duration(seconds: 6));
        expect(activity.isActive, isTrue, reason: 'b 的窗口还没到期');
        async.elapse(const Duration(seconds: 15));
        expect(activity.isActive, isFalse);
      });
    });
  });

  group('MediaPlaybackHold（常驻播放器）', () {
    test('在播持有；暂停后留一个窗口；窗口内恢复不出现空闲', () {
      fakeAsync((FakeAsync async) {
        final MediaPlaybackActivity activity = MediaPlaybackActivity(
          now: async.getClock(DateTime(2026)).now,
        );
        final MediaPlaybackHold hold = MediaPlaybackHold(activity: activity);
        int busy = 0;
        activity.onBecameActive(() => busy++);
        hold.setPlaying(true);
        hold.setPlaying(true);
        expect(busy, 1);
        hold.setPlaying(false);
        expect(activity.isActive, isTrue, reason: '暂停后还有活动窗口');
        async.elapse(const Duration(seconds: 30));
        hold.setPlaying(true);
        expect(busy, 1, reason: '窗口内恢复播放，没有出现过空闲');
        hold.setPlaying(false);
        async.elapse(kMediaPlaybackLingerWindow + const Duration(seconds: 1));
        expect(activity.isActive, isFalse, reason: '长时间暂停不能一直挡着后台任务');
      });
    });

    test('销毁时结束显式会话；之后的状态变化不再开会话', () {
      final MediaPlaybackActivity activity = MediaPlaybackActivity();
      final MediaPlaybackHold hold = MediaPlaybackHold(activity: activity)
        ..setPlaying(true);
      hold.dispose();
      expect(activity.isActive, isFalse);
      hold.setPlaying(true);
      expect(activity.isActive, isFalse);
    });
  });

  group('互联 host 送播放字节', () {
    late Directory tmp;
    late File file;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_playback_serve_');
      file = File(p.join(tmp.path, 'ep01.mkv'))
        ..writeAsBytesSync(List<int>.filled(4096, 7));
    });
    tearDown(() => tmp.deleteSync(recursive: true));
    setUp(MediaPlaybackActivity.instance.debugReset);
    tearDown(MediaPlaybackActivity.instance.debugReset);

    shelf.Request request({String? range}) => shelf.Request(
      'GET',
      Uri.parse('http://host/stream'),
      headers: <String, String>{if (range != null) 'range': range},
    );

    test('不传 playback 的响应（封面等）不算会话', () async {
      final shelf.Response res = await serveFileWithRange(file, request());
      await for (final List<int> _ in res.read()) {
        expect(MediaPlaybackActivity.instance.isActive, isFalse);
      }
      expect(MediaPlaybackActivity.instance.isActive, isFalse);
    });

    test('playback: true——body 读着的期间算会话，读完续窗口（206 与 200 都算）', () async {
      final MediaPlaybackActivity activity = MediaPlaybackActivity.instance;
      for (final String? range in <String?>['bytes=0-1023', null]) {
        activity.debugReset();
        bool sawActiveWhileReading = false;
        final shelf.Response res = await serveFileWithRange(
          file,
          request(range: range),
          playback: true,
        );
        await for (final List<int> _ in res.read()) {
          sawActiveWhileReading = activity.isActive;
        }
        expect(sawActiveWhileReading, isTrue, reason: '$range');
        expect(
          activity.isActive,
          isTrue,
          reason: '读完留活动窗口，盖住下一个 Range / seek 之前的空隙',
        );
      }
    });
  });

  group('转码工作', () {
    setUp(MediaPlaybackActivity.instance.debugReset);
    tearDown(MediaPlaybackActivity.instance.debugReset);

    test('跑的期间算会话，跑完续窗口', () async {
      final MediaPlaybackActivity activity = MediaPlaybackActivity.instance;
      bool activeInside = false;
      await runGuardedTranscodeForTesting<int>(() async {
        activeInside = activity.isActive;
        return 1;
      }, workKey: 'stream-token');
      expect(activeInside, isTrue);
      expect(activity.isActive, isTrue, reason: '分段之间的空隙由活动窗口盖住');
    });
  });
}
