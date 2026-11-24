/// 制卡重放宿主页（`WebVideoFushiPage`）的全屏态，两个来源分开记（BUG-5414 备注）：
///
/// * [window]：Fushi 自己切的窗口全屏（F 键 / 全屏钮 / F11 → runner 保边框全屏），只由本页的
///   切换执行体改，进 / 退时由它命令式收起 / 亮出桌面自绘顶栏；
/// * [site]：页面上报的 `document.fullscreenElement`（站点自己的全屏钮 / 双击画面），只随
///   每拍站点快照改。
///
/// 原来两者共用一个布尔、每拍快照直接覆盖：Fushi 全屏键进窗口全屏后 250 ms 内被快照
/// （`fs=false`）改回「没全屏」，顶栏回来、Esc 退不出 runner 全屏；站点自己进全屏只藏了 app bar、
/// 没收桌面顶栏（窗口按钮组浮在全屏画面上）。分开记之后，两种来源各自只动自己那一位，
/// [chromeHidden] 决定页面 chrome，[site] 由声明式 scope 收起桌面顶栏。
class WebVideoHostFullscreen {
  bool _window = false;
  bool _site = false;

  /// Fushi 自己切的窗口全屏（runner 持有）。
  bool get window => _window;

  /// 站点页面自己的 DOM 全屏。
  bool get site => _site;

  /// 页面 chrome（顶栏 / 工具条）该不该收起：任一来源在全屏。
  bool get chromeHidden => _window || _site;

  /// 切窗口全屏；返回切换后的目标态（true = 进）。
  bool toggleWindow() => _window = !_window;

  /// 页面快照上报的站点全屏；返回 [chromeHidden] 或 [site] 是否变了（要不要重建）。
  /// 不碰 [window]：快照只知道 DOM 全屏，不知道 runner 的窗口全屏。
  bool reportSite(bool fullscreen) {
    if (fullscreen == _site) return false;
    _site = fullscreen;
    return true;
  }
}
