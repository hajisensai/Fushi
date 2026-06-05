# 多平台适配计划审查报告

> 日期：2026-05-17
> 审查范围：`docs/specs/2026-05-16-multiplatform-design.md` + `docs/plans/2026-05-16-phase0-monorepo-extraction.md`
> 方法：对照实际代码库验证文档中每项技术声明

---

## Round 1: 事实验证 + 架构缺陷

### Scope

- 验证 hoshidicts C++ 统计数据
- 验证 NLP/词形还原依赖链（ve_dart, MeCab）
- 验证 pubspec.yaml 依赖清单
- 验证模块耦合度（language → dictionary → models）
- 验证 audiobook 文件完整性

---

### Findings

#### HBK-AUDIT-001: language 模块循环依赖 — 致命架构缺陷

- **severity:** CRITICAL
- **status:** OPEN
- **file:** `hibiki/lib/src/language/language.dart:7-11`, `implementations/*.dart`
- **根因：** Phase 0 计划将 `language/` 放入 `hibiki_core`（最底层包），将 `dictionary/` 放入 `hibiki_dictionary`（依赖 `hibiki_core`）。但实际代码中 `language.dart` 及全部三个 implementation 都 `import 'package:hibiki/dictionary.dart'` 和 `import 'package:hibiki/src/dictionary/hoshidicts.dart'`。这产生循环依赖：`hibiki_core` → 需要 dictionary → `hibiki_dictionary` → 需要 `hibiki_core`
- **影响：** Task 3 按原计划执行会直接编译失败，melos 无法解析循环包依赖
- **修复建议：**
  - 方案 A：将 `language/` 整体移入 `hibiki_dictionary`（因为它本质上是词典查询的上层）
  - 方案 B：在 `hibiki_core` 只放 `Language` 抽象类（去除所有 dictionary import），language implementations 留在 app 或 `hibiki_dictionary`
  - 方案 C：通过 callback/interface 注入词典能力，解耦 language 对具体词典实现的依赖
- **验证方式：** 修改计划后 `melos bootstrap` + `dart analyze` 通过

---

#### HBK-AUDIT-002: language 模块依赖 God Object AppModel

- **severity:** HIGH
- **status:** OPEN
- **file:** `hibiki/lib/src/language/language.dart:9` → `package:hibiki/models.dart` → `app_model.dart` (3,456 行)
- **根因：** `language.dart` 导入 `package:hibiki/models.dart`，后者导出 `app_model.dart`。AppModel 是 3,456 行的 God object，包含全局状态、导航、媒体播放等。语言模块不可能把整个 AppModel 拖入任何 package。
- **影响：** 即使解决了 HBK-AUDIT-001 的循环依赖，language 模块仍然无法直接搬出 app，因为它引用了 AppModel 中的方法或属性。
- **修复建议：** 分析 language.dart 实际从 AppModel 使用了哪些接口（大概率是 database accessor 或 preference），定义窄接口注入。需要在执行前做依赖分析。
- **验证方式：** 移出后 `dart analyze` 零 error

---

#### HBK-AUDIT-003: language 模块依赖 UI 工具（utils.dart）

- **severity:** MEDIUM
- **status:** OPEN
- **file:** `hibiki/lib/src/language/language.dart:10` → `package:hibiki/utils.dart`
- **根因：** `utils.dart` 导出 Flutter UI 组件（widget）、MethodChannel wrapper、i18n strings 等。这些不属于纯逻辑层。
- **影响：** 即使 language 搬到 package，也会拖入 Flutter UI 依赖，违反 "pure Dart core" 的设计目标
- **修复建议：** 审计 language 实际用了 utils 中的哪些符号，可能只是 i18n strings 和 error log。这些可以先搬入 core。
- **验证方式：** 拆分后 `dart analyze` 通过

---

#### HBK-AUDIT-004: ve_dart 不存在 — 设计文档错误

- **severity:** HIGH
- **status:** OPEN
- **file:** `docs/specs/2026-05-16-multiplatform-design.md` § 3.5
- **根因：** 设计文档声称 "Ve 词形还原: ve_dart（纯 Dart，git 依赖）— 直接复用，天然跨平台"。但实际上：
  - `ve_dart` 不在 `pubspec.yaml` 中
  - 全局 grep `ve_dart` 零结果
  - 词形还原（deinflection）完全由 hoshidicts C++ 引擎内部的 `deinflector.cpp` 处理
  - FFI 的 `hoshidicts_lookup` 返回 `deinflected` 字段和 `trace`，是 C++ 侧计算的
- **影响：** 设计文档给出了错误的技术依赖关系，Phase 0 的 `hibiki_dictionary` 包定义了不存在的 "Ve integration" 目录 (`nlp/`)
- **修复建议：** 删除 § 3.5 中关于 ve_dart 的全部内容。移除 Phase 0 中 `packages/hibiki_dictionary/lib/src/nlp/` 目录。明确说明 deinflection 是 hoshidicts 内建能力。
- **验证方式：** 文档与代码一致

---

#### HBK-AUDIT-005: mecab_dart 不是当前依赖 — 设计文档错误

- **severity:** HIGH
- **status:** OPEN
- **file:** `docs/specs/2026-05-16-multiplatform-design.md` § 3.5, § 4 依赖替换清单
- **根因：** 设计文档声称 "MeCab 分词: mecab_dart 0.1.3（Android native binding）" 是当前依赖。但实际上：
  - `mecab_dart` 不在 `hibiki/pubspec.yaml` 中
  - `hibiki/lib/` 中 grep `mecab` 零结果
  - 仅在 `ci/patches/hosted/mecab_dart-0.1.3/`（CI 补丁）和 `chisa/`（旧项目）中存在
  - `hibiki/assets/` 中没有 `ipadic_japanese/` 或 `ipadic_korean/`（只在 `chisa/assets/`）
  - 当前日语分词由 hoshidicts 的 scan-based lookup 实现（不需要外部分词器）
- **影响：** 设计文档中 "MeCab 跨平台方案" 整个章节（编译 MeCab C、CMake 构建、native/mecab/ 目录）都是解决不存在的问题。Phase 1 路线图中 "Week 1-2: MeCab Windows DLL 编译" 是无效工作。
- **修复建议：**
  - 删除 § 3.5 MeCab 相关内容
  - 删除 § 4 依赖替换清单中 mecab_dart 条目
  - 删除路线图中 MeCab DLL 编译任务
  - 如果未来确实需要分词（如 NLP 功能扩展），作为独立 Feature 计划，不应混入多平台适配
- **验证方式：** 文档与代码一致

---

#### HBK-AUDIT-006: wakelock 已替换 — 设计文档过时

- **severity:** LOW
- **status:** OPEN
- **file:** `docs/specs/2026-05-16-multiplatform-design.md` § 4 依赖替换清单
- **根因：** 设计文档将 "wakelock (fork)" 列为待替换依赖，建议替换为 `wakelock_plus`。但实际 `pubspec.yaml` 已经使用 `wakelock_plus: ^1.1.4`（不是 fork）。这个"待办"已经完成了。
- **影响：** 轻微——路线图中的工作量估算高了一点
- **修复建议：** 从 § 4 替换清单中移除 wakelock 条目，或标记为"已完成"
- **验证方式：** 文档一致性

---

#### HBK-AUDIT-007: hoshidicts C++ 统计数据不准确

- **severity:** LOW
- **status:** OPEN
- **file:** `docs/specs/2026-05-16-multiplatform-design.md` § 3.1
- **根因：**
  - 声称 "3,768 行核心 C++" → 实际 ~3,377 行 .cpp + 236 行 .hpp = 3,613 行
  - 声称 "12 个公开 C 函数" → 实际 16 个（hoshidicts_import, free_import_result, create, destroy, add_term_dict, add_freq_dict, add_pitch_dict, load_transforms, query, free_query_result, lookup, free_lookup_results, get_styles, free_styles, get_media, free_media）
  - 声称 "__android_log_print 4 处调用" → 实际 6 处（query.cpp:1, importer.cpp:3, deinflector.cpp:2 via macro）
  - FFI 391 行 ✓ 准确
- **影响：** 不影响技术决策，但精确数字不准确会降低文档可信度
- **修复建议：** 更正数字：~3,600 行核心 C++ + 391 行 FFI，16 个公开 C 函数，6 处 android log
- **验证方式：** `wc -l` / grep 验证

---

#### HBK-AUDIT-008: Phase 0 audiobook 文件清单不完整

- **severity:** MEDIUM
- **status:** OPEN
- **file:** `docs/plans/2026-05-16-phase0-monorepo-extraction.md` Task 7
- **根因：** Plan 中 Task 7 列出了约 19 个 audiobook 文件要移到 `hibiki_audio`。但 `hibiki/lib/src/media/audiobook/` 目录实际有 37+ 个 .dart 文件。未被提及的 18 个文件包括：
  - UI 文件：`audiobook_import_dialog.dart`, `audiobook_play_bar.dart`, `book_import_dialog.dart`
  - 仓库/存储：`bookmark_repository.dart`, `favorite_sentence_repository.dart`, `reader_position_repository.dart`, `srt_book_repository.dart`
  - 模型：`reader_position_model.dart`, `reading_statistic_model.dart`, `srt_book_model.dart`
  - 工具：`text_file_io.dart`, `text_to_epub.dart`, `reading_time_tracker.dart`, `floating_lyric_channel.dart`, `highlight_bridge.dart`, `lyrics_mode_html.dart`, `reading_statistic_idb_reader.dart`, `ttu_idb_reader.dart`
- **影响：** 如果只移部分文件，剩余文件会因为 import 断裂而编译失败。或者如果 UI 文件留在 app，需要确认它们不被 audio package 的文件所引用。
- **修复建议：**
  - UI/Dialog 文件（`*_dialog.dart`, `*_play_bar.dart`）留在 app
  - Repository 和 Model 文件应归入 `hibiki_core` 或 `hibiki_audio`（取决于是否依赖 Drift）
  - 明确分类每个文件的归属并更新 Task 7
- **验证方式：** 完整文件清单 + 编译通过

---

#### HBK-AUDIT-009: anki_view_model.dart 未纳入 Phase 0 计划

- **severity:** LOW
- **status:** OPEN
- **file:** `hibiki/lib/src/anki/anki_view_model.dart`
- **根因：** Plan Task 6 只提到 `anki_models.dart`, `anki_repository.dart`, `lapis_preset.dart`。但目录中还有 `anki_view_model.dart`。
- **影响：** 可能不影响（view_model 可能应该留在 app），但需要确认其 import 不会被搬走的文件所断裂。
- **修复建议：** 如果 view_model 只被 page 引用，留在 app。在计划中明确注明。
- **验证方式：** 编译通过

---

#### HBK-AUDIT-010: DictionaryEngine 抽象接口遗漏 4 个 FFI 函数

- **severity:** MEDIUM
- **status:** OPEN
- **file:** `docs/specs/2026-05-16-multiplatform-design.md` § 2.3
- **根因：** 设计文档定义的 `DictionaryEngine` 接口只包含 `importDictionary`, `lookup`, `query`, `getStyles`, `getMedia`, `dispose`。但实际 FFI 暴露 16 个函数，其中至少 `addTermDict`, `addFreqDict`, `addPitchDict`, `loadTransforms` 是独立的公开操作，不包含在抽象接口中。
- **影响：** 抽象接口不完整。如果其他代码直接调用这些函数（很可能——词典加载需要逐个注册），包外代码无法通过接口访问。
- **修复建议：** 审计 `hoshidicts.dart` 的公开方法，补全 `DictionaryEngine` 接口或文档化哪些操作是内部实现细节。
- **验证方式：** 接口覆盖全部外部调用点

---

#### HBK-AUDIT-011: hibiki_dictionary pubspec 遗漏 dio 依赖

- **severity:** LOW
- **status:** OPEN
- **file:** `docs/plans/2026-05-16-phase0-monorepo-extraction.md` Task 5 Step 4
- **根因：** Plan 将 `dictionary_downloader.dart` 移入 `hibiki_dictionary`，但该文件很可能使用 `dio` 包（项目 pubspec 有 `dio: ^5.1.1`）。`hibiki_dictionary/pubspec.yaml` 的依赖列表中没有 `dio`。
- **影响：** 编译失败
- **修复建议：** 确认 downloader 是否使用 dio，如果是则加入 pubspec。或者将 downloader 留在 app（它可能是 UI 层的下载管理）。
- **验证方式：** `dart analyze` 通过

---

### 评估总结

| 类别 | 数量 |
|------|------|
| CRITICAL（阻断执行） | 1 (HBK-AUDIT-001) |
| HIGH（需修改计划） | 3 (002, 004, 005) |
| MEDIUM（需补充） | 3 (003, 008, 010) |
| LOW（需更正） | 4 (006, 007, 009, 011) |

**结论：Phase 0 计划不能按当前形式执行。** 必须先解决 HBK-AUDIT-001（循环依赖）和 HBK-AUDIT-004/005（虚构依赖），否则：
- Task 3（language 提取）会产生不可解析的包依赖
- NLP/MeCab 相关设计和任务是在解决不存在的问题
- 工期估算因包含无效工作而偏高

### Next Scope

修复上述 11 个问题后，需要进一步审查：
- `app_model.dart` 中被 language 模块引用的具体接口
- `structured_content.mapper.dart`（dart_mappable 生成代码）的跨包构建兼容性
- Drift codegen 在 monorepo 跨包场景的已知问题
- flutter_inappwebview fork 的实际自定义改动范围

---

## Round 2: 文档修复

### Scope

对 Round 1 发现的 11 个问题在两份文档中做修正。

### 已修复项

| Finding | 修复内容 | 状态 |
|---------|---------|------|
| HBK-AUDIT-001 | 设计文档：language 模块从 `hibiki_core` 改到 `hibiki_dictionary`；包依赖图更新；Phase 0 Task 3 改为只提取 `LanguageConfig` 接口到 core；Task 5 新增 language 文件复制步骤和解耦说明 | FIXED |
| HBK-AUDIT-002 | Phase 0 Task 5 新增 WARNING：language.dart 依赖 AppModel 需预先解耦，估计 3-5 天 | DOCUMENTED |
| HBK-AUDIT-003 | Phase 0 Task 5 Step 5 新增审计清单：列出 language.dart 的 5 个 app import 及预期处理方式 | DOCUMENTED |
| HBK-AUDIT-004 | 设计文档 §3.5：完全重写，改为记录 hoshidicts 内建 deinflection；移除 ve_dart 所有引用；Phase 0 移除 nlp/ 目录 | FIXED |
| HBK-AUDIT-005 | 设计文档 §3.5：移除 MeCab 章节；§4 移除 mecab_dart 条目；路线图 Phase 1/2/3 移除 MeCab DLL/dylib/xcframework 任务；风险表移除 MeCab 条目 | FIXED |
| HBK-AUDIT-006 | 设计文档 §4：wakelock 条目从 "fork → wakelock_plus" 改为 "wakelock_plus 1.1.4（已完成迁移）" | FIXED |
| HBK-AUDIT-007 | 设计文档 §3.1：3,768→~3,600 行、12→16 个函数、4→6 处 android log、新增 "内建 deinflector" 说明 | FIXED |
| HBK-AUDIT-008 | Phase 0 Task 7：完整列出 37+ 文件的分类（哪些进 audio 包、哪些留 app），含 UI 文件、MethodChannel 文件、迁移文件的保留理由 | FIXED |
| HBK-AUDIT-009 | Phase 0 Task 6：新增 `anki_view_model.dart` 保留说明 | FIXED |
| HBK-AUDIT-010 | 设计文档 §2.3：DictionaryEngine 接口补全 addTermDict/addFreqDict/addPitchDict/loadTransforms，返回类型校正 | FIXED |
| HBK-AUDIT-011 | Phase 0 Task 1：hibiki_dictionary pubspec 新增 `dio: ^5.1.1` 和 `collection`，附注说明 | FIXED |

### 仍需后续工作

| 项 | 说明 |
|----|------|
| AppModel 依赖分析 | 需要实际分析 `language.dart` 从 AppModel (3,456行) 中使用了哪些方法，设计窄接口。这是 Phase 0 执行时最大的不确定性。 |
| dart_mappable 跨包 | `structured_content.mapper.dart` 是 dart_mappable 生成的代码，移到新包后可能需要重新生成。需要验证 `dart_mappable_builder` 在 workspace 模式下的行为。 |
| Drift 跨包 codegen | Drift 的 `database.g.dart` 引用 `tables.dart` 的相对路径。移到 `hibiki_core` 后需要 `dart run build_runner build` 重新生成。已在 Task 4 Step 4 中覆盖，但需确认 drift_dev 在 workspace 模式下无问题。 |
| inappwebview fork 审计 | 6.x 升级 PoC (Task 9) 需要先 diff fork vs upstream 列出全部自定义改动。当前只有高级别的 6 项分类，没有具体代码级别的差异清单。 |

---

## Round 3: AppModel 依赖分析

### Scope

深入分析 `language.dart` 及所有实现对 AppModel/utils.dart 的实际依赖，确定解耦方案。

### Findings

#### 依赖审计结果

| 文件 | AppModel 使用 | utils.dart 使用 | dictionary.dart | hoshidicts.dart |
|------|-------------|----------------|-----------------|-----------------|
| `language.dart` | 2 处参数签名 (`getTermReadingOverrideWidget`, `getPitchWidget`)，基类不访问任何属性 | 导入但未使用 | DictionarySearchResult, DictionarySearchParams, DictionaryEntry, DictionaryFormat 类型 | HoshiLookupResult, HoshiGlossaryEntry, HoshiDicts.instance |
| `japanese_language.dart` | `appModel.dictionaryFontSize` (4 处: L218, L244, L275, L299) | 导入但未使用 | DictionaryEntry, DictionarySearchResult | HoshiDicts.isInitialized, HoshiDicts.instance.lookup() |
| `chinese_language.dart` | **不导入不使用** | 导入但未使用 | YomichanFormat.instance | HoshiDicts.isInitialized, HoshiDicts.instance.lookup() |
| `english_language.dart` | **不导入不使用** | **不导入不使用** | MigakuFormat.instance | **不使用** |
| `language_utils.dart` | **不导入不使用** | ErrorLogService.instance.log() (1处) | DictionaryEntry (类型引用) | **不使用** |

#### 结论

AppModel 的 3,456 行 God object 中，language 模块仅使用 **1 个 double 属性** (`dictionaryFontSize`)。

**解耦方案（已写入 Phase 0 计划）：**
1. 将 `Language.getTermReadingOverrideWidget()` 和 `getPitchWidget()` 的 `AppModel appModel` 参数改为 `double dictionaryFontSize`
2. `JapaneseLanguage` 中 4 处 `appModel.dictionaryFontSize` 直接用新参数
3. 移除 Chinese/English 的无用 utils.dart import
4. 将 `ErrorLogService` 移到 `hibiki_core`
5. dictionary/hoshidicts 依赖在 `hibiki_dictionary` 包内变为相对引用，无需解耦

**估计工作量：1-2 天**（原预估 3-5 天，下修）

---

## Round 4: 技术验证（codegen / Drift / WebView fork）

### Scope

验证三个 Phase 0 执行风险点：
1. dart_mappable 跨包 codegen 行为
2. Drift database 耦合度
3. flutter_inappwebview fork 实际使用范围

### Findings

#### HBK-AUDIT-012: dart_mappable 使用 part 文件，移动后需重新生成

- **severity:** LOW
- **status:** DOCUMENTED
- **file:** `hibiki/lib/src/dictionary/structured_content.dart:5`, `structured_content.mapper.dart:8`
- **事实：** `structured_content.mapper.dart` 是 `part of 'structured_content.dart'` 文件。9 个 `@MappableClass` 注解类，含自定义 Hook（`ContentHook`）。生成文件 61,845 字节。
- **影响：** 移到 `hibiki_dictionary` 后，`part` 路径需要更新，然后运行 `dart run build_runner build` 重新生成。不会有逻辑问题，只是构建步骤。
- **修复建议：** 已在 Task 5 流程中覆盖。确保 `dart_mappable_builder` 在 `hibiki_dictionary/pubspec.yaml` 的 dev_dependencies 中。
- **验证方式：** 重新生成后 `dart analyze` 通过

#### HBK-AUDIT-013: Drift 数据库完全自包含 — 提取最干净的模块

- **severity:** INFO
- **status:** VERIFIED
- **file:** `hibiki/lib/src/database/database.dart`, `tables.dart`
- **事实：**
  - 20 张表，`part 'database.g.dart'`（485 KB 生成文件）
  - 唯一内部依赖：`import 'package:hibiki/src/database/tables.dart'`（同目录）
  - **零**业务逻辑耦合：不导入 language、dictionary、models、utils 中的任何内容
  - 外部依赖仅 `drift`, `sqlite3_flutter_libs`, `path`, `dart:io`, `dart:convert`
- **影响：** Task 4（数据库提取）是 Phase 0 最简单的步骤。文件搬迁 → 改 import → 重新 build_runner → 完成。
- **修复建议：** 无需修改计划。

#### HBK-AUDIT-014: inappwebview 使用点比设计文档列出的更广

- **severity:** MEDIUM
- **status:** OPEN
- **file:** `docs/specs/2026-05-16-multiplatform-design.md` § 5
- **事实：** 设计文档列出 6 个自定义点。实际审计发现 10 个文件导入 inappwebview，使用模式更复杂：

  | 文件 | 用途 | 6.x 风险 |
  |------|------|---------|
  | `dictionary_popup_webview.dart` | InAppWebView + 11 个 JS handler + shouldInterceptRequest | 中 |
  | `reader_hoshi_page.dart` | InAppWebView + JS handler + evaluateJavascript | 中 |
  | `highlight_bridge.dart` | evaluateJavascript 注入 CSS Highlights API | 低 |
  | `audiobook_bridge.dart` | evaluateJavascript + JS handler（音频同步） | 低 |
  | `ttu_idb_reader.dart` | **HeadlessInAppWebView** 读取 IndexedDB | 低（迁移代码） |
  | `reading_statistic_idb_reader.dart` | **HeadlessInAppWebView** 读取统计 | 低（迁移代码） |
  | `audiobook_play_bar.dart` | 传递 controller 引用 | 低 |
  | `main.dart` | **HeadlessInAppWebView** WebView 引擎预热 | 低 |

  **设计文档遗漏的关键模式：**
  - `HeadlessInAppWebView`（无头 WebView）用于 IndexedDB 访问和引擎预热 — 设计文档只提到了有界面的 WebView
  - CSS Highlights API 注入 — 非标准浏览器 API 使用
  - 11+ JavaScript handler 注册模式

- **影响：** Task 9（PoC）的验证范围需要扩展，不只测 6 项
- **修复建议：** 在设计文档 §5 添加 HeadlessInAppWebView 使用说明。在 Phase 0 Task 9 Step 1 中添加完整的文件级审计要求。
- **验证方式：** PoC 覆盖全部 10 个文件的 API 调用

#### HBK-AUDIT-015: hibiki_dictionary pubspec 缺少 dart_mappable dev 依赖

- **severity:** LOW
- **status:** OPEN
- **file:** `docs/plans/2026-05-16-phase0-monorepo-extraction.md` Task 1 Step 6
- **根因：** `structured_content.dart` 使用 `@MappableClass`，需要 `dart_mappable` 运行时依赖和 `dart_mappable_builder` build 依赖。当前 pubspec 定义中两者都缺。
- **修复建议：** 在 `hibiki_dictionary/pubspec.yaml` 中添加：
  ```yaml
  dependencies:
    dart_mappable: ^4.0.0-dev.1
  dev_dependencies:
    dart_mappable_builder: ^4.0.0-dev.2
    build_runner: ^2.4.6
  ```
- **验证方式：** `build_runner build` 成功

### 总结

| 组件 | 提取难度 | 说明 |
|------|---------|------|
| Drift 数据库 | **最低** | 完全自包含，零业务耦合 |
| 词典引擎/FFI | **低-中** | 自包含 + 多平台 _openLib 改造 |
| Language 模块 | **中** | 需改 1 个 AppModel 参数 + 移 ErrorLogService |
| dart_mappable 生成代码 | **低** | 重新 build_runner 即可 |
| Anki | **低** | MethodChannel 留在 app，接口+模型进包 |
| Audio + 解析器 | **中** | 37+ 文件需分类 + 6 个解析器依赖 AudioCue/text_file_io，一起进 hibiki_audio |

---

## Round 5: 测试验证

### Scope

实际执行工具链验证 Phase 0 计划的可行性：
1. `flutter analyze` — 代码库健康检查
2. `flutter test` — 单元测试基线
3. `melos bootstrap` — 工作区搭建可行性（隔离 worktree 测试）
4. 解析器隔离度分析 — 验证 Task 3 的文件分配
5. AGP 版本兼容性

### Findings

#### HBK-AUDIT-016: flutter analyze 通过（0 错误 0 警告）

- **severity:** INFO
- **status:** VERIFIED
- **事实：** `flutter analyze` 返回 13 个 info-level lint 提示（prefer_const_declarations），零错误、零警告。
- **结论：** 代码库在结构重构前状态健康。

#### HBK-AUDIT-017: flutter test 587 全部通过

- **severity:** INFO
- **status:** VERIFIED
- **事实：** `flutter test` 在 16 秒内完成 587 个测试，全部通过。
- **结论：** 单元测试基线完整。Phase 0 重构后可用作回归验证。

#### HBK-AUDIT-018: melos bootstrap 验证通过（隔离 worktree）

- **severity:** HIGH
- **status:** VERIFIED
- **事实：** 在独立 git worktree 中创建了 Task 1 定义的完整 workspace 结构（root pubspec.yaml、melos.yaml、5 个空包骨架），执行 `dart run melos bootstrap` 成功。
- **发现的修正：**
  - SDK 约束必须 `>=3.5.0`（workspace resolution 功能需要），计划中原写 `>=3.0.0` — **已修正全部 12 处**
  - Melos 7.x 必须作为 root pubspec 的 `dev_dependencies` 声明，仅全局安装不够 — **已修正 Task 1 Step 2**
  - `melos bootstrap` 命令须改为 `dart run melos bootstrap` — **已修正 Task 1 Step 8**
- **结论：** Task 1（workspace 搭建）的步骤在修正后可执行。

#### HBK-AUDIT-019: AGP 版本问题 — 已验证不存在

- **severity:** ~~HIGH~~ → INFO
- **status:** RESOLVED — 原判断错误
- **file:** `hibiki/android/settings.gradle`
- **事实：** AGP 8.3.2 + Gradle 8.12 构建 debug APK 成功。AGP 8.9.1 实际上在 Google Maven 仓库中不存在。原 worktree 构建失败是因为 worktree 中只有空骨架包（非真实 app），与 AGP 版本无关。
- **结论：** 保持 AGP 8.3.2 即可，无需升级。

#### HBK-AUDIT-020: 解析器不可提取到 hibiki_core — 已修正分配

- **severity:** HIGH
- **status:** FIXED
- **事实：** 原 Task 3 将 6 个解析器放入 `hibiki_core`。实际依赖分析发现：
  - **全部 6 个解析器**导入 `audiobook_model.dart`（`AudioCue` 类，8 个领域专属字段）
  - **全部 6 个解析器**导入 `text_file_io.dart`（`flutter_charset_detector` 包）
  - vtt/lrc/ass 解析器依赖 `srt_parser.dart`（解析器间耦合）
  - srt_parser 导入 `audiobook_bridge.dart`（show import）
  - lrc_parser 导入 `srt_book_repository.dart`（show import）
  - smil_parser 额外需要 `package:xml`
- **修正：**
  - Task 3 重写为仅提取 `LanguageConfig` 接口和共享模型（不含解析器）
  - Task 7 扩展为同时提取解析器 + audiobook 核心文件到 `hibiki_audio`
  - File Structure Map 中 `parsers/` 从 `hibiki_core` 移到 `hibiki_audio`
  - 设计文档 §2.1、§2.2、§6 同步更新
- **验证方式：** 两份文档内容一致，无矛盾引用

### 文档一致性验证

| 检查项 | 设计文档 | Phase 0 计划 | 一致？ |
|--------|---------|-------------|--------|
| 解析器位置 | hibiki_audio（§2.1, §6） | Task 7 hibiki_audio | YES |
| hibiki_core 内容 | LanguageConfig + 模型 + DB + i18n（§2.1） | Task 3 LanguageConfig only, Task 4 DB | YES |
| Language 抽象 | LanguageConfig 接口 in core（§2.2） | Task 3 Step 1 | YES |
| Language 实现 | hibiki_dictionary（§2.2） | Task 5 Step 4b | YES |
| AppModel 依赖 | dictionaryFontSize only（§2.2 耦合说明） | Task 5 Step 5 | YES |
| hoshidicts 统计 | ~3,600行 16函数（§3.1） | (引用设计文档) | YES |
| ve_dart/MeCab | 不存在（§3.5 已移除） | 无引用 | YES |
| SDK 约束 | (不涉及) | >=3.5.0 <4.0.0 (全部 12 处) | YES |
| Melos 安装 | (不涉及) | dev_dependency + dart run melos | YES |

### Next Scope

Round 6：如有必要，验证 Task 9（inappwebview 6.x PoC）审计清单完整性。当前所有高优先级问题已修正或记录。
