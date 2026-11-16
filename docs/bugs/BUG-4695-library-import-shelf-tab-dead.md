## BUG-4695 · 书库导入页点左上角「书架」回不去，仍停在导入页
- **报告**：2026-11-16（用户：维护者应用内反馈 3cmGrH7EoA，Windows 3.3.0-debug.27417）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/media_library_shell.dart:573`（修复前）停在导入页时为了高亮「我的」组，把一级页签的 `selected` 设成组值（书架）——「视觉高亮」和「当前视图」共用同一个 `selected`。页签组件把「点中 selected」当重复点击丢掉：页头大字一级切换 `fushi/lib/src/utils/components/fushi_page_masthead.dart:635`（`if (tabs[i].value != selected) onChanged(...)`），二级连体按钮组同理（同文件 774），焦点外壳 `FushiAdjustableSegmented`（`fushi/lib/src/utils/components/settings_shared.dart:3114`，`if (value != selected)`）从首段按左方向键被夹回原地同样被丢。于是导入页的「书架」看着是选中的，点 / 按都到不了 `_select`。
- **[x] ① 已修复** — 把「高亮锚点」与「当前视图」拆开：`LibrarySectionTabs` 新增 `selectedIsCurrent`（默认 true），壳在导入页传 false；页头大字一级 / 二级与 `FushiAdjustableSegmented` 在 `selectedIsCurrent == false` 时点中 / 方向键落到高亮项照常回调。壳的 `_select` 本身幂等。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_library_shell_test.dart`：导入页真实指针点「书架」回到书架；导入页键盘左方向键回到书架；不在导入页时 `selectedIsCurrent` 为 true（重复点击照旧被吞）。
- **备注**：MD3 非页头大字形态（墨水屏）的 `FushiSectionTabBar` 走 TabBar `onTap`，本就逐次回调，不受影响。Apple 非页头大字形态的原生分段控件点已选段不回调，但壳在 Apple 设计下恒走页头大字（墨水屏不走 Apple），当前没有宿主在该形态传 false。真机未复测。
