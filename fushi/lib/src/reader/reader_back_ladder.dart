/// 阅读器「返回」的逐级阶梯——按**返回从哪来**分两条，单点判定。
///
/// 阅读器里有两类返回入口，语义不同（用户反馈 NJIIDAhIZL，2026-11-01）：
///
/// - [ReaderBackSource.shortcut]：键盘 / 手柄 / 鼠标绑定的 `globalBack`（默认 Esc、
///   Alt+←、手柄 B），在本页 `_handleKeyEvent` 里解析。它是「退一级」：
///   词典弹窗 → 歌词覆盖层 → 退书（Niratan：Esc 先退歌词再关窗口）。
/// - [ReaderBackSource.route]：落到本页 `PopScope.onPopInvokedWithResult` 的
///   路由返回——Android 返回键 / 侧滑返回手势、iOS 侧滑、根 `maybePop()` 兜底。
///   移动端的系统返回是「离开这本书」：歌词模式下用户期望一次就回书架，而不是
///   先掀开歌词层再滑一次。只有词典弹窗这种**临时浮层**先关（平台惯例）。
///
/// 两条来源在框架里本来就是分开的：Android 返回键在 Flutter 里是 `goBack` 逻辑键，
/// 没绑到 `globalBack`，键事件未消费就交回系统，走 `didPopRoute` → 根 `maybePop()`
/// → 本页 `PopScope`；返回手势根本不产生键事件。`globalBack` 在本页消费掉
/// （`KeyEventResult.handled`），到不了 `PopScope` 的阶梯——它只在决定退书时才经
/// `maybePop()` 进 `PopScope`，那时词典与歌词层都已经判过、不会被二次拦截。
///
/// 显式退书（面板「退出」、重导入后正文作废，见 `_exitReaderBook`）同样经
/// `maybePop()` 进 `PopScope`，用 [explicitExit] 跳过整条阶梯直接退书。
library;

/// 返回从哪个入口来。
enum ReaderBackSource {
  /// 键盘 / 手柄 / 鼠标绑定的 `globalBack` 快捷键（本页 `_handleKeyEvent`）。
  shortcut,

  /// 路由返回：系统返回键 / 返回手势 / 根 `maybePop()`（本页 `PopScope`）。
  route,
}

/// 这一次返回该做的那一步。
enum ReaderBackStep {
  /// 只关词典弹窗，留在书里。
  closeDictionary,

  /// 掀开歌词覆盖层回到正文，留在书里。
  closeLyrics,

  /// 退出书籍（走 `PopScope` → `onWillPop` 的落库 / closeMedia / 关书同步链）。
  exitBook,
}

/// 判定一次返回该走哪一步。
///
/// [explicitExit] 为真（程序化退书在途）时无条件 [ReaderBackStep.exitBook]。
ReaderBackStep resolveReaderBackStep({
  required ReaderBackSource source,
  required bool dictionaryShown,
  required bool lyricsMode,
  bool explicitExit = false,
}) {
  if (explicitExit) return ReaderBackStep.exitBook;
  if (dictionaryShown) return ReaderBackStep.closeDictionary;
  switch (source) {
    case ReaderBackSource.shortcut:
      return lyricsMode ? ReaderBackStep.closeLyrics : ReaderBackStep.exitBook;
    case ReaderBackSource.route:
      return ReaderBackStep.exitBook;
  }
}
