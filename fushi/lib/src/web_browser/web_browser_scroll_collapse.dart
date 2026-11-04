/// 滚动收起的累积阈值（逻辑像素，v3 原型同值）：同方向累计滚过它才翻转状态，
/// 单次抖动不翻。
///
/// 放在 `web_browser` 层：页内滚动上报脚本（`web_browser_page_scripts.dart`）
/// 与 pages 层的收起状态机（`WebBrowserCollapseState`）共用同一个值，脚本只在
/// 状态机可能翻转时上报，两边必须一致；依赖方向是 pages → web_browser。
const double kWebBrowserCollapseScrollThreshold = 24;
