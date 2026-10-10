import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/bluray/aacs_media_session.dart';
import 'package:fushi_engine/sync/bluray_clip_relay_pool.dart';

class _CountingSession extends AacsMediaSession {
  _CountingSession(this.onClose);

  final void Function() onClose;

  @override
  Future<String> resolve(String path) async => 'http://relay/$path';

  @override
  Future<void> close() async => onClose();
}

void main() {
  test('在途请求期间不回收（mpv 一条长 GET 能读很久），归零后空闲到期才关', () {
    fakeAsync((FakeAsync async) {
      int opened = 0;
      int closed = 0;
      final BlurayClipRelayPool pool = BlurayClipRelayPool(
        idleTimeout: const Duration(minutes: 5),
        openSession: () {
          opened++;
          return _CountingSession(() => closed++);
        },
      );
      late BlurayClipLease long;
      pool.acquire('play', 'a.m2ts').then((BlurayClipLease l) => long = l);
      async.flushMicrotasks();
      expect(long.source, 'http://relay/a.m2ts');

      async.elapse(const Duration(minutes: 30));
      expect(closed, 0, reason: '长请求还在读');

      long.release();
      long.release(); // 重复释放无副作用。
      async.elapse(const Duration(minutes: 4));
      expect(closed, 0);

      // 空闲期内的新请求复用同一会话并取消回收。
      late BlurayClipLease again;
      pool.acquire('play', 'b.m2ts').then((BlurayClipLease l) => again = l);
      async.flushMicrotasks();
      expect(opened, 1);
      again.release();
      async.elapse(const Duration(minutes: 5));
      expect(closed, 1);
      expect(pool.sessionCount, 0);

      // 另一次播放（另一张 token）各自一份会话。
      pool.acquire('other', 'a.m2ts').then((BlurayClipLease l) => l.release());
      async.flushMicrotasks();
      expect(opened, 2);
      pool.closeAll();
      async.flushMicrotasks();
      expect(closed, 2);
      Object? error;
      pool
          .acquire('play', 'a.m2ts')
          .then<void>((_) {}, onError: (Object e) {
            error = e;
          });
      async.flushMicrotasks();
      expect(error, isStateError, reason: '停机后不再开新的解密回环');
    });
  });
}
