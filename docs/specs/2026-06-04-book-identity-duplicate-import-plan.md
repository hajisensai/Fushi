# 书籍身份根因修复 + 同名书重复导入拦截 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans / subagent-driven-development。步骤用 `- [ ]` 勾选框跟踪。

**Goal:** 在唯一的书籍导入入口 `EpubImporter` 强制按标题查重，重复导入弹窗：选「是」加序号后缀照常导入、选「否」取消添加这本书；根治"导入层允许同步层(按 sanitized 标题做身份)无法表达的同名状态"这一根因。

**Architecture:** 把"按同步身份 key 解析标题冲突"抽成纯函数 `resolveBookTitleConflict`（身份 key = `sanitizeTtuFilename(title)`，与同步远端文件夹 key 完全一致），让 `EpubImporter.import` / `importFromPath` 在插库前调用它；UI 层 `book_import_dialog` 传入弹窗回调。**仅导入层拦截、零 schema 迁移、不动现有书库**（用户已确认）。后台同步路径不传回调 → 默认自动加后缀（保持不变，因 `importRemoteBooks` 已按标题预判去重，正常流程不会触发）。

**Tech Stack:** Dart / Flutter 3.44.0；Drift（`HibikiDatabase.getAllEpubBooks()`）；Slang i18n（`tool/i18n_sync.dart` + `dart run slang`）；`showAppDialog`（项目弹窗 helper）。

**判定口径（用户确认）:** 标题相同即重复，按 `sanitizeTtuFilename(title)` 等价判定。后缀格式 ` (2)` / ` (3)`…（递增到不冲突）。

**改动文件总览:**
- 新建 `hibiki/lib/src/epub/book_title_conflict.dart` — 纯冲突解析函数 + `DuplicateTitleResolution` 枚举 + `DuplicateImportCancelledException` + `DuplicateTitleCallback` typedef。
- 改 `hibiki/lib/src/epub/epub_importer.dart` — `import` / `importFromPath` / `importFromFile` 增可选 `onDuplicateTitle`，插库前调解析函数，用解析后的标题入库。
- 改 `hibiki/lib/src/media/audiobook/book_import_dialog.dart` — 加 `_onDuplicateTitle` 弹窗回调，传给全部 5 处 `EpubImporter` 调用；`_importSubtitleBook` catch 放行取消异常；顶层 catch 把取消渲染成中性提示。
- 改 i18n（`tool/i18n_sync.dart --add` × 5 键 + `dart run slang` + `dart format`）。
- 新建 `hibiki/test/epub/book_title_conflict_test.dart` — 纯函数行为测试 + 接线源码扫描守卫。

---

### Task 1: 纯冲突解析函数（TDD）

**Files:**
- Create: `hibiki/lib/src/epub/book_title_conflict.dart`
- Test: `hibiki/test/epub/book_title_conflict_test.dart`

- [ ] **Step 1: 先写失败测试**

`hibiki/test/epub/book_title_conflict_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/book_title_conflict.dart';

void main() {
  group('resolveBookTitleConflict', () {
    test('no conflict returns proposed title and never calls callback', () async {
      var called = false;
      final String out = await resolveBookTitleConflict(
        existingTitles: const <String>['Rust'],
        proposedTitle: 'Go',
        onDuplicateTitle: (_) async {
          called = true;
          return DuplicateTitleResolution.cancel;
        },
      );
      expect(out, 'Go');
      expect(called, isFalse);
    });

    test('conflict + addSuffix returns " (2)" suffixed title', () async {
      final String out = await resolveBookTitleConflict(
        existingTitles: const <String>['Rust'],
        proposedTitle: 'Rust',
        onDuplicateTitle: (_) async => DuplicateTitleResolution.addSuffix,
      );
      expect(out, 'Rust (2)');
    });

    test('addSuffix skips already-taken suffixes', () async {
      final String out = await resolveBookTitleConflict(
        existingTitles: const <String>['Rust', 'Rust (2)'],
        proposedTitle: 'Rust',
        onDuplicateTitle: (_) async => DuplicateTitleResolution.addSuffix,
      );
      expect(out, 'Rust (3)');
    });

    test('conflict + cancel throws DuplicateImportCancelledException', () async {
      expect(
        () => resolveBookTitleConflict(
          existingTitles: const <String>['Rust'],
          proposedTitle: 'Rust',
          onDuplicateTitle: (_) async => DuplicateTitleResolution.cancel,
        ),
        throwsA(isA<DuplicateImportCancelledException>()),
      );
    });

    test('no callback auto-suffixes (keeps invariant for programmatic callers)',
        () async {
      final String out = await resolveBookTitleConflict(
        existingTitles: const <String>['Rust'],
        proposedTitle: 'Rust',
      );
      expect(out, 'Rust (2)');
    });

    test('conflict is judged on the sync key sanitizeTtuFilename(title)',
        () async {
      // "a*" sanitizes to "a~ttu-star~"; a second "a*" must be detected as dup.
      final String out = await resolveBookTitleConflict(
        existingTitles: const <String>['a*'],
        proposedTitle: 'a*',
        onDuplicateTitle: (_) async => DuplicateTitleResolution.addSuffix,
      );
      expect(out, 'a* (2)');
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd hibiki && flutter test test/epub/book_title_conflict_test.dart --no-pub`
Expected: FAIL（`book_title_conflict.dart` 不存在 / 符号未定义）

- [ ] **Step 3: 写最小实现**

`hibiki/lib/src/epub/book_title_conflict.dart`:

```dart
import 'package:hibiki/src/sync/ttu_filename.dart';

/// 用户对"检测到同名书籍"弹窗的选择。
enum DuplicateTitleResolution { addSuffix, cancel }

/// 用户选择"否/取消添加这本书"时由 [resolveBookTitleConflict] 抛出，
/// 供导入流程干净地中止（不当作错误）。
class DuplicateImportCancelledException implements Exception {
  const DuplicateImportCancelledException(this.title);
  final String title;
  @override
  String toString() => 'DuplicateImportCancelledException($title)';
}

/// 同名冲突回调：入参是拟用标题，返回用户选择。
typedef DuplicateTitleCallback = Future<DuplicateTitleResolution> Function(
  String proposedTitle,
);

/// 返回最终入库标题。书籍跨设备身份 = `sanitizeTtuFilename(title)`（同步远端
/// 文件夹 key）。若 [proposedTitle] 的身份 key 与 [existingTitles] 任一冲突：
/// 有回调则询问——addSuffix 返回唯一后缀标题（`X (2)`），cancel 抛
/// [DuplicateImportCancelledException]；无回调则自动加后缀（保持"本地不出现
/// 两本同 key 书"这一同步层依赖的不变量，供后台同步/程序化调用安全使用）。
Future<String> resolveBookTitleConflict({
  required List<String> existingTitles,
  required String proposedTitle,
  DuplicateTitleCallback? onDuplicateTitle,
}) async {
  final Set<String> keys =
      existingTitles.map(sanitizeTtuFilename).toSet();
  if (!keys.contains(sanitizeTtuFilename(proposedTitle))) {
    return proposedTitle;
  }
  if (onDuplicateTitle != null) {
    final DuplicateTitleResolution res = await onDuplicateTitle(proposedTitle);
    if (res == DuplicateTitleResolution.cancel) {
      throw DuplicateImportCancelledException(proposedTitle);
    }
  }
  return _uniqueSuffixedTitle(proposedTitle, keys);
}

String _uniqueSuffixedTitle(String base, Set<String> existingKeys) {
  for (int i = 2;; i++) {
    final String candidate = '$base ($i)';
    if (!existingKeys.contains(sanitizeTtuFilename(candidate))) {
      return candidate;
    }
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd hibiki && flutter test test/epub/book_title_conflict_test.dart --no-pub`
Expected: PASS（6 tests）

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/epub/book_title_conflict.dart hibiki/test/epub/book_title_conflict_test.dart
git commit -m "feat(epub): book title conflict resolver (sync-key identity)"
```

---

### Task 2: EpubImporter 接入查重 + 接线守卫

**Files:**
- Modify: `hibiki/lib/src/epub/epub_importer.dart`
- Test: `hibiki/test/epub/book_title_conflict_test.dart`（追加源码扫描守卫）

- [ ] **Step 1: 追加接线守卫测试（先失败）**

在 `book_title_conflict_test.dart` 的 `main()` 末尾追加：

```dart
  test('EpubImporter wires the conflict resolver into both import paths', () {
    final String src =
        File('lib/src/epub/epub_importer.dart').readAsStringSync();
    // 两条插库路径都必须在 insert 前过 resolveBookTitleConflict，且暴露回调。
    expect('resolveBookTitleConflict'.allMatches(src).length, greaterThanOrEqualTo(2),
        reason: 'both import() and importFromPath() must resolve title conflicts');
    expect(src.contains('onDuplicateTitle'), isTrue);
  });
```

并在该测试文件顶部加 `import 'dart:io';`。

- [ ] **Step 2: 跑守卫确认失败**

Run: `cd hibiki && flutter test test/epub/book_title_conflict_test.dart --no-pub`
Expected: FAIL（源码尚未引用 `resolveBookTitleConflict` / `onDuplicateTitle`）

- [ ] **Step 3: 改 EpubImporter**

`epub_importer.dart` 顶部 import 区追加：

```dart
import 'package:hibiki/src/epub/book_title_conflict.dart';
```

`import(...)` 签名增加可选参数（在 `required String fileName,` 之后）：

```dart
    required String fileName,
    DuplicateTitleCallback? onDuplicateTitle,
  }) async {
```

`importFromPath(...)` 同样在 `required String fileName,` 之后追加：

```dart
    required String fileName,
    DuplicateTitleCallback? onDuplicateTitle,
  }) async {
```

`importFromFile(...)` 增加并转发：

```dart
  static Future<int> importFromFile({
    required HibikiDatabase db,
    required String filePath,
    DuplicateTitleCallback? onDuplicateTitle,
  }) async {
    return importFromPath(
      db: db,
      filePath: filePath,
      fileName: p.basename(filePath),
      onDuplicateTitle: onDuplicateTitle,
    );
  }
```

两处插库代码（`import` ~line 65-70、`importFromPath` ~line 198-203）紧接 `resolvedTitle` 计算之后、`insert(` 之前，各插入同一段：

```dart
      final List<EpubBookRow> existingBooks = await db.getAllEpubBooks();
      final String storedTitle = await resolveBookTitleConflict(
        existingTitles:
            existingBooks.map((EpubBookRow b) => b.title).toList(),
        proposedTitle: resolvedTitle,
        onDuplicateTitle: onDuplicateTitle,
      );
```

并把两处 `EpubBooksCompanion.insert(title: resolvedTitle, ...)` 改为 `title: storedTitle,`。

> 取消语义：`resolveBookTitleConflict` 在 insert 前抛 `DuplicateImportCancelledException`，此时 `insertedBookId == null`，现有 catch 块只会 `_tryDeleteDir(extractDir)` 清理解压目录并 `rethrow`，无残留行、无脏目录。无需改 catch。

- [ ] **Step 4: 跑守卫 + 全 epub 测试确认通过**

Run: `cd hibiki && flutter test test/epub/ --no-pub`
Expected: PASS（含守卫 + 既有 epub 测试不回归）

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/epub/epub_importer.dart hibiki/test/epub/book_title_conflict_test.dart
git commit -m "feat(epub): enforce title-unique import via conflict resolver"
```

---

### Task 3: i18n 键（5 个，走 i18n_sync）

**Files:**
- Modify: `hibiki/lib/i18n/*.i18n.json`（经脚本）+ `hibiki/lib/i18n/strings.g.dart`（经 slang）

- [ ] **Step 1: 用脚本加键（en / zh）**

```bash
cd hibiki
dart tool/i18n_sync.dart --add book_import_duplicate_title "Duplicate book" "同名书籍"
dart tool/i18n_sync.dart --add book_import_duplicate_message "A book named \"{name}\" already exists. Import it anyway? \"Yes\" imports with a numbered suffix; \"No\" cancels." "书库中已存在《{name}》。仍要导入吗？「是」会加序号后缀导入，「否」取消添加这本书。"
dart tool/i18n_sync.dart --add book_import_duplicate_keep "Yes, add suffix" "是，加后缀"
dart tool/i18n_sync.dart --add book_import_duplicate_cancel "No, cancel" "否，取消"
dart tool/i18n_sync.dart --add book_import_duplicate_cancelled "Import cancelled" "已取消导入"
```

- [ ] **Step 2: 重新生成 strings.g.dart 并格式化**

```bash
cd hibiki && dart run slang && dart format lib/i18n/strings.g.dart
```

Expected: 生成 `t.book_import_duplicate_title` / `t.book_import_duplicate_message(name: ...)` / `_keep` / `_cancel` / `_cancelled`，17 语言无缺 key。

- [ ] **Step 3: 提交**

```bash
git add hibiki/lib/i18n/
git commit -m "i18n: add book_import_duplicate_* keys"
```

---

### Task 4: book_import_dialog 弹窗回调接线

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/book_import_dialog.dart`

- [ ] **Step 1: 加 import 与弹窗回调方法**

确认文件顶部已 import `package:hibiki/utils.dart`（`showAppDialog` / `t` 来源）；追加：

```dart
import 'package:hibiki/src/epub/book_title_conflict.dart';
```

在 `_BookImportDialogState`（或对应 State 类）内新增方法：

```dart
  Future<DuplicateTitleResolution> _onDuplicateTitle(
    String proposedTitle,
  ) async {
    if (!mounted) return DuplicateTitleResolution.cancel;
    final bool? keep = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.book_import_duplicate_title),
        content: Text(t.book_import_duplicate_message(name: proposedTitle)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.book_import_duplicate_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.book_import_duplicate_keep),
          ),
        ],
      ),
    );
    return keep == true
        ? DuplicateTitleResolution.addSuffix
        : DuplicateTitleResolution.cancel;
  }
```

- [ ] **Step 2: 5 处 EpubImporter 调用传回调**

为以下每处加 `onDuplicateTitle: _onDuplicateTitle,`：
- `_importSubtitleBook` 内 `EpubImporter.importFromPath(...)`（~line 551）
- `_importEpubOnly` 内 `EpubImporter.import(...)`（~line 633）与 `EpubImporter.importFromPath(...)`（~line 640）
- `_importEpubWithAlignment` 内 `EpubImporter.import(...)`（~line 671）与 `EpubImporter.importFromPath(...)`（~line 678）

例（`_importEpubOnly`）：

```dart
      bookId = await EpubImporter.import(
        db: widget.db,
        bytes: bytes,
        fileName: filename,
        onDuplicateTitle: _onDuplicateTitle,
      );
```

- [ ] **Step 3: `_importSubtitleBook` catch 放行取消异常**

把 `_importSubtitleBook`（~line 558）的：

```dart
      } catch (e, stack) {
        ErrorLogService.instance.log('BookImportDialog.epubImport', e, stack);
        debugPrint('[hibiki-import] EPUB generation/import failed: $e');
      }
```

改为（取消必须冒泡，不能被吞成 bookId=0 继续）：

```dart
      } on DuplicateImportCancelledException {
        rethrow;
      } catch (e, stack) {
        ErrorLogService.instance.log('BookImportDialog.epubImport', e, stack);
        debugPrint('[hibiki-import] EPUB generation/import failed: $e');
      }
```

- [ ] **Step 4: 顶层 `_import` catch 把取消渲染成中性提示**

在顶层导入方法（含 `Navigator.pop(context, true)` 成功分支的那个 try，catch 在 ~line 511）的 `catch (e, stack)` 之前插入：

```dart
    } on DuplicateImportCancelledException {
      if (mounted) {
        HibikiToast.show(msg: t.book_import_duplicate_cancelled);
        Navigator.pop(context, false);
      }
    } catch (e, stack) {
```

- [ ] **Step 5: analyze**

Run: `cd hibiki && flutter analyze lib/src/media/audiobook/book_import_dialog.dart lib/src/epub/`
Expected: No issues（或仅既有无关告警）

- [ ] **Step 6: 提交**

```bash
git add hibiki/lib/src/media/audiobook/book_import_dialog.dart
git commit -m "feat(import): duplicate-title prompt (yes=suffix / no=cancel)"
```

---

### Task 5: 全量验证

- [ ] **Step 1: 格式化**

Run: `cd hibiki && dart format lib/ test/`

- [ ] **Step 2: analyze**

Run: `cd hibiki && flutter analyze`
Expected: 无新增 error。

- [ ] **Step 3: 全量测试**

Run: `cd hibiki && flutter test --no-pub`
Expected: 全绿（新增 book_title_conflict 测试通过；既有 sync/epub/导入相关测试零回归）。

- [ ] **Step 4: 提交（若 format 有改动）**

```bash
git add -- hibiki/lib hibiki/test
git commit -m "style: format after duplicate-import feature"
```

> Android manifest/权限/Gradle 无改动，**无需** `assembleRelease`。
> **设备复测（声明"修好了"前由用户/集成做）**：真机重复导入同一本书 → 弹窗；选「是」书架出现 `X` 与 `X (2)` 两本且都可读；选「否」不新增、无脏目录。属 UI 流程，留证据。

---

### Task 6: Opus 代码审查（CLAUDE.md 强制）

- [ ] **Step 1: 派生 code-reviewer 子代理，显式 `model: "opus"`**，审查：是否符合本计划、取消路径无残留（解压目录清理）、5 处调用全部接线、`_importSubtitleBook` 取消不被吞、后台同步路径行为零变化、后缀循环无死循环、i18n 17 语言完整。
- [ ] **Step 2: 按审查结果修复后重新提交。**

---

## Self-Review

- **Spec 覆盖**：① 根本性修复（导入层 = 生产唯一插书入口强制查重，身份 key 对齐同步）✓ Task1-2；② 同名无法重复导入（冲突即拦）✓；③ 弹窗 ✓ Task4；④ 是→加后缀 ✓（`addSuffix`/`_uniqueSuffixedTitle`）；⑤ 否→取消这本书 ✓（`cancel`→异常→中止）。
- **占位符**：无 TODO/TBD；每步含真实代码/命令。
- **类型一致**：`DuplicateTitleResolution` / `DuplicateImportCancelledException` / `DuplicateTitleCallback` / `resolveBookTitleConflict` 在 Task1 定义，Task2/4 一致引用。
- **残留风险**：取消在 insert 前抛出 → `insertedBookId==null` → 既有 catch 清 `extractDir`。后台同步无回调 → 默认自动加后缀，但 `importRemoteBooks` 已按标题预判 `continue`，正常流程不触发，行为不变。
