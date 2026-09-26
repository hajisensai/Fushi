## BUG-2709 · 词典在线更新：钉版本号的下载地址更新不到新版，旧版导入的词典被判不可更新
- **报告**：2026-09-26（用户：手动更新和 Yomitan / Hoshi 不一样，行尾「更新」按钮要自己下最新词典到本地再选文件；希望顶部一键更新所有词典，Pixiv Light 这种几百 MB 的大词典尤其需要）
- **真实性**：✅ 真 bug，两个根因 + 一个入口问题：
  1. **更新下载的是旧包**：单本 / 批量 / 启动自动更新三条链路都拿本地 metadata 里存的 `downloadUrl` 去下载（`dictionary_dialog_page.dart` `_redownloadAndReimport` 的 `url: dictionary.downloadUrl`，`app_model.dart` `_autoRedownloadAndReimport` 同样）。而这个地址是**已装版本**的 index.json 里写的——MarvNC/pixiv-yomitan 的是钉死版本号的 `.../releases/download/2026-03-26/PixivLight_2026-03-26.zip`（本机开发数据库实测）。远端 index 出了新 revision，下回来的仍是旧包，revision 永远对不上。Yomitan 的口径是用**远端 index 里的 downloadUrl**。
  2. **旧版导入的词典被判不可更新**：`Dictionary.isUpdatable` 只看 metadata；在线更新（TODO-609）之前导入的词典 metadata 里没有来源字段，即使词典目录下的 index.json 声明了 `isUpdatable:true`，行尾按钮也走 `_updateDictionaryFromFile`（让用户选本地文件）——这就是用户看到的「要我自己下一个最新的词典」。
  3. 顶部「检查更新」按钮只在存在 `isUpdatable` 词典时显示（`_buildActionBar`），2 发生时入口整个消失；且远端 index 拉取失败被当成「已是最新」。
- **[x] ① 已修复** — `DictionaryRemoteIndexResult` 带回远端 `downloadUrl`，三条链路统一 `remote.resolveDownloadUrl(本地地址)`（远端优先、缺失回退）；启动期 `_backfillDictionarySourceMetadata` 异步读词典目录 index.json 一次性回填来源字段（`kDictSourceProbeKey` 标记，`persistDictionaries` 批量落库只重载一次引擎）；动作栏首位常驻「更新全部词典」（Cupertino 桌面 / 移动动作栏同样有），无可更新词典时说明原因；检查失败单本提示 `dict_update_check_failed`、批量计入失败；不可在线更新词典的行尾 tooltip 改成「从本地文件更新」。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/dictionary_update_service_test.dart`（远端 downloadUrl 解析与选址、回填判定/合并、用真实 Pixiv index.json 回填后 `isUpdatable` 为真）、`dictionary_update_ui_guard_test.dart`（按钮常驻首位、远端地址、检查失败计失败）、`dictionary_auto_update_test.dart`（自动更新用远端地址、回填接线与批量落库）。
- **备注**：未在真 app 上跑一次完整的 Pixiv 大词典在线更新（需联网下载数百 MB）；逻辑由上述单测与源码守卫覆盖。
