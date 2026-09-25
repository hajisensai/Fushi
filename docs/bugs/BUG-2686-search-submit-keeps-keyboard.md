## BUG-2686 · 移动端搜索框按键盘确认后软键盘不收起
- **报告**：2026-09-26（用户：移动端查词页输完按键盘右下角确认，键盘不收）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/fushi_material_components.dart` 的 `FushiSearchField` 为修 BUG-2620 给 `TextField` 传了只清 composing 的 `onEditingComplete`，焦点刻意留在框里；而 `EditableText._finalizeEditing` 对 `search` 这类 shouldUnfocus 动作，在焦点仍在时会于 `onSubmitted` 之后排 microtask 重建输入连接并 `show()`（flutter#84240），于是移动端软键盘永远收不起来。改成 unfocus 也不行：`FushiFocusRoot` 的被动修复（`ensureFocus` → `_currentEntry`）会把焦点还给登记过 focusId 的搜索框，键盘再弹一次。
- **[x] ① 已修复** — 移动端（Android / iOS）提交收尾里保留焦点、只收软键盘；hide 排到下一帧的后帧回调（显式 `scheduleFrame`），确定地排在框架重建连接那次 show 之后。物理回车兜底路径同样收键盘。桌面不变。提交：见 PR 分支 `pr/lookup-ime-submit`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_search_field_submit_keyboard_test.dart`（Android/iOS 提交后 `testTextInput.isVisible == false` 且焦点仍在；再点框键盘回来；Windows 不动键盘）。
- **备注**：未上真机复测（本机无安卓真机会话）；widget 测试日志确认顺序为 clearClient → setClient → show → hide。
