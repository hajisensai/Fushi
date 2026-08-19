## BUG-1734 · 游戏内卡片制卡拿不到台词行时静默失败，无任何提示
- **报告**：2026-08-19（用户：真机验证游戏内查词制卡时发现）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart:736-739`
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：见下

### 复现（真机，2026-08-19）

《天使☆嚣嚣 RE-BOOT!》（KiriKiri Z）由 Fushi 启动，游戏内查词一切正常
（`lookup_diag=0x106F`，卡片已画进游戏图层，点击也已转发：`inputs=3`）。
点卡片右上角「+」制卡：

- **第一次**（还没选文本线程）：弹出「完成捕获设置：请先选择台词线程」。行为正确。
- **选完线程之后再点**：**什么都不发生**。没有 toast、没有进度、没有错误，Anki 一条都没多
  （AnkiConnect 前后 `total_notes` 13200 → 13200，`galgame_card_test` 12 → 12）。

用户视角完全无法区分「制卡失败了」和「我没点到按钮」。

### 根因

`fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart:730-748` `_ingameMiningHandlerFor`：

```dart
final String? resolved = _resolveIngameMiningLineId(line);
if (resolved == null) {
  return const <String, Object?>{'ankiConnect': false, 'noteId': null};   // :736-739
}
```

**静默返回**：不 toast、不 `_record`、不打日志。
而 `_resolveIngameMiningLineId`（`:712-727`）第一步就读 `_session.selectedSessionLines`
（`gal_hook_session_controller.dart:768`），列表为空直接 `return null`（`:714`）。

对照：**浮窗点词那条制卡路径拿不到 entry 时是有提示的**——
`gal_hook_text_overlay_controller.dart:672-680` 会 `FushiToast.show(t.game_hook_line_unavailable, error)`。
两个入口对同一种失败的处理不对称，游戏内这条是纯静默死。

### 与 BUG-1733 的关系

BUG-1733 是**为什么列表是空的**（KiriKiriZ 线程的台词被伪影门丢了）；本条是**列表空时不该静默**。
两者要分别修：即便 1733 修好，仍会有「用户选了一条真的没台词的线程」这种合法情形，
那时也必须告诉用户，而不是让「+」按钮看起来坏了。

### 修复方向

失败分支给出与浮窗路径同源的提示（同一条 i18n key 或新增一条更准确的），
并区分两种原因：本会话没有任何台词行 / 有台词但匹配不上当前这句。
