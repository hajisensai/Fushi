## BUG-2707 · 词典在线更新用本地旧 downloadUrl 下载，更新永不生效
- **报告**：2026-09-26（用户：自动更新词典没生效）
- **真实性**：✅ 真 bug。三条更新链路（启动自动更新 `AppModel._autoRedownloadAndReimport`、单本「更新」`_updateSingleDictionary`、「检查更新」`_checkForUpdates`）拉远端 index 时**只取了 `revision`**，下载却用本地记录的 `dictionary.downloadUrl`（`fushi/lib/src/models/app_model.dart` `_autoRedownloadAndReimport` 的 `DictionaryDownloader.download(url: dictionary.downloadUrl)`；`dictionary_dialog_page.dart` `_redownloadAndReimport` 同形），重导后又用 `sourceOverride` 把旧 URL 原样写回 metadata。
  - 2026-09-26 实测用户两套数据根里的可更新词典对远端 index：**Pixiv Light** 本地 `downloadUrl` 钉在 `.../releases/download/2026-03-26/PixivLight_2026-03-26.zip`，远端 index 已声明 `2026-09-26` 的新地址；**COBUILD8** 远端已换成 `COBUILD10.zip`。拿旧地址下载 = 把旧包重导一遍，revision 不变，下一次检查照样报「有新版」，自动更新每轮都白跑、永不生效（旧包地址 404 时则整轮失败、`last_dictionary_update_at` 也不推进）。
  - 地址恒为 `/releases/latest/download/...` 的词典（JMnedict / Jitendex / Jiten）不受影响。
  - 另注：本机开发版与安装版两个库的 `preferences` 里都**没有** `auto_update_dictionaries` 行（即开关在这两个库上从未打开，默认 false）；用户若是在本机观察到「没生效」，还需确认开关已打开。开关写穿路径（`setAutoUpdateDictionaries` → `setPref`）本身正常。
- **[x] ① 已修复** — `DictionaryRemoteIndexResult` 带回远端 index 声明的 `downloadUrl` / `indexUrl`（仅采信 http(s) 绝对地址），新增 `resolveDownloadUrl` / `updatedSourceMetadata`；三条链路改为按远端新版地址下载并回写（与 Yomitan 同口径，缺省才回落本地记录）；删除已无生产调用的 nullable `fetchRemoteIndex`。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/dictionary_update_service_test.dart`（group「BUG-2707 远端 index 的新版地址」，夹具取自真实 Pixiv Light 远端 index）+ `fushi/test/dictionary/dictionary_update_ui_guard_test.dart`（源码守卫：dialog 与 AppModel 两处都必须 `remote.resolveDownloadUrl(` / `remote.updatedSourceMetadata(`，禁止回写或下载本地旧 `downloadUrl`）。
- **备注**：未跑真机端到端（需要真实下载重导数百 MB 词典）；远端 index 形状已用 python 对 8 本真实词典逐一实测。
