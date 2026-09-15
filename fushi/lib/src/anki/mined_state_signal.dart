import 'dart:async';

/// 一个词的制卡态（查词弹窗上的「已制卡 ✓ / 可制卡 +」）**在弹窗之外**变了。
///
/// [expression] 非空 = 只有这个词变了（刷新时只重问它，不给整屏词条发桥）；
/// `null` = 「都可能变了」，收方按自己的节流口径处理（见
/// `DictionaryPopupWebViewState._refreshMineStates`：只重问已经探测过的按钮）。
class MinedStateChange {
  const MinedStateChange({this.expression});

  /// 变化的词头；`null` 表示范围未知。
  final String? expression;
}

/// 「制卡态可能已经变了，正在显示 ✓ 的界面该重新问一次」的进程内广播。
///
/// **为什么非得有这条回头通知**：弹窗上的 ✓ 是**查词那一刻**探测出来的（popup.js
/// `scheduleEntryStateCheck` → `duplicateCheck` 桥），此后只有两个时机会再问 Anki：
/// 用户点按钮，或重新查一次这个词。对同步后端（AnkiConnect / AnkiDroid，`mineEntry`
/// 返回时卡已经在库里）这就够了——制卡成功后 popup.js 紧跟着回问一次就能拿到真值。
///
/// AnkiMobile 不是同步后端：它的 `mineEntry` 只能确认「AnkiMobile 被拉起来了」，
/// 真正的「卡进库了」要等 `x-success` 回跳（见 `AnkiMobileMinedLedger`）——那已经是
/// 用户从 AnkiMobile 切回来之后的事。于是 popup.js 那次紧跟着的回问**必然**落在落账
/// 之前、拿到 `false`，✓ 不亮，用户得重新点一次这个词才看得见（用户报「iOS 添加完
/// 卡片并没有出现打勾」）。这不是偶发竞态，是时序上的结构性错配：只能由**落账那一侧
/// 回头通知界面**，而不是让界面去猜该等多久（延迟重试是掩盖，不是修复）。
///
/// 谁发：确知制卡态变了的地方——iOS 的 `x-success` 落账、用户纠正 iOS 台账
/// （`AnkiMobileMinedLedger.record` / `forget` 内部统一发，调用点不必记得）。
/// 谁收：正在显示制卡态的表面（`DictionaryPopupWebViewState`）。
///
/// 广播流、进程内、不持久化：它只负责「已经画在屏幕上的那个 ✓ 现在过期了」。没有
/// 监听者时发送是 no-op（弹窗没开着 → 下次查词本来就会重新探测）。
class MinedStateSignal {
  MinedStateSignal._();

  static final MinedStateSignal instance = MinedStateSignal._();

  final StreamController<MinedStateChange> _controller =
      StreamController<MinedStateChange>.broadcast();

  /// 订阅制卡态失效通知。广播流：多个表面可同时订阅，各自独立取消。
  Stream<MinedStateChange> get changes => _controller.stream;

  /// 这个词的制卡态变了（iOS 落账 / 台账被纠正）。
  void notifyWord(String expression) {
    final String trimmed = expression.trim();
    if (trimmed.isEmpty) return;
    _emit(MinedStateChange(expression: trimmed));
  }

  /// 范围未知的失效（如「从后台切回前台，期间用户可能在 Anki 里删了卡」）。
  void notifyAll() => _emit(const MinedStateChange());

  void _emit(MinedStateChange change) {
    if (_controller.isClosed) return;
    _controller.add(change);
  }
}
