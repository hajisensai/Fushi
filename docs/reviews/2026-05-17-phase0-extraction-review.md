# Phase 0 Monorepo Extraction — 审查报告

**日期**: 2026-05-17
**分支**: feature/multiplatform
**审查范围**: 5 个提取的包 (hibiki_core, hibiki_dictionary, hibiki_audio, hibiki_anki, hibiki_platform) + melos workspace

---

## Round 1: 包结构与依赖审查

### Scope
- 所有 5 个包的 pubspec.yaml、barrel export、内部 import 图、test/ 目录
- melos.yaml workspace 配置
- app 层 pubspec.yaml 引用

### Findings

#### HBK-AUDIT-001 — hibiki_audio 冗余声明 sqlite3_flutter_libs
- **severity**: low
- **status**: ✅ 已修复 (a612ce4a)
- **文件**: `packages/hibiki_audio/pubspec.yaml`
- **根因**: sqlite3_flutter_libs 是纯运行时 native 插件（只提供 .so/.dylib），hibiki_audio 没有任何 Dart import，且已通过 hibiki_core 传递依赖。
- **影响**: 不影响功能，但违反 "只声明直接使用的依赖" 原则。
- **修复**: 移除 `sqlite3_flutter_libs: ^0.5.28`，pub get 确认降级为 transitive dependency。
- **验证**: flutter analyze 0 issues, 587 tests passed, flutter build apk --release 成功 (43.4MB)

#### HBK-AUDIT-002 — hibiki_platform 是空接口包，app 未实际引用
- **severity**: info
- **status**: 已知设计决策，无需修复
- **文件**: `packages/hibiki_platform/lib/src/` (3 个 abstract class)
- **根因**: Phase 0 先建骨架，Phase 1 桌面平台适配时实现。
- **影响**: 无害。app pubspec 声明了 `hibiki_platform` 依赖但无 import — 只增加一行 pubspec 声明，不影响编译产物。

#### HBK-AUDIT-003 — hibiki_dictionary 混合了 UI 依赖
- **severity**: low
- **status**: Phase 1 scope，当前不修
- **文件**: `packages/hibiki_dictionary/pubspec.yaml`
- **根因**: dictionary format 类（Yomichan/MDict/ABBYY/Migaku）使用 file_picker 选文件、flutter_html 渲染释义。这些类和纯引擎代码一起被抽出。
- **影响**: 桌面平台编译时可能需要 stub，但当前只编译 Android，不阻塞。
- **建议**: Phase 1 拆分 `hibiki_dictionary` 为 `hibiki_dictionary_core` (engine/FFI/models) + `hibiki_dictionary_ui` (format handlers/HTML rendering)。

#### HBK-AUDIT-004 — 所有包 test/ 目录为空
- **severity**: low
- **status**: 已知技术债
- **根因**: Phase 0 的目标是提取包结构，测试仍保留在 app 的 `hibiki/test/` (587 tests)。
- **影响**: 不影响当前功能验证。但包无法独立 `flutter test`。
- **建议**: 逐步将 app test 中只依赖单个包 API 的测试迁移到对应包。

#### HBK-AUDIT-005 — hibiki_anki 的 AnkiRepository 未实现 AnkiService 接口
- **severity**: info
- **status**: 已知设计决策
- **文件**: `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart`
- **根因**: `AnkiRepository` 是 AnkiDroid 专用的高层 mining controller（管理设置、模板渲染、媒体处理），职责比 `AnkiService` 更宽。`AnkiConnectService` 正确实现了 `AnkiService` 接口。
- **影响**: 无功能影响。两套实现走不同 codepath（AnkiDroid 走 MethodChannel，桌面走 AnkiConnect HTTP）。

#### HBK-AUDIT-006 — melos.yaml 配置正确
- **severity**: info
- **status**: ✅ 无问题
- **文件**: `melos.yaml`
- **验证**: workspace 定义 `packages/*` + `hibiki`，bootstrap 使用 pubspecOverrides，analyze/test/build scripts 正确。

#### HBK-AUDIT-007 — hibiki_core 内部无循环依赖，数据库迁移链完整
- **severity**: info
- **status**: ✅ 无问题
- **文件**: `packages/hibiki_core/lib/src/database/`
- **验证**: 18 张表，12 版 schema migration，外键关系正确（cascade delete），无循环 import。

#### HBK-AUDIT-008 — hibiki_audio drift 直接依赖合理
- **severity**: info
- **status**: ✅ 无问题
- **文件**: `packages/hibiki_audio/lib/src/audiobook/*.dart`
- **验证**: 4 个 repository 文件直接 `import 'package:drift/drift.dart'`，需要 drift 作为直接依赖。保留正确。

### Verification Matrix

| 检查项 | 状态 |
|--------|------|
| flutter analyze — hibiki_audio | ✅ 0 issues |
| flutter analyze — hibiki app | ✅ 0 errors, 13 info-level lint (与 Phase 0 基线一致) |
| flutter test | ✅ 587 tests passed |
| flutter build apk --release | ✅ 43.4MB |
| 包间循环依赖 | ✅ 无 |
| barrel export 完整性 | ✅ 所有包正确 export |

### Next Scope
Round 2: app 层对各包的 import 引用完整性 — 确认 app 中原有 import 全部正确迁移到新包路径，无残留旧路径引用。

---

## Round 2: Import 迁移完整性 + 跨包依赖图

### Scope
- app `hibiki/lib/` 中所有 `package:hibiki_*` import 路径
- 是否存在残留旧路径（直接引用已迁移文件的原始位置）
- 跨包依赖图验证（循环依赖、未声明依赖）
- hibiki_platform 冗余依赖

### Findings

#### HBK-AUDIT-009 — App import 迁移 100% 完整
- **severity**: info
- **status**: ✅ 无问题
- **验证**: 86 个跨包 import，72 个文件，全部使用 `package:hibiki_XXX/hibiki_XXX.dart` barrel import，零旧路径残留。

#### HBK-AUDIT-010 — hibiki_platform 声明了未使用的 hibiki_core 依赖
- **severity**: low
- **status**: ✅ 已修复 (6e81d723)
- **文件**: `packages/hibiki_platform/pubspec.yaml`
- **根因**: hibiki_platform 3 个 abstract class 只使用 `dart:async`、`dart:io` 和 `package:flutter/painting.dart`，不 import hibiki_core。
- **修复**: 移除 `hibiki_core` 依赖。
- **验证**: analyze 0 issues, 587 tests passed。

#### HBK-AUDIT-011 — 跨包依赖图清洁
- **severity**: info
- **status**: ✅ 无问题
- **验证**:
  - hibiki_core → 无包依赖（root）
  - hibiki_dictionary → hibiki_core（声明 + 使用，3 文件）
  - hibiki_audio → hibiki_core（声明 + 使用，7 文件）
  - hibiki_anki → 无包依赖
  - hibiki_platform → 无包依赖
  - 无循环依赖，无未声明的跨包 import。

#### HBK-AUDIT-012 — anki_view_model.dart 留在 app 层合理
- **severity**: info
- **status**: 无需修复
- **文件**: `hibiki/lib/src/anki/anki_view_model.dart`
- **根因**: 这是 Riverpod StateNotifier，管理 AnkiUiState，依赖 app 层 UI 框架。6 个 app 页面引用它。作为 UI/ViewModel 层，正确归属于 app 而非 hibiki_anki 包。

### Next Scope
Round 3: Barrel export 完整性审查。

---

## Round 3: Barrel Export + pubspec_overrides 审查

### Scope
- 所有 5 个包的 barrel file export 与 app import 的一致性
- 是否有 app 直接引用包内 `src/` 路径（绕过 barrel）
- pubspec_overrides.yaml melos 一致性

### Findings

#### HBK-AUDIT-013 — Barrel export 纪律完美
- **severity**: info
- **status**: ✅ 无问题
- **验证**: app 的全部 86 个跨包 import 均走 barrel file（`package:hibiki_XXX/hibiki_XXX.dart`），零直接 `src/` 路径引用。

#### HBK-AUDIT-014 — pubspec_overrides.yaml melos 管理正确
- **severity**: info
- **status**: ✅ 无问题
- **验证**: 4 个包有 pubspec_overrides.yaml（hibiki_core 是根包不需要），全部由 melos 自动管理 `# melos_managed_dependency_overrides: hibiki_core`。

---

## Final Verification Matrix

| 检查项 | 状态 |
|--------|------|
| flutter analyze — hibiki_core | ✅ 0 issues |
| flutter analyze — hibiki_dictionary | ✅ 0 issues |
| flutter analyze — hibiki_audio | ✅ 0 issues |
| flutter analyze — hibiki_anki | ✅ 0 issues |
| flutter analyze — hibiki_platform | ✅ 0 issues |
| flutter analyze — hibiki app | ✅ 0 errors (13 info lint, 基线一致) |
| flutter test | ✅ 587 tests passed |
| flutter build apk --release | ✅ 43.4MB |
| 包间循环依赖 | ✅ 无 |
| barrel export 完整性 | ✅ 86/86 正确 |
| app import 迁移 | ✅ 100% 完整 |
| melos workspace 配置 | ✅ 正确 |

## 结论

Phase 0 monorepo extraction 审查完成。**无阻塞性问题。**

修复了 2 个 low severity 清理项：
1. `a612ce4a` — hibiki_audio 移除冗余 sqlite3_flutter_libs
2. `6e81d723` — hibiki_platform 移除未使用的 hibiki_core 依赖

已知技术债（Phase 1 范围）：
- HBK-AUDIT-003: hibiki_dictionary 混合 UI 依赖
- HBK-AUDIT-004: 包内无独立测试

当前分支可安全合并或作为 Phase 1 基础。
