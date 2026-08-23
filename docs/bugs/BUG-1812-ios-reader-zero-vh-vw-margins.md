## BUG-1812 · iOS阅读器WebView视口单位为零导致四边页边距失效
- **报告**：2026-08-24（iOS 全功能实机巡检）
- **真实性**：✅ 真 bug。iPhone SE / iOS 26.6 的真实分页 WebView 日志为
  `dartW=375 dartH=667 innerW=0 innerH=0`。修前
  `fushi/lib/src/reader/reader_content_styles.dart:84-89,249-300` 虽已让列盒基准读
  Dart 下发的 `--reader-viewport-height/--page-width`，四边用户边距却仍以裸
  `vh/vw` 参与 padding、column-width、clip 与遮罩边框；于是设置 1.3% 上边距后
  computed `paddingTop` 仍只有 20px chrome inset，1.3vh 实际贡献 0，分页 pitch 也
  从应有的小数退化为整数。左右 `vw` 同因归零。
- **[x] ① 已修复** — `ReaderEngineConfig` 随每次导航携带四边百分比；
  `reader_fushi/webview.part.dart` 的引擎 install 用 Dart 权威视口把百分比换成 px，发布
  `--reader-margin-{top,bottom,left,right}`。分页、连续、VN 三个 shell 的 resize 都重算；
  `ReaderContentStyles` 的 padding / 列宽 / clip / 覆盖边框统一消费这四个变量，原
  `vh/vw` 只留作引擎 install 前的跨平台兜底。随后把同一零视口根因在字级 caret
  （可见区原先也读 `window.inner*`）与查词 popup（容器实测 0×242）两处收口：caret
  改读 reader CSS 视口 + 负坐标 body frame；popup 在 `renderPopup` 前把 Flutter
  `LayoutBuilder` 宽度写入文档。修复提交：`9eaf2023d`、`9a1a35e72`。
- **[x] ② 已加自动化测试** —
  - `test/reader/reader_content_styles_test.dart`：分页/连续/VN 三态均必须消费四个变量，
    不得把裸 1.3vh 写进 padding；既有列宽、遮罩、字号坍塌测试同步守住新表达式。
  - `test/reader/reader_engine_static_source_guard_test.dart`：四个值进入 per-nav config，
    install 用 Dart 宽高换算，三个 resize 路径全部重算。
  - `test/reader/reader_caret_scripts_test.dart`、
    `test/pages/dictionary_popup_webview_test.dart`：caret 不能依赖零 `inner*`，popup 必须
    在推送词条前应用 Flutter 宽度。
  - `integration_test/reader_pagination_test.dart` + harness：iOS 真实负坐标/零 inner-size
    下按 reader CSS 变量与 body rect 计算可见正文盒；实机最终得到
    `paddingTop=28.671, left/right=7.5, pitch=638.328979`，141 页覆盖 420/420 markers，
    I1-I7、位置恢复 I9、快速 chrome 切换 I10 全绿。
  - `integration_test/reader_computer_use_flow_test.dart`：iOS 实机 20 前翻 + 5 后翻，
    Enter 进入 reader caret，`testword/猫` 交替查词 5 轮；popup 宽度稳定 338px、释义
    可见，每轮 Escape 回到原 caret，零陈旧结果，最终全绿。
- **备注**：未用延时/取整或删小数断言规避。`window.innerWidth/Height=0` 是该
  WKWebView 文档的稳定平台事实，唯一尺寸真相仍是 Flutter `MediaQuery` 下发值。
