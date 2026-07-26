## BUG-1095 · galgame 台词浮窗拖动窗口时字号跟着变，「放不下」怎么拖都放不下

- **报告**：2026-07-26（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/windows/runner/floating_lyric_window.cpp:825-831`（修复前）：
  hook 模式的字号是 `style_.font_size * clamp(strip_height_dip_ / 140dip, 0.9, 2.5)`，
  而 `strip_height_dip_` 的唯一来源就是窗口实际 rect（`SyncStripSizeFromWindow()`，
  每次 `WM_SIZE` 都重算并 `text_format_.Reset()`）。于是「把浮窗拖高」和「把台词放大」
  是同一个手势：从默认 140dip 拖到上限 480dip（3.4×）时字号同步 ×2.5，可见行数只从
  约 2.3 行涨到约 4.3 行——用户「放不下想拖高」永远拖不出想要的效果。
  另一半是文本区没有滚动：段落垂直居中 + `PushAxisAlignedClip` 硬裁，溢出直接被切掉。
  字号当时**没有任何独立真值**（`kGalHookTextFontSize = 30.0` 是硬常量、无 pref），
  整个 galgame 浮窗在设置页也一条条目都没有。
- **[x] ① 已修复** — 字号与窗高彻底解耦：
  - native `hibiki/windows/runner/floating_lyric_window.cpp:45-62`（常量注释）、`:828-841`
    hook 模式的 `height_scale` 恒为 `1.0f`，直接用 `style_.font_size`；有声书歌词条保持
    原有随高缩放行为不变。删除 `kHookTextBaseHeightForFontDip` / `kHookTextFontScaleMin`
    / `kHookTextFontScaleMax` 三个常量。
  - 新增独立偏好 `gal_hook_text_font_size`（`hibiki/lib/src/models/preferences_repository.dart`
    `galHookTextFontSize`，范围 12..72，默认 30）+ `AppModel` 委托 + 设置项
    `lookup.gal_hook_text_font_size`（`hibiki/lib/src/settings/settings_schema_lookup.dart`，
    仅 Windows 可见）。
  - `GalHookTextOverlayChannel.show/updateStyle` 传真实 `fontSize`；
    `GalHookTextOverlayController.applyFontSizeFromPreferences()` 在设置页改完立刻推 native。
  - **向后兼容**：默认 30 恰好等于旧公式在默认窗高 140dip 下的实际字号（`clamp(140/140)=1.0`），
    没拖过浮窗的用户逐像素不变；拖过窗的用户字号回到 30 并从此由设置项控制——这正是本 bug
    要求的行为改变（拖高 = 多显示几行，而不是把同样两行放得更大）。老 rect pref
    `gal_hook_text_window_rect` 语义未变，不需要迁移。
  - 顺带：hook 模式下台词一旦装不下就从垂直居中改成**顶端对齐**（`floating_lyric_window.cpp:874-890`），
    保住阅读起点，只丢句尾；装得下时仍居中（像素不变）。
  - 提交：64e0e8211
- **[x] ② 已加自动化测试** —
  - 源码守卫 `hibiki/test/build/gal_overlay_font_decoupled_guard_test.dart`：断言 hook 分支不再
    出现按窗高缩放的常量/表达式、恒为 1.0f，且溢出顶端对齐存在。
  - Dart 真单测 `hibiki/test/lookup/gal_hook_text_overlay_controller_test.dart`（新增两条）：
    `show` 携带偏好里的字号；`applyFontSizeFromPreferences()` 把新字号经 `updateStyle` 推给 native。
  - 偏好边界 `hibiki/test/models/preferences_repository_gal_hook_font_test.dart`：默认值 / 上下钳位 / 脏数据收敛。
- **备注**：native C++ 改动已用 `flutter build windows --debug` 真编译验证。
  **仍未做**：文本区依旧没有滚动，字号调太大 + 窗口太小时溢出仍被硬裁（只是改成裁句尾）。
  分层滚动需要在 Direct2D 分层窗里自建滚动条与命中测试，属独立工程量，本轮不做。
  真机肉眼复测（拖高浮窗看行数是否真变多）待补。
