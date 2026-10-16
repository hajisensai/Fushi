import 'package:flutter/foundation.dart';

/// 遥控面挂在哪种阅读器上（决定哪些定位方式可用）。
enum ReaderSessionKind {
  /// EPUB 阅读器：按章 / 章内进度 / 全书百分比定位。
  epub,

  /// PDF 阅读器：按页定位。
  pdf,

  /// 漫画阅读器：按页定位；在线作品还能按话切换。
  manga,
}

/// 书类阅读页对外暴露的最小遥控面（桌面控制通道 `fushi_cli reader ...` 用）。
///
/// 与 `VideoPlaybackRemote` 同一形态：阅读器状态是各页面 State 的私有字段，页面在
/// initState 把自己的实现登记进 [readerSessionRemotes]、dispose 时注销。实现只转调
/// 页内已有的执行体（翻页键 / 浮动翻页条 / 目录跳章 / 进度条拖动背后的同一批方法），
/// 不另写阅读器逻辑。某种阅读器不支持的动作返回 false，路由层先按
/// [ReaderSessionSnapshot.kind] 挡下。
abstract interface class ReaderSessionRemote {
  /// 当前阅读状态；书还没加载好（首开加载中 / 加载失败）时为 null。
  ReaderSessionSnapshot? snapshot();

  /// 往前（[forward] = true）或往后翻一页；与翻页快捷键同一入口。
  Future<void> turnPage({required bool forward});

  /// EPUB：跳到 0 起计的第 [chapterIndex] 章、章内分数 [progress]（0–1）；在线漫画：
  /// 切到第 [chapterIndex] 话（忽略 [progress]）。返回是否落定在目标章 / 话。
  Future<bool> goToChapter(int chapterIndex, {double progress = 0});

  /// EPUB：跳到全书百分比 [percent]（0–100）。字数统计未就绪 / 非 EPUB 返回 false。
  Future<bool> goToBookPercent(double percent);

  /// PDF / 漫画：跳到 0 起计的第 [pageIndex] 页。EPUB 返回 false。
  Future<bool> goToPage(int pageIndex);
}

/// [ReaderSessionRemote.snapshot] 的只读快照。不适用于当前阅读器的字段为 null。
@immutable
class ReaderSessionSnapshot {
  const ReaderSessionSnapshot({
    required this.kind,
    required this.bookKey,
    required this.title,
    required this.contentReady,
    this.chapterIndex,
    this.chapterCount,
    this.chapterProgress,
    this.currentChars,
    this.totalChars,
    this.pageIndex,
    this.pageCount,
  });

  final ReaderSessionKind kind;
  final String bookKey;
  final String? title;

  /// 正文是否已就绪（导航 / 恢复在飞时为 false）。
  final bool contentReady;

  /// 0 起计的当前章（EPUB）/ 话（在线漫画）。
  final int? chapterIndex;
  final int? chapterCount;

  /// EPUB 章内进度（0–1，最近一次进度采样）。
  final double? chapterProgress;

  /// EPUB 全书已读字数 / 总字数（字数统计未就绪时为 null）。
  final int? currentChars;
  final int? totalChars;

  /// PDF / 漫画：0 起计的当前页与总页数。
  final int? pageIndex;
  final int? pageCount;

  /// EPUB 全书百分比（0–100，一位小数）；字数未就绪为 null。
  double? get bookPercent {
    final int? current = currentChars;
    final int? total = totalChars;
    if (current == null || total == null || total <= 0) return null;
    return ((current / total) * 1000).clamp(0, 1000).round() / 10;
  }
}

/// 阅读页遥控登记表：按登记顺序成栈，[current] 恒为最后登记、仍存活的那页。
class ReaderSessionRemoteRegistry {
  final List<ReaderSessionRemote> _stack = <ReaderSessionRemote>[];

  /// 当前可遥控的阅读页；没有阅读页时为 null。
  final ValueNotifier<ReaderSessionRemote?> current =
      ValueNotifier<ReaderSessionRemote?>(null);

  /// 登记 [remote] 到栈顶；重复登记是 no-op。
  void register(ReaderSessionRemote remote) {
    if (_stack.contains(remote)) return;
    _stack.add(remote);
    current.value = remote;
  }

  /// 注销 [remote]（未登记时 no-op）；栈顶回落到下一个仍登记的页面。
  void unregister(ReaderSessionRemote remote) {
    if (!_stack.remove(remote)) return;
    current.value = _stack.isEmpty ? null : _stack.last;
  }

  @visibleForTesting
  int get debugLength => _stack.length;
}

/// 进程级唯一登记点。
final ReaderSessionRemoteRegistry readerSessionRemotes =
    ReaderSessionRemoteRegistry();
