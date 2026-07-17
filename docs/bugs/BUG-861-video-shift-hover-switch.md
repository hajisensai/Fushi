## BUG-861 · 视频按住Shift无法连续切换查词
- **报告**：2026-07-16（用户：）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart`（查词浮层 dismiss barrier 缺 `onPointerHover` 转发）
- **[x] ① 已修复** — `hibiki/lib/src/pages/implementations/video_hibiki_page.dart`（`_onDismissBarrierHover` + `_handleSubtitleHoverLookup` + barrier 外挂 `Listener(onPointerHover:)`）/ `video_hibiki/layout.part.dart`（`onCharHover` 走去重入口）
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_shift_hover_switch_static_test.dart`
- **备注**：

### 根因

视频字幕查词与阅读器一样，桌面支持「按住 Shift 悬停字幕字符即查词」（TODO-756a）。首次悬停查词后弹出的查词浮层（`_buildPopupOverlay`）会在根 Overlay 铺一层**全屏 dismiss barrier**盖在字幕之上。

- **阅读器**（`base_source_page.dart` / `reader_hibiki_page.dart:onDismissBarrierHover`）：barrier 外层挂了 `Listener(onPointerHover: onDismissBarrierHover)`——首弹后 barrier 盖住正文、WebView / 字幕自身收不到 hover 时，barrier 是**唯一**还能接 hover 的入口，按住 Shift 一路滑就反查命中字符 → `replaceStack` 无缝换词。
- **视频**（`video_hibiki_page.dart:_buildPopupOverlay`）：barrier 只有一个 `GestureDetector`（处理 tap / 横拖关栈），**没有任何 `onPointerHover` 转发**。首弹后字幕盒自己的 `VideoSubtitleOverlay` `MouseRegion.onHover`（`_handleShiftHover`）被 barrier 遮住收不到 hover，于是「按住 Shift 连续切换查词」在**首弹之后彻底失效**——只能先关掉浮层、再悬停下一个词。

### 修复（根因修复，非绕过）

对齐阅读器，给视频 barrier 补上 hover 转发：

1. barrier 的 `GestureDetector` 外层包 `Listener(onPointerHover: _onDismissBarrierHover)`（`_buildPopupOverlay`）。
2. `_onDismissBarrierHover(PointerHoverEvent)`：门控与字幕盒 `_handleShiftHover` 一致（按住 Shift 或开「悬停即查词」）；8px 平方阈值节流（`barrierHoverThresholdPx`，与 `_kShiftHoverThresholdPx` 同构）；用已存在的 `_subtitleHitTester.hitTest`（全局坐标）反查命中字符；非嵌套 + 命中才换词（复用 `shouldSwitchWordOnBarrierTap` 门控，嵌套态换词会误替整栈）。
3. `_handleSubtitleHoverLookup`：字幕盒 `onCharHover` 与 barrier hover 两条路径的**统一去重入口**——用「同句同 grapheme」短路，避免字符没被浮层遮住时两条 hover 路径同时命中导致同词双 `replaceStack` 闪烁 / 重复刷 FFI。`onCharTap`（点击查词）不经此入口，重复点同字仍照常重查。
4. 关栈会话结束（`_popNestedPopupAt` stackEmpty）复位去重键，使关掉浮层后再次悬停同一字符能重查。

### 验证

- `flutter analyze` 干净。
- `flutter test test/pages/video_shift_hover_switch_static_test.dart` 通过（源码接线守卫 + 门控纯函数）。
- ⏳ 待真机（Windows 桌面，鼠标 + Shift）复测：首弹后按住 Shift 划过同句其它字符应连续换词、松开 Shift 停止。
