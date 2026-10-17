## BUG-3294 · 点制卡按钮出现蓝色方框背景（未复现）
- **报告**：2026-10-12（反馈 #qFuEIpcwsC，Windows：「点击制卡按钮，会出现一个蓝色方框背景，正常来说不应该出现」；无截图，日志显示在视频播放页查词）
- **真实性**：❌ 未复现，需截图。已排查：① BUG-3096 的 tap highlight 已在 `popup.css` 的 `html` 上全局置透明（且只影响 Android）；② M3E 下制卡键本身就是 filled primary 圆钮，按下时 `:active` 把圆角变形为 medium 并叠 pressed 状态层（`popup.css` `html.fushi-m3e .header-buttons > .inline-action-button:...:active`），制卡后切 `.duplicate` 为 primaryContainer 底——都是设计内的底色，在蓝色主题下即「蓝色块」；③ 头部按钮 `:focus-visible` 是 surface 间隙 + primary 描边环，只在键盘焦点时出现；④ 视频页制卡路径（`video_fushi/lookup_mining.part.dart` → `_mineVideoCard`）没有任何 Flutter 侧高亮 / 焦点框绘制。无法从描述区分是②的设计态、③在宿主转发按键后被 Chromium 判成键盘焦点、还是别的层。
- **[ ] ① 未修复** — 等用户补截图（点按瞬间与点完之后各一张）与当前设计系统 / 主题色后再定根因。
- **[ ] ② 未加自动化测试** —
- **备注**：未复现记一条。
