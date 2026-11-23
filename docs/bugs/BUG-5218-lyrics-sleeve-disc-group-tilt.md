## BUG-5218 · lyrics-sleeve-disc-group-tilt
- **报告**：2026-11-22（代码审查 HBK-AUDIT-228，PR #4114）
- **真实性**：✅ 真 bug，与 PR #4114 写明的目标「3D 倾斜套在整组外，封面与唱片一起倾斜」矛盾。分栏布局 `_buildSleeveWithDisc`（`fushi/lib/src/pages/implementations/music/music_lyrics_page.dart:1704-1749`）外层的 `FushiHoverLift` 只放大并广播指针位置，真正的倾斜变换是封面框自己的 `FushiTilt`（`fushi/lib/src/utils/components/shelf_card_widgets.dart:470` / `shelf_cover_material.dart:888`），只套在封面上；同一个 Stack 里的唱片（兄弟节点）没有倾斜层，悬停时封面倾、唱片平，两层错开。
- **[x] ① 已修复** — `FushiTilt` 加 `group` 参数（`fushi/lib/src/utils/components/fushi_hover_lift.dart`）：group 层往下广播「已由祖先整组倾斜」，子树里的 `FushiTilt` 不再各自旋转（树结构不变）。歌词页分栏把「封面 + 唱片」那个方块包进 `FushiTilt(group: true)`，封面与唱片共用一个变换；封面的镜面高光照旧。
- **[x] ② 已加自动化测试** — `fushi/test/utils/components/fushi_hover_lift_tilt_test.dart`「group 倾斜：整组共用一个变换…」：鼠标悬停后全树只有一层透视变换，且是唱片的祖先；`fushi/test/pages/music_lyrics_page_test.dart` 分栏用例断言唱片与封面高光都在同一个 group 倾斜层下（变异实测：还原歌词页的 group 包装后该用例红，恢复后绿）。
- **备注**：
