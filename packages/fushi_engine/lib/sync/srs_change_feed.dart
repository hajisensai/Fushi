/// 复习同步的「有新段」通知（docs/specs/2026-10-25-srs-sync-v2-design.md §6.3：互联快速通道）。
///
/// host 不理解操作内容，只知道「SRS 目录里刚有人写了东西」：已配对设备经互联写进 `fushi-srs/` 下的文件，或 host
/// 自己的复习数据刚发布到本机目录。客户端长轮询 `GET /api/srs/changes?after=<令牌>`：令牌变了立刻回，没变就挂住
/// 最多 [kSrsChangeWait] 再回原令牌。客户端拿到新令牌就跑一轮同步——协议、去重、合并与网盘路径完全同一套，
/// 这里只省掉「等下一次定时同步」的那段延迟。
library;

import 'dart:async';

/// 一次长轮询最多挂多久（小于常见反向代理的 60 s 空闲超时）。
const Duration kSrsChangeWait = Duration(seconds: 25);

class SrsChangeFeed {
  SrsChangeFeed() : _token = DateTime.now().microsecondsSinceEpoch;

  /// 以启动时刻起步：host 重启后令牌必然和客户端记的不同，客户端会多跑一轮，不会漏。
  int _token;
  Completer<void> _changed = Completer<void>();

  int get token => _token;

  /// 有新东西了：唤醒全部挂着的长轮询。
  void bump() {
    _token++;
    final Completer<void> c = _changed;
    _changed = Completer<void>();
    c.complete();
  }

  /// [after] 与当前令牌不同就立刻返回当前令牌；否则等到下一次 [bump] 或 [timeout]。
  Future<int> waitAfter(int? after, {Duration timeout = kSrsChangeWait}) async {
    if (after != _token) return _token;
    try {
      await _changed.future.timeout(timeout);
    } on TimeoutException {
      // 到点照常回当前令牌（没变），客户端接着下一次长轮询。
    }
    return _token;
  }
}
