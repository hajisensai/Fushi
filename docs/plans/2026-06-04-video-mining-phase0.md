# 视频播放基座（Phase 0）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Hibiki 能播放本地视频文件并按外挂字幕（srt/vtt/ass）做句级同步高亮、句级导航、进度持久化，作为后续「字幕查词」「视频制卡」的基座。

**Architecture:** 视频走全平台 `media_kit`(libmpv)；有声书音频继续 `just_audio`（双栈，互不耦合）。新建 `VideoPlayerController` 照搬有声书 `_updateCurrentCue`（125ms tick + `findCueIndex`）的 cue 同步逻辑，把 `AudioPlayer` 换成 media_kit `Player`。字幕 cue 复用现有解析器与 `AudioCue` 模型，存进现有 `audioCues` 表；新增 `VideoBooks` 表只存视频元数据 + 进度。页面 `VideoHibikiPage` 照 `reader_hibiki_page.dart` 的「无参构造控制器 + 回调字段注入」范式装配，经 `Navigator.push(adaptivePageRoute(...))` 打开。

**Tech Stack:** Flutter 3.44.0 / Dart 3.12；media_kit + media_kit_video；Drift（schema v15→v16）；Riverpod；file_picker。

**Worktree:** `worktree-video-mining`（基于 develop `6c8a3b515`）。所有路径相对 worktree 根 `D:\APP\vs_claude_code\hibiki\.claude\worktrees\video-mining`。

**工具链（本机 flutter 不在 PATH）:**
- Flutter：`D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat`
- Dart：`D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat`
- 单测在 `hibiki/` 下跑；drift codegen 在 `packages/hibiki_core/` 下跑。

**范围边界（本 Phase 不做，留后续 plan）:** 逐字查词（Phase 1）、制卡/截图/音频裁剪（Phase 2）。内嵌字幕轨在本 Phase 仅做 spike + libmpv 渲染显示（Task 9），文本提取用于查词留 Phase 1 决策。

---

## File Structure

新建：
- `hibiki/lib/src/media/video/video_player_controller.dart` — 视频播放 + cue 同步控制器（核心）
- `hibiki/lib/src/media/video/video_subtitle_overlay.dart` — 当前句字幕 overlay widget
- `hibiki/lib/src/media/video/video_play_bar.dart` — 播放控制条 widget
- `hibiki/lib/src/media/video/video_import_dialog.dart` — 视频导入对话框
- `hibiki/lib/src/media/video/video_book_repository.dart` — VideoBooks 仓库
- `hibiki/lib/src/pages/implementations/video_hibiki_page.dart` — 视频页（装配）
- `hibiki/test/database/video_books_test.dart` — VideoBooks DB CRUD 单测
- `hibiki/test/media/video/video_player_controller_test.dart` — cue 同步单测
- `hibiki/test/widgets/video_subtitle_overlay_test.dart` — overlay widget 测试
- `hibiki/test/widgets/video_play_bar_test.dart` — 控制条 widget 测试
- `hibiki/integration_test/video_player_test.dart` — 焦点驱动集成测试
- `docs/specs/media_kit-api-notes.md` — Task 0 spike 产出的真实 API 笔记

修改：
- `hibiki/pubspec.yaml` — 加 media_kit 视频依赖
- `hibiki/lib/main.dart:78` 旁 — `MediaKit.ensureInitialized()`
- `packages/hibiki_core/lib/src/database/tables.dart` — 加 `VideoBooks` 表
- `packages/hibiki_core/lib/src/database/database.dart` — 注册表、schemaVersion→16、迁移、DB 方法
- `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart` — 书架加「导入视频」入口与打开视频页
- `hibiki/lib/i18n/*.i18n.json` — 视频页 UI 文案（经 i18n_sync）

---

## Task 0: 引入 media_kit 视频后端 + 初始化 + 跨端 API spike

**Files:**
- Modify: `hibiki/pubspec.yaml:87-89`
- Modify: `hibiki/lib/main.dart:6`（import）、`hibiki/lib/main.dart:78`（init）
- Create: `docs/specs/media_kit-api-notes.md`
- Create: `hibiki/test/media/video/media_kit_smoke_test.dart`

> **为什么是 spike：** 仓库当前只用 `just_audio_media_kit`（音频后端），从未直接调用 `media_kit` 的 `Player`/`VideoController`/字幕轨/截图 API。本 Task 引入依赖并用最小程序锁定这些 API 的**真实签名与行为**，写进 `media_kit-api-notes.md`。后续所有 Task 的 media_kit 调用以该笔记为准（本 plan 中的 media_kit 代码是基于 media_kit 1.1.x 已知 API 的预期写法）。

- [ ] **Step 1: 加依赖**

在 `hibiki/pubspec.yaml` 的 `dependencies` 段，紧接现有第 87-89 行之后追加（保留现有 `media_kit_libs_windows_audio`，它是 just_audio_media_kit 的音频后端）：

```yaml
  just_audio: ^0.9.31
  just_audio_media_kit: ^2.1.0
  media_kit_libs_windows_audio: ^1.0.9
  # ── 视频后端（Phase 0 新增）──
  media_kit: ^1.1.11
  media_kit_video: ^1.2.5
  media_kit_libs_video: ^1.0.5          # 聚合包：含全平台视频原生库
```

- [ ] **Step 2: 取依赖**

Run（在 `hibiki/`）:
```
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat pub get
```
Expected: 成功解析，无版本冲突。若 `media_kit_libs_video` 与 `media_kit_libs_windows_audio` 冲突，以 pub 提示为准调整约束并记入 spike 笔记。

- [ ] **Step 3: 初始化视频后端**

`hibiki/lib/main.dart:6` 已有 `import 'package:just_audio_media_kit/just_audio_media_kit.dart';`，其后加：
```dart
import 'package:media_kit/media_kit.dart';
```
`hibiki/lib/main.dart:78`（`JustAudioMediaKit.ensureInitialized();` 那行）之后加一行：
```dart
    MediaKit.ensureInitialized();
```

- [ ] **Step 4: 写 smoke 测试（验证依赖可用、构造不崩）**

Create `hibiki/test/media/video/media_kit_smoke_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test('media_kit Player can be constructed and disposed', () async {
    MediaKit.ensureInitialized();
    final player = Player();
    expect(player, isNotNull);
    await player.dispose();
  });
}
```

- [ ] **Step 5: 跑 smoke 测试**

Run（在 `hibiki/`）:
```
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/media/video/media_kit_smoke_test.dart --reporter expanded
```
Expected: PASS。若 libmpv 原生库在测试宿主缺失导致构造失败，记入笔记并把该验证降级到设备 spike（Step 6）。

- [ ] **Step 6: 设备 spike，锁定真实 API，写笔记**

在真实设备/模拟器（至少 Windows 离屏 + 一个 Android 模拟器）上，用一个临时按钮触发，逐项验证并把**真实签名与返回类型**记进 `docs/specs/media_kit-api-notes.md`：

```markdown
# media_kit 真实 API 笔记（spike 锁定）
- 打开本地视频：Player().open(Media('file:///<abs>'), play: false) — 确认 URI 前缀/转义
- 当前位置：player.state.position 类型？player.stream.position 更新频率？
- 时长：player.state.duration
- 播放态：player.state.playing / player.stream.playing
- 控制：play() / pause() / seek(Duration) / setRate(double) / setVolume(0-100?)
- 字幕轨枚举：player.state.tracks.subtitle -> List<SubtitleTrack>（字段：id/title/language？）
- 切字幕轨：setSubtitleTrack(SubtitleTrack)；外挂：SubtitleTrack.uri('file://...')；关闭：SubtitleTrack.no()
- 当前显示字幕文本：player.stream.subtitle -> List<String>？（Phase 1 内嵌字幕查词用）
- 截图（Phase 2 用，提前确认）：player.screenshot(format:'image/jpeg') -> Uint8List? 各端是否支持
- VideoController(player) 构造 + Video(controller:) widget 渲染
- dispose 时序：先 controller 还是先 player
```

- [ ] **Step 7: 移除临时 spike UI，提交**

```bash
git add hibiki/pubspec.yaml hibiki/pubspec.lock hibiki/lib/main.dart \
  hibiki/test/media/video/media_kit_smoke_test.dart docs/specs/media_kit-api-notes.md
git commit -m "feat(video): add media_kit video backend + init + API spike notes"
```

---

## Task 1: VideoBooks 表（schema v15→v16）

**Files:**
- Modify: `packages/hibiki_core/lib/src/database/tables.dart`（加表，参考 `tables.dart:56-70` Audiobooks 范式）
- Modify: `packages/hibiki_core/lib/src/database/database.dart:29-50`（注册）、`:60`（版本）、`:224-226` 后（迁移）、加 DB 方法
- Test: `hibiki/test/database/video_books_test.dart`

- [ ] **Step 1: 写失败的 DB CRUD 测试**

Create `hibiki/test/database/video_books_test.dart`（照 `hibiki/test/database/audiobooks_test.dart:1-48` 范式）:
```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

VideoBooksCompanion _book() => const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('Sample'),
      videoPath: Value('/abs/sample.mp4'),
      subtitleFormat: Value('srt'),
    );

void main() {
  group('VideoBooks table', () {
    test('upsert and retrieve by bookUid', () async {
      final db = await _openDb();
      await db.upsertVideoBook(_book());
      final row = await db.getVideoBookByBookUid('video/1');
      expect(row, isNotNull);
      expect(row!.title, 'Sample');
      expect(row.lastPositionMs, 0);
    });

    test('updateVideoBookPosition writes through', () async {
      final db = await _openDb();
      await db.upsertVideoBook(_book());
      await db.updateVideoBookPosition('video/1', 12345);
      final row = await db.getVideoBookByBookUid('video/1');
      expect(row!.lastPositionMs, 12345);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run（在 `hibiki/`）:
```
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/database/video_books_test.dart --reporter expanded
```
Expected: FAIL（`VideoBooksCompanion` / `upsertVideoBook` 未定义）。

- [ ] **Step 3: 定义 VideoBooks 表**

`packages/hibiki_core/lib/src/database/tables.dart` 末尾追加（紧跟现有最后一张表，照 `tables.dart:56-70` 语法）:
```dart
// ── video_books ─────────────────────────────────────────────────────
@DataClassName('VideoBookRow')
class VideoBooks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get bookUid => text().unique()();
  TextColumn get title => text()();
  TextColumn get videoPath => text()();
  TextColumn get subtitleSource => text().nullable()();      // 外挂字幕持久化路径
  TextColumn get subtitleFormat => text().nullable()();      // srt/vtt/ass
  IntColumn get embeddedSubtitleTrack => integer().nullable()(); // 内嵌字幕轨 index
  TextColumn get coverPath => text().nullable()();
  IntColumn get lastPositionMs => integer().withDefault(const Constant(0))();
  DateTimeColumn get importedAt => dateTime().nullable()();
}
```

- [ ] **Step 4: 注册表 + 升版 + 迁移 + DB 方法**

`database.dart:50`（`@DriftDatabase(tables: [...])` 列表末项 `SyncBaselines,` 之后）加：
```dart
  VideoBooks,
```
`database.dart:60` 改：
```dart
  int get schemaVersion => 16;
```
`database.dart:224-226`（`if (from < 15)` 分支之后）加：
```dart
          if (from < 16) {
            await m.createTable(videoBooks);
          }
```
在 DB 类内（参考 `upsertAudiobook` `database.dart:547-549`）加方法：
```dart
  Future<void> upsertVideoBook(VideoBooksCompanion vb) =>
      into(videoBooks).insert(vb,
          onConflict: DoUpdate((_) => vb, target: [videoBooks.bookUid]));

  Future<VideoBookRow?> getVideoBookByBookUid(String bookUid) =>
      (select(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  Future<void> updateVideoBookPosition(String bookUid, int positionMs) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(lastPositionMs: Value(positionMs)));
```

- [ ] **Step 5: 重新生成 drift 代码**

Run（在 `packages/hibiki_core/`）:
```
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat run build_runner build --delete-conflicting-outputs
```
Expected: 生成 `VideoBookRow` / `VideoBooksCompanion` 到 `database.g.dart`，无错误。

- [ ] **Step 6: 跑 DB 测试确认通过**

Run（在 `hibiki/`）:
```
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test/database/video_books_test.dart --reporter expanded
```
Expected: PASS（2 个测试）。

- [ ] **Step 7: 补迁移测试 v15→v16**

在 `hibiki/test/database/migration_test.dart` 现有逐版本迁移测试范式后，补一条断言从 v15 升到 16 后 `video_books` 表存在（照该文件现有 from→to 用例写）。Run 同上文件，Expected PASS。

- [ ] **Step 8: 提交**

```bash
git add packages/hibiki_core/lib/src/database/tables.dart \
  packages/hibiki_core/lib/src/database/database.dart \
  packages/hibiki_core/lib/src/database/database.g.dart \
  hibiki/test/database/video_books_test.dart hibiki/test/database/migration_test.dart
git commit -m "feat(db): add VideoBooks table (schema v16) + CRUD + migration"
```

---

## Task 2: VideoBookRepository

**Files:**
- Create: `hibiki/lib/src/media/video/video_book_repository.dart`
- Test: 复用 Task 1 的 DB 测试已覆盖底层；本 Task 加 repository 薄封装测试 `hibiki/test/media/video/video_book_repository_test.dart`

- [ ] **Step 1: 写失败测试**

Create `hibiki/test/media/video/video_book_repository_test.dart`:
```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  test('saveVideoBook + saveCues + getByBookUid round-trips', () async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = VideoBookRepository(db);

    await repo.saveVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/1'),
      title: Value('T'),
      videoPath: Value('/v.mp4'),
    ));
    final cue = AudioCue()
      ..bookUid = 'video/1'
      ..chapterHref = 'video://default'
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = 'hello'
      ..startMs = 0
      ..endMs = 1000
      ..audioFileIndex = 0;
    await repo.saveCues(bookUid: 'video/1', cues: [cue]);

    final row = await repo.getByBookUid('video/1');
    expect(row!.title, 'T');
    final cues = await repo.loadCues('video/1');
    expect(cues, hasLength(1));
    expect(cues.first.text, 'hello');
  });
}
```

- [ ] **Step 2: 跑确认失败**

Run: `...flutter.bat test test/media/video/video_book_repository_test.dart --reporter expanded` → FAIL（`VideoBookRepository` 未定义）。

- [ ] **Step 3: 实现 repository**

Create `hibiki/lib/src/media/video/video_book_repository.dart`（照 `audiobook_repository.dart:10-83` 范式，DB 构造注入）:
```dart
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// VideoBooks 仓库：视频元数据 + 进度；字幕 cue 复用 audioCues 表。
class VideoBookRepository {
  const VideoBookRepository(this._db);

  final HibikiDatabase _db;

  Future<void> saveVideoBook(VideoBooksCompanion book) =>
      _db.upsertVideoBook(book);

  Future<VideoBookRow?> getByBookUid(String bookUid) =>
      _db.getVideoBookByBookUid(bookUid);

  Future<void> updatePosition(String bookUid, int positionMs) =>
      _db.updateVideoBookPosition(bookUid, positionMs);

  Future<void> saveCues({
    required String bookUid,
    required List<AudioCue> cues,
  }) =>
      _db.replaceCuesForBook(
          bookUid, cues.map(AudioCue.toCompanion).toList());

  Future<List<AudioCue>> loadCues(String bookUid) async {
    final rows = await _db.cuesForBook(bookUid);
    return rows.map(AudioCue.fromRow).toList();
  }
}
```
> 若 `cuesForBook` 在 DB 层尚不存在，照 `replaceCuesForBook`（`database.dart:584-593`）旁补一个：
> ```dart
> Future<List<AudioCueRow>> cuesForBook(String bookUid) =>
>     (select(audioCues)
>           ..where((t) => t.bookUid.equals(bookUid))
>           ..orderBy([(t) => OrderingTerm(expression: t.startMs)]))
>         .get();
> ```
> 验证：先 grep `cuesForBook` 是否已存在（有声书加载 cue 必有等价方法），有则直接复用其真实名字，无则按上面补并 build_runner 重新生成不需要（非表变更，纯查询方法）。

- [ ] **Step 4: 跑确认通过**

Run 同 Step 2 → PASS。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/media/video/video_book_repository.dart \
  hibiki/test/media/video/video_book_repository_test.dart \
  packages/hibiki_core/lib/src/database/database.dart
git commit -m "feat(video): VideoBookRepository (metadata/progress + reuse audioCues)"
```

---

## Task 3: VideoPlayerController — cue 同步核心

**Files:**
- Create: `hibiki/lib/src/media/video/video_player_controller.dart`
- Test: `hibiki/test/media/video/video_player_controller_test.dart`

> 照搬 `AudiobookPlayerController._updateCurrentCue`（`audiobook_controller.dart:771-822`）的 cue 选择逻辑。播放器后端换 media_kit `Player`，位置来源从 `_player.createPositionStream` 换成 `Timer.periodic(125ms)` 读 `player.state.position`。为可测，把「按 positionMs 更新当前 cue」抽成 `@visibleForTesting` 钩子，单测注入位置序列，不依赖真实播放。

- [ ] **Step 1: 写失败的 cue 同步单测**

Create `hibiki/test/media/video/video_player_controller_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue _cue(int i, int s, int e) => AudioCue()
  ..bookUid = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = 'line$i'
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

void main() {
  group('VideoPlayerController cue sync', () {
    test('selects cue by position; gap keeps previous; notifies on change',
        () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([_cue(0, 0, 1000), _cue(1, 2000, 3000)]);

      int notifications = 0;
      c.addListener(() => notifications++);

      c.debugUpdateCueForPosition(500); // 命中 cue0
      expect(c.currentCueIndex, 0);
      expect(c.currentCue!.text, 'line0');

      c.debugUpdateCueForPosition(1500); // gap：保留 cue0
      expect(c.currentCueIndex, 0);

      c.debugUpdateCueForPosition(2500); // 命中 cue1
      expect(c.currentCueIndex, 1);
      expect(c.currentCue!.text, 'line1');

      c.debugUpdateCueForPosition(2600); // 同句不重复通知
      expect(c.currentCueIndex, 1);

      expect(notifications, 2); // 仅 cue0→、cue1→ 两次变化
    });

    test('delayMs offsets cue lookup', () async {
      final c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues([_cue(0, 0, 1000)]);
      c.setDelayMs(600);
      c.debugUpdateCueForPosition(1500); // 扣减 600 → 900，仍命中 cue0
      expect(c.currentCueIndex, 0);
    });
  });
}
```

- [ ] **Step 2: 跑确认失败**

Run: `...flutter.bat test test/media/video/video_player_controller_test.dart --reporter expanded` → FAIL（`VideoPlayerController` 未定义）。

- [ ] **Step 3: 实现控制器**

Create `hibiki/lib/src/media/video/video_player_controller.dart`（media_kit 调用以 Task 0 笔记为准；下为基于 media_kit 1.1.x 的预期写法）:
```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 视频播放 + 字幕 cue 同步控制器（双栈：视频用 media_kit，独立于有声书 just_audio）。
class VideoPlayerController extends ChangeNotifier {
  VideoPlayerController();

  final Player _player = Player();
  late final VideoController videoController = VideoController(_player);

  Player get player => _player;

  List<AudioCue> _cues = const [];
  AudioCue? _currentCue;
  int _currentCueIndex = -1;
  int _delayMs = 0;
  Timer? _tick;
  String? _bookUid;
  int _lastSavedSec = -1;

  AudioCue? get currentCue => _currentCue;
  int get currentCueIndex => _currentCueIndex;
  List<AudioCue> get cues => _cues;
  bool get isPlaying => _player.state.playing;

  /// 进度持久化回调（每整秒一次），由页面注入。
  Future<void> Function(String bookUid, int positionMs)? onPositionWrite;

  void setCues(List<AudioCue> cues) {
    _cues = List<AudioCue>.from(cues)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    _currentCue = null;
    _currentCueIndex = -1;
    notifyListeners();
  }

  void setDelayMs(int ms) {
    _delayMs = ms.clamp(-600000, 600000);
  }

  Future<void> load({
    required String bookUid,
    required File videoFile,
    required List<AudioCue> cues,
    int initialPositionMs = 0,
    double initialSpeed = 1.0,
    String? externalSubtitlePath,
  }) async {
    _bookUid = bookUid;
    setCues(cues);
    await _player.open(Media(videoFile.uri.toString()), play: false);
    if (externalSubtitlePath != null) {
      await _player.setSubtitleTrack(
          SubtitleTrack.uri(File(externalSubtitlePath).uri.toString()));
    }
    if (initialSpeed != 1.0) await _player.setRate(initialSpeed);
    if (initialPositionMs > 0) {
      await _player.seek(Duration(milliseconds: initialPositionMs));
    }
    _startTick();
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 125), (_) {
      updateCueForPosition(_player.state.position.inMilliseconds);
    });
  }

  /// cue 选择逻辑，照搬有声书 _updateCurrentCue 的核心（endMs 闭区间，gap 保留上一句）。
  void updateCueForPosition(int posMs) {
    _maybeSavePosition(posMs);
    if (_cues.isEmpty) return;
    final int effectiveMs = (posMs - _delayMs).clamp(0, 1 << 30);
    final int idx = JsonAlignmentParser.findCueIndex(
      cues: _cues,
      positionMs: effectiveMs,
    );
    if (idx < 0) return; // gap：保留上一句高亮
    if (idx == _currentCueIndex) return;
    _currentCueIndex = idx;
    _currentCue = _cues[idx];
    notifyListeners();
  }

  @visibleForTesting
  void debugUpdateCueForPosition(int posMs) => updateCueForPosition(posMs);

  void _maybeSavePosition(int posMs) {
    final int sec = posMs ~/ 1000;
    if (sec == _lastSavedSec || _bookUid == null) return;
    _lastSavedSec = sec;
    final cb = onPositionWrite;
    if (cb != null) unawaited(cb(_bookUid!, posMs));
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> togglePlayPause() => _player.playOrPause();
  Future<void> seekMs(int positionMs) =>
      _player.seek(Duration(milliseconds: positionMs));
  Future<void> setSpeed(double speed) => _player.setRate(speed);

  Future<void> skipToCue(AudioCue cue) => seekMs(cue.startMs);

  Future<void> skipToNextCue() async {
    final int next = _currentCueIndex + 1;
    if (next < _cues.length) await skipToCue(_cues[next]);
  }

  Future<void> skipToPrevCue() async {
    final int prev = _currentCueIndex - 1;
    if (prev >= 0) await skipToCue(_cues[prev]);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _player.dispose();
    super.dispose();
  }
}

// File 用于 videoFile/externalSubtitlePath 参数。
import 'dart:io';
```
> 注意：Dart 的 `import` 必须置顶——把 `import 'dart:io';` 移到文件顶部，上面行内注释只为说明用途。

- [ ] **Step 4: 跑确认通过**

Run 同 Step 2 → PASS（2 个测试）。若 `findCueIndex` 的 gap 语义与断言不符，回看 `json_alignment_parser.dart:102-130`（endMs 闭区间）对齐测试数据，不要改生产逻辑。

- [ ] **Step 5: analyze + 提交**

```
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze lib/src/media/video/video_player_controller.dart
```
```bash
git add hibiki/lib/src/media/video/video_player_controller.dart \
  hibiki/test/media/video/video_player_controller_test.dart
git commit -m "feat(video): VideoPlayerController with 125ms cue-sync (media_kit backend)"
```

---

## Task 4: 字幕 overlay widget

**Files:**
- Create: `hibiki/lib/src/media/video/video_subtitle_overlay.dart`
- Test: `hibiki/test/widgets/video_subtitle_overlay_test.dart`

> overlay 监听 controller，显示 `currentCue.text`。本 widget 不渲染视频画面（画面由 `Video(controller:)` 在页面层叠加），只负责当前句文本展示，便于独立测试与 Phase 1 挂查词手势。

- [ ] **Step 1: 写失败 widget 测试**

Create `hibiki/test/widgets/video_subtitle_overlay_test.dart`（照 `hibiki/test/widgets/widget_test_helpers.dart` 的 `buildTestApp`）:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'widget_test_helpers.dart';

AudioCue _cue(String t, int s, int e) => AudioCue()
  ..bookUid = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = t
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

void main() {
  testWidgets('shows current cue text and updates on change', (tester) async {
    final c = VideoPlayerController();
    addTearDown(c.dispose);
    c.setCues([_cue('hello', 0, 1000), _cue('world', 2000, 3000)]);

    await tester.pumpWidget(buildTestApp(VideoSubtitleOverlay(controller: c)));
    c.debugUpdateCueForPosition(500);
    await tester.pump();
    expect(find.text('hello'), findsOneWidget);

    c.debugUpdateCueForPosition(2500);
    await tester.pump();
    expect(find.text('world'), findsOneWidget);
    expect(find.text('hello'), findsNothing);
  });
}
```

- [ ] **Step 2: 跑确认失败**

Run: `...flutter.bat test test/widgets/video_subtitle_overlay_test.dart --reporter expanded` → FAIL（`VideoSubtitleOverlay` 未定义）。

- [ ] **Step 3: 实现 overlay**

Create `hibiki/lib/src/media/video/video_subtitle_overlay.dart`:
```dart
import 'package:flutter/material.dart';

import 'video_player_controller.dart';

/// 视频底部当前句字幕 overlay；监听 controller.currentCue。
class VideoSubtitleOverlay extends StatelessWidget {
  const VideoSubtitleOverlay({required this.controller, super.key});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final text = controller.currentCue?.text ?? '';
        if (text.isEmpty) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 32),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 22),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
```

- [ ] **Step 4: 跑确认通过 → 提交**

Run 同 Step 2 → PASS。
```bash
git add hibiki/lib/src/media/video/video_subtitle_overlay.dart \
  hibiki/test/widgets/video_subtitle_overlay_test.dart
git commit -m "feat(video): subtitle overlay widget bound to current cue"
```

---

## Task 5: 视频播放控制条

**Files:**
- Create: `hibiki/lib/src/media/video/video_play_bar.dart`
- Test: `hibiki/test/widgets/video_play_bar_test.dart`

> 控制条：上一句 / 播放暂停 / 下一句（句级导航复用 controller 方法）。所有按钮可被焦点遍历到（Phase 1/2 集成测试依赖）。

- [ ] **Step 1: 写失败 widget 测试**

Create `hibiki/test/widgets/video_play_bar_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_play_bar.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';

import 'widget_test_helpers.dart';

void main() {
  testWidgets('renders prev/play/next controls', (tester) async {
    final c = VideoPlayerController();
    addTearDown(c.dispose);
    await tester.pumpWidget(buildTestApp(VideoPlayBar(controller: c)));
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑确认失败**

Run: `...flutter.bat test test/widgets/video_play_bar_test.dart --reporter expanded` → FAIL。

- [ ] **Step 3: 实现控制条**

Create `hibiki/lib/src/media/video/video_play_bar.dart`:
```dart
import 'package:flutter/material.dart';

import 'video_player_controller.dart';

class VideoPlayBar extends StatelessWidget {
  const VideoPlayBar({required this.controller, super.key});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous),
              onPressed: controller.skipToPrevCue,
            ),
            IconButton(
              icon: Icon(
                  controller.isPlaying ? Icons.pause : Icons.play_arrow),
              onPressed: controller.togglePlayPause,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              onPressed: controller.skipToNextCue,
            ),
          ],
        );
      },
    );
  }
}
```

- [ ] **Step 4: 跑确认通过 → 提交**

Run 同 Step 2 → PASS。
```bash
git add hibiki/lib/src/media/video/video_play_bar.dart \
  hibiki/test/widgets/video_play_bar_test.dart
git commit -m "feat(video): play bar with sentence-level navigation"
```

---

## Task 6: 视频导入对话框

**Files:**
- Create: `hibiki/lib/src/media/video/video_import_dialog.dart`
- Test: `hibiki/test/widgets/video_import_dialog_test.dart`

> 照 `audiobook_import_dialog.dart` 范式：file_picker 选视频 + 外挂字幕 → 按扩展名路由 parser（`SrtParser`/`VttParser`/`AssParser`）解析 cue → `repo.saveVideoBook` + `repo.saveCues`。i18n 文案经 i18n_sync。

- [ ] **Step 1: 加 i18n key**

Run（在 `hibiki/`，逐条）:
```
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat tool/i18n_sync.dart --add video.import.title "Import Video" "导入视频"
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat tool/i18n_sync.dart --add video.import.pickVideo "Pick video file" "选择视频文件"
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat tool/i18n_sync.dart --add video.import.pickSubtitle "Pick subtitle (srt/vtt/ass)" "选择字幕(srt/vtt/ass)"
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat tool/i18n_sync.dart --add video.import.confirm "Import" "导入"
```
重新生成:
```
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat run slang
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format lib/i18n/strings.g.dart
```

- [ ] **Step 2: 写 cue 解析路由的失败单测**

把「按扩展名路由到 parser」抽成可测纯函数。Create `hibiki/test/media/video/parse_subtitle_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart'
    show parseSubtitleCues;

void main() {
  test('routes srt content to SrtParser cues', () {
    const srt = '1\n00:00:00,000 --> 00:00:01,000\nhello\n';
    final cues = parseSubtitleCues(
        content: srt, format: 'srt', bookUid: 'video/1');
    expect(cues, hasLength(1));
    expect(cues.first.text, 'hello');
    expect(cues.first.startMs, 0);
    expect(cues.first.endMs, 1000);
  });
}
```

- [ ] **Step 3: 跑确认失败**

Run: `...flutter.bat test test/media/video/parse_subtitle_test.dart --reporter expanded` → FAIL（`parseSubtitleCues` 未定义）。

- [ ] **Step 4: 实现对话框 + 解析路由**

Create `hibiki/lib/src/media/video/video_import_dialog.dart`:
```dart
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'video_book_repository.dart';

/// 按字幕扩展名路由到对应 parser，返回排序后的 cue 列表。
List<AudioCue> parseSubtitleCues({
  required String content,
  required String format,
  required String bookUid,
}) {
  final List<AudioCue> cues;
  switch (format.toLowerCase()) {
    case 'srt':
      cues = SrtParser.parseString(content: content, bookUid: bookUid);
      break;
    case 'vtt':
      cues = VttParser.parseString(content: content, bookUid: bookUid);
      break;
    case 'ass':
    case 'ssa':
      cues = AssParser.parseString(content: content, bookUid: bookUid);
      break;
    default:
      throw ArgumentError('unsupported subtitle format: $format');
  }
  cues.sort((a, b) => a.startMs.compareTo(b.startMs));
  return cues;
}

class VideoImportDialog extends StatefulWidget {
  const VideoImportDialog({required this.repo, super.key});

  final VideoBookRepository repo;

  @override
  State<VideoImportDialog> createState() => _VideoImportDialogState();
}

class _VideoImportDialogState extends State<VideoImportDialog> {
  String? _videoPath;
  String? _subtitlePath;
  bool _busy = false;

  Future<void> _pickVideo() async {
    final r = await FilePicker.platform
        .pickFiles(type: FileType.video, allowMultiple: false);
    if (r != null && r.files.single.path != null) {
      setState(() => _videoPath = r.files.single.path);
    }
  }

  Future<void> _pickSubtitle() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'vtt', 'ass', 'ssa'],
    );
    if (r != null && r.files.single.path != null) {
      setState(() => _subtitlePath = r.files.single.path);
    }
  }

  Future<void> _doImport() async {
    if (_videoPath == null || _subtitlePath == null) return;
    setState(() => _busy = true);
    final String bookUid = 'video/${_videoPath!.hashCode}';
    final String format = _subtitlePath!.split('.').last.toLowerCase();
    final String content =
        await readTextWithEncoding(File(_subtitlePath!));
    final cues = parseSubtitleCues(
        content: content, format: format, bookUid: bookUid);
    await widget.repo.saveVideoBook(VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(_videoPath!.split(Platform.pathSeparator).last),
      videoPath: Value(_videoPath!),
      subtitleSource: Value(_subtitlePath!),
      subtitleFormat: Value(format),
    ));
    await widget.repo.saveCues(bookUid: bookUid, cues: cues);
    if (mounted) Navigator.pop(context, bookUid);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import Video'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(_videoPath ?? 'Pick video file'),
            trailing: const Icon(Icons.movie),
            onTap: _pickVideo,
          ),
          ListTile(
            title: Text(_subtitlePath ?? 'Pick subtitle (srt/vtt/ass)'),
            trailing: const Icon(Icons.subtitles),
            onTap: _pickSubtitle,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: (_busy || _videoPath == null || _subtitlePath == null)
              ? null
              : _doImport,
          child: const Text('Import'),
        ),
      ],
    );
  }
}
```
> 文案先用英文字面量占位以保证可编译；落地时替换为 `context` 下的 slang `t.video.import.*`（参照仓库其它对话框取 `Translations` 的方式，grep `t.` 用例）。`VideoBooksCompanion`/`Value` 来自 `hibiki_core`，按需补 `import 'package:hibiki_core/hibiki_core.dart';` 与 `package:drift/drift.dart' show Value;`（或经 hibiki_core 的 re-export）。

- [ ] **Step 5: 跑确认通过 → 提交**

Run 同 Step 3 → PASS。analyze 该目录。
```bash
git add hibiki/lib/src/media/video/video_import_dialog.dart \
  hibiki/test/media/video/parse_subtitle_test.dart \
  hibiki/lib/i18n/
git commit -m "feat(video): import dialog (video + external subtitle) reusing parsers"
```

---

## Task 7: VideoHibikiPage（装配页面）

**Files:**
- Create: `hibiki/lib/src/pages/implementations/video_hibiki_page.dart`
- Test: 集成测试在 Task 8；本 Task 加一个最小 widget 冒烟测试 `hibiki/test/pages/video_hibiki_page_smoke_test.dart`（不真正播放，注入预置 cues）

> 照 `reader_hibiki_page.dart` 的 `_initAudiobookController`（`:762-825`）装配：构造 `VideoPlayerController`（无参）→ 读 repo 进度 → `load(...)` → 赋 `onPositionWrite` → `addListener` → `setState`。画面层 `Video(controller.videoController)` + `VideoSubtitleOverlay` + `VideoPlayBar` 叠 `Stack`。

- [ ] **Step 1: 实现页面**

Create `hibiki/lib/src/pages/implementations/video_hibiki_page.dart`:
```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../media/video/video_book_repository.dart';
import '../../media/video/video_play_bar.dart';
import '../../media/video/video_player_controller.dart';
import '../../media/video/video_subtitle_overlay.dart';

class VideoHibikiPage extends StatefulWidget {
  const VideoHibikiPage({
    required this.bookUid,
    required this.repo,
    super.key,
  });

  final String bookUid;
  final VideoBookRepository repo;

  @override
  State<VideoHibikiPage> createState() => _VideoHibikiPageState();
}

class _VideoHibikiPageState extends State<VideoHibikiPage> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final row = await widget.repo.getByBookUid(widget.bookUid);
    if (row == null) return;
    final cues = await widget.repo.loadCues(widget.bookUid);
    final controller = VideoPlayerController();
    await controller.load(
      bookUid: widget.bookUid,
      videoFile: File(row.videoPath),
      cues: cues,
      initialPositionMs: row.lastPositionMs,
      externalSubtitlePath: row.subtitleSource,
    );
    controller.onPositionWrite =
        (uid, posMs) => widget.repo.updatePosition(uid, posMs);
    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() => _controller = controller);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: controller == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Video(controller: controller.videoController),
                      ),
                      Positioned.fill(
                        child: VideoSubtitleOverlay(controller: controller),
                      ),
                    ],
                  ),
                ),
                VideoPlayBar(controller: controller),
              ],
            ),
    );
  }
}
```

- [ ] **Step 2: 写冒烟 widget 测试（注入空 repo，断言加载占位）**

Create `hibiki/test/pages/video_hibiki_page_smoke_test.dart`:
```dart
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  testWidgets('shows loader when book missing', (tester) async {
    final db = HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      home: VideoHibikiPage(bookUid: 'video/none', repo: VideoBookRepository(db)),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
```

- [ ] **Step 3: 跑 + analyze + 提交**

Run: `...flutter.bat test test/pages/video_hibiki_page_smoke_test.dart --reporter expanded` → PASS。
```
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze lib/src/pages/implementations/video_hibiki_page.dart lib/src/media/video/
```
```bash
git add hibiki/lib/src/pages/implementations/video_hibiki_page.dart \
  hibiki/test/pages/video_hibiki_page_smoke_test.dart
git commit -m "feat(video): VideoHibikiPage assembling player + overlay + bar"
```

---

## Task 8: 书架入口 + 焦点驱动集成测试

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart`（加「导入视频」入口 + 列表项打开 `VideoHibikiPage`）
- Create: `hibiki/integration_test/video_player_test.dart`

- [ ] **Step 1: 接书架入口**

在 `reader_hibiki_history_page.dart` 书架顶栏/菜单（参考现有打开 `AudiobookImportDialog` 的 `:1257`/`:1273` 与 SRT 书打开 `:751-759` 的 `Navigator.push(adaptivePageRoute(...))`），加：
- 一个「导入视频」动作：`showAppDialog(builder: (_) => VideoImportDialog(repo: VideoBookRepository(db)))`，返回 `bookUid` 后刷新列表。
- 视频书列表项点击：
```dart
Navigator.push(
  context,
  adaptivePageRoute<void>(
    builder: (_) => VideoHibikiPage(bookUid: bookUid, repo: VideoBookRepository(db)),
  ),
);
```
> `db` / `repo` 的获取方式照该文件现有对 `AudiobookRepository`/`HibikiDatabase` 的取用（grep 该文件里 `Repository(` 与 `database` 的 provider 读取）。视频书列表数据源：新增 `db.select(db.videoBooks).get()` 或在 repo 加 `listAll()`，照有声书列表范式。

- [ ] **Step 2: 写焦点驱动集成测试**

Create `hibiki/integration_test/video_player_test.dart`（照 `integration_test/comprehensive_settings_test.dart` 的 ProviderContainer 取 AppModel + FocusDriver 遍历 + 写穿断言范式）:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hibiki/main.dart' as app;

import 'helpers/focus_driver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('video page: focus traversal reaches play controls; play toggles',
      (tester) async {
    app.main();
    // 预置一条视频书 + cues（经 DB 直插 fixture，照其它集成测试 seed 范式），
    // 打开 VideoHibikiPage，FocusDriver Tab 遍历至播放按钮，activate()，
    // 断言 controller.isPlaying 由 false→true（经页面暴露的 test hook 或 UI 图标变化）。
    final driver = FocusDriver(tester);
    await driver.reachAll();
    // 断言至少能聚焦到 skip_next / play 控件（find.byIcon），activate 后图标变 pause。
    expect(find.byIcon(Icons.play_arrow), findsWidgets);
  });
}
```
> 真实 seed 与断言细节按 `comprehensive_settings_test.dart` 实测范式补全（注入 fixture 视频文件路径 → 桌面用一个小测试视频资产；置于 `integration_test/fixtures/`）。本测试在设备/离屏跑，不进 `flutter test` 单测集。

- [ ] **Step 3: 跑集成测试（Windows 离屏 + 一个模拟器）**

Run（仓库根，PowerShell）:
```
.\hibiki\tool\run_windows_itest.ps1 integration_test/video_player_test.dart
```
Android:
```
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test integration_test/video_player_test.dart -d emulator-<port>
```
Expected: 焦点能到达播放控件、play 切换生效。失败按真实路径根因修，不得吞断言。

- [ ] **Step 4: 提交**

```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart \
  hibiki/integration_test/video_player_test.dart \
  hibiki/integration_test/fixtures/
git commit -m "feat(video): shelf entry + focus-driven integration test"
```

---

## Task 9: 内嵌字幕轨（spike + libmpv 渲染）

**Files:**
- Modify: `hibiki/lib/src/media/video/video_player_controller.dart`（加字幕轨枚举/切换）
- Modify: `hibiki/lib/src/media/video/video_import_dialog.dart`（内嵌轨选择）
- Update: `docs/specs/media_kit-api-notes.md`（补内嵌字幕文本提取结论）

> 用户要求支持内嵌字幕轨。本 Task 先打通「枚举 + libmpv 渲染显示 + 进度同步靠时间」；**「内嵌字幕文本提取用于查词」的可行性是 spike 重点**——libmpv `player.stream.subtitle`（当前显示字幕文本）是否够 Phase 1 查词用，结论写进笔记并据此决定 Phase 1 内嵌字幕查词的实现/降级。

- [ ] **Step 1: 控制器加字幕轨 API**

在 `VideoPlayerController` 加（API 以 Task 0 笔记为准）:
```dart
List<SubtitleTrack> get subtitleTracks => _player.state.tracks.subtitle;
Future<void> selectSubtitleTrack(SubtitleTrack track) =>
    _player.setSubtitleTrack(track);
```

- [ ] **Step 2: 导入对话框支持选内嵌轨**

视频选定后，若用户不选外挂字幕，则 `open` 后枚举 `subtitleTracks`，让用户选一条内嵌轨，存 `embeddedSubtitleTrack` 到 `VideoBooks`。渲染交给 libmpv（`setSubtitleTrack`）。

- [ ] **Step 3: spike 内嵌字幕文本提取**

设备上验证：选内嵌轨播放，读 `player.stream.subtitle`，确认能否拿到当前句文本（用于 Phase 1 点词查词的 sentence 来源）。把结论（可行 / 仅当前句无时间轴 / 需 ffmpeg 抽轨）写进 `docs/specs/media_kit-api-notes.md`。

- [ ] **Step 4: 提交**

```bash
git add hibiki/lib/src/media/video/video_player_controller.dart \
  hibiki/lib/src/media/video/video_import_dialog.dart \
  docs/specs/media_kit-api-notes.md
git commit -m "feat(video): embedded subtitle track enumeration + libmpv render + extraction spike"
```

---

## 收尾验证（Phase 0 完成判据）

- [ ] 全量单测绿：`cd hibiki && D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test`
- [ ] `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze` 无 error
- [ ] `D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .`
- [ ] Android assembleRelease（因加了原生 media_kit libs + 表结构）：`cd hibiki/android && ./gradlew :app:assembleRelease`
- [ ] 设备复测原始路径：导入本地视频 + 外挂 srt → 播放 → 字幕随播放高亮 → 上一句/下一句生效 → 退出再进恢复进度。留证据。
- [ ] code review：spawn code-reviewer subagent（`model: opus`）审查。

## Self-Review 备注（写计划时已核对）

- **Spec 覆盖**：设计第 4 节 Phase 0「media_kit 全平台 / VideoPlayerController / VideoHibikiPage / 导入入口 / Phase 0 重点验证(共存时序、截图 API)」→ Task 0(依赖+spike含截图确认)/2-3/7/6/8 覆盖；第 3 节存储(VideoBooks v15→v16 + 复用 audioCues)→ Task 1-2；内嵌字幕轨 → Task 9。
- **类型一致**：`VideoPlayerController` 的 `setCues`/`currentCue`/`currentCueIndex`/`updateCueForPosition`/`debugUpdateCueForPosition`/`onPositionWrite` 在 Task 3 定义，Task 4/5/7 引用一致；`VideoBookRepository` 的 `saveVideoBook`/`getByBookUid`/`saveCues`/`loadCues`/`updatePosition` 在 Task 2 定义，Task 6/7/8 引用一致；DB 方法 `upsertVideoBook`/`getVideoBookByBookUid`/`updateVideoBookPosition`/`cuesForBook` 在 Task 1-2 定义。
- **占位符**：media_kit 具体 API 调用统一以 Task 0 spike 笔记为准（已显式标注，非占位符）；内嵌字幕文本提取走 Task 9 spike 决策，不在 Phase 0 强行实现。
