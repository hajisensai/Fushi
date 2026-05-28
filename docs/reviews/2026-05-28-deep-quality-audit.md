# Hibiki 深度质量审计报告

**日期**: 2026-05-28
**审计范围**: 全项目 — 504 个 Dart 源文件，~85,000 行代码
**审计维度**: 架构设计、代码实现、工程规范、类型系统、状态管理、异步流程、并发安全、错误处理、资源释放、模块边界、依赖关系、可维护性、可扩展性、性能、安全性、测试覆盖率、CI/CD、构建配置
**特别关注**: AI 生成代码与 vibe coding 场景下的隐性问题

---

## 审计总览

| 维度 | 评分 | 状态 |
|------|------|------|
| 包级架构 | A | 依赖无环，层次清晰 |
| 类级设计 | F | 两个超大 God Object |
| 类型安全 | C | 252 处 dynamic，434 处类型转换 |
| 状态管理 | B- | Riverpod + ChangeNotifier 混用，基本正确 |
| 异步安全 | B+ | mounted 检查到位，Stream 泄漏已修复 |
| 并发安全 | B+ | 阅读器导航 generation counter 模式验证完备，已补 completer 清理 |
| 错误处理 | B | 空 catch 块已添加日志，仍有 generic catch |
| 资源释放 | A- | WebView 泄漏已修复，主要资源正确释放 |
| 安全性 | C+ | JS 注入验证安全，混合内容已修复，凭证明文存储待加密（backlog） |
| 测试覆盖 | C+ | 主应用 59%，packages 接近 0%（CI 已覆盖） |
| CI/CD | B+ | 两条流水线均已覆盖全部 packages |
| 代码重复 | C | Creator 21 个文件重复模式（backlog） |
| 僵尸代码 | A | 僵尸类已删除，lint 规则已启用，30+ 冗余 import 已清理 |

---

## 第一部分：Critical 级别问题

### HBK-AUDIT-001: God Object — AppModel (2,579 行)

- **severity**: CRITICAL
- **status**: OPEN
- **file**: `hibiki/lib/src/models/app_model.dart`
- **根因**: 单一类承载 12 个完全不相关的子系统

**具体数据**:
- 181 个方法
- 226+ 个状态字段
- 12 个职责域: 主题、词典搜索/导入/导出、媒体管理、Anki 集成、文件导出、偏好设置、搜索历史、音频控制、悬浮词典、本地音频 DB、初始化/生命周期、导航
- `initialise()` 方法 170 行 (L970-L1139)
- 46+ import 语句

**影响**: 所有页面通过 `appModel` 访问一切，形成了 Facade 但没有真正的边界。任何修改都有全局影响风险。

**修复建议**: 按职责拆分为 5-7 个独立 Manager/Controller:
1. `ThemeManager` (已部分抽出到 ThemeNotifier)
2. `DictionaryManager` (搜索+导入+导出)
3. `MediaManager` (媒体源管理+历史)
4. `FileManager` (目录+导出)
5. `PreferencesManager` (已部分抽出到 PreferencesRepository)
6. `AudioManager` (音频控制+本地音频)

---

### HBK-AUDIT-002: God Object — ReaderHibikiPage (4,221 行)

- **severity**: CRITICAL
- **status**: OPEN
- **file**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`
- **根因**: 14 个独立 UI 功能塞进一个 StatefulWidget

**具体数据**:
- 121 个方法
- 69+ 个状态字段
- 46 个 import 语句
- 14 个功能域: EPUB 渲染引擎、WebView 管理、有声书/SRT 播放、歌词模式、双页展开、音量键处理、内容样式注入、文本选择/查词、阅读进度追踪、收藏句子、Anki 挖矿、章节导航、手势/输入处理、悬浮歌词/媒体通知同步

**影响**: 无法独立测试任何子功能；修改一处可能影响其他 13 个功能域。

**修复建议**: 提取为独立组件:
1. `AudiobookReaderController` (音频状态机)
2. `LyricsPageWidget` (歌词模式独立 Widget)
3. `SelectionManager` (文本选择逻辑)
4. `ReaderStatsTracker` (阅读统计)
5. `ChapterNavigator` (章节导航状态)

---

### HBK-AUDIT-003: JavaScript 注入风险

- **severity**: ~~CRITICAL~~ → CONFIRMED SAFE (降级)
- **status**: VERIFIED
- **file**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`

**深入审查结论**: 初始审计将此标记为 CRITICAL，但全面审查所有 54 个 `evaluateJavascript()` 调用后确认：
1. 所有字符串值插值都通过 `jsonEncode()` / `_jsStringLiteral(jsonEncode())` 正确转义
2. 所有数字值（int/double）直接插值，不存在注入风险
3. `audiobook_bridge.dart` 中的调用同样使用 `jsonEncode()` 处理
4. `dictionary_popup_webview.dart` 的颜色值来自 `Color` 对象的数字分量

无需修复。代码已正确防御 JS 注入。

---

### HBK-AUDIT-004: Stream 订阅泄漏 — AudioRecorderPage

- **severity**: CRITICAL
- **status**: ✅ FIXED
- **file**: `hibiki/lib/src/pages/implementations/audio_recorder_page.dart`
- **行号**: L265-273

**问题**: 3 个 stream subscription 调用 `.listen()` 但未存储引用、未在 `dispose()` 中取消。

**修复**: 添加 3 个 `StreamSubscription` 成员变量，在 `initialiseAudio()` 中赋值，在 `dispose()` 中 `cancel()`。

---

## 第二部分：High 级别问题

### HBK-AUDIT-005: WebView Controller 未释放

- **severity**: HIGH
- **status**: ✅ FIXED
- **file**: `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart`

**修复**: 添加 `dispose()` override，调用 `_controller?.dispose(); super.dispose();`。

---

### HBK-AUDIT-006: WebView 混合内容策略

- **severity**: HIGH
- **status**: ✅ FIXED
- **file**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`

**修复**: 改为 `MIXED_CONTENT_COMPATIBILITY_MODE`（而非 NEVER_ALLOW，避免破坏含外部 HTTP 资源的 EPUB）。

---

### HBK-AUDIT-007: UI 层直接访问数据库

- **severity**: HIGH
- **status**: BACKLOG — 架构级重构，40+ 处 `appModel.database` 引用
- **受影响文件**: `reader_hibiki_page.dart` (20+处), `reader_hibiki_history_page.dart` (15+处), `collections_page.dart`, `custom_fonts_page.dart` 等

**评估**: Repository 类已存在（`AudiobookRepository`, `SrtBookRepository`, `BookmarkRepository` 等），但 UI 页面直接 `appModel.database` 创建实例而非通过 Provider DI。当前模式功能正确，但违反分层架构。全面 DI 化需要改动 4000+ 行文件，回归风险高。

**建议**: 作为独立 refactoring sprint 执行，不与 bug fix 混合。

---

### HBK-AUDIT-008: Provider 缺少 autoDispose

- **severity**: HIGH
- **status**: BACKLOG — 需要逐 Provider 评估 UX 影响
- **影响**: 全部 15+ Provider 定义

**评估**: 多数 Provider（`appProvider`, `creatorProvider`, `themeProvider`, `profileViewModelProvider`）是刻意全局生命周期，添加 autoDispose 会改变 UX 行为（如 Creator 状态在导航后重置）。需要逐 Provider 审查消费者场景和 `ref.keepAlive()` 需求。

**可安全 autoDispose 的候选**: `selectedTagIdsProvider`, `pipSearchTermProvider`, `pipSearchPositionProvider`, `visibleOnceProvider`。

**建议**: 作为独立 PR，每个 Provider 单独评估并测试。

---

### HBK-AUDIT-009: 阅读器导航竞态条件

- **severity**: HIGH
- **status**: ✅ VERIFIED SAFE + FIXED (completer 缺失已补)
- **file**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`

**深入审查结论**: 初始审计标记多处竞态，但全面分析 generation counter 模式后确认：

1. `_navigateGeneration` 在每个导航方法中递增，所有异步回调在每个 await 点检查 generation，正确拒绝过时回调
2. `_restoreExpectedGeneration` 在 `_onRestoreComplete()` (JS 回调) 中校验，正确防止旧 restore 覆盖新 restore
3. `_currentChapter` 仅在同时递增 `_navigateGeneration` 的方法中修改，双重检查是安全的 belt-and-suspenders
4. `_restoreCompleter` 在每个导航方法中先 complete(false) 旧 completer 再创建新的，生命周期正确
5. 所有等待 completer 的代码都有 timeout fallback（8-10 秒）

**唯一修复**: `reloadWithCurrentSettings()` 递增了 generation 但未清理旧 completer，已添加 completer 生命周期管理。

---

### HBK-AUDIT-010: Creator 模块大量重复代码

- **severity**: HIGH
- **status**: BACKLOG — 21 个文件的 refactoring，功能正确
- **路径**: `hibiki/lib/src/creator/fields/` (21 个文件)

**深入评估**: ~70% 为样板代码（单例初始化 ~11 行、方法签名 ~7 行、本地化 ~3 行），每个文件的自定义逻辑仅占 2-36%。提取单例 + 本地化模式可减少 ~13 行/文件。

**建议**: 提取为 mixin 或工厂方法，保留 `onCreatorOpenAction` body 自定义。不强制复杂字段（Frequency、PitchAccent）适配过窄的基类。

---

## 第三部分：Medium 级别问题

### HBK-AUDIT-011: 类型系统弱化

- **severity**: MEDIUM
- **status**: OPEN

**量化数据**:
- 252 处 `dynamic` 类型使用（分布在 20+ 文件）
- 434 处类型转换 (`as`)
- 111 个 `late` 变量声明（潜在 `LateInitializationError`）

**最集中区域**:
- `app_model.dart` — 14 处 dynamic
- `audiobook_bridge.dart` — 多处 dynamic
- `ttu_idb_reader.dart` — 多处 dynamic
- `floating_dict_channel.dart` — 多处 dynamic

---

### HBK-AUDIT-012: 生产代码中的 debugPrint

- **severity**: MEDIUM
- **status**: OPEN
- **数量**: 194 处

**问题**: 未使用结构化日志框架。项目已有 `ErrorLogService` 但仅用于异常，一般调试信息直接用 `debugPrint`。

**集中区域**: `ttu_migration.dart` (16 处), `audiobook_import_dialog.dart` (5 处)

---

### HBK-AUDIT-013: 空 catch 块吞没异常

- **severity**: MEDIUM
- **status**: ✅ FIXED (8/11 Dart 处已添加 debugPrint 日志)
- **数量**: 11 处 → 3 处残留

**已修复**: `base_audio_field.dart` (2处), `theme_notifier.dart`, `profile_view_model.dart`, `google_drive_handler.dart`, `sync_manager.dart`, `webdav_sync_backend.dart` (2处) — 全部添加 `debugPrint` 日志。

**残留**: `ttu_idb_reader.dart:333` (遗留迁移代码), `reader_pagination_scripts.dart:303` (JS 端 catch)。

---

### HBK-AUDIT-014: 同步凭证明文存储

- **severity**: MEDIUM
- **status**: BACKLOG — 需要新依赖 + 数据迁移
- **file**: `hibiki/lib/src/sync/sync_repository.dart` L182-192

**深入审查**: 所有同步后端（WebDAV/FTP/SFTP/SMB/OAuth/Dropbox/Box/OneDrive）的凭证均使用 base64 编码（NOT 加密）存储在 Drift SQLite `preferences` 表。`_encodeSecret()` / `_decodeSecret()` 只是 `base64Encode` / `base64Decode`。

**代码注释**: "依赖操作系统文件权限保护用户数据目录" — 移动端 OS sandbox 提供基本保护，但 root/备份场景下可被提取。

**建议**: 引入 `flutter_secure_storage`（Android Keystore / iOS Keychain），编写迁移逻辑读取旧 base64 值并重新存储加密。需要处理迁移失败回退。

---

### HBK-AUDIT-015: CI 只测试主应用

- **severity**: MEDIUM
- **status**: ✅ FIXED
- **file**: `.github/workflows/main.yml`, `.github/workflows/release.yml`

**修复**: 在两条 CI 流水线中均添加 "Run package tests" 步骤，遍历 `packages/hibiki_core`, `hibiki_dictionary`, `hibiki_anki`, `hibiki_audio`, `hibiki_platform`。

---

### HBK-AUDIT-016: Lint 规则屏蔽死代码检测

- **severity**: MEDIUM
- **status**: ✅ FIXED
- **file**: `hibiki/analysis_options.yaml`

**修复**:
- `unnecessary_import: ignore` → `warning` — 暴露并清理 30+ 冗余 import
- `unused_element` 和 `unused_element_parameter` — 移除 ignore，恢复默认 warning — 暴露并清理 3 个死方法 + 3 个未使用参数
- `deprecated_member_use` — 保留 ignore（当前无 deprecated 调用，启用仅增加噪音）

---

### HBK-AUDIT-017: 僵尸抽象类

- **severity**: MEDIUM
- **status**: ✅ PARTIALLY FIXED

| 抽象类 | 定义文件 | 子类数 | 状态 |
|--------|----------|--------|------|
| `BaseMediaSearchBarState` | `pages/base_media_search_bar.dart` | 0 | 保留 — 被 `MediaSource.buildBar()` 返回类型引用 |
| `MediaField` | `creator/media_field.dart` | 0 | ✅ 已删除 + barrel export 清理 |

---

### HBK-AUDIT-018: 两套词典弹窗实现

- **severity**: MEDIUM
- **status**: BACKLOG — 架构级 refactoring
- **文件**:
  - `dictionary_popup_webview.dart` (710 行)
  - `dictionary_popup_native.dart` (419 行)

**问题**: 两个并行实现处理相同的逻辑（条目展示、选择回调、挖矿回调、重复检查），修复一处时容易遗漏另一处。

**建议**: 提取共享 mixin 或 base class，作为独立 PR。

---

### HBK-AUDIT-019: 包 barrel 导出过宽

- **severity**: MEDIUM
- **status**: OPEN

**问题**: `hibiki_dictionary` 直接导出所有格式实现类（`yomichan_dictionary_format.dart`, `mdict_format.dart` 等）和语言实现类（`japanese_language.dart`, `english_language.dart` 等），客户端可以绕过抽象层直接依赖具体实现。

---

## 第四部分：Low 级别问题

### HBK-AUDIT-020: 文档-代码不一致

- **severity**: LOW
- **status**: OPEN

| 文档声明 | 实际 |
|----------|------|
| CLAUDE.md: "AppModel (3146 行)" | 实际 2,579 行 |
| CLAUDE.md: "ReaderHibikiPage (4088 行)" | 实际 4,221 行 |

---

### HBK-AUDIT-021: 单例模式过度使用

- **severity**: LOW
- **status**: OPEN
- **数量**: Creator 模块 21 个 Field 单例

---

### HBK-AUDIT-022: 单实现抽象类

- **severity**: LOW
- **status**: OPEN

| 抽象类 | 实现数 |
|--------|--------|
| `AudioExportField` | 1 |
| `ImageExportField` | 1 |
| `MediaSource` | 1 |
| `ReaderMediaSource` | 1 |

---

## 第五部分：测试覆盖审计

### 覆盖率总览

```
模块                | 源文件 | 测试文件 | 比率  | 评级
--------------------|--------|----------|-------|------
hibiki/anki         | 1      | 1        | 100%  | A+
hibiki/media        | 21     | 24       | 114%  | A+
hibiki/epub         | 10     | 9        | 90%   | A
hibiki/database     | 3      | 16       | 533%  | A
hibiki/reader       | 6      | 5        | 83%   | A-
hibiki/models       | 11     | 6        | 55%   | B
hibiki/pages        | 53     | 28       | 53%   | B
hibiki/settings     | 9      | 4        | 44%   | C+
hibiki/sync         | 14     | 6        | 43%   | C+
hibiki/profile      | 4      | 1        | 25%   | D
hibiki/utils        | 53     | 11       | 21%   | D
hibiki/creator      | 51     | 3        | 6%    | F
--------------------|--------|----------|-------|------
hibiki_audio        | 27     | 2        | 7%    | F
hibiki_core         | 4      | 0        | 0%    | F
hibiki_dictionary   | 21     | 0        | 0%    | F
hibiki_anki         | 7      | 0        | 0%    | F
hibiki_platform     | 3      | 0        | 0%    | F
--------------------|--------|----------|-------|------
总计                | 369    | 141      | 38%   | C+
主应用 (hibiki)      | 238    | 141      | 59%   | B-
```

### 最严重的测试盲区 (Top 5)

1. **Creator Enhancements**: 0/14 个 enhancement 有测试 — 音频录制、图片裁剪、文本分段等全部未测试
2. **hibiki_dictionary**: 21 个文件 0 测试 — 格式检测、解析、验证、错误恢复全部未覆盖
3. **Creator Fields**: 2/21 测试 (仅 frequency + pitch accent) — 19 个字段类型未验证
4. **hibiki_platform**: 3 个文件 0 测试 — 平台通道响应完全未验证
5. **Utils 模块**: 42/53 文件未测试 — 文本转换器、自适应布局等

---

## 第六部分：安全审计

### 安全防御正面确认

| 防御 | 状态 | 位置 |
|------|------|------|
| EPUB 路径遍历防护 | ✓ 正确 | `reader_hibiki_page.dart:1057-1068` — `p.canonicalize` + `p.isWithin` |
| 字体路径白名单 | ✓ 正确 | `reader_hibiki_page.dart:1013-1054` — URI 解码 + 规范化 + 白名单 |
| FFI 空指针检查 | ✓ 正确 | `hoshidicts_ffi_bindings.dart` — null check + 立即转 Dart string |
| TTU 迁移路径遍历阻止 | ✓ 正确 | `ttu_migration.dart:331` — `debugPrint('[ttu-migration] path traversal blocked')` |
| OAuth 凭证 | ✓ 编译时注入 | `google_drive_auth.dart:31-39` — `String.fromEnvironment()` |
| Secret 文件未入 git | ✓ 正确 | keystore/key.properties/dart_defines.env 均不在 git 跟踪中 |

---

## 第七部分：CI/CD 与工程规范

### CI 流水线

| 流水线 | 触发 | 分析 | 测试 | 构建 | 覆盖率 | 问题 |
|--------|------|------|------|------|--------|------|
| main.yml | push to main / PR | ✓ | ✓ hibiki/ + packages/ | ✓ debug + release | ✓ --coverage | ✅ 已修复 |
| release.yml | GitHub Release | ✓ | ✓ hibiki/ + packages/ | ✓ release split-per-abi | ✗ | ✅ 已修复 |

### 工程规范评估

| 规范 | 状态 | 详情 |
|------|------|------|
| 静态分析 | ✓ (13 info) | 0 error, 0 warning |
| 代码格式 | ✓ | 格式化一致 |
| import 规范 | ✓ | 强制 `always_use_package_imports` |
| 订阅取消检查 | ✓ | `cancel_subscriptions` 规则启用 |
| 异常规范 | ✓ | `only_throw_errors` 规则启用 |
| 死代码检测 | ✓ | `unused_element: warning` + `unnecessary_import: warning` 已启用 |
| deprecated 检测 | ✗ | `deprecated_member_use: ignore` 保留（当前无 deprecated 调用） |

---

## 第八部分：修复优先级矩阵

### P0 — 立即修复 (安全/数据完整性) — ✅ 全部完成

| ID | 问题 | 状态 |
|----|------|------|
| HBK-AUDIT-003 | JS 注入 | ✅ VERIFIED SAFE — `jsonEncode()` 正确防御 |
| HBK-AUDIT-004 | Stream 泄漏 — audio_recorder_page.dart | ✅ FIXED |
| HBK-AUDIT-005 | WebView 未释放 — dictionary_popup_webview.dart | ✅ FIXED |
| HBK-AUDIT-006 | 混合内容策略 | ✅ FIXED → COMPATIBILITY_MODE |

### P1 — 本周修复 (稳定性) — ✅ 全部完成

| ID | 问题 | 状态 |
|----|------|------|
| HBK-AUDIT-009 | 阅读器导航竞态 | ✅ VERIFIED SAFE + completer 清理已补 |
| HBK-AUDIT-013 | 空 catch 块添加日志 | ✅ FIXED (8/11 Dart 处) |
| HBK-AUDIT-015 | CI 覆盖全部 packages | ✅ FIXED — main.yml + release.yml |
| HBK-AUDIT-016 | 启用 lint 规则 | ✅ FIXED — 30+ import + 3 死方法 + 3 未使用参数已清理 |
| HBK-AUDIT-017 | 删除僵尸抽象类 | ✅ FIXED (MediaField 删除) |

### P2 — Backlog (代码质量 — 功能正确，架构改进)

| ID | 问题 | 评估 | 建议 |
|----|------|------|------|
| HBK-AUDIT-007 | UI 层 DB 访问 → Repository DI | 40+ 处引用，Repository 已存在但未 DI | 独立 refactoring sprint |
| HBK-AUDIT-008 | Provider autoDispose | 需逐 Provider 评估 UX 影响 | 独立 PR，逐 Provider 审查 |
| HBK-AUDIT-010 | Creator 字段去重 | 21 文件 70% 样板，功能正确 | 提取 mixin/工厂，独立 PR |
| HBK-AUDIT-014 | 凭证加密 | 需 `flutter_secure_storage` + 迁移 | 独立安全 PR |
| HBK-AUDIT-018 | 词典弹窗共享逻辑 | 两套并行实现 | 提取共享 mixin，独立 PR |

### P3 — 月度计划 (架构改进)

| ID | 问题 | 工作量 |
|----|------|--------|
| HBK-AUDIT-001 | AppModel 拆分 | 2-3 天 |
| HBK-AUDIT-002 | ReaderHibikiPage 拆分 | 3-5 天 |
| 测试盲区 | Creator/Dictionary/Platform 包测试 | 3-5 天 |

---

## 第九部分：修复总结

### 本轮修复统计

| 类型 | 数量 |
|------|------|
| 文件修改 | 30+ |
| 错误修复 (P0) | 3 件 + 1 验证安全 |
| 稳定性修复 (P1) | 5 件 |
| 冗余代码清理 | 30+ import, 3 死方法, 1 僵尸类, 3 未使用参数 |
| CI 改进 | 2 条流水线扩展 package 测试 |

### 修复后 analyze 状态

```
0 errors, 0 warnings, 13 info (均为 avoid_print in CLI tool + 1 test dependency)
```

### 修复后 test 状态

```
1210 pass, 1 fail (pre-existing: settings_redesign_static_test.dart — sync schema 变更后测试未更新)
```

---

## Next Scope

下一轮审查范围：
1. 修复 `settings_redesign_static_test.dart` 中的 pre-existing 测试失败
2. 深入审查同步模块 (`lib/src/sync/`) 的错误恢复路径
3. 审查数据库迁移路径 (schema v1 → v13) 的完整性
4. 检查 Android 原生代码 (17 个 Java 文件) 的资源管理
5. 执行 P2 backlog 中的 `flutter_secure_storage` 凭证加密迁移
