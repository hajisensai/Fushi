## BUG-1872 · 视频发现搜索资源/订阅在缺受管视频来源时只弹「暂无来源」snackbar
- **报告**：2026-08-25（用户：截图——视频发现详情页点「搜索资源」，底部只弹「暂无来源」；「这里的暂无来源不对，看上去只是没配置下载后端。应该给弹窗配置」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_page.dart:1432` / `:1504`（修前）`_openVideoDiscoveryResourceSearch` / `_openVideoDiscoverySubscription`：`registry`/`pipeline` 非空（后端**已就绪**）后 `getManagedVideoDownloadSources()` 为空 → `_showVideoDiscoveryMessage(t.media_source_no_sources)`。
  真实缺陷是两条，都**不是**「两个原因被折叠成一句 snackbar」——修前「缺后端」与「缺来源」本来就是各自独立的分支：
  1. **用错 i18n key**：拿通用扫描根的 `media_source_no_sources`（「暂无来源」）去描述「缺下载完成后落地用的本地视频文件夹」（`app_model.dart:3938` 过滤 `transport == 'local'` 且目录存在）。文案既不说缺什么、也不说这跟下载有关，用户自然猜成「没配下载后端」。
  2. **那条分支没有可点的动作**：只有一句 snackbar，没有任何入口能就地把缺的东西补上。
  下载页早在 BUG-1706 把这一环拆成 `DownloadsResourceNoManagedSource` → 就地开 `MediaSourcesDialog(mediaKind: 'video')`（`downloads_page.dart:110`），首页发现路径漏改。
- **[x] ① 已修复** — `c953b9494d`：新增 `fushi/lib/src/pages/implementations/managed_video_source_prompt.dart`（`promptManagedVideoSourceSetup` + `ManagedVideoSourcePromptDialog`，与 `promptDownloadBackendSetup` 同姿态：一句说清缺的是落地用的视频文件夹 + 「添加视频来源」按钮就地开 `MediaSourcesDialog`）；`home_page.dart` 两条流程统一走 `_managedVideoDownloadSourcesOrPrompt`，用户加完来源后重读清单继续原动作，取消 = 明确放弃。
- **[x] ② 已加自动化测试**
  - `fushi/test/pages/home_video_discovery_managed_source_guard_test.dart`（PR #1018 复审新增，**接线守卫**）：两个入口必须走 `_managedVideoDownloadSourcesOrPrompt`、不得自己裸调 `getManagedVideoDownloadSources`、这三个方法体内不得再出现 `media_source_no_sources`（同一个 key 在 `_scrapeAllVideosFromSources` 里是对的，所以只钉这条路径的方法体、不做全文件禁用），且重读仍为空时必须 `_showVideoDiscoveryMessage(t.download_no_managed_video_source)`。原始路径要真 `AppModel`（Drift + 下载后端 + 资源注册表）才跑得到，widget 层不可达，只能在源码层钉。
  - `fushi/test/pages/managed_video_source_prompt_test.dart`：确认 → 来源对话框开一次、返回 true；取消 → 不开对话框、返回 false；标题（`download_video_source_required`）与主按钮（`download_add_video_source`）文案必须不同。原来那条 `expect(find.text('暂无来源'), findsNothing)` 是**恒真断言**（本对话框任何分支都不渲染那个硬编码中文串），已删。
  - 变异实测：把 `home_page.dart` 的第一个入口改回旧的 `sources.isEmpty → snackbar` 写法 → 新守卫 2 条红、`managed_video_source_prompt_test.dart` 仍**全绿**（正是审查指出的覆盖缺口）；删掉「重读仍为空给提示」那段 → 新守卫第 3 条红。
- **[x] ③ 静默死胡同已堵**（PR #1018 复审）：`promptManagedVideoSourceSetup` 返回 true 只表示用户**走进并关掉了**来源对话框，不表示真加成了（来源对话框是通用增删界面，不回报增量）。首修里「返回 true → 重读 → 仍为空 → 直接 return」= 用户点「搜索资源」→ 引导弹窗 → 「添加视频来源」→ 对话框 → 什么都没加就关掉 → 界面上什么都不发生，比修前那句 snackbar 还糟。下载页那条路径上有可停留的空态门（`downloads_page.dart` `_addVideoSource` 关掉后 `setState` 重算，门继续留在页面上说明缺什么），首页发现没有，所以 `_managedVideoDownloadSourcesOrPrompt` 在重读仍为空时必须给回 `download_no_managed_video_source`。
- **备注**：
  - `VideoDownloadBackendUnavailable`（后端配了但连不上，如内置引擎缺运行时）仍按原样透传后端自己的原因，不改成配置引导——用户已经配过了。
  - **剩余面（本轮有意未动，不要当成「已统一出口」）**：同一条件「后端就绪但缺受管视频来源」在 `video_download_subscriptions_panel.dart:232-234`（裸 snackbar 无动作）与 `manual_download_task_dialog.dart:409-414`（红字无动作）仍是死胡同。这三处的真相源本应是 `fushi/lib/src/pages/implementations/downloads_resource_gap.dart:39` 的 `findDownloadsResourceGap` + sealed `DownloadsResourceGap`（BUG-1706 正为此而建），本 PR 没复用它——`promptManagedVideoSourceSetup` 是首页发现这一条路径的出口，不是全局统一出口。收敛到 `findDownloadsResourceGap` 是后续独立一条。
