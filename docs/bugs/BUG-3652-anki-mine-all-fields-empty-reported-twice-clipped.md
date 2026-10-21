## BUG-3652 · anki-mine-all-fields-empty-reported-twice-clipped
- **报告**：2026-10-21（用户：反馈 #AGLC0BuaKB「无法导入anki」，iOS 3.0.0-debug.20409 / AnkiMobile，韩语词制卡；所有者补截图：报错位置显示不对）
- **真实性**：✅ 真 bug，两层：
  - **空映射 → 每次制卡必失败、英文原文直给用户**：选了非 Lapis 笔记类型时映射被重置成 `LapisPreset.applyDefaults(noteType, {})`（`fushi/lib/src/anki/anki_view_model.dart:183`），它对非 Lapis 类型原样返回 `{}`（`packages/fushi_anki/lib/src/lapis_preset.dart:22`）；渲染后字段表为空，空卡门 `fushi/lib/src/anki/ankimobile_repository.dart:563` 拒收（AnkiConnect / AnkiDroid / 互联 Anki 同步同一道门）。这条失败**不带错误码**，`logMineFailure`（`fushi/lib/src/utils/misc/error_log_service.dart:562`）只能把后端英文原文 `All fields are empty — refusing to create a blank card…` 拼进 toast。用户日志里 10-20～10-21 连续十几次同一条。
  - **同一次失败报两遍、iOS 上被裁掉**：弹窗发起的制卡，宿主先 `FushiToast.show`（如 `reader_fushi/mining.part.dart:382`），弹窗再在 else 分支 `showInlineHint(mineButton, result.message || window.i18nMineFailed)`（`fushi/assets/popup/popup.js:4824`）；而 `MinePopupResult.toJson()` 从不带 `message`，弹窗永远只能说通用的「导出卡片失败。」（重复卡也这么说）。宿主那条 toast 在 iOS 固定画在底边上方 96pt（`fushi_toast.dart:177`），正落在底部停靠的查词弹窗上，截图里被弹窗下边缘裁掉半截（推测是 Flutter 浮层叠在两个 WKWebView 平台视图上的合成问题，无 iOS 真机未能实测确认机制）。
- **[x] ① 已修复** — 本分支 `worktree-fix-anki-mine-empty-fields`：
  - 新增 `AnkiErrorCode.allFieldsEmpty`，挂到全部 7 处空卡门（AnkiMobile / AnkiConnect 新制+覆写 / AnkiDroid 新制+覆写 / 互联 Anki 同步 / 内置复习覆写），`localizeAnkiMineError` 映射为 i18n `anki_error_all_fields_empty`（指明是字段映射没配、去 Anki 设置里配）。
  - `MinePopupResult.failed(outcome, message:)` 把本地化原因随回包带给 popup.js；弹窗发起制卡的 6 个表面（词典弹窗 mixin 新制 / 覆写、阅读器新制 / 覆写、漫画、PDF、texthooker、gal 浮窗回包）失败时**只在弹窗按钮旁说一次**，结果 toast 只在被收下（成功 / 进待发队列）时弹；「已制卡动作」对话框（`base_source_page` / mixin）失败时原样交回带原因的结果；网页视频全局查词窗口的回包改用 `toJson()` 一并带出。
  - popup.js `showInlineHint` 停留时长随字数延长（短提示仍 1.8s，封顶 6s），`.inline-hint` 允许换行、宽度不超出弹窗；扩展 vendor 副本与 `fushi/assets/browser_extension` 镜像已同步。
- **[x] ② 已加自动化测试** — `fushi/test/anki/mine_failure_reported_in_popup_test.dart`（AnkiMobile 非 Lapis + 空映射 → `allFieldsEmpty` 且不打开 Anki；本地化文案不含英文原文；`MinePopupResult` 序列化 `message`；6 个表面失败回包带原因且结果 toast 只在成功分支；已制卡动作交回原结果）+ `fushi/test/utils/misc/popup_asset_behavior_test.js` `testLongMineFailureReasonStaysLongEnoughToRead`。变异实测：去掉 AnkiMobile 的 errorCode、把 texthooker 的 toast 挪出成功分支 → 新测试 2 条红；把停留时长写死 1800ms → JS 测试红。
- **备注**：
  - 未覆盖：视频页（失败走播放器居中 OSD，弹窗仍显示通用文案）与串流页（自己的状态行）不在本次改动内。
  - 没做：非 Lapis 笔记类型按字段名自动猜映射（内置复习已有 `srsGuessFieldMapping`，Anki 这条路没有）；默认制卡目标——2026-10-16 所有者拍板「新装默认 Fushi 复习、老用户继续发 Anki」，本反馈用户日志始于 09-03，被判为老用户留在 Anki；Anki 路径没有 Fushi Card 选项，AnkiMobile 也建不了笔记类型（`ankimobile_repository.dart:815`）。两项都待所有者决定。
  - iOS 真机未复测（本机无 iOS 设备）；裁切机制只是推测，本修法不依赖它——失败不再画 Flutter toast。

### 续：回包回来时弹窗已不在 → 失败零提示（#2438 审查遗留，2026-10-21）

- **真实性**：✅ 真问题。#2438 后失败只交给弹窗就地说（`showInlineHint`），宿主不再 toast；但制卡是异步的（阅读器经制卡串行队列、AnkiConnect 慢），回包到达时弹窗可能已被关掉 / 被导航销毁 / 收回热槽停驻 / 同一层换了词。此时回包要么送进已卸载的 WebView（`dictionary_popup_webview.dart` 的 `mineEntry` 桥直接 `return result.toJson()`，无人接收），要么送进停驻在屏外的热槽、或锚到已被 `renderPopup` 的 `container.innerHTML = ''` 摘掉的按钮上（`popup.js` 失败分支无条件 `showInlineHint`）——用户什么都看不到，比 #2438 之前（至少有 toast）更糟。
- **各表面「弹窗还在不在」的判据**（统一收口在 `fushi/lib/src/anki/mine_failure_notice.dart` 的 `MineFailureNotice.settle`）：
  - app 内 WebView 弹窗（词典弹窗 mixin 新制 / 覆写 / 已制卡动作、阅读器、漫画、PDF、texthooker，全走 `DictionaryPopupWebView` 的三根桥 → `_runMineBridge`）：发起前 `_captureMineOrigin()` 记下文档代次与原生 controller；回包时 `mounted` + 同一文档 + `isSessionOnScreen()`，后者由三个宿主（`base_source_page` / `dictionary_page_mixin` / `popup_dictionary_page`）绑到 `DictionaryPopupController.isEntryOnScreen(entry)`（仍在栈内且未停驻；读模型不读已建好的 widget 树，关窗后重建帧未跑时也判得准；对话框把弹窗挪到屏外不算不在）。
  - app 外覆盖窗（桌面查词 / gal 卡片 / 网页视频全局查词，`overlay_bridge_handlers.dart` 的 `_handleMineBridge` / `_handleUpdateBridge`）：`global_lookup_controller.dart` 派发时捕获本条消息所在的查词 route，回包时 `origin == _activeRoute && isRouteValid(origin)`（真正关窗 `_onOverlayHidden` 与下一次查词 `_activateRoute` 都会作废它）。
  - 「弹窗还在、但已不是发起的那一次」（同一层换词 / 原地跳转 / 热槽复用）：宿主看不到 DOM，由 popup.js `reportMineFailure` 按发起按钮 `isConnected` 判；按钮已被摘掉就不画，回 `mineFailureUnseen` 桥，宿主 `MineFailureNotice.reportUnseen` toast 一次（app 内 WebView 与覆盖窗共享桥各接一处）。
  - 宿主判定弹窗已不在时 toast 一次，并把回包改成去掉 `message`、带 `hostReported: true`：那份文档若还活着（停驻热槽），popup.js 也不会再说第二遍。
- **[x] ① 已修复** — 分支 `fix/mine-failure-toast-when-popup-gone`。
- **[x] ② 已加自动化测试** — `fushi/test/anki/mine_failure_exactly_once_test.dart`（`MineFailureNotice` 单元；app 内真宿主形态 widget 测试：弹窗在 → 回包带原因且零 toast / 回包前关窗（WebView 卸载）→ toast 1 / 回包前收回热槽（WebView 仍挂载）→ toast 1 且回包 hostReported；覆盖窗真 handler：route 有效 → 原因回卡片零 toast / route 作废 → toast 1（制卡与覆写）/ `mineFailureUnseen` → toast 1；三宿主与控制器接线源码守卫）；`fushi/test/utils/misc/popup_asset_behavior_test.js` 三条（按钮在 → 就地说且不回执 / 按钮被换掉 → 不画、回执恰好一次且带 duplicate / hostReported → 闭嘴）；`fushi/test/pages/popup_mine_failure_hint_test.dart` 源码层守卫跟进到 `reportMineFailure`。toast 一律经可注入的 `MineFailureNotice.debugToastSink` 计数（widget 测试里 FushiToast 永不进树）。
- **备注**：
  - gal 场景的挖卡委托（`gal_hook_text_overlay_controller.dart` `_mineFromLookup`）在失败时本来就自己 `FushiToast.showMine` 一次（BUG-1734/1908 既有设计，gal 代码改动须走 galgame SOP，未在本次改动）；卡已关时 `settle` 再 toast 的是同一句、`showMine` 的自绘 overlay 会顶替上一条，视觉上仍是一条。卡还在时「gal toast + 卡内提示」的双报是 gal 侧旧行为，未在本次处理。
  - 覆盖窗嵌套子卡被复用（`popup_bridge_adapter.js` `__fushiBridgeCancelPending` 先以 null 结掉在途请求）时，真回包到达已无人等待、route 仍有效，这一次失败仍会丢失——与 #2438 之前相同（该路径从来没有 toast），需要 adapter 回报「回包无人接收」才能补，未在本次处理。
  - 宿主异常路径（桥 catch 回 `const MinePopupResult()`，无原因）仍只由弹窗说通用「导出卡片失败」；弹窗已不在时与 #2438 前一样无提示（那条路宿主本来就在 toast 之前抛出）。
  - 判据完全基于生命周期 / 会话身份，没有延迟、计时器或重试。真机未复测。
