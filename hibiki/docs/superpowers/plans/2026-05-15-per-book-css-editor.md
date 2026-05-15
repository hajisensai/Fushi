# Per-Book CSS Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to view and edit EPUB books' embedded CSS files per-book, with backup/reset to original.

**Architecture:** Pure file-system state — `.original` backups alongside CSS files in `extractDir`. `BookCssRepository` handles all IO; `BookCssEditorPage` is a stateful Tab editor. Entry via `ReaderHoshiHistoryPage.extraActions()`. Zero database changes, zero WebView changes.

**Tech Stack:** Flutter/Dart, `dart:io`, `path` package, Slang i18n, `flutter_test`

**Spec:** `docs/superpowers/specs/2026-05-15-per-book-css-editor-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/src/epub/book_css_repository.dart` | Create | CSS discovery, read, safe-write, backup, reset, display-title dedup |
| `lib/src/pages/implementations/book_css_editor_page.dart` | Create | Tab editor UI, unsaved-changes guards, save/reset actions |
| `lib/src/pages/implementations/reader_hoshi_history_page.dart` | Modify (line ~637) | Add "Edit CSS" button to `extraActions()` |
| `lib/i18n/strings.i18n.json` | Modify | Add flat i18n keys |
| `test/epub/book_css_repository_test.dart` | Create | Unit tests for all repository logic |

---

### Task 1: BookCssRepository — CSS Discovery & Display Title

**Files:**
- Create: `hibiki/lib/src/epub/book_css_repository.dart`
- Create: `hibiki/test/epub/book_css_repository_test.dart`

The repository is a pure-IO class with no Flutter dependencies — fully testable without widget harness.

- [ ] **Step 1: Write the CssFileEntry model and BookCssRepository skeleton**

Create `hibiki/lib/src/epub/book_css_repository.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

class CssFileEntry {
  CssFileEntry({
    required this.absolutePath,
    required this.relativePath,
    required this.displayTitle,
  });

  final String absolutePath;
  final String relativePath;
  final String displayTitle;

  String get originalPath => '$absolutePath.original';
  bool get hasOriginal => File(originalPath).existsSync();

  bool isDifferentFromOriginal() {
    if (!hasOriginal) return false;
    final String current = File(absolutePath).readAsStringSync();
    final String original = File(originalPath).readAsStringSync();
    return current != original;
  }
}

class BookCssRepository {
  BookCssRepository(this.extractDir);

  final String extractDir;

  List<CssFileEntry> discoverCssFiles() {
    final Directory dir = Directory(extractDir);
    if (!dir.existsSync()) return const [];

    final List<File> cssFiles = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) {
          final String ext = p.extension(f.path).toLowerCase();
          return ext == '.css' && !f.path.endsWith('.original');
        })
        .toList();

    final List<String> relativePaths = cssFiles.map((f) {
      return p.relative(f.path, from: extractDir).replaceAll(r'\', '/');
    }).toList()
      ..sort();

    final Map<String, String> displayTitles =
        _shortestUniqueSuffixes(relativePaths);

    return relativePaths.map((rel) {
      return CssFileEntry(
        absolutePath: p.join(extractDir, rel.replaceAll('/', p.separator)),
        relativePath: rel,
        displayTitle: displayTitles[rel]!,
      );
    }).toList();
  }

  static Map<String, String> _shortestUniqueSuffixes(List<String> paths) {
    final Map<String, String> result = {};

    final Map<String, List<String>> byBasename = {};
    for (final String path in paths) {
      final String base = p.posix.basename(path);
      byBasename.putIfAbsent(base, () => []).add(path);
    }

    for (final entry in byBasename.entries) {
      if (entry.value.length == 1) {
        result[entry.value.first] = entry.key;
      } else {
        for (final String fullPath in entry.value) {
          final List<String> segments = p.posix.split(fullPath);
          String suffix = segments.last;
          for (int i = segments.length - 2; i >= 0; i--) {
            suffix = '${segments[i]}/$suffix';
            final bool unique = entry.value
                .where((other) => other != fullPath && other.endsWith(suffix))
                .isEmpty;
            if (unique) break;
          }
          result[fullPath] = suffix;
        }
      }
    }
    return result;
  }
}
```

- [ ] **Step 2: Write discovery tests**

Create `hibiki/test/epub/book_css_repository_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:hibiki/src/epub/book_css_repository.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('book_css_repo_test_');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  group('discoverCssFiles', () {
    test('returns empty list when extractDir does not exist', () {
      final repo = BookCssRepository(p.join(tmpDir.path, 'nonexistent'));
      expect(repo.discoverCssFiles(), isEmpty);
    });

    test('discovers CSS files recursively', () {
      _createFile(tmpDir, 'OEBPS/Styles/style.css', 'body{}');
      _createFile(tmpDir, 'OEBPS/Styles/fonts.css', '@font-face{}');
      _createFile(tmpDir, 'OEBPS/Text/chapter1.xhtml', '<html/>');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.length, 2);
      expect(
        files.map((f) => f.relativePath).toList(),
        ['OEBPS/Styles/fonts.css', 'OEBPS/Styles/style.css'],
      );
    });

    test('excludes .original backup files', () {
      _createFile(tmpDir, 'OEBPS/style.css', 'body{}');
      _createFile(tmpDir, 'OEBPS/style.css.original', 'old{}');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.length, 1);
      expect(files.first.relativePath, 'OEBPS/style.css');
    });

    test('matches CSS extension case-insensitively', () {
      _createFile(tmpDir, 'OEBPS/STYLE.CSS', 'body{}');
      _createFile(tmpDir, 'OEBPS/Mixed.Css', 'body{}');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.length, 2);
    });

    test('relativePaths use forward slashes', () {
      _createFile(tmpDir, 'OEBPS/Styles/style.css', 'body{}');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.first.relativePath, 'OEBPS/Styles/style.css');
      expect(files.first.relativePath.contains(r'\'), isFalse);
    });

    test('results are sorted by relativePath', () {
      _createFile(tmpDir, 'z/z.css', 'z');
      _createFile(tmpDir, 'a/a.css', 'a');
      _createFile(tmpDir, 'm/m.css', 'm');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.map((f) => f.relativePath).toList(), ['a/a.css', 'm/m.css', 'z/z.css']);
    });
  });

  group('displayTitle shortest unique suffix', () {
    test('unique basenames use basename only', () {
      _createFile(tmpDir, 'OEBPS/Styles/style.css', 'a');
      _createFile(tmpDir, 'OEBPS/Styles/fonts.css', 'b');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      expect(files.map((f) => f.displayTitle).toSet(), {'fonts.css', 'style.css'});
    });

    test('duplicate basenames get parent prefix', () {
      _createFile(tmpDir, 'OEBPS/Styles/style.css', 'a');
      _createFile(tmpDir, 'OEBPS/Alt/style.css', 'b');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      final titles = files.map((f) => f.displayTitle).toSet();
      expect(titles, {'Styles/style.css', 'Alt/style.css'});
    });

    test('triple collision adds enough prefix', () {
      _createFile(tmpDir, 'a/common/style.css', '1');
      _createFile(tmpDir, 'b/common/style.css', '2');
      _createFile(tmpDir, 'c/other/style.css', '3');

      final repo = BookCssRepository(tmpDir.path);
      final files = repo.discoverCssFiles();

      final titles = files.map((f) => f.displayTitle).toSet();
      expect(titles.length, 3);
      for (final t in titles) {
        expect(t.endsWith('style.css'), isTrue);
      }
    });
  });
}

void _createFile(Directory root, String relativePath, String content) {
  final File file = File(p.join(root.path, relativePath.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}
```

- [ ] **Step 3: Run tests to verify they pass**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/epub/book_css_repository_test.dart -v
```

Expected: All tests PASS.

- [ ] **Step 4: Commit**

```powershell
git add hibiki/lib/src/epub/book_css_repository.dart hibiki/test/epub/book_css_repository_test.dart
git commit -m "feat(css-editor): add BookCssRepository with discovery and display-title dedup"
```

---

### Task 2: BookCssRepository — Read, Safe-Write, Backup, Reset

**Files:**
- Modify: `hibiki/lib/src/epub/book_css_repository.dart`
- Modify: `hibiki/test/epub/book_css_repository_test.dart`

- [ ] **Step 1: Add read, save, resetFile, resetAll methods to BookCssRepository**

Append to `BookCssRepository` class in `book_css_repository.dart`:

```dart
  String readCss(CssFileEntry entry) {
    return File(entry.absolutePath).readAsStringSync();
  }

  /// Safe write: backup original if needed, write via temp+rename,
  /// delete .original if content matches original.
  void saveCss(CssFileEntry entry, String content) {
    final File target = File(entry.absolutePath);
    final File original = File(entry.originalPath);

    // Step 1: backup if no .original exists and content actually differs
    if (!original.existsSync()) {
      final String currentContent = target.readAsStringSync();
      if (currentContent == content) return; // no-op
      original.writeAsStringSync(currentContent, flush: true);
    }

    // Step 2: write via temp → rename
    final File temp = File('${entry.absolutePath}.tmp');
    temp.writeAsStringSync(content, flush: true);
    temp.renameSync(entry.absolutePath);

    // Step 3: if content equals original, delete .original
    if (original.existsSync()) {
      final String originalContent = original.readAsStringSync();
      if (originalContent == content) {
        original.deleteSync();
      }
    }
  }

  void resetFile(CssFileEntry entry) {
    final File original = File(entry.originalPath);
    if (!original.existsSync()) return;
    final File temp = File('${entry.absolutePath}.tmp');
    temp.writeAsStringSync(original.readAsStringSync(), flush: true);
    temp.renameSync(entry.absolutePath);
    original.deleteSync();
  }

  void resetAll() {
    for (final CssFileEntry entry in discoverCssFiles()) {
      if (entry.hasOriginal) {
        resetFile(entry);
      }
    }
  }
```

- [ ] **Step 2: Write tests for save, reset, and .original lifecycle**

Append these test groups to `book_css_repository_test.dart`:

```dart
  group('readCss', () {
    test('reads file content as UTF-8', () {
      _createFile(tmpDir, 'style.css', 'body { color: red; }');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(repo.readCss(entry), 'body { color: red; }');
    });
  });

  group('saveCss', () {
    test('first save creates .original backup', () {
      _createFile(tmpDir, 'style.css', 'original content');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.saveCss(entry, 'modified content');

      expect(File(entry.originalPath).existsSync(), isTrue);
      expect(File(entry.originalPath).readAsStringSync(), 'original content');
      expect(File(entry.absolutePath).readAsStringSync(), 'modified content');
    });

    test('saving same content as disk is a no-op (no .original created)', () {
      _createFile(tmpDir, 'style.css', 'same');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.saveCss(entry, 'same');

      expect(File(entry.originalPath).existsSync(), isFalse);
    });

    test('saving back to original content deletes .original', () {
      _createFile(tmpDir, 'style.css', 'original');
      final repo = BookCssRepository(tmpDir.path);
      var entry = repo.discoverCssFiles().first;

      repo.saveCss(entry, 'changed');
      expect(entry.hasOriginal, isTrue);

      entry = repo.discoverCssFiles().first; // refresh
      repo.saveCss(entry, 'original');
      expect(File(entry.originalPath).existsSync(), isFalse);
      expect(File(entry.absolutePath).readAsStringSync(), 'original');
    });

    test('second save does not overwrite .original', () {
      _createFile(tmpDir, 'style.css', 'v1');
      final repo = BookCssRepository(tmpDir.path);
      var entry = repo.discoverCssFiles().first;

      repo.saveCss(entry, 'v2');
      entry = repo.discoverCssFiles().first;
      repo.saveCss(entry, 'v3');

      expect(File(entry.originalPath).readAsStringSync(), 'v1');
      expect(File(entry.absolutePath).readAsStringSync(), 'v3');
    });
  });

  group('isDifferentFromOriginal', () {
    test('returns false when no .original exists', () {
      _createFile(tmpDir, 'style.css', 'body{}');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(entry.isDifferentFromOriginal(), isFalse);
    });

    test('returns true when content differs from .original', () {
      _createFile(tmpDir, 'style.css', 'modified');
      _createFile(tmpDir, 'style.css.original', 'original');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(entry.isDifferentFromOriginal(), isTrue);
    });

    test('returns false when content matches .original', () {
      _createFile(tmpDir, 'style.css', 'same');
      _createFile(tmpDir, 'style.css.original', 'same');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;
      expect(entry.isDifferentFromOriginal(), isFalse);
    });
  });

  group('resetFile', () {
    test('restores content from .original and deletes backup', () {
      _createFile(tmpDir, 'style.css', 'modified');
      _createFile(tmpDir, 'style.css.original', 'original');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.resetFile(entry);

      expect(File(entry.absolutePath).readAsStringSync(), 'original');
      expect(File(entry.originalPath).existsSync(), isFalse);
    });

    test('no-op when no .original exists', () {
      _createFile(tmpDir, 'style.css', 'content');
      final repo = BookCssRepository(tmpDir.path);
      final entry = repo.discoverCssFiles().first;

      repo.resetFile(entry); // should not throw

      expect(File(entry.absolutePath).readAsStringSync(), 'content');
    });
  });

  group('resetAll', () {
    test('resets all files that have .original backups', () {
      _createFile(tmpDir, 'a.css', 'modified-a');
      _createFile(tmpDir, 'a.css.original', 'original-a');
      _createFile(tmpDir, 'b.css', 'untouched-b');
      _createFile(tmpDir, 'c.css', 'modified-c');
      _createFile(tmpDir, 'c.css.original', 'original-c');

      final repo = BookCssRepository(tmpDir.path);
      repo.resetAll();

      expect(File(p.join(tmpDir.path, 'a.css')).readAsStringSync(), 'original-a');
      expect(File(p.join(tmpDir.path, 'b.css')).readAsStringSync(), 'untouched-b');
      expect(File(p.join(tmpDir.path, 'c.css')).readAsStringSync(), 'original-c');
      expect(File(p.join(tmpDir.path, 'a.css.original')).existsSync(), isFalse);
      expect(File(p.join(tmpDir.path, 'c.css.original')).existsSync(), isFalse);
    });
  });
```

- [ ] **Step 3: Run tests**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/epub/book_css_repository_test.dart -v
```

Expected: All tests PASS.

- [ ] **Step 4: Commit**

```powershell
git add hibiki/lib/src/epub/book_css_repository.dart hibiki/test/epub/book_css_repository_test.dart
git commit -m "feat(css-editor): add read, safe-write, backup, and reset to BookCssRepository"
```

---

### Task 3: i18n Keys

**Files:**
- Modify: `hibiki/lib/i18n/strings.i18n.json`

- [ ] **Step 1: Add i18n keys to strings.i18n.json**

Add these flat keys (insert near the existing `custom_dict_css` keys around line 46 for grouping, or at the end of the file before the closing `}`):

```json
    "book_css_editor_title": "Edit Book CSS",
    "book_css_editor_edit_css": "Edit CSS",
    "book_css_editor_reset_current": "Reset Current",
    "book_css_editor_reset_all": "Reset All",
    "book_css_editor_save": "Save",
    "book_css_editor_no_css_files": "This book has no CSS files.",
    "book_css_editor_unsaved_changes": "Unsaved Changes",
    "book_css_editor_unsaved_changes_message": "You have unsaved changes. What would you like to do?",
    "book_css_editor_confirm_reset": "Reset this file to its original content?",
    "book_css_editor_confirm_reset_all": "Reset all modified CSS files to their original content?",
    "book_css_editor_save_button": "Save",
    "book_css_editor_discard": "Discard",
    "book_css_editor_cancel": "Cancel",
    "book_css_editor_saved": "CSS saved.",
    "book_css_editor_reset_done": "CSS reset.",
    "book_css_editor_no_extract_dir": "Book data not found on disk."
```

- [ ] **Step 2: Regenerate Slang**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat run slang
```

This regenerates `lib/i18n/strings.g.dart` with the new keys.

- [ ] **Step 3: Verify generation succeeded**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze lib/i18n/strings.g.dart
```

Expected: No errors (warnings about other files are OK).

- [ ] **Step 4: Commit**

```powershell
git add hibiki/lib/i18n/strings.i18n.json hibiki/lib/i18n/strings.g.dart
git commit -m "feat(css-editor): add i18n keys for book CSS editor"
```

---

### Task 4: BookCssEditorPage — UI

**Files:**
- Create: `hibiki/lib/src/pages/implementations/book_css_editor_page.dart`

This is the main editor page. It receives `extractDir` (already validated), creates a `BookCssRepository`, and renders Tab editor with save/reset.

- [ ] **Step 1: Create BookCssEditorPage**

Create `hibiki/lib/src/pages/implementations/book_css_editor_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/epub/book_css_repository.dart';

class BookCssEditorPage extends StatefulWidget {
  const BookCssEditorPage({super.key, required this.extractDir});

  final String extractDir;

  @override
  State<BookCssEditorPage> createState() => _BookCssEditorPageState();
}

class _BookCssEditorPageState extends State<BookCssEditorPage>
    with TickerProviderStateMixin {
  late BookCssRepository _repo;
  List<CssFileEntry> _entries = [];
  TabController? _tabController;

  final Map<int, TextEditingController> _textControllers = {};
  final Map<int, String> _diskContent = {};

  @override
  void initState() {
    super.initState();
    _repo = BookCssRepository(widget.extractDir);
    _reload();
  }

  void _reload() {
    _entries = _repo.discoverCssFiles();
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    _textControllers.clear();
    _diskContent.clear();

    _tabController?.dispose();
    if (_entries.isNotEmpty) {
      _tabController = TabController(length: _entries.length, vsync: this);
      _tabController!.addListener(_onTabChange);
      for (int i = 0; i < _entries.length; i++) {
        final String content = _repo.readCss(_entries[i]);
        _diskContent[i] = content;
        _textControllers[i] = TextEditingController(text: content);
      }
    } else {
      _tabController = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController?.removeListener(_onTabChange);
    _tabController?.dispose();
    for (final c in _textControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool _hasUnsavedChanges(int index) {
    final String? disk = _diskContent[index];
    final String? editor = _textControllers[index]?.text;
    return disk != null && editor != null && disk != editor;
  }

  bool _isModifiedFromOriginal(int index) {
    return _entries[index].isDifferentFromOriginal();
  }

  String _tabLabel(int index) {
    final String title = _entries[index].displayTitle;
    final bool modified = _isModifiedFromOriginal(index) ||
        _hasUnsavedChanges(index);
    return modified ? '* $title' : title;
  }

  int get _currentIndex => _tabController?.index ?? 0;

  Future<void> _onTabChange() async {
    // Tab change listener handles unsaved changes via _guardUnsaved
    // called in the tab's onTap callback below.
  }

  Future<bool> _guardUnsaved(int index) async {
    if (!_hasUnsavedChanges(index)) return true;

    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t.book_css_editor_unsaved_changes),
        content: Text(t.book_css_editor_unsaved_changes_message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: Text(t.book_css_editor_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: Text(t.book_css_editor_discard),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: Text(t.book_css_editor_save_button),
          ),
        ],
      ),
    );

    if (result == 'save') {
      _doSave(index);
      return true;
    } else if (result == 'discard') {
      _textControllers[index]!.text = _diskContent[index]!;
      return true;
    }
    return false; // cancel
  }

  void _doSave(int index) {
    final String content = _textControllers[index]!.text;
    _repo.saveCss(_entries[index], content);
    _diskContent[index] = content;
    _entries = _repo.discoverCssFiles(); // refresh .original state
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.book_css_editor_saved)),
    );
  }

  Future<void> _doResetCurrent() async {
    final int idx = _currentIndex;
    if (!_entries[idx].hasOriginal) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t.book_css_editor_unsaved_changes),
        content: Text(t.book_css_editor_confirm_reset),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.book_css_editor_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.book_css_editor_reset_current),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    _repo.resetFile(_entries[idx]);
    final String restored = _repo.readCss(_entries[idx]);
    _diskContent[idx] = restored;
    _textControllers[idx]!.text = restored;
    _entries = _repo.discoverCssFiles();
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.book_css_editor_reset_done)),
      );
    }
  }

  Future<void> _doResetAll() async {
    final bool hasAny = _entries.any((e) => e.hasOriginal);
    if (!hasAny) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t.book_css_editor_unsaved_changes),
        content: Text(t.book_css_editor_confirm_reset_all),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.book_css_editor_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.book_css_editor_reset_all),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    _repo.resetAll();
    _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.book_css_editor_reset_done)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(t.book_css_editor_title)),
        body: Center(child: Text(t.book_css_editor_no_css_files)),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, _) async {
        if (didPop) return;
        final bool canLeave = await _guardUnsaved(_currentIndex);
        if (canLeave && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.book_css_editor_title),
          actions: [
            TextButton(
              onPressed: _doResetAll,
              child: Text(t.book_css_editor_reset_all),
            ),
          ],
          bottom: TabBar(
            controller: _tabController,
            isScrollable: true,
            onTap: (int newIndex) async {
              final int previousIndex = _currentIndex;
              if (previousIndex == newIndex) return;
              // We need to guard before the tab switches.
              // TabBar.onTap fires before the controller animates.
              if (_hasUnsavedChanges(previousIndex)) {
                final bool ok = await _guardUnsaved(previousIndex);
                if (!ok) {
                  // Revert tab selection
                  _tabController!.animateTo(previousIndex);
                }
              }
            },
            tabs: List.generate(_entries.length, (i) {
              return Tab(text: _tabLabel(i));
            }),
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: List.generate(_entries.length, (i) {
            return Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextField(
                controller: _textControllers[i],
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
                decoration: InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
            );
          }),
        ),
        bottomNavigationBar: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              OutlinedButton(
                onPressed: _doResetCurrent,
                child: Text(t.book_css_editor_reset_current),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => _doSave(_currentIndex),
                child: Text(t.book_css_editor_save_button),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Run analyze**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze lib/src/pages/implementations/book_css_editor_page.dart
```

Expected: No errors.

- [ ] **Step 3: Commit**

```powershell
git add hibiki/lib/src/pages/implementations/book_css_editor_page.dart
git commit -m "feat(css-editor): add BookCssEditorPage with tab editor, save, reset, unsaved guards"
```

---

### Task 5: Wire Entry Point in Bookshelf

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hoshi_history_page.dart` (line ~634-659)

The `extraActions()` method is synchronous and returns `List<Widget>`. `EpubStorage.bookExists()` is async. Strategy: always show the button (we already have a valid `bookId` from `_parseBookId`), but on tap, async-check `bookExists()` and show toast if missing.

- [ ] **Step 1: Add import and button to extraActions()**

Add import at top of `reader_hoshi_history_page.dart`:

```dart
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
```

Then in `extraActions()` (after the existing profile picker button, before the closing `];`), add:

```dart
      TextButton(
        onPressed: () => _openCssEditor(bookId),
        child: Text(t.book_css_editor_edit_css),
      ),
```

- [ ] **Step 2: Add _openCssEditor method**

Add this method to the `_ReaderHoshiHistoryPageState` class (near the other `_open*` methods around line 712):

```dart
  Future<void> _openCssEditor(int bookId) async {
    final bool exists = await EpubStorage.bookExists(bookId);
    if (!exists) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.book_css_editor_no_extract_dir)),
        );
      }
      return;
    }
    final String extractDir = await EpubStorage.bookPath(bookId);
    if (mounted) {
      Navigator.pop(context); // close the dialog first
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => BookCssEditorPage(extractDir: extractDir),
        ),
      );
    }
  }
```

- [ ] **Step 3: Run analyze**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze lib/src/pages/implementations/reader_hoshi_history_page.dart
```

Expected: No errors.

- [ ] **Step 4: Commit**

```powershell
git add hibiki/lib/src/pages/implementations/reader_hoshi_history_page.dart
git commit -m "feat(css-editor): wire Edit CSS button into bookshelf long-press menu"
```

---

### Task 6: Full Verification

- [ ] **Step 1: Run dart format**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .
```

- [ ] **Step 2: Run flutter test (full suite)**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test
```

Expected: All tests pass, including the new `book_css_repository_test.dart`.

- [ ] **Step 3: Build release APK**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat build apk --release --split-per-abi --target-platform android-arm64
```

Expected: Build succeeds.

- [ ] **Step 4: Install on emulator and smoke-test**

```powershell
D:\android\platform-tools\adb.exe -s emulator-5556 install -r hibiki\build\app\outputs\flutter-apk\app-x86_64-release.apk
```

Manual verification:
1. Open app → book shelf → long-press a book → see "Edit CSS" button
2. Tap "Edit CSS" → CSS editor opens with tabs
3. Edit some CSS → tap Save → snackbar shows
4. Close and reopen → edit persists
5. Reset Current → content reverts
6. Verify `*` indicator on tabs tracks modification state

- [ ] **Step 5: Final commit (format fixes if any)**

```powershell
git add -A
git commit -m "style: format per-book CSS editor files"
```

---

## Async Caveat for extraActions()

`extraActions()` returns `List<Widget>` synchronously. We cannot call `EpubStorage.bookExists()` there. The button is always shown when `bookId != null` (which is already validated by the existing guard at line 635). The async `bookExists()` check happens on tap — if the extract directory is missing (corrupted state), the user sees a toast. This avoids restructuring the dialog system just for a pre-check.

## What This Plan Does NOT Do

- No database schema changes
- No WebView/`_interceptRequest` changes
- No changes to `ReaderResourceSanitizer`
- No non-English i18n files (Slang generates stubs for other locales automatically)
- No widget tests for `BookCssEditorPage` (repository tests cover the logic; UI is a standard TabBar + TextField composition)
