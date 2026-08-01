## BUG-1327 · 视频页制卡上下文对话框被查词浮层 barrier 吃掉点击

- **报告**：2026-08-01（用户：视频里点「上下句」调整后点制卡没反应，而且制卡把查词弹窗关了）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:3981`（修复前的 `if (_hasVisiblePopup || _popup.isSearchingUi)`）。

  视频页 / 首页词典页 / texthooker 把整棵查词浮层子树挂在**根 Overlay**
  （`Overlay.of(context, rootOverlay: true).insert(...)`，`video_hibiki_page.dart:3938`、
  `home_dictionary_page.dart:887`、`texthooker_page.dart:1709`；动机是盖过 media_kit 全屏路由）。
  根 Overlay 里手动 `insert` 的 entry 排在 `showAppDialog` 推的路由**之上**（Navigator 推
  route 时是 `insertAll(above: 上一个 route 的最后一个 entry)`，够不到手动 entry）。浮层子树
  里那层整屏 dismiss barrier 是 `Positioned.fill` + `HitTestBehavior.translucent`，于是把落在
  对话框上的点击整个吃掉：
  - 点「确认制卡」→ 按钮收不到点击 = 用户看到的「没反应」；
  - 同一下被 `_onDismissBarrierTap` 判成「点浮层外面」→ `_popNestedPopupAt(0)` 清整栈
    = 用户看到的「制卡把我查词弹窗关了」。

  BUG-797 当初只把弹窗 WebView 停到屏外（`parkedPopupLayer` 的 `visible` 接了
  `_popupHidingDialogDepth`），解决了「对话框看得见」，**命中测试这一半漏了**：barrier 的
  渲染条件从来没接这个门控。影响面是三个根 Overlay 表面上所有 `runWithLookupPopupHidden`
  的对话框——句子上下文对话框、点 ✓ 的已制卡操作单（BUG-1040）、「在 Anki 中打开」的多卡
  选择框。阅读器/有声书车道不受影响（浮层画在页面 `Stack` 里，对话框路由在其之上）。

- **[x] ① 已修复** — `DictionaryPageMixin` 暴露 `lookupPopupHiddenByDialog`
  （`dictionary_page_mixin.dart`），barrier 判据收口成纯函数
  `shouldShowLookupDismissBarrier`（`dictionary_popup_layer.dart`），视频页 / 首页词典页 /
  texthooker 三处 barrier 改用它 → 对话框期间浮层既不显示也不拦点击。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/lookup_dismiss_barrier_dialog_test.dart`：
  最小 harness 复现根 Overlay 与对话框的真实层序（barrier 挂着时点按钮落到 barrier、
  confirm 不触发；撤掉 barrier 后 confirm 触发且 barrier 不吃点击）+ 判据真值表 + 三宿主页
  源码守卫（含「裸条件复发即红」的负向断言）。
- **备注**：与 BUG-1326（同一操作路径上的第二个缺陷：`openSentenceContextModal` 参数被
  `JSON.stringify`，entryIndex 恒 0）同 PR 修复。
