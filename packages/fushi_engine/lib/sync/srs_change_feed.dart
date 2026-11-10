/// 复习同步的「有新段」通知（docs/specs/2026-10-25-srs-sync-v2-design.md §6.3：互联快速通道）。
///
/// host 不理解操作内容，只知道「SRS 目录里刚有人写了东西」：已配对设备经互联写进 `fushi-srs/` 下的文件，或 host
/// 自己的复习数据刚发布到本机目录。客户端长轮询 `GET /api/srs/changes?after=<令牌>`：令牌变了立刻回，没变就挂住
/// 最多 [kSrsChangeWait] 再回原令牌。客户端拿到新令牌就跑一轮同步——协议、去重、合并与网盘路径完全同一套，
/// 这里只省掉「等下一次定时同步」的那段延迟。
library;

import 'dart:async';

import 'package:meta/meta.dart';

/// host 自己加入复习同步 v2 了没有（BUG-4320）：`GET` 回 `{"joined": bool}`。app 作为 host 时，用户确认首次 v2
/// 同步之前它不跑本机目录那一轮——既不发布自己的复习数据，也不并入已配对设备写进来的段，客户端那一轮「成功」却什么
/// 都收不到。客户端一轮跑完问这里，据此说「对端还没开复习同步」而不是「全部已同步」。没有首次确认这一步的 host
/// （无头服务端 / 老版本）不提供这个端点（404），客户端按「不报告」处理。
const String kSrsSyncStatusPath = '/api/srs/sync-status';

/// 一次长轮询最多挂多久（小于常见反向代理的 60 s 空闲超时）。
const Duration kSrsChangeWait = Duration(seconds: 25);

/// 一次长轮询的回答：[token] 是 host 此刻的令牌；[ownOnly] = 从客户端记的令牌到 [token] 之间的每一次推进都是提问的
/// 这台设备自己写 head 引起的（BUG-4378）。客户端据此不为自己刚发出去的 head 再跑一轮——那一轮什么也收不到，只会
/// 让「立即同步」报完「已同步」之后同步状态行又从「准备」走一遍。认不出写者（共享口令 / host 自己发布 / 记录已滚
/// 出窗口 / 老 host）一律为 false，照常同步，宁可多跑一轮也不漏。
@immutable
class SrsChangePoll {
  const SrsChangePoll(this.token, {this.ownOnly = false});

  final int token;
  final bool ownOnly;

  @override
  bool operator ==(Object other) =>
      other is SrsChangePoll &&
      other.token == token &&
      other.ownOnly == ownOnly;

  @override
  int get hashCode => Object.hash(token, ownOnly);

  @override
  String toString() => 'SrsChangePoll($token, ownOnly: $ownOnly)';
}

/// [SrsChangeFeed] 记多少次最近推进的写者（只用来判 [SrsChangePoll.ownOnly]）。客户端每次长轮询都带上一次的令牌，
/// 正常只差一两次推进；差得比这多就按认不出写者处理。
const int kSrsChangeWriterWindow = 64;

class SrsChangeFeed {
  SrsChangeFeed() : _token = DateTime.now().microsecondsSinceEpoch;

  /// 以启动时刻起步：host 重启后令牌必然和客户端记的不同，客户端会多跑一轮，不会漏。
  int _token;
  Completer<void> _changed = Completer<void>();

  /// 最近 [kSrsChangeWriterWindow] 次推进的写者（下标 i 对应令牌 `_token - 写者数 + 1 + i`）；null = 认不出。
  /// 写者是已配对设备各自的口令，只在内存里比对，不落盘、不进日志。
  final List<String?> _writers = <String?>[];

  int get token => _token;

  /// 有新东西了：唤醒全部挂着的长轮询。[writer] 是写入方的身份（已配对设备的专属口令）；host 自己发布 / 认不出
  /// 时为 null。
  void bump({String? writer}) {
    _token++;
    _writers.add(writer);
    if (_writers.length > kSrsChangeWriterWindow) _writers.removeAt(0);
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

  /// 同 [waitAfter]，另判这段推进是不是全由 [reader] 自己写出来的（见 [SrsChangePoll.ownOnly]）。
  Future<SrsChangePoll> poll(
    int? after, {
    String? reader,
    Duration timeout = kSrsChangeWait,
  }) async {
    final int token = await waitAfter(after, timeout: timeout);
    return SrsChangePoll(token, ownOnly: _ownOnly(after, token, reader));
  }

  bool _ownOnly(int? after, int token, String? reader) {
    if (reader == null || after == null || token <= after) return false;
    // 这段推进对应的写者在 _writers 里的位置：令牌 t 的写者在下标 `t - (_token - 长度 + 1)`。
    final int first = _token - _writers.length + 1;
    if (after + 1 < first || token > _token) return false;
    for (int t = after + 1; t <= token; t++) {
      if (_writers[t - first] != reader) return false;
    }
    return true;
  }
}
