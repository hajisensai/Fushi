## BUG-3704 · 评分后下一张卡「显示答案」空格失灵
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：评分后下一张卡出现时，按空格「显示答案」无反应。
- **真实性**：✅ 真 bug。根因：换卡时 `reclaimAfterFrame`（`srs_review_page.dart` 换卡处）只做 Flutter 内 `requestFocus`；系统键盘焦点仍留在已离屏的 WebView2（`custom_platform_view.dart` 平台视图抢焦点）。修复改为 `requestViewFocusChange` 把焦点拉回 FlutterView。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_feedback_test.dart`
- **备注**：根因为推断：未在真机抓焦点验证；以代码路径与行为测试为据。
  - 2026-10-23 Windows 真机实测（`fushi/integration_test/srs_review_os_focus_itest.dart`，`GetGUIThreadInfo.hwndFocus` 读 OS 焦点、`PostMessage` 向焦点窗真投空格）：卡面 / 释义 / 查词弹窗的 WebView2 都是 composition 宿主，指针经插件 `SendMouseInput` 转发，点进释义 WebView 后 **OS 焦点仍是 FLUTTERVIEW**（Flutter primary 落到平台视图的无标签节点）；评分换卡后 Flutter primary 回到 `srs-review`，真投递的空格能翻面。把 `requestViewFocusChange` 换成 no-op 同样通过——上面「OS 焦点留在 WebView2」的链在当前宿主下不成立，`requestViewFocusChange` 只是空操作的防护（窗口宿主模式 `--fushi-windowed-hosting` 只给网页视频用）。用户的「空格失灵」真实原因仍待定位；实测中观察到一个同样表现的设计行为：点在释义文字上会开查词弹窗，弹窗开着时空格 / 数字键按设计不翻面、不评分（`SrsCardLookupController.guardKey`），可作为下一步排查方向（未证实是用户场景）。
