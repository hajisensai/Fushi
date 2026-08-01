## BUG-1230 · 漫画查词弹窗未按 OCR 文字方向避让
- **报告**：2026-07-29（用户：漫画竖排弹窗应在气泡左右，横排应在文字上下）
- **真实性**：✅ 真 bug。覆盖层原本只在字符 span 上携带 OCR 方向，但
  `hibiki/lib/src/reader/reader_selection_scripts.dart:1082` 构造 payload 时丢弃
  该信息，`hibiki/lib/src/reader/reader_selection_data.dart` 也无方向字段；
  漫画页继承 `BaseSourcePageState.popupVerticalWriting == false`，因此混排页面
  的所有根弹窗都按横排上下布局。此外旧 payload 的 rect 只有点中字形大小，
  即使打开竖排模式也可能压住同一气泡的其他列。
- **[x] ① 已修复** — `0599fa97b`：overlay 为每个命中写入横/竖方向和句组
  ID；WebView 将整组 block 的视口并集作为弹窗锚点并传递
  `verticalWriting`。漫画页逐次命中更新根弹窗方向：竖排走气泡组左右侧，
  横排保持文字组正上/正下。
- **[x] ② 已加自动化测试** — `0599fa97b`：
  `hibiki/test/media/manga/manga_overlay_html_test.dart:264` 守卫整组 rect 与方向
  payload；`hibiki/test/pages/manga_selection_dispatch_test.dart:110` 守卫方向
  传到根弹窗；`hibiki/test/pages/dictionary_popup_layer_test.dart` 的既有行为测试
  验证竖排左右不重叠、横排上下不重叠及窄屏回退。
- **备注**：相关 81 项 Flutter 测试全部通过，Windows debug 构建成功。
  修复版实机在用户原页点击 `大丈夫`，弹窗左边缘贴住完整竖排句组的右边缘；
  在封面横排 `第1189話` 上点击，弹窗顶边位于整行文字下方。两条原始布局路径均
  肉眼通过。
