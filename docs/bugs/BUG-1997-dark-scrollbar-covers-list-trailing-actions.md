## BUG-1997 · 深色主题滚动条 8px 盖住并吞掉列表右侧操作按钮
- **报告**：2026-09-01（用户配图：字幕列表右侧的星标图标被滚动条压住一半。「是不是应该给滚动条搞个独立的区域好点」）
- **真实性**：✅ 真 bug，且是**系统性**的。根因 `fushi/lib/src/models/theme_notifier.dart:1072-1075`：

  ```dart
  thickness: brightness == Brightness.light ? WidgetStateProperty.all(3) : null,
  ```

  深色是 `null` → 退回 Material 默认 `_kScrollbarThickness = 8`，加 `crossAxisMargin` 默认 2 = **10px**。而桌面端 `MaterialScrollBehavior.buildScrollbar` 给 windows/macOS/linux 上**每个**垂直 Scrollable 无条件包一层 `Scrollbar`，配上全局 `thumbVisibility: all(true)`，那 10px 是**常驻覆盖**在每个列表右侧的（overlay 不占布局）。

  仓库里有 **9 处** `RawScrollbar` 硬写 `thickness: 3`——3 才是设计意图，深色只是漏钉。

  截图那处是 `fushi/lib/src/media/video/video_subtitle_jump_panel.dart` 的字幕跳转面板（`_buildRowActions` L1968：▶跳转 / ⧉复制 / ☆收藏）。几何账：行右内缩 `kSubtitleRowPaddingRight = 4`（TODO-1200 特意压小以把宽度还给文本列）+ 星标按钮内 `Padding(all: 2)` → 图标盒右缘距面板右缘 6px，被 10px 滚动条压掉 4px。亮色下 2+3=5 < 6 不重叠，**所以只在深色发作**。

  比「看起来被盖住」更严重的一条：`Scrollbar` 在桌面默认 `interactive = true`，那 10px **会吞掉点击**——星标右侧按下去是在拖滚动条，不是收藏。
- **[x] ① 已修复** — 两步，第一步才是根因：
  1. `theme_notifier.dart` 两个亮度统一用新常量 `kFushiScrollbarThickness = 3`（抽到 `fushi/lib/src/utils/components/fushi_design_tokens.dart`，与那 9 处硬编码同源）。**单这一步用户症状即消失**（5 < 6），且下面第 4 节列的其它命中也一并从「压 6px」降到「压 1px」。
  2. 字幕面板给滚动条让出独立通道：新增 `kSubtitleRowScrollbarGutter = kFushiScrollbarGutter`（= thickness + crossAxisMargin，跟着主题走，不写死数字），**渲染侧行 padding 与测量侧 `subtitleRowTextWidth` 同改**（BUG-1034 的「测量与渲染同源」约束）。刻意不用 `ListView(padding: right)`：那样行背景/选中高亮不铺满、右侧露一条底色，还会改变 `itemExtentBuilder` 拿到的 `crossAxisExtent`；走常量方案则既有守卫 `video_subtitle_row_extent_guard_test.dart` 调的是同一个纯函数，**零改动自动跟着变**。
- **[x] ② 已加自动化测试** — 两条，均已变异实测：
  - `fushi/test/models/theme_notifier_test.dart` → `GUARD: scrollbar thickness is pinned and identical in both brightnesses`。变异（把三元恢复成 `: null`）→ 正确变红；已还原（sha256 校验一致）。
  - `fushi/test/media/video/video_subtitle_row_extent_guard_test.dart` → `GUARD: 最右侧星标按钮为滚动条让出 gutter`。**量的是 `InkResponse`（可点区域）而不是 Icon**——第一版拿 Icon 量，因为 Icon 的 rect 不含按钮那 2px padding，多出的余量让守卫在去掉 gutter 后照样绿（空转），改测可点区域后变异才真红。变异（渲染侧去掉 gutter）→ 正确变红；已还原。
  - 78 tests ran, all passed。
- **备注**：**还有一批同类命中没修**（本轮只修了用户报的字幕面板 + 全局根因）。thickness 降到 3 之后它们从「压 6px」降到「压 1px」，但下面前三处右内缩为 **0**、trailing 是可点控件，仍会被压 5px 并吞点击，建议后续给 `contentPadding` 加回 horizontal ≥ 8：
  - `subtitle_search_panel.dart:1407`（ListView 无 padding + `ListTile(contentPadding: symmetric(vertical: 4))`，trailing 是下载图标/进度圈）——最严重；
  - `video_shader_dialog.dart:560`（`CheckboxListTile(contentPadding: zero)`，**Checkbox 直接被压**）与 `:661`；
  - `torrent_detail_dialog.dart:716`（trailing 是 `DropdownButton`，箭头被压）、`:783`/`:843`；
  - 次级（只盖文本/图形）：`torrent_detail_dialog.dart:505`、`subtitle_collection_panel.dart:861`。
  - 待实测一处：`video_shader_dialog.dart:371`（滚动容器是外层设置页 body，取决于该 body 的 padding）。

  未做真机验证：本轮验证停在 `flutter test` 层，建议在 Windows 深色主题下打开视频字幕列表面板复看一次。
