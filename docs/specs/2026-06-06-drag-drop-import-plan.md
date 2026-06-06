# 拖拽导入字幕 / 书籍 / 视频 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 桌面三端（Windows/macOS/Linux）支持把文件拖入应用窗口完成导入：书/视频拖到对应 tab 新建媒体并预填导入对话框；字幕/音频拖到某书卡/视频卡附加到该媒体。

**Architecture:** 按扩展名把拖入文件分四类（book/video/subtitle/audio），**落点决定语义**（.mp4 在视频页=视频、在书卡=音频）。每个 tab 一个页面级 `DropTarget`（来自 `desktop_drop`），拿到落点坐标后用「卡片登记表」做命中测试找到目标卡。所有落库走现成静态导入器/repo，三个对话框只加可选 `initial*` 预填参数（向后兼容）。

**Tech Stack:** Flutter 3.44 / Dart 3.12，`desktop_drop`，`file_picker`（现有），Riverpod，Drift。

**设计文档：** `docs/specs/2026-06-06-drag-drop-import-design.md`

**工作目录：** worktree `D:\APP\vs_claude_code\hibiki\.claude\worktrees\drag-drop-import`，分支 `worktree-drag-drop-import`。所有手动命令在此根下跑，**不要 cd 主仓库**。Flutter 测试在 `hibiki/` 子目录下跑。

---

## 文件结构

新增（全部在 `hibiki/lib/src/media/drag_drop/`，纯逻辑与 widget 分离）：

- `drop_classification.dart` — 纯函数：扩展名集合 + `DroppedFiles` + `classifyDroppedFiles`。
- `drop_decision.dart` — 纯函数：`DropSurface` / `DropIntent` + `decideDropIntent`。
- `card_hit_test.dart` — 纯函数：`hitTestCards`（矩形几何）。
- `card_drop_registry.dart` — `CardDropRegistry<T>` + `CardDropScope`（InheritedWidget）+ `CardDropZone`（注册/注销 widget）。
- `hibiki_file_drop_target.dart` — `HibikiFileDropTarget`（平台门控，封 `desktop_drop`）。

测试新增（`hibiki/test/media/drag_drop/`）：

- `drop_classification_test.dart`
- `drop_decision_test.dart`
- `card_hit_test_test.dart`
- `dialog_prefill_test.dart`
- `drag_drop_platform_guard_test.dart`（源码扫描守卫）

修改：

- `hibiki/pubspec.yaml` — 加 `desktop_drop`。
- `hibiki/lib/src/media/audiobook/book_import_dialog.dart` — 加 `initialEpubPath` / `initialSubtitlePath` + `initState`。
- `hibiki/lib/src/media/video/video_import_dialog.dart` — 加 `initialVideoPath` / `initialSubtitlePath` + `initState`。
- `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart` — 加 `initialAudioPaths` / `initialAlignmentPath`，在 `_initExisting` 收尾应用。
- `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart` — 书架 tab 接 `HibikiFileDropTarget` + 书卡接 `CardDropZone`。
- `hibiki/lib/src/pages/implementations/home_video_page.dart` — 视频 tab 接 `HibikiFileDropTarget` + 视频卡接 `CardDropZone`。
- `hibiki/lib/i18n/*.i18n.json`（经 `tool/i18n_sync.dart`）+ 重新生成 `strings.g.dart`。

---

## Task 1: 加 `desktop_drop` 依赖

**Files:**
- Modify: `hibiki/pubspec.yaml`

- [ ] **Step 1: 加依赖**

在 `hibiki/pubspec.yaml` 的 `dependencies:` 段加（紧挨已有桌面相关依赖，按字母序找合适位置）：

```yaml
  desktop_drop: ^0.5.0
```

- [ ] **Step 2: 拉取依赖**

Run（在 worktree 根）：
```bash
cd hibiki && flutter pub get
```
Expected: `Got dependencies!`（若网络拉包失败，本机有代理 `127.0.0.1:34151`，按 CLAUDE.local.md 设 `HTTPS_PROXY`/`HTTP_PROXY` 后重试）。

- [ ] **Step 3: Commit**

```bash
git add hibiki/pubspec.yaml hibiki/pubspec.lock
git commit -m "build(drag-drop): add desktop_drop dependency"
```

---

## Task 2: 文件分类纯函数

**Files:**
- Create: `hibiki/lib/src/media/drag_drop/drop_classification.dart`
- Test: `hibiki/test/media/drag_drop/drop_classification_test.dart`

- [ ] **Step 1: 写失败测试**

`hibiki/test/media/drag_drop/drop_classification_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';

void main() {
  group('classifyDroppedFiles', () {
    test('epub goes to books', () {
      final r = classifyDroppedFiles([r'C:\x\a.epub']);
      expect(r.books, [r'C:\x\a.epub']);
      expect(r.videos, isEmpty);
      expect(r.subtitles, isEmpty);
      expect(r.audios, isEmpty);
    });

    test('text formats go to books', () {
      final r = classifyDroppedFiles(['/x/a.txt', '/x/b.md']);
      expect(r.books, ['/x/a.txt', '/x/b.md']);
    });

    test('subtitle extensions go to subtitles', () {
      final r = classifyDroppedFiles(['/x/a.srt', '/x/b.vtt', '/x/c.ass', '/x/d.ssa', '/x/e.lrc']);
      expect(r.subtitles, hasLength(5));
    });

    test('mp4 is BOTH video and audio (resolved by drop surface)', () {
      final r = classifyDroppedFiles(['/x/movie.mp4']);
      expect(r.videos, ['/x/movie.mp4']);
      expect(r.audios, ['/x/movie.mp4']);
    });

    test('mkv is video only', () {
      final r = classifyDroppedFiles(['/x/a.mkv']);
      expect(r.videos, ['/x/a.mkv']);
      expect(r.audios, isEmpty);
    });

    test('mp3 is audio only', () {
      final r = classifyDroppedFiles(['/x/a.mp3']);
      expect(r.audios, ['/x/a.mp3']);
      expect(r.videos, isEmpty);
    });

    test('extension match is case-insensitive', () {
      final r = classifyDroppedFiles(['/x/A.EPUB', '/x/B.SRT']);
      expect(r.books, ['/x/A.EPUB']);
      expect(r.subtitles, ['/x/B.SRT']);
    });

    test('unknown extension goes to unknown', () {
      final r = classifyDroppedFiles(['/x/a.zip']);
      expect(r.unknown, ['/x/a.zip']);
    });

    test('isEmpty true when nothing classified into media', () {
      expect(classifyDroppedFiles([]).hasAny, isFalse);
      expect(classifyDroppedFiles(['/x/a.epub']).hasAny, isTrue);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
cd hibiki && flutter test test/media/drag_drop/drop_classification_test.dart --no-pub
```
Expected: 编译失败（`drop_classification.dart` 不存在）。

- [ ] **Step 3: 实现**

`hibiki/lib/src/media/drag_drop/drop_classification.dart`:
```dart
import 'package:path/path.dart' as p;

/// 书籍扩展名（不带点，小写）。= epub + TextToEpub.supportedExtensions。
const Set<String> kDragBookExtensions = <String>{
  'epub',
  'txt', 'html', 'htm', 'xhtml', 'md', 'markdown', 'rst',
  'org', 'csv', 'tsv', 'log', 'json', 'xml',
};

/// 字幕扩展名（不带点，小写）。
const Set<String> kDragSubtitleExtensions = <String>{
  'srt', 'vtt', 'ass', 'ssa', 'lrc',
};

/// 视频扩展名（不带点，小写）。
const Set<String> kDragVideoExtensions = <String>{
  'mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v', 'flv', 'ts', 'wmv', 'mpg', 'mpeg', 'm2ts',
};

/// 音频扩展名（不带点，小写）。镜像 AudiobookStorage.audioExtensions（守卫测试钉死同步）。
const Set<String> kDragAudioExtensions = <String>{
  'mp3', 'm4a', 'm4b', 'aac', 'ogg', 'opus', 'flac', 'wav', 'wma', 'ac3', 'eac3', 'mp4',
};

/// 拖入文件按扩展名分类的结果。一个路径可同时落入多个类（如 .mp4 既是视频又是音频），
/// 由落点上下文（DropSurface）决定最终语义。
class DroppedFiles {
  const DroppedFiles({
    required this.books,
    required this.videos,
    required this.subtitles,
    required this.audios,
    required this.unknown,
  });

  final List<String> books;
  final List<String> videos;
  final List<String> subtitles;
  final List<String> audios;
  final List<String> unknown;

  /// 是否有任何可被本功能识别（非 unknown）的文件。
  bool get hasAny =>
      books.isNotEmpty ||
      videos.isNotEmpty ||
      subtitles.isNotEmpty ||
      audios.isNotEmpty;
}

String _ext(String path) {
  final String e = p.extension(path); // 含前导点，如 ".EPUB"
  if (e.isEmpty) return '';
  return e.substring(1).toLowerCase();
}

/// 把拖入文件路径按扩展名分类。纯函数，无副作用。
DroppedFiles classifyDroppedFiles(List<String> paths) {
  final List<String> books = <String>[];
  final List<String> videos = <String>[];
  final List<String> subtitles = <String>[];
  final List<String> audios = <String>[];
  final List<String> unknown = <String>[];

  for (final String path in paths) {
    final String ext = _ext(path);
    bool matched = false;
    if (kDragBookExtensions.contains(ext)) {
      books.add(path);
      matched = true;
    }
    if (kDragVideoExtensions.contains(ext)) {
      videos.add(path);
      matched = true;
    }
    if (kDragSubtitleExtensions.contains(ext)) {
      subtitles.add(path);
      matched = true;
    }
    if (kDragAudioExtensions.contains(ext)) {
      audios.add(path);
      matched = true;
    }
    if (!matched) unknown.add(path);
  }

  return DroppedFiles(
    books: books,
    videos: videos,
    subtitles: subtitles,
    audios: audios,
    unknown: unknown,
  );
}
```

> 注：`json` 同时在 book 与（AudiobookImportDialog 的对齐）字幕语义里。这里把 `json` 归 book（纯文本书），不归 subtitle——拖到书卡的对齐 json 属少见高级用法，YAGNI，不在分类层处理。

- [ ] **Step 4: 跑测试确认通过**

Run:
```bash
cd hibiki && flutter test test/media/drag_drop/drop_classification_test.dart --no-pub
```
Expected: All tests passed.

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/media/drag_drop/drop_classification.dart hibiki/test/media/drag_drop/drop_classification_test.dart
git commit -m "feat(drag-drop): file classification by extension"
```

---

## Task 3: 音频扩展名同步守卫测试

**Files:**
- Modify: `hibiki/test/media/drag_drop/drop_classification_test.dart`

防 `kDragAudioExtensions` 与 `AudiobookStorage.audioExtensions` 漂移（后者加格式时强制本表跟进）。

- [ ] **Step 1: 加守卫测试**

在 `drop_classification_test.dart` 顶部加 import：
```dart
import 'package:hibiki_audio/hibiki_audio.dart';
```
在 `main()` 里加 group：
```dart
  test('kDragAudioExtensions stays in sync with AudiobookStorage.audioExtensions', () {
    // AudiobookStorage 用带点小写扩展名；本表不带点。规整后比较。
    final Set<String> storage =
        AudiobookStorage.audioExtensions.map((String e) => e.replaceFirst('.', '')).toSet();
    expect(kDragAudioExtensions, equals(storage),
        reason: '音频扩展名漂移：更新 kDragAudioExtensions 与 AudiobookStorage.audioExtensions 保持一致');
  });
```

- [ ] **Step 2: 跑测试**

Run:
```bash
cd hibiki && flutter test test/media/drag_drop/drop_classification_test.dart --no-pub
```
Expected: PASS。若 import 报 `AudiobookStorage` 未导出 → 打开 `packages/hibiki_audio/lib/hibiki_audio.dart`，加一行 `export 'src/audiobook/audiobook_storage.dart';`（仅当未导出时）。若比较失败 → 按报错把 `kDragAudioExtensions` 调到与 storage 一致后重跑。

- [ ] **Step 3: Commit**

```bash
git add hibiki/test/media/drag_drop/drop_classification_test.dart packages/hibiki_audio/lib/hibiki_audio.dart
git commit -m "test(drag-drop): guard audio extension list against drift"
```

---

## Task 4: 落点决策纯函数

**Files:**
- Create: `hibiki/lib/src/media/drag_drop/drop_decision.dart`
- Test: `hibiki/test/media/drag_drop/drop_decision_test.dart`

- [ ] **Step 1: 写失败测试**

`hibiki/test/media/drag_drop/drop_decision_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/drop_decision.dart';

DroppedFiles _files({
  List<String> books = const [],
  List<String> videos = const [],
  List<String> subtitles = const [],
  List<String> audios = const [],
}) =>
    DroppedFiles(books: books, videos: videos, subtitles: subtitles, audios: audios, unknown: const []);

void main() {
  group('decideDropIntent — books surface', () {
    test('book file -> importNewBook', () {
      expect(
        decideDropIntent(surface: DropSurface.books, files: _files(books: ['/a.epub']), cardHit: false),
        DropIntent.importNewBook,
      );
    });
    test('subtitle on a card -> attachToBookCard', () {
      expect(
        decideDropIntent(surface: DropSurface.books, files: _files(subtitles: ['/a.srt']), cardHit: true),
        DropIntent.attachToBookCard,
      );
    });
    test('audio not on a card -> needCardTarget', () {
      expect(
        decideDropIntent(surface: DropSurface.books, files: _files(audios: ['/a.mp3']), cardHit: false),
        DropIntent.needCardTarget,
      );
    });
    test('book wins over subtitle when both dropped', () {
      expect(
        decideDropIntent(surface: DropSurface.books, files: _files(books: ['/a.epub'], subtitles: ['/a.srt']), cardHit: false),
        DropIntent.importNewBook,
      );
    });
    test('nothing relevant -> ignore', () {
      expect(
        decideDropIntent(surface: DropSurface.books, files: _files(videos: ['/a.mkv']), cardHit: false),
        DropIntent.ignore,
      );
    });
  });

  group('decideDropIntent — video surface', () {
    test('video file -> importNewVideo', () {
      expect(
        decideDropIntent(surface: DropSurface.video, files: _files(videos: ['/a.mkv']), cardHit: false),
        DropIntent.importNewVideo,
      );
    });
    test('subtitle on a video card -> attachToVideoCard', () {
      expect(
        decideDropIntent(surface: DropSurface.video, files: _files(subtitles: ['/a.srt']), cardHit: true),
        DropIntent.attachToVideoCard,
      );
    });
    test('subtitle not on a card -> needCardTarget', () {
      expect(
        decideDropIntent(surface: DropSurface.video, files: _files(subtitles: ['/a.srt']), cardHit: false),
        DropIntent.needCardTarget,
      );
    });
    test('audio-only on video surface -> ignore (video cards do not take audio)', () {
      expect(
        decideDropIntent(surface: DropSurface.video, files: _files(audios: ['/a.mp3']), cardHit: true),
        DropIntent.ignore,
      );
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
cd hibiki && flutter test test/media/drag_drop/drop_decision_test.dart --no-pub
```
Expected: 编译失败（`drop_decision.dart` 不存在）。

- [ ] **Step 3: 实现**

`hibiki/lib/src/media/drag_drop/drop_decision.dart`:
```dart
import 'drop_classification.dart';

/// 拖拽落点所在的 tab 表面。
enum DropSurface { books, video }

/// 决策结果意图。widget 层据此打开对话框 / 提示 / 忽略。
enum DropIntent {
  importNewBook,
  importNewVideo,
  attachToBookCard,
  attachToVideoCard,
  needCardTarget,
  ignore,
}

/// 根据落点表面、文件分类、是否命中卡片，决定要做什么。纯函数。
///
/// 规则：
/// - books 表面：有书文件→新建书；否则有字幕/音频→命中卡则附加、否则提示需要目标卡；其余忽略。
/// - video 表面：有视频文件→新建视频；否则有字幕→命中卡则附加、否则提示；其余忽略
///   （视频卡不接受音频，故 video 表面下只看 subtitles）。
DropIntent decideDropIntent({
  required DropSurface surface,
  required DroppedFiles files,
  required bool cardHit,
}) {
  switch (surface) {
    case DropSurface.books:
      if (files.books.isNotEmpty) return DropIntent.importNewBook;
      if (files.subtitles.isNotEmpty || files.audios.isNotEmpty) {
        return cardHit ? DropIntent.attachToBookCard : DropIntent.needCardTarget;
      }
      return DropIntent.ignore;
    case DropSurface.video:
      if (files.videos.isNotEmpty) return DropIntent.importNewVideo;
      if (files.subtitles.isNotEmpty) {
        return cardHit ? DropIntent.attachToVideoCard : DropIntent.needCardTarget;
      }
      return DropIntent.ignore;
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run:
```bash
cd hibiki && flutter test test/media/drag_drop/drop_decision_test.dart --no-pub
```
Expected: All tests passed.

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/media/drag_drop/drop_decision.dart hibiki/test/media/drag_drop/drop_decision_test.dart
git commit -m "feat(drag-drop): drop intent decision (pure)"
```

---

## Task 5: 卡片命中测试纯函数

**Files:**
- Create: `hibiki/lib/src/media/drag_drop/card_hit_test.dart`
- Test: `hibiki/test/media/drag_drop/card_hit_test_test.dart`

- [ ] **Step 1: 写失败测试**

`hibiki/test/media/drag_drop/card_hit_test_test.dart`:
```dart
import 'package:flutter/widgets.dart' show Rect, Offset;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/drag_drop/card_hit_test.dart';

void main() {
  group('hitTestCards', () {
    final cards = <CardRect<String>>[
      CardRect(rect: const Rect.fromLTWH(0, 0, 100, 100), meta: 'a'),
      CardRect(rect: const Rect.fromLTWH(100, 0, 100, 100), meta: 'b'),
    ];

    test('returns meta of card containing the point', () {
      expect(hitTestCards(cards, const Offset(50, 50)), 'a');
      expect(hitTestCards(cards, const Offset(150, 50)), 'b');
    });

    test('returns null when point is outside all cards', () {
      expect(hitTestCards(cards, const Offset(300, 300)), isNull);
    });

    test('returns first match on overlap', () {
      final overlap = <CardRect<String>>[
        CardRect(rect: const Rect.fromLTWH(0, 0, 100, 100), meta: 'first'),
        CardRect(rect: const Rect.fromLTWH(0, 0, 100, 100), meta: 'second'),
      ];
      expect(hitTestCards(overlap, const Offset(10, 10)), 'first');
    });

    test('empty list returns null', () {
      expect(hitTestCards(<CardRect<String>>[], const Offset(0, 0)), isNull);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
cd hibiki && flutter test test/media/drag_drop/card_hit_test_test.dart --no-pub
```
Expected: 编译失败（`card_hit_test.dart` 不存在）。

- [ ] **Step 3: 实现**

`hibiki/lib/src/media/drag_drop/card_hit_test.dart`:
```dart
import 'package:flutter/widgets.dart' show Rect, Offset;

/// 一张卡片的屏幕矩形 + 其元数据。
class CardRect<T> {
  const CardRect({required this.rect, required this.meta});
  final Rect rect;
  final T meta;
}

/// 返回首个包含 [point] 的卡片 meta；都不包含返回 null。纯函数。
T? hitTestCards<T>(List<CardRect<T>> cards, Offset point) {
  for (final CardRect<T> card in cards) {
    if (card.rect.contains(point)) return card.meta;
  }
  return null;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run:
```bash
cd hibiki && flutter test test/media/drag_drop/card_hit_test_test.dart --no-pub
```
Expected: All tests passed.

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/media/drag_drop/card_hit_test.dart hibiki/test/media/drag_drop/card_hit_test_test.dart
git commit -m "feat(drag-drop): card rect hit-test (pure)"
```

---

## Task 6: 卡片登记表 + Scope + Zone widget

**Files:**
- Create: `hibiki/lib/src/media/drag_drop/card_drop_registry.dart`

无独立 widget 测试（GlobalKey/RenderBox 命中靠真机；纯几何已在 Task 5 覆盖）。本任务只产出 widget 设施，编译通过即可。

- [ ] **Step 1: 实现**

`hibiki/lib/src/media/drag_drop/card_drop_registry.dart`:
```dart
import 'package:flutter/widgets.dart';

import 'card_hit_test.dart';

/// 收集当前屏上所有可作为字幕/音频拖放目标的卡片，提供按落点命中测试。
/// 范型 T = 卡片元数据（书卡用 String bookKey，视频卡用 VideoBookRow）。
class CardDropRegistry<T> {
  final Map<GlobalKey, T> _entries = <GlobalKey, T>{};

  void register(GlobalKey key, T meta) => _entries[key] = meta;
  void unregister(GlobalKey key) => _entries.remove(key);

  /// 用 [globalPosition]（屏幕坐标）命中卡片，返回 meta 或 null。
  T? hitTest(Offset globalPosition) {
    final List<CardRect<T>> rects = <CardRect<T>>[];
    for (final MapEntry<GlobalKey, T> e in _entries.entries) {
      final BuildContext? ctx = e.key.currentContext;
      if (ctx == null) continue;
      final RenderObject? ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.attached) continue;
      final Offset topLeft = ro.localToGlobal(Offset.zero);
      rects.add(CardRect<T>(rect: topLeft & ro.size, meta: e.value));
    }
    return hitTestCards<T>(rects, globalPosition);
  }
}

/// 把 registry 下发给子树卡片。
class CardDropScope<T> extends InheritedWidget {
  const CardDropScope({required this.registry, required super.child, super.key});

  final CardDropRegistry<T> registry;

  static CardDropRegistry<T>? maybeOf<T>(BuildContext context) {
    final CardDropScope<T>? scope =
        context.dependOnInheritedWidgetOfExactType<CardDropScope<T>>();
    return scope?.registry;
  }

  @override
  bool updateShouldNotify(CardDropScope<T> oldWidget) => registry != oldWidget.registry;
}

/// 包住一张卡片：挂 GlobalKey，并在生命周期内向最近的 CardDropScope 注册/注销自己。
class CardDropZone<T> extends StatefulWidget {
  const CardDropZone({required this.meta, required this.child, super.key});

  final T meta;
  final Widget child;

  @override
  State<CardDropZone<T>> createState() => _CardDropZoneState<T>();
}

class _CardDropZoneState<T> extends State<CardDropZone<T>> {
  final GlobalKey _key = GlobalKey();
  CardDropRegistry<T>? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final CardDropRegistry<T>? next = CardDropScope.maybeOf<T>(context);
    if (!identical(next, _registry)) {
      _registry?.unregister(_key);
      _registry = next;
      _registry?.register(_key, widget.meta);
    }
  }

  @override
  void didUpdateWidget(CardDropZone<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.meta != widget.meta) {
      _registry?.register(_key, widget.meta);
    }
  }

  @override
  void dispose() {
    _registry?.unregister(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(key: _key, child: widget.child);
}
```

- [ ] **Step 2: 编译验证**

Run:
```bash
cd hibiki && flutter analyze lib/src/media/drag_drop/card_drop_registry.dart
```
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/src/media/drag_drop/card_drop_registry.dart
git commit -m "feat(drag-drop): card drop registry + scope + zone"
```

---

## Task 7: 平台门控 DropTarget 封装

**Files:**
- Create: `hibiki/lib/src/media/drag_drop/hibiki_file_drop_target.dart`

- [ ] **Step 1: 实现**

`hibiki/lib/src/media/drag_drop/hibiki_file_drop_target.dart`:
```dart
import 'dart:io' show Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

/// 拖入文件落地后回调：paths = 拖入文件绝对路径，localPosition = 落点（相对本 widget 左上角）。
typedef FileDropCallback = void Function(List<String> paths, Offset localPosition);

/// 仅桌面三端启用 desktop_drop；其余平台直接透传 child（零开销）。
class HibikiFileDropTarget extends StatelessWidget {
  const HibikiFileDropTarget({required this.onDrop, required this.child, super.key});

  final FileDropCallback onDrop;
  final Widget child;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) return child;
    return DropTarget(
      onDragDone: (DropDoneDetails detail) {
        final List<String> paths = detail.files
            .map((XFile f) => f.path)
            .where((String s) => s.isNotEmpty)
            .toList();
        if (paths.isEmpty) return;
        onDrop(paths, detail.localPosition);
      },
      child: child,
    );
  }
}
```

> `XFile` 由 `desktop_drop` 经 `cross_file` 重导出；`detail.localPosition` 是相对 DropTarget 的局部坐标。卡片登记表的命中测试用屏幕坐标，故 widget 接线处需把 localPosition 经本 DropTarget 的 RenderBox `localToGlobal` 转屏幕坐标后再传给 `registry.hitTest`（见 Task 9/10）。

- [ ] **Step 2: 编译验证**

Run:
```bash
cd hibiki && flutter analyze lib/src/media/drag_drop/hibiki_file_drop_target.dart
```
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/src/media/drag_drop/hibiki_file_drop_target.dart
git commit -m "feat(drag-drop): platform-gated file drop target wrapper"
```

---

## Task 8: 提示文案 i18n key

**Files:**
- Modify: `hibiki/lib/i18n/*.i18n.json`（经脚本）+ `hibiki/lib/i18n/strings.g.dart`（重新生成）

- [ ] **Step 1: 加 key**

Run（在 worktree 根，**禁止手改 17 个 json**）：
```bash
cd hibiki && dart run tool/i18n_sync.dart --add drag_drop_need_card_target "Drop subtitles or audio onto a book or video" "请把字幕或音频拖到某本书或某个视频上"
```
Expected: 17 个语言文件补齐该 key。

- [ ] **Step 2: 重新生成 strings.g.dart**

Run:
```bash
cd hibiki && dart run slang && dart format lib/i18n/strings.g.dart
```
Expected: `strings.g.dart` 含 `drag_drop_need_card_target` getter。

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/i18n
git commit -m "i18n(drag-drop): add drag_drop_need_card_target"
```

---

## Task 9: 三个对话框加 `initial*` 预填参数

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/book_import_dialog.dart`
- Modify: `hibiki/lib/src/media/video/video_import_dialog.dart`
- Modify: `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart`
- Test: `hibiki/test/media/drag_drop/dialog_prefill_test.dart`

### 9A. BookImportDialog

- [ ] **Step 1: 改构造函数**（`book_import_dialog.dart:31-40`）

把构造改为带可选预填参数：
```dart
  const BookImportDialog({
    required this.repo,
    required this.audiobookRepo,
    required this.db,
    this.initialEpubPath,
    this.initialSubtitlePath,
    super.key,
  });

  final SrtBookRepository repo;
  final AudiobookRepository audiobookRepo;
  final HibikiDatabase db;
  final String? initialEpubPath;
  final String? initialSubtitlePath;
```

- [ ] **Step 2: 加 initState 应用预填**

该 State 当前**无 initState**（只有 dispose）。在 State 类里加（`import 'package:path/path.dart' as p;` 若文件未引入则加到顶部 import）：
```dart
  @override
  void initState() {
    super.initState();
    final String? epub = widget.initialEpubPath;
    if (epub != null) {
      _epubPath = epub;
      _epubName = p.basename(epub);
      if (_titleCtrl.text.isEmpty) {
        _titleCtrl.text = p.basenameWithoutExtension(epub);
      }
    }
    final String? sub = widget.initialSubtitlePath;
    if (sub != null) {
      _subtitlePath = sub;
      _subtitleName = p.basename(sub);
    }
  }
```
> 字段名 `_epubPath`/`_epubName`/`_subtitlePath`/`_subtitleName` 与 `_titleCtrl` 取自现有 State（`:50-58`，`_pickEpub`/`_pickSubtitle` 同款赋值）。`initState` 里 setState 不需要（build 尚未发生）。

### 9B. VideoImportDialog

- [ ] **Step 3: 改构造函数**（`video_import_dialog.dart:152-155`）
```dart
  const VideoImportDialog({
    required this.repo,
    this.initialVideoPath,
    this.initialSubtitlePath,
    super.key,
  });

  final VideoBookRepository repo;
  final String? initialVideoPath;
  final String? initialSubtitlePath;
```

- [ ] **Step 4: 加 initState**（当前 State 无 lifecycle override）
```dart
  @override
  void initState() {
    super.initState();
    _videoPath = widget.initialVideoPath;
    _subtitlePath = widget.initialSubtitlePath;
  }
```
> 字段 `_videoPath`/`_subtitlePath` 取自现有 State（`:162-164`）。

### 9C. AudiobookImportDialog

- [ ] **Step 5: 改构造函数**（`audiobook_import_dialog.dart:19-38`）
```dart
  const AudiobookImportDialog({
    required this.bookKey,
    required this.repo,
    this.extractDir,
    this.audioOnly = false,
    this.initialAudioPaths,
    this.initialAlignmentPath,
    super.key,
  });

  final String bookKey;
  final AudiobookRepository repo;
  final String? extractDir;
  final bool audioOnly;
  final List<String>? initialAudioPaths;
  final String? initialAlignmentPath;
```

- [ ] **Step 6: 在 `_initExisting` 收尾应用预填**（`audiobook_import_dialog.dart:114-128`）

在 `_initExisting` 的 `setState(() { ... })` 块**末尾**（`_alignmentPath = existing.alignmentPath;` 之后、闭合 `}` 之前）追加，让拖入值覆盖 existing 推断值：
```dart
      final List<String>? dropAudio = widget.initialAudioPaths;
      if (dropAudio != null && dropAudio.isNotEmpty) {
        _audioPaths = dropAudio;
        _audioDir = null;
      }
      final String? dropAlign = widget.initialAlignmentPath;
      if (dropAlign != null) {
        _alignmentPath = dropAlign;
        _alignmentName = p.basename(dropAlign);
      }
```
> 字段 `_audioPaths`/`_audioDir`/`_alignmentPath`/`_alignmentName` 取自现有 State（`:46-49`）。确认文件已 `import 'package:path/path.dart' as p;`；若 `_alignmentName` 既有赋值用别的取名方式，沿用之（`_pickAlignment` 用 `file.name`，这里无 PlatformFile，故用 `p.basename`）。若文件未引入 path 包，在顶部加 import。

### 9D. 预填 widget 行为测试

- [ ] **Step 7: 写测试**

`hibiki/test/media/drag_drop/dialog_prefill_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';
// VideoBookRepository 构造需要数据库；用内存库。
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  testWidgets('VideoImportDialog prefills dragged video path into UI', (tester) async {
    final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoImportDialog(
            repo: VideoBookRepository(db),
            initialVideoPath: r'C:\movies\Spirited Away.mkv',
          ),
        ),
      ),
    );
    await tester.pump();
    // 文件名应出现在对话框里（已选视频展示）。
    expect(find.textContaining('Spirited Away'), findsWidgets);
  });
}
```
> 若 `VideoBookRepository` 的构造签名 / `HibikiDatabase.forTesting` 写法与本仓库不符，参照现有 video 相关测试（如 `hibiki/test/media/video/` 下）建库方式对齐；目标只是断言 `initialVideoPath` 的文件名渲染进了对话框。若对话框不直接显示文件名而显示「已选择」状态，改断言对应状态文案/控件。

- [ ] **Step 8: 跑测试 + analyze**

Run:
```bash
cd hibiki && flutter test test/media/drag_drop/dialog_prefill_test.dart --no-pub && flutter analyze lib/src/media/audiobook/book_import_dialog.dart lib/src/media/video/video_import_dialog.dart lib/src/media/audiobook/audiobook_import_dialog.dart
```
Expected: PASS + No issues found。

- [ ] **Step 9: Commit**

```bash
git add hibiki/lib/src/media/audiobook/book_import_dialog.dart hibiki/lib/src/media/video/video_import_dialog.dart hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart hibiki/test/media/drag_drop/dialog_prefill_test.dart
git commit -m "feat(drag-drop): optional initial* prefill on import dialogs"
```

---

## Task 10: 接线书架 tab（books 表面）

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`

目标：① build 返回的内容滚动区外层包 `HibikiFileDropTarget` + `CardDropScope<String>`（registry 范型=bookKey）；② 书卡（`buildMediaItem` / `_bookCardShell`）外包 `CardDropZone<String>(meta: bookKey)`；③ `onDrop` 实现决策路由。

- [ ] **Step 1: 读文件定位挂载点**

Run:
```bash
cd hibiki && sed -n '1,60p;690,800p;1200,1270p' lib/src/pages/implementations/reader_hibiki_history_page.dart
```
找到：`build()` 返回的顶层滚动 widget；`_bookCardShell({...})`（`:702`，已含内部 `BookDragTarget` 标签拖放壳）；`buildMediaItem`（`:1224`，`bookKey` 在 `:1225`）。

- [ ] **Step 2: 加 imports + registry 字段**

文件顶部加：
```dart
import 'package:hibiki/src/media/drag_drop/card_drop_registry.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/drop_decision.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
```
（已存在的 import 不重复加。）在 State 类字段区加：
```dart
  final CardDropRegistry<String> _cardDropRegistry = CardDropRegistry<String>();
```

- [ ] **Step 3: 包书卡为拖放目标**

在 `buildMediaItem`（`:1224`）返回 EPUB 书卡的最外层，用 `CardDropZone<String>` 包裹（仅当 `bookKey != null`）：
```dart
    final Widget card = /* 现有书卡 widget */;
    if (bookKey == null) return card;
    return CardDropZone<String>(meta: bookKey, child: card);
```
> `buildMediaItem` 现有返回值赋给 `card`，最后改成上面这段。`_buildSrtCard`/`_buildVideoCard` 不在 books 表面拖放范围内（SRT 书走有声书别径、视频在视频 tab），本任务不包它们。

- [ ] **Step 4: 包内容区为 DropTarget + Scope，并实现 onDrop**

在 `build()` 返回的顶层滚动 widget 外层包：
```dart
    return HibikiFileDropTarget(
      onDrop: _handleShelfDrop,
      child: CardDropScope<String>(
        registry: _cardDropRegistry,
        child: /* 现有顶层滚动 widget */,
      ),
    );
```
在 State 类加处理方法：
```dart
  void _handleShelfDrop(List<String> paths, Offset localPosition) {
    final DroppedFiles files = classifyDroppedFiles(paths);
    // localPosition 转屏幕坐标用于卡片命中。
    final RenderObject? ro = context.findRenderObject();
    Offset global = localPosition;
    if (ro is RenderBox && ro.attached) {
      global = ro.localToGlobal(localPosition);
    }
    final String? hitBookKey = _cardDropRegistry.hitTest(global);
    final DropIntent intent = decideDropIntent(
      surface: DropSurface.books,
      files: files,
      cardHit: hitBookKey != null,
    );
    switch (intent) {
      case DropIntent.importNewBook:
        _openBookImportPrefilled(
          epubPath: files.books.first,
          subtitlePath: files.subtitles.isNotEmpty ? files.subtitles.first : null,
        );
      case DropIntent.attachToBookCard:
        _openAudiobookPrefilled(
          bookKey: hitBookKey!,
          audioPaths: files.audios,
          alignmentPath: files.subtitles.isNotEmpty ? files.subtitles.first : null,
        );
      case DropIntent.needCardTarget:
        _showDropHint();
      case DropIntent.importNewVideo:
      case DropIntent.attachToVideoCard:
      case DropIntent.ignore:
        break;
    }
  }
```
> `_openBookImportPrefilled` 复用现有打开 `BookImportDialog` 的方式（参照 `ReaderHibikiSource.buildBookImportButton` 的 `showAppDialog<...>(... BookImportDialog(repo:..., audiobookRepo:..., db:...))`），只多传 `initialEpubPath`/`initialSubtitlePath`。`_openAudiobookPrefilled` 复用 `_openAudiobookImport`（`:1396`）打开 `AudiobookImportDialog` 的方式：先 `final row = await appModel.database.getEpubBook(bookKey); final extractDir = row?.extractDir;`（取 extractDir 的现成 pattern 见 `:1440-1441`），再 `AudiobookImportDialog(bookKey: bookKey, repo: <audiobookRepo>, extractDir: extractDir, initialAudioPaths: audioPaths.isEmpty ? null : audioPaths, initialAlignmentPath: alignmentPath)`。`_showDropHint` = `ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.drag_drop_need_card_target)))`（`t` 取现有 i18n 访问方式）。这三个 helper 照搬该文件既有对话框打开/取库/SnackBar 写法，签名自洽即可。

- [ ] **Step 5: analyze**

Run:
```bash
cd hibiki && flutter analyze lib/src/pages/implementations/reader_hibiki_history_page.dart
```
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart
git commit -m "feat(drag-drop): wire shelf tab file drop (book import + subtitle/audio to card)"
```

---

## Task 11: 接线视频 tab（video 表面）

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/home_video_page.dart`

- [ ] **Step 1: 读文件定位**

Run:
```bash
cd hibiki && sed -n '1,60p;40,170p' lib/src/pages/implementations/home_video_page.dart
```
找到：`build()` 顶层（视频网格滚动区）；`_buildCard(VideoBookRow book)`（`:136`，`book.bookUid` 在 `:138`）；`_open(book)`（`:53`）。

- [ ] **Step 2: 加 imports + registry 字段**

顶部加：
```dart
import 'package:hibiki/src/media/drag_drop/card_drop_registry.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/drop_decision.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
```
State 字段区加（范型=VideoBookRow）：
```dart
  final CardDropRegistry<VideoBookRow> _cardDropRegistry = CardDropRegistry<VideoBookRow>();
```

- [ ] **Step 3: 包视频卡**

在 `_buildCard`（`:136`）返回的最外层用 `CardDropZone<VideoBookRow>(meta: book, child: <现有卡片>)` 包裹。

- [ ] **Step 4: 包内容区 + onDrop**

`build()` 顶层滚动区外包：
```dart
    return HibikiFileDropTarget(
      onDrop: _handleVideoDrop,
      child: CardDropScope<VideoBookRow>(
        registry: _cardDropRegistry,
        child: /* 现有顶层视频网格 widget */,
      ),
    );
```
加处理方法：
```dart
  void _handleVideoDrop(List<String> paths, Offset localPosition) {
    final DroppedFiles files = classifyDroppedFiles(paths);
    final RenderObject? ro = context.findRenderObject();
    Offset global = localPosition;
    if (ro is RenderBox && ro.attached) {
      global = ro.localToGlobal(localPosition);
    }
    final VideoBookRow? hit = _cardDropRegistry.hitTest(global);
    final DropIntent intent = decideDropIntent(
      surface: DropSurface.video,
      files: files,
      cardHit: hit != null,
    );
    switch (intent) {
      case DropIntent.importNewVideo:
        _openVideoImportPrefilled(
          videoPath: files.videos.first,
          subtitlePath: files.subtitles.isNotEmpty ? files.subtitles.first : null,
        );
      case DropIntent.attachToVideoCard:
        _attachSubtitleToVideo(hit!, files.subtitles.first);
      case DropIntent.needCardTarget:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(/* t.drag_drop_need_card_target */)),
        );
      case DropIntent.importNewBook:
      case DropIntent.attachToBookCard:
      case DropIntent.ignore:
        break;
    }
  }
```
> `_openVideoImportPrefilled` 复用现有打开 `VideoImportDialog` 的方式（`home_video_page.dart:46` 的 `showAppDialog<String>(... VideoImportDialog(repo: widget.repo))`），多传 `initialVideoPath`/`initialSubtitlePath`，关闭后照现有逻辑刷新列表。`_attachSubtitleToVideo(book, subPath)`：复用 `VideoImportDialog` 的外挂字幕路径（最省=打开 `VideoImportDialog(repo: widget.repo, initialVideoPath: book.path, initialSubtitlePath: subPath)` 让用户确认后保存——它会按文件名派生 bookUid，对同一视频幂等覆盖 cue）。`t` 用本文件现有 i18n 访问方式（参照同文件其它 `Text(t....)`）。

- [ ] **Step 5: analyze**

Run:
```bash
cd hibiki && flutter analyze lib/src/pages/implementations/home_video_page.dart
```
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add hibiki/lib/src/pages/implementations/home_video_page.dart
git commit -m "feat(drag-drop): wire video tab file drop (video import + subtitle to card)"
```

---

## Task 12: 平台门控源码守卫测试

**Files:**
- Create: `hibiki/test/media/drag_drop/drag_drop_platform_guard_test.dart`

防止 `desktop_drop` 在非门控处被引用（移动端误引入）。

- [ ] **Step 1: 写守卫测试**

`hibiki/test/media/drag_drop/drag_drop_platform_guard_test.dart`:
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop_drop is only imported inside the platform-gated wrapper', () {
    final Directory libDir = Directory('lib');
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in libDir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      // 唯一允许引用 desktop_drop 的文件。
      if (e.path.replaceAll(r'\', '/').endsWith(
          'src/media/drag_drop/hibiki_file_drop_target.dart')) {
        continue;
      }
      final String src = e.readAsStringSync();
      if (src.contains("package:desktop_drop/")) {
        offenders.add(e.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'desktop_drop 只能在 hibiki_file_drop_target.dart 里引用（平台门控）；其余文件请用 HibikiFileDropTarget');
  });
}
```

- [ ] **Step 2: 跑测试**

Run:
```bash
cd hibiki && flutter test test/media/drag_drop/drag_drop_platform_guard_test.dart --no-pub
```
Expected: PASS。

- [ ] **Step 3: Commit**

```bash
git add hibiki/test/media/drag_drop/drag_drop_platform_guard_test.dart
git commit -m "test(drag-drop): guard desktop_drop import behind platform gate"
```

---

## Task 13: 全量验证

- [ ] **Step 1: format**

Run:
```bash
cd hibiki && dart format lib/src/media/drag_drop test/media/drag_drop lib/src/media/audiobook/book_import_dialog.dart lib/src/media/video/video_import_dialog.dart lib/src/media/audiobook/audiobook_import_dialog.dart lib/src/pages/implementations/reader_hibiki_history_page.dart lib/src/pages/implementations/home_video_page.dart
```

- [ ] **Step 2: analyze 全仓**

Run:
```bash
cd hibiki && flutter analyze
```
Expected: No issues found（若有既有无关告警，确认非本改动引入）。

- [ ] **Step 3: 全量测试**

Run:
```bash
cd hibiki && flutter test --no-pub
```
Expected: All tests passed（记录绿色数；若有 develop 预存红，确认与本改动无关并在汇报里说明）。

- [ ] **Step 4: Commit（如 format 有改动）**

```bash
git add -u hibiki
git commit -m "style(drag-drop): dart format" || echo "nothing to format-commit"
```

---

## 验证与交付

- **可自动化层已全测**：分类 / 决策 / 命中几何 / 对话框预填 / 平台守卫。
- **真机三端实际拖放（用户）**：Windows/macOS/Linux 各拖一遍——① 拖 epub 到书架→出导入框预填；② 拖 mp4 到视频 tab→出视频导入框预填；③ 拖 srt 到某书卡→出有声书对齐框（字幕槽预填）；④ 拖 mp3+srt 到某书卡→音频槽+字幕槽都预填；⑤ 拖 srt 到某视频卡→出视频导入框（该视频+字幕预填）；⑥ 拖字幕到空白处→SnackBar 提示。
- 桌面构建若涉及打包，按需 `gradlew`（仅 Android，本功能不改 Android）；桌面端 `flutter run -d windows/macos/linux` 实测。

## 自查（计划 vs spec）

- spec §3 分类纯函数 → Task 2/3 ✅
- spec §4 单 DropTarget + 卡片登记表命中 → Task 5/6/7 + Task 10/11 接线 ✅
- spec §4 决策（书/视频/字幕/音频/提示）→ Task 4 ✅
- spec §5 三对话框 initial* 预填 → Task 9 ✅
- spec §6 平台隔离 → Task 7 + Task 12 守卫 ✅
- spec §7 测试策略（纯函数+预填+源码守卫）→ Task 2/3/4/5/9/12 ✅
- 类型一致性：`CardDropRegistry<T>`/`CardDropScope<T>`/`CardDropZone<T>`/`CardRect<T>`/`hitTestCards<T>` 范型贯穿；`DropSurface`/`DropIntent`/`decideDropIntent` 命名跨 Task 4/10/11 一致；`HibikiFileDropTarget.onDrop` 签名 `(List<String>, Offset)` 与 Task 10/11 的 `_handle*Drop` 一致；对话框字段名（`_epubPath`/`_videoPath`/`_audioPaths`/`_alignmentPath` 等）与调查所得现有 State 字段一致。
- 占位符扫描：无 TBD/TODO；接线任务（10/11）含「读文件定位 + 照搬现有 helper」指令属既有大文件的必要现场对齐，已给精确行号与复用范式。
