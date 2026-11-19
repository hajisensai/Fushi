/// 漫画阅读器「查词时暂停」（BUG-4907）：查词弹窗出现时把正在播的朗读 / 漫画有声
/// 按住，弹窗整栈关闭时恢复；查词前本来就停着的不动。
///
/// 开关与小说阅读器共用「查词时暂停」（`ReaderFushiSource.pauseOnLookup`）。两种音源
/// （成品音频驱动 / 现场合成控制器）由阅读器适配成 [MangaLookupPausable] 交进来，
/// 这里只管「按住了没有」这一个标记。
library;

/// 能被查词按住的播放。
abstract interface class MangaLookupPausable {
  /// 此刻在出声（或正在为出声做准备：合成 / 等页文字）。
  bool get isRunning;

  void pause();

  /// 恢复被按住的播放；用户这期间自己已经恢复或停掉时由实现自行跳过。
  void resume();
}

class MangaLookupPause {
  bool _held = false;

  /// 查词弹窗正按住播放。
  bool get held => _held;

  /// 查词弹窗出现。幂等：多层弹窗逐层出现只按一次，已按住的不重复记。
  void lookupOpened(MangaLookupPausable? playback, {required bool enabled}) {
    if (!enabled || _held || playback == null || !playback.isRunning) return;
    playback.pause();
    _held = true;
  }

  /// 查词弹窗整栈关闭：恢复按住的播放。
  void lookupClosed(MangaLookupPausable? playback) {
    if (!_held) return;
    _held = false;
    playback?.resume();
  }

  /// 用户停掉 / 换了音源：撤掉标记，之后关弹窗不再恢复。
  void drop() => _held = false;
}
