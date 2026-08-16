## BUG-1685 · 播放页找字幕只搜 Jimaku，与下载管线的统一 registry 是两套实现
- **报告**：2026-08-16（用户：「获取字幕的api应该统一（下载，视频，设置等）」）
- **真实性**：✅ 真 bug。字幕获取有两条并行实现：
  下载管线走 `VideoSubtitleRegistry`（`fushi/lib/src/media/video/download/video_subtitle_registry.dart`，
  Jimaku + OpenSubtitles，含去重/优先级/失败归类），而播放页的找字幕对话框
  `fushi/lib/src/pages/implementations/jimaku_subtitle_dialog.dart:344,402`
  自建 `JimakuClient` 直连 Jimaku。同一个动作在两个入口能力不同——播放页永远搜不到
  OpenSubtitles，用户在设置里配了也没用；且搜索门槛硬卡 Jimaku key（同文件 `:320`），
  只配了 OpenSubtitles 的用户连搜都搜不了。
  配置侧同样分家：Jimaku key 在 设置 → 视频 → 字幕
  （`fushi/lib/src/settings/settings_schema_video.dart:1138`），OpenSubtitles 只在
  设置 → 下载 → 外部来源（`video_external_provider_settings_section.dart`）。
- **[x] ① 已修复** — `56f073bef6`。对话框改为经 registry 搜索与下载（候选模型改成
  provider 无关投影，语言优先取 provider 给的权威码）；搜索门槛改成「有没有可用来源」；
  registry 延迟解析，避免绑到填 key 之前的旧实例；设置页「视频 → 字幕」内联**同一份**
  OpenSubtitles 编辑组件（`onlySubtitleSources` 按节可裁），不复制 UI。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_subtitle_dialog_registry_test.dart`
  （播放页列出全部已配置来源的候选；只配 OpenSubtitles 也能搜、不再报「没有 key」）。
- **备注**：番剧下载对话框与批量匹配对话框的**手工**选字幕面板仍直连 Jimaku。它们的
  计划持久化字段是 Jimaku 专有的（`AnimeDownloadPlan.jimakuEntryId` / `jimakuEntryName`），
  下载完成后由 `anime_download_subtitle_resolver.dart` 按该 id 回查；改成 provider 无关
  句柄要动已落盘的计划结构 + resolver，属独立迁移任务。下载链路的**自动**配字幕本来
  就走 registry，不受影响。
