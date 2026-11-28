## BUG-5489 · 词典文件缺失时界面静默只显示无释义
- **报告**：2026-11-26（反馈 cH-HbP8XkQ / nrMj_CBwCC 追查中确认：Android 用户书与词典数据丢失，丢失本身的根因待用户补信息，本条只修「丢了之后界面不说」）
- **真实性**：✅ 真 bug。词典元数据在 `dictionary_metadata`，文件在 `<书库根>/dictionaryResources/<名>/`（`fushi/lib/src/models/app_model.dart:5913`）。两边脱节时装载链路只把它当「不进引擎」：
  - 异步排期 `_scheduleDictPathsAsync` 把不存在 / 物化探测失败的目录算成 `exists: false`（`fushi/lib/src/models/app_model.dart:4691`），失败只进错误日志；
  - 同步重建同样只是 `exists: Directory(p).existsSync() && …`（`app_model.dart:4234`）；
  - 目录在但缺必需文件时，C++ `DictionaryQuery::add_dict`（`native/fushidicts/fushidicts_src/query.cpp:433`）读不到 `index.json` / 索引直接 `return`。
  - 没有任何状态被发布到界面：词典列表、开关照旧，查词浮层空态只显示「未找到 + 换个词试试」（`fushi/lib/src/pages/implementations/dictionary_popup_layer.dart:2368`）、首页词典页只显示 `no_search_results`（`home_dictionary_page.dart:1345`），WebView 弹窗同理（`popup_settings_injection.dart` 的 `_noResultsHint`）。书有「找不到书籍文件」、视频有 `video_resource_missing_*`，词典没有对应。
- **[x] ① 已修复** — 新增 `fushi/lib/src/dictionary/dictionary_file_health.dart`：在 Dart 装载层判定「不在（资源根可读但目录没了 / 缺 index.json、记录文件、索引任一组）」与「暂时读不到（资源根列不出来、或探测读失败）」，由 `AppModel._assessDictionaryFileHealth`（异步排期每次重判）与 `_recheckDictionaryFileHealthSync`（同步重建只撤销、不新增）发布到 `DictionaryFileHealthMonitor`。**只判定、不删除任何东西**；资源根读不到一律判「暂时读不到」，不当成删除。界面：词典管理列表顶部横幅 + 行标签 + 详情说明（不在 → 「重新导入 / 删除」，在线来源强制重下不比版本；读不到 → 只说明没删任何东西）；查词浮层空态、首页词典页（空态 + 部分缺失时结果上方横幅）、WebView 弹窗空态在全部 / 部分词典有问题时如实说明。状态变化进数据位置取证环（BUG-5490，`AppModel.dictionaryFiles`）。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/dictionary_file_health_test.dart`（判定真值表、必需文件判据、查词说明、真 AppModel 异步排期：不在 / 缺文件 / 隐藏词典 / 文件回来撤销 / 资源根读不到全判读不到且不删元数据、三处查词表面接线守卫）；`fushi/test/pages/dictionary_manager_page_test.dart`（横幅、行标签、详情「重新导入 / 删除」、恢复后消失、读不到时不给删除，含 Apple 设计）。
- **备注**：「先闪一下旧结果」未单独定位（推测是查词历史 / 结果缓存先展示、重查后变空），本条只保证空态如实说明原因。未在真机上复测（需要构造「元数据在、文件被删」的 Android 设备状态）。
