## BUG-1874 · 「下载」设置分类里的下载页入口副标题也叫「下载设置」
- **报告**：2026-08-25（用户：「下载设置里面怎么还有一个下载设置」）
- **真实性**：✅ 真 bug。`fushi/lib/src/settings/settings_schema_downloads.dart:36-38`（修前）：destination 的 `summary: t.download_settings`（「下载设置」），其第一条 `SettingsNavigationItem('downloads.open_page')` 的 `subtitle` 也是 `t.download_settings`——同一个词出现两层，而这条导航项打开的其实是**下载页**（`DownloadsPage`：任务 / 资源 / 订阅），不是任何设置。
- **[x] ① 已修复** — `c953b9494d`：副标题改为新 key `settings_downloads_open_page_hint`（「打开下载页（任务 / 资源 / 订阅）」）。
- **[x] ② 已加自动化测试** — `fushi/test/settings/settings_downloads_open_page_subtitle_guard_test.dart`：源码守卫，`downloads.open_page` 项的 subtitle 必须是 `settings_downloads_open_page_hint` 且不得回到 `download_settings`。变异实测：改回 `t.download_settings` → 红。
  PR #1018 复审补一条**不变式**断言：源码守卫只钉 key 名，把新 key 的**值**改成「下载设置」照样绿；真正的不变式是「subtitle 文案 ≠ 本分类 summary 文案」，现在 en / zh-CN 两个 locale 各断言一次 `t.settings_downloads_open_page_hint != t.download_settings`。变异实测：把 zh-CN 生成值改成「下载设置」→ 原 key 名那条仍绿、新不变式那条红。
- **备注**：新 key `settings_downloads_open_page_hint` 经 `i18n_sync --add` 加入 17 个语言文件；除 en / zh-CN 外 15 语暂回落英文待译（与本批其余新 key 同）。
