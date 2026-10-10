## BUG-3253 · 串流窄布局面板最小高度 200 在软键盘弹出时溢出
- **报告**：2026-10-10（PR #2050 审查遗留疑点）
- **真实性**：✅ 真 bug（widget 测试复现）。`fushi/lib/src/models/game_stream_lookup_layout.dart` `effectiveCompactRailHeight` 无论 body 多矮都把面板高度钳到 `minCompactRailHeight`（200）以上，`compactRailHeightLimit` 同样以 200 为下限。宽 < 700 的横屏小手机（窄布局）弹出软键盘后 body 只剩一两百，面板比 body 还高：`game_stream_page.dart` 窄布局外层 Column 里画面被挤成 0 并溢出（body 142 时溢出 58px）。改前实现是 `min(360, h*0.5)`，不会溢出。
- **[x] ① 已修复** — 新增 `GameStreamLookupLayout.compactRailResizable`（body ≥ 面板下限 + 画面下限）；放不下两者下限时退回改前的对半分，用户存的高度不参与；此时拖分隔条不改写存着的高度（`_resizeCompactRail` 早退）。body 够高时行为不变。提交见 `fix(game-stream): split a short narrow-layout body instead of overflowing`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/game_stream_lookup_resize_test.dart`「a body too short for both minimums is split in half instead of overflowing」（420/260/200/150/90 高五档：画面 + 分隔条 + 面板 = body，拖动不改写存值；去掉修复五条全红）。
- **备注**：这么矮的 body 里画面内的手柄按键（需 ~280）与面板里的标题 + 行区仍放不下，属改前（同样对半分）就有的内部溢出，不在本条范围。
