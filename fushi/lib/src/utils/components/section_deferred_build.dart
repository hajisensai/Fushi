/// 保活分区里的页面：藏着时不重建，切回可见时有欠账才补一次。
///
/// 保活 tab 用 `Offstage` 藏着，但它的页面 State 仍然订阅着全局状态：
/// `ref.watch` 的 provider 一变、`AppModel` 一通知、主题 / 窗口尺寸一变，藏着的
/// 页面照样整页 `build`——首页切回时失效书列表 provider，藏着的书架与漫画书架
/// 各跟着重建四次，用户看到的是「回首页卡一下」（BUG-4848）。外壳的
/// `_hiddenTabContent` 只挡得住自上而下的 widget 更新，挡不住页面自己被标脏。
///
/// 这里在页面自己的 Element 上截住：分区藏着时 `build` 原样交回上一次的产物
/// （子树因 widget 同一而整棵跳过），并记下「欠一次构建」；分区重新可见时欠着
/// 才真构建，没欠就继续交回旧产物——只因可见性翻转被叫起来不算构建理由。
///
/// 订阅全程不断：Riverpod 的依赖登记发生在真构建里，藏着时不进真构建，上一轮
/// 的 `ref.watch` / `ref.listen` 原样留着，`ref.listen` 的回调照常触发。
/// `State.didChangeDependencies` 也照常被调用。
///
/// 用了它的页面要守一条：**State 的 `build` 产物不能直接依赖
/// [SectionVisibility]**（可见性翻转不触发它重建）。要按可见性换内容的地方放进
/// 子 widget（[SectionPopScope]、`Builder`）里读。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';

/// 混进页面的 widget 类；见库注释。不在任何分区里（独立路由、组件测试）时
/// 行为与普通 [ConsumerStatefulWidget] 完全相同。
mixin SectionDeferredBuild on ConsumerStatefulWidget {
  @override
  ConsumerStatefulElement createElement() => _SectionDeferredBuildElement(this);
}

class _SectionDeferredBuildElement extends ConsumerStatefulElement {
  _SectionDeferredBuildElement(super.widget);

  /// 上一次真构建的产物。
  Widget? _built;

  /// 最近一次得知的分区可见性。
  bool _visible = true;

  /// 有没有还没兑现的构建请求（`setState`、provider 通知、可见性以外的依赖
  /// 变化、父级换了 widget）。
  bool _owed = true;

  /// 正在处理的这次依赖变化通知是不是可见性翻转本身。
  bool _absorbingFlip = false;

  @override
  void markNeedsBuild() {
    if (!_absorbingFlip) _owed = true;
    super.markNeedsBuild();
  }

  @override
  void didChangeDependencies() {
    // 依赖变化按「哪个祖先变了」逐个通知。通知到达时可见性与上次得知的不同，
    // 这一次就是可见性翻转：照常走框架流程（State.didChangeDependencies 仍会
    // 被调用、本 Element 仍进脏表），只是不记成构建欠账。
    final bool visible = SectionVisibility.peek(this);
    if (visible == _visible) {
      super.didChangeDependencies();
      return;
    }
    _visible = visible;
    _absorbingFlip = true;
    try {
      super.didChangeDependencies();
    } finally {
      _absorbingFlip = false;
    }
  }

  @override
  void update(StatefulWidget newWidget) {
    // 父级换了 widget 走的是强制重建，不经 markNeedsBuild。
    _owed = true;
    super.update(newWidget);
  }

  @override
  Widget build() {
    _visible = SectionVisibility.of(this);
    final Widget? built = _built;
    if (built != null && (!_visible || !_owed)) return built;
    final Widget next = super.build();
    _owed = false;
    return _built = next;
  }
}
