## BUG-1890 · gal 台词浮窗文字放得下时被强制垂直居中，无法选择顶部对齐
- **报告**：2026-08-27（用户对着「文字对齐」设置截图：「这个文字对齐可以加一个让它上下也不要居中吗」）
- **真实性**：✅ 真需求，且**顶对齐的代码路径早就存在、只是够不着**。设置页那项「文字对齐」（`fushi/lib/src/settings/settings_schema_game.dart:190-211`，i18n `gal_hook_text_alignment*`）只有水平的「居中 / 左对齐」两档，落到 native 是 `DWRITE_TEXT_ALIGNMENT_LEADING/CENTER`（`fushi/windows/runner/floating_lyric_window.cpp:1425-1428`）。垂直方向由 `SetParagraphAlignment` 控制，有两处、第二处每帧覆写第一处：
  - `floating_lyric_window.cpp:1429` 创建 `text_format_` 时的初值，恒 `DWRITE_PARAGRAPH_ALIGNMENT_CENTER`；
  - `floating_lyric_window.cpp:1526-1541` 每帧对 layout 覆写，判据是 `metrics.height > text_rect_.height ? NEAR : CENTER` —— 即 **BUG-1095 的设计：只有文字溢出窗口时才顶对齐**（保住阅读顺序，只丢句尾），放得下就强制垂直居中。
  也就是说 `NEAR`（顶对齐）分支一直在，用户却没有任何入口选它；长短句交替时台词就在窗口里上下跳。
- **[x] ① 已修复** — 新增与水平对齐**正交**的垂直对齐偏好（不合并成三选一——合并会造出「选了顶部就没法同时左对齐」这种假互斥）：
  - 偏好 `gal_hook_text_vertical_alignment`（`preferences_repository.dart`，白名单二值 `'center'`/`'top'`，默认 `'center'` = 修前行为逐像素不变），进 `preference_keys.dart` 白名单（字母序）、`app_model.dart` 转发。
  - 设置项 `game.gal_hook_text_vertical_alignment` 分段控件（`settings_schema_game.dart`，图标 `Icons.vertical_align_center`），新 i18n key `gal_hook_text_vertical_alignment{,_center,_top}` 进 17 语。
  - 控制器 `gal_hook_text_overlay_controller.dart` 读偏好并随 `show` / `updateStyle` 下发；通道 `gal_hook_text_overlay_channel.dart` 与水平对齐同样的 String→int 编码（`'top' → 1`），键名 `verticalAlignment` 独立，两轴互不覆盖。
  - native：`floating_lyric_window.h` 加 `int vertical_alignment = 0;`；`flutter_window.cpp` 解析；`floating_lyric_window.cpp:1429` 的初值与 `:1529` 的每帧覆写各读一次。每帧覆写处改成 `(style_.vertical_alignment == 1 || metrics.height > text_rect_.height) ? NEAR : CENTER` —— 「用户选了顶部」与「文字溢出」是**并联**条件，溢出场景行为与修前完全一致；而下面的滚动模型（`scroll_max_px_` / `text_origin_y`）本来就是按 NEAR 顶对齐推导的，恒 NEAR 只让它更自洽。
  - 两处都用 `hook_text_mode_ &&` 限定：有声书歌词条要的是当前行居中，不受此偏好影响。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_hook_text_vertical_alignment_test.dart`，13 条分四层：偏好白名单收敛（真 DB：默认 center / 写 top 读回 / 非法值落回 / **与水平对齐互不干扰**）、通道 String→int 编码（show 与 updateStyle 各验，含默认与非法值）、native 消费点源码守卫（结构体字段 / 通道解析 / 每帧覆写读该偏好 / 歌词条不受影响）、设置页入口是独立分段项。
  变异实测：把 native 每帧覆写处改回 `metrics.height > text_rect_.height` 单一判据 → 精确红「每帧覆写处读该偏好」1 条，其余 12 条全绿；还原后 sha256 与变异前一致（`85f4c816ba4e555e…`）。
- **备注**：Windows-only（这个浮窗是 Win32 分层窗 + Direct2D/DirectWrite，Android 侧无对应实现）。native 改动未做 Windows 构建验证与肉眼复测（真机验证环节用户已取消），属待补缺口——Dart 侧全链路与 native 源码结构由上述测试覆盖。
