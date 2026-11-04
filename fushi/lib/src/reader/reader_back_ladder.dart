/// 阅读器「返回」的阶梯——单点判定。
///
/// 阅读器里有两类返回入口，**阶梯相同**：
///
/// - 键盘 / 手柄 / 鼠标绑定的 `globalBack`（默认 Esc、Alt+←、手柄 B），在本页
///   `_handleKeyEvent` 里解析；
/// - 落到本页 `PopScope.onPopInvokedWithResult` 的路由返回——Android 返回键 /
///   侧滑返回手势、iOS 侧滑、根 `maybePop()` 兜底。
///
/// 两条都是「离开这本书」：歌词模式下一次就回书架，不先掀开歌词层再退一次
/// （系统返回见反馈 NJIIDAhIZL，Esc 见反馈 NaFaJbaAdc）。歌词层只是这本书的一种
/// 显示方式，退书时它的开关照常记在书上，重开仍是歌词模式。只有词典弹窗这种
/// **临时浮层**先关（平台惯例）。快捷键那条退书前还会先退窗口全屏（见
/// `_exitWindowFullscreenOrPopReader`），那是窗口状态、不属于本阶梯。
///
/// 两条来源在框架里是分开的：Android 返回键在 Flutter 里是 `goBack` 逻辑键，
/// 没绑到 `globalBack`，键事件未消费就交回系统，走 `didPopRoute` → 根 `maybePop()`
/// → 本页 `PopScope`；返回手势根本不产生键事件。`globalBack` 在本页消费掉
/// （`KeyEventResult.handled`），决定退书时才经 `maybePop()` 进 `PopScope`，那时
/// 词典弹窗已经判过、不会被二次拦截。
///
/// 显式退书（面板「退出」、重导入后正文作废，见 `_exitReaderBook`）同样经
/// `maybePop()` 进 `PopScope`，用 [explicitExit] 跳过整条阶梯直接退书。
library;

/// 这一次返回该做的那一步。
enum ReaderBackStep {
  /// 只关词典弹窗，留在书里。
  closeDictionary,

  /// 退出书籍（走 `PopScope` → `onWillPop` 的落库 / closeMedia / 关书同步链）。
  exitBook,
}

/// 判定一次返回该走哪一步。
///
/// [explicitExit] 为真（程序化退书在途）时无条件 [ReaderBackStep.exitBook]。
ReaderBackStep resolveReaderBackStep({
  required bool dictionaryShown,
  bool explicitExit = false,
}) {
  if (explicitExit) return ReaderBackStep.exitBook;
  if (dictionaryShown) return ReaderBackStep.closeDictionary;
  return ReaderBackStep.exitBook;
}
