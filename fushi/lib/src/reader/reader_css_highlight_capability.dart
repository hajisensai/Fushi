/// 阅读器「能否用 CSS Custom Highlight API（`CSS.highlights` + `::highlight()`）画高亮」
/// 的唯一判据（JS 表达式）。
///
/// 选区 / 查词（`ReaderSelectionScripts`）、收藏（`HighlightBridge`）、分页与连续
/// shell 都在运行时把它赋给 `window.__fushiCssHighlightsSupported`，四处必须同一口径
/// （那几份脚本源码会被 node 行为测试按文本切出来直接跑，不能写 Dart 插值，所以各放
/// 逐字副本；与本常量逐字相等由 `reader_css_highlight_capability_bug3328_test.dart`
/// 钉住，改判据先改这里）
/// ——过去各写一份 `!!(window.CSS && CSS.highlights && window.Highlight)`，只问「API 在
/// 不在」。
///
/// BUG-3343：**Blink 105–119 的 `::highlight()` 在竖排里画错位置**。API 在
/// （Chromium 105 起），但竖排文字的高亮矩形没按书写方向旋转：被当成横排「两个字宽 ×
/// 一行高」的横条、画在以行盒起点为原点转置后的位置——标题里的字高亮跑到左上方的邻列，
/// 正文里的字高亮常落到别的列甚至视口外（看不见）。本机 Chrome for Testing 逐版实测：
/// 113 / 119 错位，120 / 121 / 125 / 154 正确（同一探针页、同一 Range）。用户机（
/// 鸿蒙 4.2 / Android 12 的系统 WebView）的症状与这个区间逐一吻合（日志不带 UA，版本未直接确认）。
///
/// 这类内核上退回「API 不可用」的既有兜底：查词选区用 `.fushi-dict-highlight` 包裹
/// span、收藏用 class span——元素背景随文字排版，横竖排都画在字上。代价只有一个：旧
/// 内核上的搜索命中不画 `::highlight(fushi-search)` 标记（跳转照常）。WebKit（iOS /
/// macOS / WPE）的 UA 不带 `Chrome/`，不受影响。
const String kReaderCssHighlightsSupportedJs =
    '(!!(window.CSS && CSS.highlights && window.Highlight) && '
    '!(function(){var ua=typeof navigator!=="undefined"&&navigator.userAgent||"";'
    'var m=/Chrome\\/(\\d+)\\./.exec(ua);'
    'return !!m && +m[1] < $kBlinkVerticalHighlightFixedMajor;})())';

/// 修好竖排 `::highlight()` 绘制的第一个 Chromium 大版本（实测，见上）。
const int kBlinkVerticalHighlightFixedMajor = 120;
