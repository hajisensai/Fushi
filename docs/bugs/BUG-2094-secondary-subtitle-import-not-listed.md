## BUG-2094 · 导入的副字幕在字幕列表里消失，但画面仍在渲染它
- **报告**：2026-09-03（用户：截图，视频设置 → 字幕）
- **现象**：画面上同时渲染主 + 副两行字幕，但设置面板「字幕轨」列表和「副字幕」分组里都只剩一条 sidecar/主字幕，用户导入的那条副字幕档在两个列表里都没有；副字幕组里没有任何一行是高亮的（当前副字幕源不在列表里），因此也切不回来、删不掉。
- **真实性**：✅ 真 bug —— 根因 `fushi/lib/src/media/video/video_subtitle_source.dart:844` `includeCurrentPersistedSubtitleForMenu` 只补**主**字幕一条持久化指针。
- **根因**：字幕轨菜单的最终列表由三份拼成——① `listAllSubtitleSources` 枚举（按设计只看内封轨 + 视频**同目录** sidecar，永远看不到导入档所在的 `<dataRoot>/documents/video_subtitles/`）；② `_importedSubtitleSources`（**本会话**登记，换视频/换集清空，`video_fushi_page.dart:2396` 一带）；③ `includeCurrentPersistedSubtitleForMenu` 补「当前持久化的导入档」。第 ③ 层是跨会话唯一的补齐通道，而它只认 `currentSubtitleSource`（主字幕）一条指针，副字幕指针 `_currentSecondarySubtitleSource`（`video_fushi_page.dart:2204` 从 `row.secondarySubtitleSource` 恢复）从来没有对应的补齐。于是重开视频后：副字幕 cue 照常从库里重放继续渲染，而列表里没有任何一行承载那个档案。这正是 BUG-1861 在主字幕那半已经修掉的同一个洞（「字幕应用上了、列表里却没有它」），副字幕这半没修。
- **[x] ① 已修复** — `includeCurrentPersistedSubtitleForMenu` 改为对「当前正在使用的每一条持久化指针」（主、副）跑**同一条**补齐规则（是导入档 + 文件在盘上 + 能解析出 cue），用循环而不是主/副两套分支；主副选同一档时按归一化路径去重只列一行，主字幕仍排最前。调用点 `_subtitleSourcesForMenu` / `_ensureSubtitleMenuSourcesLoaded` 把 `_currentSecondarySubtitleSource` + `controller.secondaryCues` 传下去。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_source_test.dart`：只作副字幕用的导入档要被列出、主副两档都在且主在前、主副同档只列一行；`fushi/test/pages/video_subtitle_fixes_guard_test.dart` 的 TODO-016 守卫补了 wiring 断言（helper 与枚举入口都必须把副字幕指针/cue 传下去）。
- **备注**：**远端（互联/YouTube）模式同形缺口未修**——远端分支的字幕行不读 `_menuSubtitleSources`，本机落盘档只由本会话的 `_importedSubtitleSources` 承载，跨会话恢复后同样没有行。本次只修用户报告的本地视频路径，远端那半需要各自的持久化指针补齐，待单独一条处理。
