// 复习同步快速通道的长轮询令牌（srs_change_feed.dart）：令牌不同立刻回；相同就挂到下一次 bump 或超时。
import 'package:fushi_engine/sync/srs_change_feed.dart';
import 'package:test/test.dart';

void main() {
  test('客户端记的令牌过期：立刻返回当前令牌', () async {
    final SrsChangeFeed f = SrsChangeFeed();
    expect(await f.waitAfter(null), f.token);
    expect(await f.waitAfter(f.token - 1), f.token);
  });

  test('令牌相同：挂住，bump 时唤醒全部等待者', () async {
    final SrsChangeFeed f = SrsChangeFeed();
    final int t0 = f.token;
    final Future<int> w1 = f.waitAfter(t0);
    final Future<int> w2 = f.waitAfter(t0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    f.bump();
    expect(await w1, t0 + 1);
    expect(await w2, t0 + 1);
  });

  // BUG-4370：「立即同步」/ 推送写完 head，host 推进令牌，写的设备自己的长轮询也被叫醒、再空跑一轮。
  test('这段推进全是提问者自己写的：ownOnly；夹着别人 / 认不出的写者：不是', () async {
    final SrsChangeFeed f = SrsChangeFeed();
    final int t0 = f.token;
    f.bump(writer: 'phone');
    f.bump(writer: 'phone');
    expect(
      await f.poll(t0, reader: 'phone'),
      SrsChangePoll(t0 + 2, ownOnly: true),
    );
    expect(
      await f.poll(t0, reader: 'tablet'),
      SrsChangePoll(t0 + 2),
      reason: '别的设备看到的是新数据',
    );
    expect(
      await f.poll(t0),
      SrsChangePoll(t0 + 2),
      reason: '认不出提问者（共享口令）：照常同步',
    );
    f.bump(writer: 'tablet');
    expect(
      (await f.poll(t0, reader: 'phone')).ownOnly,
      isFalse,
      reason: '中间夹着别人写的 head',
    );
    expect(
      await f.poll(t0 + 2, reader: 'tablet'),
      SrsChangePoll(t0 + 3, ownOnly: true),
    );
    f.bump();
    expect(
      (await f.poll(t0 + 3, reader: 'tablet')).ownOnly,
      isFalse,
      reason: 'host 自己发布（没有写者）',
    );
  });

  test('第一次（没有基线）/ 记录已滚出窗口：不算 ownOnly', () async {
    final SrsChangeFeed f = SrsChangeFeed();
    final int t0 = f.token;
    f.bump(writer: 'phone');
    expect((await f.poll(null, reader: 'phone')).ownOnly, isFalse);
    for (int i = 0; i < kSrsChangeWriterWindow + 1; i++) {
      f.bump(writer: 'phone');
    }
    expect(
      (await f.poll(t0, reader: 'phone')).ownOnly,
      isFalse,
      reason: '最早那几次推进的写者已经不记得了',
    );
    expect(
      (await f.poll(f.token - kSrsChangeWriterWindow, reader: 'phone')).ownOnly,
      isTrue,
    );
  });

  test('挂着等的长轮询被自己的写入叫醒：回 ownOnly', () async {
    final SrsChangeFeed f = SrsChangeFeed();
    final int t0 = f.token;
    final Future<SrsChangePoll> mine = f.poll(t0, reader: 'phone');
    final Future<SrsChangePoll> theirs = f.poll(t0, reader: 'tablet');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    f.bump(writer: 'phone');
    expect(await mine, SrsChangePoll(t0 + 1, ownOnly: true));
    expect(await theirs, SrsChangePoll(t0 + 1));
  });

  test('令牌相同且一直没写：到点回原令牌', () async {
    final SrsChangeFeed f = SrsChangeFeed();
    final int t0 = f.token;
    expect(
      await f.waitAfter(t0, timeout: const Duration(milliseconds: 30)),
      t0,
    );
  });
}
