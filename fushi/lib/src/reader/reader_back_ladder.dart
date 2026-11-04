/// 阅读器「返回」的逐级阶梯——单点判定。
///
/// 阅读器里有两类返回入口，走同一条阶梯：
///
/// - 键盘 / 手柄 / 鼠标绑定的 `globalBack`（默认 Esc、Alt+←、手柄 B），在本页
///   `_handleKeyEvent` 里解析；
/// - 落到本页 `PopScope.onPopInvokedWithResult` 的路由返回——Android 返回键 /
///   侧滑返回手势、iOS 侧滑、根 `maybePop()` 兜底。
///
/// 阶梯只有一级临时浮层：**词典弹窗先关**（平台惯例），其余一律退书。歌词覆盖层
/// **不是**一级：歌词模式是这本书的阅读形态（每本书各记各的），返回就是「离开这本书
/// 回书架」，不是先掀开歌词层露出正文再退一次（系统返回见反馈 NJIIDAhIZL，Esc 见
/// 反馈 NaFaJbaAdc / BUG-4005；歌词层右上角 × 也是直接退书，见 QvYpZODImz）。
/// 想留在书里看正文用歌词层上的「书籍模式」键。退书**不**先关歌词层：那会把持久化
/// 的 lyrics_mode 写成 false，重开书就不再恢复歌词模式（BUG-785）。
///
/// `globalBack` 在本页消费掉（`KeyEventResult.handled`），决定退书时才经
/// `maybePop()` 进 `PopScope`——那时词典已经判过、不会被二次拦截。
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
