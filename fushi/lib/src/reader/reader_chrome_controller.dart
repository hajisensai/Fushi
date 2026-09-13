/// 阅读器 chrome（顶部工具栏 / 底栏 / 顶部进度 pill）显隐状态的唯一持有者。
///
/// 页面 `_ReaderFushiPageState` 只保留同名转发 getter/setter（`_showChrome` /
/// `_chromeTransientVisible` / `_appearanceSheetOpen`），状态与自动收起计时器都在
/// 这里；控制器变更经 [ChangeNotifier] 通知页面重建。把这台状态机从 4000 行页面里
/// 拆出来，UI 迭代不再需要在页面 State 上穿针，且可脱离页面单测。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

class ReaderChromeController extends ChangeNotifier {
  /// 挤压态下「底栏功能是否启用」的持久开关（TODO-975：悬浮态下它是不可见旗）。
  bool _showChrome = true;
  bool get showChrome => _showChrome;
  set showChrome(bool value) {
    if (_showChrome == value) return;
    _showChrome = value;
    notifyListeners();
  }

  /// 悬浮 chrome 被点击唤出后的临时可见态；计时到 / 再点一下收起。
  bool _transientVisible = false;
  bool get transientVisible => _transientVisible;
  set transientVisible(bool value) {
    if (_transientVisible == value) return;
    _transientVisible = value;
    notifyListeners();
  }

  /// 书内设置面板（抽屉 / 对话框 / sheet）是否开着——重入守卫 + 顶部进度 pill 停
  /// 模糊（BUG-969）的判据。
  bool _appearanceSheetOpen = false;
  bool get appearanceSheetOpen => _appearanceSheetOpen;
  set appearanceSheetOpen(bool value) {
    if (_appearanceSheetOpen == value) return;
    _appearanceSheetOpen = value;
    notifyListeners();
  }

  /// 右侧设置抽屉上次打开的分组 id（会话内记忆；默认布局显示）。
  String lastSettingsTab = 'layout';

  /// 导航抽屉目录里手动展开的父节（按 label；会话内记忆）。
  final Set<String> expandedTocParents = <String>{};

  Timer? _autoHideTimer;

  /// 自动收起计时器（只读；页面 dispose 路径按旧守卫字面量 `cancel()` 它）。
  Timer? get autoHideTimer => _autoHideTimer;

  bool get autoHideArmed => _autoHideTimer != null;

  /// 武装自动收起：到时把临时可见态收起并通知。重复武装 = 重新计时。
  void armAutoHide(Duration after) {
    cancelAutoHide();
    _autoHideTimer = Timer(after, () {
      _autoHideTimer = null;
      if (!_transientVisible) return;
      _transientVisible = false;
      notifyListeners();
    });
  }

  void cancelAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
  }

  /// 唤出悬浮 chrome 并（重新）武装自动收起。
  void reveal(Duration autoHideAfter) {
    _transientVisible = true;
    notifyListeners();
    armAutoHide(autoHideAfter);
  }

  /// 立即收起临时可见态（并取消计时）。
  void hideTransient() {
    cancelAutoHide();
    if (!_transientVisible) return;
    _transientVisible = false;
    notifyListeners();
  }

  @override
  void dispose() {
    cancelAutoHide();
    super.dispose();
  }
}
