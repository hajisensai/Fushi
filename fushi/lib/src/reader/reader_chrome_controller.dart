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

  /// 顶栏与底栏被关掉（偏好 `hide_toolbars` 且应用内悬浮球开着，判据
  /// `readerToolbarsHidden`，页面同步进来）：开着时顶栏与底栏（含悬浮态的临时
  /// 唤出）一律不画，任何唤出 / 切换手势都打不开它们——入口改由悬浮球接管。
  ///
  /// 它**不改** [showChrome]：那是用户对挤压态底栏的持久意图，同时是 JS 点词
  /// 门控的镜像（chrome 收起时点正文 = 唤出 chrome 而非查词）。栏关掉时要的是
  /// 「栏不在、点词照常」，所以页面的布局判据读 `showChrome && !toolbarsHidden`，
  /// 点词门控仍读原值；开回来后栏回到关掉前的状态。
  bool _toolbarsHidden = false;
  bool get toolbarsHidden => _toolbarsHidden;
  set toolbarsHidden(bool value) {
    if (_toolbarsHidden == value) return;
    _toolbarsHidden = value;
    if (value) {
      // 关掉时把已唤出的悬浮栏一并收掉，并停掉 VN 推进武装的收起计时。
      cancelAutoHide();
      _transientVisible = false;
    }
    notifyListeners();
  }

  /// 悬浮 chrome 被点击唤出后的临时可见态；计时到 / 再点一下收起。
  ///
  /// 栏被关掉时只能收、不能唤出（置 true 被忽略）。
  bool _transientVisible = false;
  bool get transientVisible => _transientVisible;
  set transientVisible(bool value) {
    if (_transientVisible == value) return;
    if (value && _toolbarsHidden) return;
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

  /// 设置侧板上次打开的分页 id（会话内记忆）。
  /// 空串 = 本次会话还没切过页：书籍模式落「主题与字体」、歌词模式落「歌词模式」
  /// （readerSettingsInitialTab）。
  String lastSettingsTab = '';

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

  /// 唤出悬浮 chrome 而**不**武装自动收起：点出来就留着，只有下一次点击能关掉它
  /// （用户 2026-09-14 定的悬浮控制栏口径）。已在计时的收起一并停掉，否则上一轮
  /// 武装的计时会把这次刚点出来的栏收走。
  void showTransient() {
    cancelAutoHide();
    if (_transientVisible || _toolbarsHidden) return;
    _transientVisible = true;
    notifyListeners();
  }

  /// 唤出悬浮 chrome 并（重新）武装自动收起。
  ///
  /// 只剩「点空白已被别的动作占死、收起没有第二条手势通道」的场景还该用它
  /// （EPUB 的 VN 翻页）；常规显隐一律用 [showTransient] + [hideTransient]。
  void reveal(Duration autoHideAfter) {
    if (_toolbarsHidden) return;
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
