## BUG-939 · 字幕轨菜单每次打开都重跑ffprobe显加载条+已有字幕先消失

- **报告**：2026-07-19（用户：截图「字幕轨」区顶部一直转加载条，明明无可加载的字幕轨；且之前枚举出的字幕会消失，要等加载）
- **真实性**：✅ 真 bug。根因在字幕轨枚举无按视频缓存、且有两个各自枚举的入口：
  - `hibiki/lib/src/pages/implementations/video_hibiki/subtitle.part.dart:354`（旧 `_showSubtitleSourceMenu`）每次打开都 `_subtitleMenuSources = []` + `_subtitleMenuLoading = true` 再重跑 `_subtitleSourcesForMenu`（ffprobe 枚举内嵌轨 + 同目录外挂）→ 已枚举出的字幕轨先消失、加载条转（「之前有的字幕还会消失，要等加载」）。
  - `hibiki/lib/src/pages/implementations/video_hibiki/subtitle.part.dart:381`（`_ensureSubtitleMenuSourcesLoaded`，由设置面板「字幕」分类被打开事件 `onSubtitleCategoryShown` 驱动）无条件重枚举，无内嵌轨/外挂的视频枚举恒空却每次都显加载条（「字幕轨要加载，明明根本没有可加载的地方」）。

- **[x] ① 已修复** — commit `<pending>`
  - 新增按视频路径的枚举缓存 key `_subtitleMenuSourcesPath`（`video_hibiki_page.dart:950` 附近）。
  - `_ensureSubtitleMenuSourcesLoaded` 成为**唯一枚举者**并加缓存短路：`if (_subtitleMenuSourcesPath == videoPath) return;`，成功后记 `_subtitleMenuSourcesPath = videoPath`；失败不写 key 下次重试。
  - `_showSubtitleSourceMenu`（控制条「字幕轨」按钮）退化为纯打开设置面板「字幕」分类——枚举交给面板打开必触发的 `_ensureSubtitleMenuSourcesLoaded`（initState / didUpdateWidget / `_selectSubPage` 三条路径），不再自清空 + 重枚举（消除闪烁与重复枚举）。
  - 缓存失效：换视频/换集（`_applyLoad` 内 `clipExportSourceChanged`）复位缓存；导入外挂字幕档 / Jimaku 下载后 `_invalidateSubtitleMenuSourcesCache()` 让新档下次枚举列进。
- **[x] ② 已加自动化测试** — `hibiki/test/tools/subtitle_menu_reenumerate_guard_test.dart`（源码扫描守卫：缓存字段存在、`_ensureSubtitleMenuSourcesLoaded` 有路径短路并记录、`_showSubtitleSourceMenu` 不再调 `_subtitleSourcesForMenu` / 不再置 loading=true）。3 用例全绿。

- **备注**：巨型 `_VideoHibikiPageState`（~7300 行）私有方法难做 widget 行为测试（需 controller + ffprobe + DB），按 BUG 流程用源码扫描守卫作最强可落地层。远端视频分支行为不变（远端字幕轨走 `_youtubeCaptionTracks` / `_remoteEmbeddedSubtitleTracks`，本地枚举缓存清空即可）。
