## BUG-1908 · gal 浮窗制卡失败完全没有提示：回程只传布尔，失败分支没有 else
- **报告**：2026-08-28（用户：「gal制卡报错没有明显提示」）
- **真实性**：✅ 真 bug（静默失败）。

### 根因（三层叠加）

**① 回程通道传不出原因。**
`GalHookMiningCoordinator.GalHookMiningResult.toPopupReply()` 与
`overlay_bridge_handlers` 的两条 reply 都只有两个字段：

```dart
Map<String, Object?> toPopupReply() => <String, Object?>{
      'ankiConnect': success,
      'noteId': success ? outcome?.noteId : null,
    };
```

宿主那边其实**已经算出了**可读的失败原因（`describeMineOutcome`、
「窗口截图失败」、「音频回退被禁用」），只是没地方放。

**② 浮窗侧整段没有 else。**
`popup.js` 的制卡按钮里只有 `if (result.ankiConnect) { … }`。
`ankiConnect:false` 是**正常 resolve、不抛**，既不进 `catch` 也不进 `if` ——
零反馈。（`console.error` 在裸 WebView2 里也没有可见控制台。）

**③ Flutter toast 在这个场景下救不了场。**
galgame 浮窗是**独立的 native WebView2 窗口**；`FushiToast` 画在**主 app 窗口**的
Flutter Overlay 上（`fushi_toast.dart` 拿不到 overlay 时直接 `return`）。
游戏全屏在前台时主窗在后台，那些 toast 用户一个也看不见。
`overlay_bridge_handlers` 的两处 `catch` 更是只 `glog` 写磁盘文件，用户零感知。

浮窗内**本来就有**为这个场景建的页内车道：`showInlineHint`（BUG-1064，注释原文
「app 外没有 Flutter toast 可用……这类结果必须就地说清楚，绝不静默」），
只是制卡链路从没接上。

### 修复与测试

- **[x] ① 已修复**（三条回程 + JS 侧一并接通）：
  - `toPopupReply({String? message})`：失败时带上**已本地化**的原因；成功不带
    （浮窗靠 ➕→✓ 翻转表达成功）。
  - `gal_hook_text_overlay_controller`：abort 分支与正常失败分支把**给 toast 用的
    同一句话**同时回给浮窗。
  - `overlay_bridge_handlers`：非 gal 的裸浮窗（`_mineEntry` / `_updateEntry`）同样
    带原因；两处 `catch` 至少回 `card_export_failed`（诊断细节仍只进 `glog`，
    不把 `e.toString()` 塞给用户）。
  - `popup.js`：`parseMineResult` 解析 `reply.message`；失败分支调用
    `showInlineHint` 就地提示并把按钮恢复成可点。兜底文案由宿主按 locale 注入
    （`window.i18nMineFailed`），不硬编码语言进 JS。三镜像已同步。
  - **不需要动 native**：`resolveBridge` 本来就是 `jsonEncode` 任意值的通用通道，
    多一个字段是免费的。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_mine_failure_hint_test.dart`：
  JS 侧解析 message + 失败分支紧邻 `showInlineHint`（锚点用失败分支自身的注释——
  `BUG-1908` 在文件里出现多次，拿第一处当锚会量到文件另一头）；Dart 三条回程都能带
  message；三镜像字节一致。
  **变异实测**（2026-08-28）：删掉失败分支的 `showInlineHint` 调用 → 转红。
  还原后 lookup + mining + 浮窗 parity 共 **1823 项**全绿。

### 备注

- 本条只改**反馈**，不改制卡本身的成败判据。用户这一批里另一条
  [BUG-1900]（AnkiConnect 字段映射不匹配被报成 `cannot create note because it is
  empty`）修的是**为什么会失败**；两条合起来才是「失败了、而且说得清为什么」。
- galgame 平台边界：本改动全在 Dart + JS 资产，**未触碰** `native/galgame_hook/`、
  未改 IPC 契约、未改 `engine-support.yaml`，因此不涉及任何引擎支持状态的声明。
- 未做真机复测（需要真实 galgame 全屏 + 故意构造制卡失败）。源码/结构层已覆盖。
