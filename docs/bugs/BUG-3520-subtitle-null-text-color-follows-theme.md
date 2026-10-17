## BUG-3520 · 关掉「尊重字幕自带样式」后字幕文字色随 App 主题忽白忽黑
- **报告**：2026-10-18（GitHub issue #2312，用户：「字幕开启忽视自带格式后字体异常，会一会白一会黑」）
- **真实性**：✅ 真 bug（触发条件：持久化的字幕样式 `textColor` 为 null，即 TODO-051 之前落盘的旧
  数据）。根因 `fushi/lib/src/pages/implementations/video_fushi_page.dart:1487`（修复前）
  `_subtitleTextColor(cs) => cs.onSurface`，经 `layout.part.dart:676`
  `_subtitleStyle.resolveTextColor(_subtitleTextColor(...))` 喂给 overlay；overlay 自身的回退
  `video_subtitle_overlay.dart:2917`（及 `\p` 图形填充 `:2520`）也是 `colorScheme.onSurface`。
  字幕于是**跟随 App 主题明暗**：深色主题白、浅色主题黑，主题跟随系统昼夜切换时同一部片子
  忽白忽黑。开着「尊重字幕自带样式」时 ASS 的 PrimaryColour（通常白）盖住了它，一关（纯字幕
  模式，颜色语义归零回落用户 textColor，BUG-915/1285）就暴露——与用户描述的触发条件一致。
  同时设置页取色行把 null 显示成白色（`video_settings_actions.dart` 原 `style.textColor ?? 白`），
  用户看到的设置与实际渲染矛盾。
  静态阅读未找到纯字幕模式下**同一主题内**颜色随播放状态切换的其它路径（mpv 原生渲染只在图形
  字幕 / 光盘菜单打开，与该开关无关）；若用户的「一会白一会黑」发生在主题不变时，需要样本文件。
- **[x] ① 已修复** — `VideoSubtitleStyle.resolveTextColor()` 改为无参、null 解析为固定白
  `kDefaultSubtitleTextColor`（与 TODO-1059 把背景色从主题 surface 改成固定黑同一思路：字幕画在
  视频上，不画在 App 表面上）；播放页、设置页预览、取色行初值、overlay 回退统一走它。持久化的
  null 原样保留，不改写用户数据。提交见分支 `worktree-fix-2312-subtitle-linebreak-style`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_text_color_test.dart` 新增
  group「#2312 未指定文字色时恒为固定白」：浅色 / 深色主题 × respect 开 / 关四组 widget 测试，
  断言填充色为固定白；`video_subtitle_style_test.dart` 两条把「null = 跟随主题」钉死的旧断言按
  契约变更改写；`test/pages/video_theme_color_static_test.dart` 改为禁止页面再给文字色喂主题色。
- **备注**：阴影色 null 仍回落 `cs.shadow`（Material 深浅主题均为黑），本次不动。
