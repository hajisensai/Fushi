import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';

/// 「搜索期盖板」必须随关栈自动落幕。
///
/// 用户报的现象：在播放控件隐藏的前后几百毫秒里点查词界面，查词界面就卡住 ——
/// 再点关不掉、Esc 关不掉，而且播放控件从此再也唤不回来。
///
/// 根因不在视频页，也不在焦点：那几百毫秒正是「结果已到、WebView 还没回
/// popupRendered」的挂起窗口（而且这个窗口就是控件淡出的窗口 —— 全屏 opaque 的
/// LookupDismissBarrier 一挂上，真实鼠标就命中不到 media_kit 自己的 MouseRegion，
/// 触发 onExit → 控件开始淡出）。在这个窗口里关栈，走的是
/// [DictionaryPopupController.dismissAt] —— 而旧实现里盖板是一个独立的
/// `bool _searchingUi` 镜像，只有宿主 mixin 的成功路径会复位它，dismissAt /
/// truncateTo / pruneToWarmSlot / clear 四条关栈路径一条都不复位。镜像于是永久
/// 卡在 true：barrier 撤不掉（再点只是重走一遍 no-op 的 dismissAt），
/// `_lookupOverlayActive` 恒真、`_pokeControlsVisible()` 永久早退。
///
/// 现在 [DictionaryPopupController.isSearchingUi] 是派生值 ——「目标 entry 仍在栈内
/// 且仍 isSearching / revealOnRender」。下面每条用例都直接钉这个不变式：任何一条
/// 关栈路径走完，盖板与 barrier 都必须落幕。
void main() {
  const Rect kRect = Rect.fromLTWH(10, 10, 4, 4);

  /// 把 controller 推进「结果已到、等 popupRendered」的挂起态 —— 也就是用户点下去
  /// 卡住的那个窗口。返回挂起中的目标。
  DictionaryPopupEntry enterPendingReveal(DictionaryPopupController popup) {
    final DictionaryPopupEntry target = popup.beginTop(
      term: 'テスト',
      rect: kRect,
      reuseWarmSlot: true,
      replaceStack: true,
      visible: false,
    );
    popup.beginSearchUi(kRect, target);
    // 结果内容与本不变式无关，用与生产同一个 canonical 空结果单例即可。
    popup.fillResult(
      target,
      result: kPopupSearchingPlaceholderResult,
      allLoaded: true,
    );
    popup.markPendingReveal(target, onForcedReveal: () {});
    return target;
  }

  bool barrierUp(DictionaryPopupController popup) =>
      shouldShowLookupDismissBarrier(
        hasVisiblePopup: popup.hasVisiblePopup,
        isSearching: popup.isSearchingUi,
        hiddenByDialog: false,
      );

  test('前置：挂起态本身必须亮着盖板（否则下面的用例什么都证明不了）', () {
    final DictionaryPopupController popup = DictionaryPopupController(
      lowMemory: false,
    );
    addTearDown(popup.dispose);
    enterPendingReveal(popup);

    expect(
      popup.isSearchingUi,
      isTrue,
      reason: '结果已到但还在等 popupRendered：盖板必须还亮着',
    );
    expect(popup.pendingRect, kRect);
    expect(barrierUp(popup), isTrue);
  });

  test('挂起期 dismissAt(0) → 盖板落幕（用户报的卡死路径）', () {
    final DictionaryPopupController popup = DictionaryPopupController(
      lowMemory: false,
    )..seedWarmSlot();
    addTearDown(popup.dispose);
    enterPendingReveal(popup);

    popup.dismissAt(0);

    expect(
      popup.isSearchingUi,
      isFalse,
      reason: '关栈后盖板还亮着 = barrier 永久挂住 = 再点也关不掉',
    );
    expect(popup.pendingRect, isNull);
    expect(barrierUp(popup), isFalse);
  });

  test('挂起期 truncateTo(0) → 盖板落幕', () {
    final DictionaryPopupController popup = DictionaryPopupController(
      lowMemory: false,
    );
    addTearDown(popup.dispose);
    enterPendingReveal(popup);

    popup.truncateTo(0);

    expect(popup.isSearchingUi, isFalse);
    expect(popup.pendingRect, isNull);
    expect(barrierUp(popup), isFalse);
  });

  test('挂起期 pruneToWarmSlot() → 盖板落幕', () {
    final DictionaryPopupController popup = DictionaryPopupController(
      lowMemory: false,
    )..seedWarmSlot();
    addTearDown(popup.dispose);
    enterPendingReveal(popup);

    popup.pruneToWarmSlot();

    expect(popup.isSearchingUi, isFalse);
    expect(popup.pendingRect, isNull);
    expect(barrierUp(popup), isFalse);
  });

  test('挂起期 clear() → 盖板落幕', () {
    final DictionaryPopupController popup = DictionaryPopupController(
      lowMemory: false,
    );
    addTearDown(popup.dispose);
    enterPendingReveal(popup);

    popup.clear();

    expect(popup.isSearchingUi, isFalse);
    expect(popup.pendingRect, isNull);
    expect(barrierUp(popup), isFalse);
  });

  test('正常路径不受影响：revealRendered 翻可见后盖板落幕、弹窗仍在', () {
    final DictionaryPopupController popup = DictionaryPopupController(
      lowMemory: false,
    );
    addTearDown(popup.dispose);
    final DictionaryPopupEntry target = enterPendingReveal(popup);

    expect(popup.revealRendered(target), isTrue);

    expect(popup.isSearchingUi, isFalse, reason: '已经翻可见，不该再盖着加载卡');
    expect(popup.hasVisiblePopup, isTrue, reason: '弹窗本身必须留着');
    expect(barrierUp(popup), isTrue, reason: '弹窗可见时 barrier 照常挂着');
  });
}
