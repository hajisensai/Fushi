## BUG-3293 · 查词加载指示器在结果出来后仍压着结果转
- **报告**：2026-10-10（反馈 #7NmMDZKs2f，Android：「每次点击查词之后会有个小齿轮转一下再出来，没有之前顺滑」）
- **真实性**：✅ 真 bug（按代码判定，未真机录屏）。热槽 WebView 复用正常、不是每次重建（`base_source_page.dart` 的 reuse 路径 + `dictionary_popup_controller.dart` 原地复用同一 GlobalKey）。「齿轮」是 10-05 换上的 M3E 变形加载指示器：`base_source_page.dart` 的 `buildDictionaryLoading()` 用 `FushiDeferredLoading(active: _isSearchingNotifier)` 盖在顶层弹窗上，**不铺底色**；`_showPopupWaitingForRender` 把在途标记一直保持到 WebView 回报 `popupRendered`。`fushi/lib/src/utils/components/fushi_deferred_loading.dart` 的 `_end()` 对一切层都补足 300ms 最短停留再 150ms 淡出——这条只对铺了底色、顶替内容的层成立；浮在已渲染结果上的 overlay 因此在结果出来后还压着结果多转约 0.3–0.45s。
- **[x] ① 已修复** — `FushiDeferredLoading` 不铺底色（`background == null`）时，`active` 变 false 立即淡出、取消最短停留计时；铺底色的层（结果区盖板、首页词典）行为不变。提交 `cde1987e24`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_deferred_loading_test.dart`「不铺底色：结束即淡出，不补最短停留」。
- **备注**：150ms 露出门槛未动：Android 上查询 + 渲染超过 150ms 时指示器仍会短暂淡入。是否把阅读器热槽路径整个换回细进度条或提高门槛属于设计取舍，未在本批改。
