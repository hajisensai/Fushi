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

  test('令牌相同且一直没写：到点回原令牌', () async {
    final SrsChangeFeed f = SrsChangeFeed();
    final int t0 = f.token;
    expect(
      await f.waitAfter(t0, timeout: const Duration(milliseconds: 30)),
      t0,
    );
  });
}
