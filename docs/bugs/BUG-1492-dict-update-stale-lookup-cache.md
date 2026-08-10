## BUG-1492 · 词典覆盖导入/在线更新后查词缓存不失效，更新完的词典查不到词
- **报告**：2026-08-10（用户：视频页字幕点「アケコン」查不到，只匹配到 2 字的「アケ → あけ」，弹窗来源标签里没有 Pixiv Light；同一个词在「查词」页搜得到，来源正是 Pixiv Light [2026-02-01]。用户随后「重新导入就能查到了」）
- **真实性**：✅ 真 bug

### 根因

词典元数据的**写/删**没有和「引擎重载 + 查词缓存失效」绑在一起：

| 位置 | 重载引擎 | 清查词缓存 |
|---|---|---|
| `fushi/lib/src/models/dictionary_repository.dart:168` `persistDictionary`（修前） | ✅ `_onCacheRebuild` | ❌ |
| `fushi/lib/src/models/dictionary_repository.dart:256` `deleteDictionaryMeta`（修前） | ❌ | ❌ |
| `dictionary_repository.dart:181` `updateDictionaryOrder` | ✅ | ✅ |
| `fushi/lib/src/models/app_model.dart:4222` `deleteDictionary` | ✅ | ✅ |
| `app_model.dart:4177` `toggleDictionaryHidden` | ✅ | ✅ |

覆盖导入/在线更新的替换分支（`fushi/lib/src/models/dictionary_import_manager.dart:383-397`）顺序是：

1. `dictionary_import_manager.dart:335` 导入**开头**清一次缓存；
2. `:351` native FFI 整包导入到 `import_temp`（30MB 的 Pixiv 包要几十秒到几分钟）；
3. `:393` 删旧词典目录、`:394` `deleteDictionaryMeta` 删旧 meta —— **引擎不重载**，其 in-memory 索引仍指着已被删掉的目录；
4. `:405` 把新包 publish 到位；
5. `:437` `persistDictionary` 写新 meta → 重载引擎 —— **但不清缓存**。

于是第 3~5 步之间存在一个「引擎与磁盘不一致」的窗口。窗口内任何一次查词都会拿到「缺这本词典」的结果并写进 `_dictionarySearchCache` / `_ffiLookupCache`（`app_model.dart:4427` / `:4410`），而收尾没人清 → 同一个查询串此后永远重放缺词典的旧结果，直到下次导入或重启 app。

窗口在两种更新下都会被撞上：
- 启动时的**静默自动更新** `app_model.dart:4078` `maybeAutoUpdateDictionaries` —— 无遮罩、无提示，用户此时正常查词；
- 手动更新时用户杀进程/切走（该链路当时既无超时也无取消，见 BUG-1493）。

用户三条现象逐条对上：
- **弹窗查不到**：视频字幕查词的查询串是「点中字位 → 句尾」的长尾串（`fushi/lib/src/pages/implementations/video_fushi_page.dart:328` `subtitleLookupTerm`），被污染的正是这个 key；引擎里没有 Pixiv Light 时，最长匹配退到别的词典有的「アケ」。
- **查词页查得到**：两条路径共用同一个 `app_model.dart:4314` `searchDictionary`、同一个 `FushiDicts` 单例、同一组缓存（子代理逐条核过 maxResults=10 / scanLength=16 / 去屈折 / hidden 过滤全部相同），**唯一差异是查询串**——手打「アケコン」是另一个 cache key，miss 后走真查，命中新导入的词典。
- **「重新导入就好了」**：不是重导修好了词典，而是 `importFromFile` 在**开头**（`:335`）清了一次缓存。

排除项（查过、不是根因）：`forceReplaceExisting` 的替换是**先导新到 temp、再删旧、再发布**，不会留下「旧的删了新的没建好」的半状态；`order`/`hiddenLanguages`/`collapsedLanguages` 由 `:389-390` `preservedSettings` 原样保留，更新后不会变 hidden；`sourceOverride` 只补来源身份字段，不影响启用状态。

- **[x] ① 已修复** — `fushi/lib/src/models/dictionary_repository.dart`：把「重载引擎 + 清查词缓存」收进 `persistDictionary` 与 `deleteDictionaryMeta` 两个真相源，任何调用方都不可能漏补；`fushi/lib/src/models/app_model.dart` 的 `importDictionary` 在 `finally` 里 `dictionarySearchAgainNotifier.notifyListeners()`，让已打开的查词页/弹窗重查（与 delete / reorder 路径对称）。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/dictionary_replace_import_invalidation_test.dart`（4 例：persist / delete 各自的失效对称性、覆盖导入全程窗口污染不得存活、换名更新）。变异实测：分别去掉 `persistDictionary` 与 `deleteDictionaryMeta` 里的失效语句，各打红 2 例，反向替换还原。
- **备注**：修复只保证「缓存与引擎跟着词典集合走」。导入期间那几十秒内查词仍会短暂查不到该词典（引擎里确实没有），但结果不再被固化——这是正确行为，不是遗留缺陷。
