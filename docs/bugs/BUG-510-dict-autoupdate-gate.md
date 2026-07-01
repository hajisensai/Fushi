## BUG-510 · TODO-1075 词典自动更新 isUpdatable gate 在 catalog 导入路径恒空档
- **报告**：2026-07-01（用户：）
- **真实性**：✅ 真 bug（初装 gate 空档 + UB + UI 位置 + i18n 未译）。根因链见下。
- **[x] ① 已修复** — 见提交
- **[x] ② 已加自动化测试** — `hibiki/test/dictionary/dictionary_catalog_updatable_test.dart` + 更新 `dictionary_update_ui_guard_test.dart`
- **备注**：

### 根因（chicken-and-egg：初装永远置不上 isUpdatable）
- `Dictionary.isUpdatable` 是三条件与门（`packages/hibiki_dictionary/lib/src/engine/dictionary.dart:64-67`）：
  `metadata['isUpdatable']=='true' && indexUrl.isNotEmpty && downloadUrl.isNotEmpty`。
- 这三个字段来源只有两处，经 `mergeSourceMetadata`（`hibiki/lib/src/models/dictionary_import_manager.dart:718`，`{...fromIndex, ...override}`）合并：
  ① 词典包内 index.json（`readSourceMetadataFromIndex`）；② `sourceOverride`。
- catalog 在线导入（唯一让新词典首次落库的路径，`hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart` 原 :880）
  只传 `sourceOverride:{'downloadUrl': rec.url}`——不给 isUpdatable、不给 indexUrl。
- 一旦某来源的包内 index.json 不声明 isUpdatable/indexUrl（如 MarvNC / grammar / frequency 打包），
  三条件与门恒 false → `AppModel.maybeAutoUpdateDictionaries`（`hibiki/lib/src/models/app_model.dart:2508`）
  过滤掉全部词典 → `shouldAutoUpdateDictionaries`（`.../dictionary_update_service.dart:32`）恒 false → 自动更新永不执行。
- 唯一会回填 `isUpdatable:'true'` 的路径是**手动更新**（`app_model.dart:2568` / `dictionary_dialog_page.dart:1572`），
  但它们读 `dictionary.indexUrl`——只有词典**已可更新**才可达 → 先有鸡才有蛋，无法自举。

### 次因
- **UB**：`native/hoshidicts/hoshidicts_src/json/yomitan_parser.hpp:12` `bool isUpdatable;` 未初始化；
  源包缺该 key 时 glaze 回写不确定值（可能把无源词典误标可更新）。已改 `= false`。
- **注释矛盾**：`dictionary_dialog_page.dart` 原 `_buildAutoUpdateCard` 注释「开关默认 true」，与
  `preferences_repository.dart:268` `defaultValue: false`（opt-in，todo861 契约）矛盾。已修注释。
- **UI 位置**：自动更新设置卡原插在动作条与分类选择器之间，横切高频操作动线。已移到词典列表之后（页尾）。
- **i18n**：7 个自动更新卡 key + 2 个异名确认 key 在 15 个非 zh-CN 语言仍是英文占位。已补齐。

### 修复（根因向）
1. `RecommendedDictionary` 加派生 getter `indexUrl`（`packages/hibiki_dictionary/lib/src/formats/dictionary_downloader.dart`）：
   对**存在分离 index.json 端点**的来源返回真值——yomidevs releases（`.zip`→`.json` sibling，实测 200）、
   wty（HuggingFace `.../latest/index/wty-ja-<lang>-index.json?download=true`）；其余（MarvNC/Kuuuube/grammar）返回 null。
2. catalog 导入（`dictionary_dialog_page.dart` `_downloadSelectedDictionaries`）：`rec.indexUrl!=null` 时回填
   `{isUpdatable:'true', indexUrl, downloadUrl:rec.url}`（与手动更新路径对齐，初装即可更新）；否则只 `{downloadUrl}`
   （不误标无源词典为可更新）。把可更新性权威信号锚定在 catalog 来源真值，不再脆弱依赖第三方包是否碰巧声明。
3. `yomitan_parser.hpp` `bool isUpdatable = false;`（消 UB）。
4. UI 卡片移到列表后 + 修「默认 true」误注释（→ 默认 false / opt-in）。
5. i18n：`i18n/*.i18n.json` 9 个 key × 15 语言补真实翻译（值级替换，key 不变），`dart run slang` 重生成 + format。

### 测试
- `hibiki/test/dictionary/dictionary_catalog_updatable_test.dart`：
  断言 indexUrl 派生（yomidevs/wty 真值、MarvNC/grammar null）；catalog 导入端到端产出 `isUpdatable==true`；
  导入后 `shouldAutoUpdateDictionaries` 返回 true（修复前恒 false）；无源来源不被误标可更新。
- `hibiki/test/dictionary/dictionary_update_ui_guard_test.dart`：守卫 catalog sourceOverride 回填 isUpdatable+indexUrl。
