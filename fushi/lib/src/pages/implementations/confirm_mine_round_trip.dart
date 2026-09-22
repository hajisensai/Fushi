import 'dart:async';

/// 「确认制卡」往返（[DictionaryPopupWebViewState.mineEntryByIndex]）的**竞态与超时
/// 策略**，抽成不依赖 WebView 的纯逻辑。
///
/// 真往返要 WebView2 + 真弹窗 + 真对话框，只有 `-Visible` 的 Windows runner 跑得动；
/// 策略本身却是这条链路上最容易出错的地方（BUG-2627 与 BUG-2634 两轮都栽在它上面），
/// 所以判据放在这里由单测驱动，State 只负责接线。
///
/// ## 两个信号各司其职（BUG-2634 第二轮）
///
/// 第一轮只有一个「已接受」信号，同时兼管「解除超时」与「可以关窗」，于是两条路各出
/// 一个问题：
///
/// * `minedCardAction`（这个词以前制过卡 → 弹「覆写 / 新增重复 / 取消」操作单）会
///   **无限等用户做选择**。把信号放在 `await` 之后，45 秒计时照旧盖住「模态等人」，
///   超时后报的正是用户原话那句「查词弹窗已经关掉了」，还会把用户正在用的操作单
///   `Navigator.pop` 掉。
/// * 放在 `await` 之前又会踩另一头：阅读器的 `onMineFromPopup` 经制卡串行队列入队，
///   草稿要等前一次制卡整段跑完才被读走；提前关窗 → 弹窗关栈 → 草稿被清，排到的任务
///   用空草稿合成，卡制出来、toast 报成功、用户刚调的上下文全丢。
///
/// 所以拆成两个：
///
/// * [markHostEntered]：宿主已接手 payload。**唯一作用是解除 [preHostTimeout]**——那个
///   超时本来就只为「弹窗桥半死不回」而设，宿主的 Dart 代码一旦在跑，桥就已经回过话
///   了，再让它计时就是在给「宿主在等用户」判死刑。三个制卡桥 handler 都在把 payload
///   交出去的那一刻调它。
/// * [markPayloadConsumed]：宿主**已经把草稿 / 制卡上下文读走了**，对话框可以关了。
///   只有能保证「在首个 `await` 之前同步读完」的宿主才调（见
///   [DictionaryPopupWebViewState.mineEntryByIndex] 的 `releaseWhenPayloadConsumed`）。
///   不调的宿主退回「等落地」这条老路——慢一点，但绝不丢草稿。
///
/// 没人调 [markPayloadConsumed] 时本类的行为与 BUG-2634 之前完全一致，**只是不会再
/// 因为宿主慢而误报失败**。
class ConfirmMineRoundTrip {
  ConfirmMineRoundTrip({required this.preHostTimeout});

  /// 「回点前」那一段（下发 JS → 查重 → 取音 → 组 payload）的上限。宿主接手或 JS 先
  /// 落地都算解除；解除之后**不再设上限**，因为那之后的等待是「宿主在干活 / 在等用户」，
  /// 给它判超时只会制造假失败。
  final Duration preHostTimeout;

  final Completer<void> _hostEntered = Completer<void>();
  final Completer<void> _payloadConsumed = Completer<void>();

  /// 宿主已接手 payload；解除 [preHostTimeout]。重复调用是 no-op。
  void markHostEntered() {
    if (!_hostEntered.isCompleted) _hostEntered.complete();
  }

  /// 宿主已读走草稿 / 制卡上下文；对话框可以关窗，制卡在 Dart 侧照常跑完。
  /// 隐含 [markHostEntered]。重复调用是 no-op。
  void markPayloadConsumed() {
    markHostEntered();
    if (!_payloadConsumed.isCompleted) _payloadConsumed.complete();
  }

  /// 跑完一次往返。[landed] 是 popup.js 那头 promise 的落地结果（true = 真的点到了
  /// 那颗制卡按钮）。它**不得以 error 结束**——调用方负责把通道异常折成 `false` 并
  /// 记日志；这里再兜一层只是不让策略层因为别人的疏忽而挂掉。
  Future<ConfirmMineOutcome> run(Future<bool> landed) async {
    bool settled = false;
    bool clicked = false;
    final Future<void> landedSettled = landed.then<void>(
      (bool value) {
        settled = true;
        clicked = value;
      },
      onError: (Object _, StackTrace __) {
        settled = true;
        clicked = false;
      },
    );

    // 第一段：只盖「回点前」。宿主接手或 JS 先落地，两者任一都算桥是活的。
    try {
      await Future.any<void>(<Future<void>>[
        _hostEntered.future,
        landedSettled,
      ]).timeout(preHostTimeout);
    } on TimeoutException {
      return ConfirmMineOutcome.bridgeTimedOut;
    }
    if (settled) {
      return clicked
          ? ConfirmMineOutcome.clicked
          : ConfirmMineOutcome.notClicked;
    }

    // 第二段：宿主在跑（可能在等用户从操作单里选）。不设上限。
    await Future.any<void>(<Future<void>>[
      _payloadConsumed.future,
      landedSettled,
    ]);
    if (settled) {
      return clicked
          ? ConfirmMineOutcome.clicked
          : ConfirmMineOutcome.notClicked;
    }
    // 草稿已被宿主读走：按「点到了」关窗，制卡的成功 / 失败 toast 由宿主自己出，
    // 与直接点弹窗里的 + 完全一样。
    return ConfirmMineOutcome.releasedEarly;
  }
}

/// 一次「确认制卡」往返的结局。只有 [notClicked] 与 [bridgeTimedOut] 该提示用户
/// 「没点到」，且两者的文案与日志必须分得开——BUG-2634 就是把后者说成前者。
enum ConfirmMineOutcome {
  /// popup.js 报「点到了那颗按钮」并且整条制卡链路已经落地。
  clicked,

  /// popup.js 明确拒点：容器里没有 `.entry` / 越界 / 该词条没有可用的制卡按钮。
  notClicked,

  /// 宿主已把草稿读走，对话框提前关窗；制卡还在 Dart 侧跑。
  releasedEarly,

  /// 「回点前」那段都没走完：弹窗桥半死不回。**不是**「宿主慢」。
  bridgeTimedOut;

  /// 对调用方而言「这次算不算点到了」。
  bool get clickedOrAccepted =>
      this == ConfirmMineOutcome.clicked ||
      this == ConfirmMineOutcome.releasedEarly;
}
