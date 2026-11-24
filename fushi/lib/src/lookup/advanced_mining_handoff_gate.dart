// 拍板台 rf--UcsGta-overlay：主窗查词页等「转交来的高级制卡」时的状态机。
//
// 转交只认**那一次请求**的查词结果：结果区画完那次结果后去 popup.js 问词条的 DOM
// 下标（一次异步往返），回来再打开对话框。往返途中用户可能已经手动查了别的词、结果
// 区可能已换成别的结果——旧回包的下标属于旧 DOM，套到新结果上就是制错卡
// （BUG：审查 HBK-AUDIT-003）。所以：
//
// - 用户手动起查 / 清空（页面铸新查词代）时立刻 [revoke]，不等下一次渲染才发现；
// - 回包后再核一遍：仍是同一个转交、同一查词代、同一份结果、同一个 WebView，
//   任何一项变了都不打开对话框。
//
// 纯 Dart、不碰 Flutter：页面把「当前查词代」「当前已画好的结果目标」「定位」
// 「打开对话框」作为回调注入，测试可以拿可手动完成的 Future 精确复现竞态。

import 'package:fushi/src/lookup/advanced_mining_handoff.dart';

/// 结果区此刻已画好的那份结果与承载它的 WebView（只按身份比较）。
typedef AdvancedMiningRenderTarget<R extends Object, V extends Object> = ({
  R result,
  V view,
});

/// 见文件头。[R] 是查词结果类型，[V] 是结果区 WebView 状态类型。
class AdvancedMiningHandoffGate<R extends Object, V extends Object> {
  AdvancedMiningHandoffGate({
    required int Function() currentGeneration,
    required AdvancedMiningRenderTarget<R, V>? Function() renderedTarget,
    required Future<int> Function(
      AdvancedMiningRenderTarget<R, V> target,
      AdvancedMiningHandoff handoff,
    )
    locate,
    required Future<void> Function(int domIndex, AdvancedMiningHandoff handoff)
    open,
    required void Function(AdvancedMiningHandoff handoff) onNotFound,
  }) : _currentGeneration = currentGeneration,
       _renderedTarget = renderedTarget,
       _locate = locate,
       _open = open,
       _onNotFound = onNotFound;

  final int Function() _currentGeneration;

  /// 结果区画好的是当前结果时回它的目标；还在查 / 还没画完 / 没有结果时回 null。
  final AdvancedMiningRenderTarget<R, V>? Function() _renderedTarget;
  final Future<int> Function(
    AdvancedMiningRenderTarget<R, V> target,
    AdvancedMiningHandoff handoff,
  )
  _locate;
  final Future<void> Function(int domIndex, AdvancedMiningHandoff handoff)
  _open;
  final void Function(AdvancedMiningHandoff handoff) _onNotFound;

  AdvancedMiningHandoff? _pending;
  int _generation = -1;
  bool _locating = false;
  bool _renderedWhileBusy = false;
  bool _disposed = false;

  /// 正在等的转交（测试与调试用）。
  AdvancedMiningHandoff? get pending => _pending;

  /// 转交请求发出的那次查词已铸出查词代 [generation]：从此只认这一代的结果。
  /// [handoff] 为 null（这次请求不带转交）等同 [revoke]。
  void arm(AdvancedMiningHandoff? handoff, {required int generation}) {
    _pending = handoff;
    _generation = handoff == null ? -1 : generation;
  }

  /// 作废等着的转交：用户手动查了别的词 / 清空了查询 / 来了新的外部查词请求。
  /// 已经在途的定位回包回来后会发现转交已不是它的，不会打开对话框。
  void revoke() {
    _pending = null;
    _generation = -1;
  }

  /// 页面销毁：之后的回包一律丢弃。
  void dispose() {
    _disposed = true;
    revoke();
  }

  /// 结果区每画完一次（`popupRendered`）都来。返回的 Future 只为测试可等待。
  Future<void> onRendered() async {
    if (_disposed) return;
    final AdvancedMiningHandoff? handoff = _pending;
    if (handoff == null) return;
    if (_locating) {
      // 往返途中又画了一次：回包时据此决定要不要立刻再问（尾批画完的信号不能丢）。
      _renderedWhileBusy = true;
      return;
    }
    final int generation = _generation;
    if (generation != _currentGeneration()) {
      // 兜底：铸代处漏了 revoke 也不会把转交套到别的查词上。
      revoke();
      return;
    }
    final AdvancedMiningRenderTarget<R, V>? target = _renderedTarget();
    if (target == null) return;

    _locating = true;
    _renderedWhileBusy = false;
    bool retry = false;
    try {
      final int index = await _locate(target, handoff);
      if (_disposed) return;
      if (!_stillCurrent(handoff, generation, target)) {
        // 回包已不属于眼下的结果：下标作废。换上来的若已画好（往返途中来过渲染
        // 信号，可能是新转交的那次结果），立刻按新状态再走一遍。
        retry = _renderedWhileBusy;
        return;
      }
      if (index == kPopupEntryIndexStillRendering) {
        retry = _renderedWhileBusy;
        return;
      }
      _pending = null;
      _generation = -1;
      if (index < 0) {
        // 主窗结果里没有这个词条：不猜下标，猜错就是制错卡。
        _onNotFound(handoff);
        return;
      }
      await _open(index, handoff);
    } finally {
      _locating = false;
      _renderedWhileBusy = false;
      if (retry && !_disposed) await onRendered();
    }
  }

  bool _stillCurrent(
    AdvancedMiningHandoff handoff,
    int generation,
    AdvancedMiningRenderTarget<R, V> target,
  ) {
    if (!identical(_pending, handoff)) return false;
    if (_generation != generation || generation != _currentGeneration()) {
      return false;
    }
    final AdvancedMiningRenderTarget<R, V>? now = _renderedTarget();
    return now != null &&
        identical(now.result, target.result) &&
        identical(now.view, target.view);
  }
}
