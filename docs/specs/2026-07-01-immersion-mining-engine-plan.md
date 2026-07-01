# TODO-1000 沉浸制卡引擎 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers 的分任务执行子技能逐任务实现本计划。步骤用 checkbox（`- [ ]`）跟踪。

**Goal:** 让 Hibiki 在任意视频来源（本地文件 / YouTube / Netflix 等流媒体）上做「一键制卡（句子文本 + 截图/GIF + 音频）且前台不回放」，查词用 Hibiki 自己的词库，不依赖 Yomitan。

**Architecture:** 一个统一制卡引擎 `ImmersionMiningEngine`（从现有 `_mineVideoCard` 抽出、注入式可测）+ 三个来源适配器共用它：① 本地文件走现有 media_kit 播放器 + ffmpeg 按时间戳裁（现成）；② YouTube 用 `youtube_explode_dart` 解析出可播放流 URL + 字幕，喂现有原生播放器（原生查词 + ffmpeg 从可 seek 的流 URL 裁，零回放）；③ Netflix 走现有浏览器扩展桥（已有 MVP）+ Hibiki 本地 server，字幕/时间戳/shift-hover 取词回 Hibiki，媒体分层：文本+截图不回放（2A）、音频/GIF 由后台专用软解 Chromium 实例 seek 抓取（2B）。**核心不变式：任何来源的媒体抽取都以「输入路径/URL + 毫秒时间戳」为参数，绝不 seek 或干扰前台播放器。**

**Tech Stack:** Dart / Flutter / Riverpod；media_kit(libmpv) 播放；ffmpeg（现成 `desktop_audio_clipper.dart` 纯函数）抽 GIF/帧/音频；hibiki_anki 的 `mineEntry`；hibiki_audio 的 `VttParser`/`SrtParser`；shelf（`HibikiSyncServer`）本地 HTTP；MV3 浏览器扩展（`tools/browser-extension/`，已有 MVP）；`youtube_explode_dart`（新增依赖，仅 YouTube 适配器）；Windows native runner（第二层B 后台实例）。

---

## 关键事实（来自签名盘点，写代码前必须知道）

1. **媒体抽取全是纯函数**（`hibiki/lib/src/utils/misc/desktop_audio_clipper.dart`），输入「本地路径/URL + 毫秒」，**不碰播放器**：
   - `extractClipGifViaFfmpeg({required String inputPath, required int startMs, required int endMs, required String outputPath, FfmpegFailureReporter? onFailure, int fps = 8, int width = 320})`（L619）
   - `extractAudioSegmentViaFfmpeg({required String inputPath, required int startMs, required int endMs, required String outputPath, int? audioStreamIndex, int? audioStreamCount, FfmpegFailureReporter? onFailure, int audioChannels = 1, String audioBitrate = '64k'})`（L841）
   - `extractVideoFrameViaFfmpeg({required String inputPath, required String outputPath, double atSeconds = 10.0, FfmpegFailureReporter? onFailure})`（L476）
   - `MiningMediaCompression`（L29；`forCompressionEnabled(bool)` L78；字段 audioChannels/audioBitrate/gifFps/gifWidth/screenshotMaxLongEdge/screenshotQuality）
   - `typedef FfmpegFailureReporter = void Function(String summary);`（L16）
   - ffmpeg 接受 http(s) URL 作为 inputPath；带 `-ss` 前置 seek，对可 range 的流 URL 有效。
2. **现有制卡主路径** `hibiki/lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart` 的 `_mineVideoCard`（L269-464）已实现「GIF 主 → cue 帧降级 → 当前解码帧兜底 → 音频段 → 无音频则中止 → 组 AnkiMiningContext → mineEntry/updateMinedNote」。本计划把 L285-441 的核心抽成引擎。
3. **Anki 后端**（`packages/hibiki_anki/lib/src/base_anki_repository.dart`）：`Future<MineOutcome> mineEntry({required String rawPayloadJson, required AnkiMiningContext context})`（L92）；`Future<MineOutcome> updateMinedNote({required int noteId, required String rawPayloadJson, required AnkiMiningContext context})`（L106）。`AnkiMiningContext`（anki_models.dart L371）字段 sentence/cueSentence/documentTitle/coverPath/sasayakiAudioPath/sentenceOffset/source/bookTitleTag；`enum AnkiMiningSource { book, video }`；`MineOutcome.result: MineResult{success,duplicate,notConfigured,error}` + noteId。
4. **YouTube 无流提取能力**（`url_stream_video.dart` 只有 kKnownWebPageVideoHosts 软警告白名单）。libmpv 直吃 http/HLS + header：`applyHttpHeaderFieldsToPlayer(Player, Map<String,String>)`（video_mpv_config.dart L598）、`buildHttpHeaderFieldsProperty(Map)`（L583）。
5. **字幕解析**（hibiki_audio）：`VttParser.parseString({required String content, required String bookKey, String chapterHref, int audioFileIndex})`（parsers/vtt_parser.dart L91）、`SrtParser.parseString(...)`（L93），返回 `List<AudioCue>`。`AudioCue`（audiobook/audiobook_model.dart L64）是 late 字段可变类（无参构造 + 级联赋值），字段 text/startMs/endMs/bookKey/chapterHref/sentenceIndex/textFragmentId/audioFileIndex，无 durationMs。
6. **HibikiSyncServer**（`hibiki/lib/src/sync/hibiki_sync_server.dart`）：路由在 `_handleRequest`（L297，顺序 if 链，WebDAV 兜底在最后）；`_handleLookupApi`（L545）下 `POST /api/lookup/dictionary` body {term,wildcards,maximumTerms,record} → {type:'dictionaryResult', result, popupJson}；`POST /api/mine` → `_handleMine`（L655）**当前只读 fields+sentence**（未消费 timestamp/媒体）。`_authMiddleware`（L217）里加公开端点用 `request.url.path`（无前导 /），`_handleRequest` 用 reqPath（含前导 /）。新增路由插在 videos 分支后、WebDAV 兜底前。
7. **浏览器扩展 MVP 已存在** `tools/browser-extension/`：content.js（caretRangeFromPoint shift-hover + `chrome.runtime.sendMessage({type:'lookup',term})` → renderPopup()）、background.js（POST /api/lookup/dictionary body {term,record} + POST /api/mine body {fields,sentence}）、bridge-shim.js（mineEntry → sendMessage({type:'mine',...})）、scan.js（expandWordWindow/extractSentence + scan.test.js，node:test）。**缺：字幕轨读取 + timestamp + 截图 + 媒体制卡。**
8. **DictionaryPageMixin**（dictionary_page_mixin.dart）：`pushNestedPopup({required String query, required Rect selectionRect, required DictionaryPopupController controller, ...})`（L474）、`buildNestedPopupLayer(...)`（L339）、`onMineEntry(Map<String,String>)`（L131）。宿主需提供 mixinAppModel/mixinTheme/dictionarySourceType。NestedPopupEntry 已废，用 DictionaryPopupController/DictionaryPopupEntry。本地/YouTube 直接复用现有视频页查词，不新写 mixin 宿主。
9. **home tab**（home_page.dart）：`enum HomeTab {books,video,dictionaries,texthooker,settings}`（L28），`homeActiveTabs({required bool videoEnabled, required bool texthookerEnabled})`（L35）条件插入，穷尽 switch。YouTube 复用现有 video 页/入口，不新增 tab。

---

## 文件结构

**新增：**
- `hibiki/lib/src/mining/immersion_mining_request.dart` — 引擎请求/结果值对象（纯数据）。
- `hibiki/lib/src/mining/immersion_mining_engine.dart` — 统一制卡引擎（注入式抽取器 + 降级阶梯 + 组 context + 落卡）。
- `hibiki/lib/src/media/video/youtube_source_resolver.dart` — YouTube URL → 流 URL + 字幕 cue。
- `hibiki/lib/src/sync/immersion_mine_payload.dart` — server /api/mine 扩展 body 的纯解析/校验。
- `hibiki/lib/src/mining/immersion_capture_channel.dart` — 第二层B 后台实例 Dart↔native 通道封装。
- `tools/browser-extension/subtitle-adapters.js` — per-site 字幕轨 + `<video>.currentTime` 读取（Netflix 首发）。
- `hibiki/windows/runner/immersion_capture_window.h` / `.cpp` — 第二层B 后台专用软解 WebView2 实例。
- 测试：`hibiki/test/mining/immersion_mining_engine_test.dart`、`hibiki/test/media/video/youtube_source_resolver_test.dart`、`hibiki/test/sync/immersion_mine_payload_test.dart`、`tools/browser-extension/subtitle-adapters.test.js`。

**修改：**
- `hibiki/lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart` — `_mineVideoCard` 改为构造 `ImmersionMiningRequest` 委托引擎（保持行为）。
- `hibiki/lib/src/media/video/video_player_controller.dart` — 加 miningSource 覆盖（YouTube 流 URL）。
- `hibiki/lib/src/media/video/`（视频源装配处）— 接 YouTube 解析结果。
- `hibiki/lib/src/sync/hibiki_sync_server.dart` — `_handleMine` 扩展消费 timestamp/媒体；沉浸挖词走引擎。
- `hibiki/pubspec.yaml` — 加 youtube_explode_dart + html_unescape。
- `tools/browser-extension/content.js` / `background.js` / `manifest.json` — 字幕+timestamp 上报、截图、媒体制卡。
- `hibiki/windows/runner/flutter_window.cpp` — 注册 immersion_capture channel。

---

## Phase 0：抽取 `ImmersionMiningEngine`（纯 Dart，TDD，零行为变更）

目标：把 `_mineVideoCard`（L285-441）的「媒体抽取降级阶梯 + 无音频中止 + 组 context + 落卡」抽成注入式可测引擎，`_mineVideoCard` 变薄壳。三个来源共用的收口。

### Task 0.1：请求/结果值对象

**Files:** Create `hibiki/lib/src/mining/immersion_mining_request.dart`

- [ ] **Step 1: 写值对象**

```dart
// hibiki/lib/src/mining/immersion_mining_request.dart
import 'dart:typed_data';
import 'package:hibiki_anki/hibiki_anki.dart' show AnkiMiningSource;

/// 统一沉浸制卡请求。任何来源（本地/YouTube/Netflix）都构造这个喂引擎。
/// [mediaSource] 是 ffmpeg 的 inputPath——本地绝对路径 或 可 seek 的 http 流 URL。
/// 若 [mediaSource] 为 null（如 Netflix 前台无本地源），引擎只用 [stillFallback]/
/// [providedCoverBytes]/[providedAudioBytes] 组卡。
class ImmersionMiningRequest {
  const ImmersionMiningRequest({
    required this.fields,
    required this.clipStartMs,
    required this.clipEndMs,
    required this.sentence,
    this.mediaSource,
    this.cueSentence,
    this.documentTitle,
    this.audioStreamIndex,
    this.audioStreamCount,
    this.source = AnkiMiningSource.video,
    this.bookTitleTag,
    this.updateNoteId,
    this.stillFallback,
    this.providedCoverBytes,
    this.providedCoverName,
    this.providedAudioBytes,
    this.providedAudioName,
    this.requireAudio = true,
  });

  final Map<String, String> fields;
  final int clipStartMs;
  final int clipEndMs;
  final String sentence;
  final String? mediaSource;
  final String? cueSentence;
  final String? documentTitle;
  final int? audioStreamIndex;
  final int? audioStreamCount;
  final AnkiMiningSource source;
  final String? bookTitleTag;
  final int? updateNoteId; // 非 null = 覆盖现有卡（updateMinedNote，不计统计）
  final Future<Uint8List?> Function()? stillFallback; // 当前解码帧兜底（本地传 controller.screenshot）
  final Uint8List? providedCoverBytes;
  final String? providedCoverName;
  final Uint8List? providedAudioBytes;
  final String? providedAudioName;
  final bool requireAudio; // true=无音频则中止（本地/YouTube）；false=允许无音频卡（Netflix 2A）

  bool get hasRange => clipEndMs > clipStartMs;
}

/// 引擎产出。[outcome] 用 Object? 承 MineOutcome，避免此文件依赖 anki_models 全量。
class ImmersionMiningResult {
  const ImmersionMiningResult({required this.aborted, this.outcome, this.degradedToStill = false});
  final bool aborted;
  final Object? outcome;
  final bool degradedToStill;
}
```

- [ ] **Step 2: 提交**

```
git add hibiki/lib/src/mining/immersion_mining_request.dart
git commit -m "feat(mining): add ImmersionMiningRequest/Result value objects (TODO-1000)"
```

### Task 0.2：引擎核心（注入式抽取器 + 降级阶梯）

**Files:** Create `hibiki/lib/src/mining/immersion_mining_engine.dart`；Test `hibiki/test/mining/immersion_mining_engine_test.dart`

- [ ] **Step 1: 写失败测试**（假抽取器验证「阶梯 + 无音频中止 + context 组装 + 落卡」，不跑 ffmpeg）

```dart
// hibiki/test/mining/immersion_mining_engine_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart' show MiningMediaCompression;

class _FakeRepo implements BaseAnkiRepository {
  AnkiMiningContext? minedContext;
  int? updatedNoteId;
  @override
  Future<MineOutcome> mineEntry({required String rawPayloadJson, required AnkiMiningContext context}) async {
    minedContext = context;
    return const MineOutcome.success(noteId: 42);
  }
  @override
  Future<MineOutcome> updateMinedNote({required int noteId, required String rawPayloadJson, required AnkiMiningContext context}) async {
    updatedNoteId = noteId; minedContext = context;
    return const MineOutcome.success(noteId: 99);
  }
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late Directory tmp;
  setUp(() async { tmp = await Directory.systemTemp.createTemp('immersion_engine'); });
  tearDown(() async { if (tmp.existsSync()) await tmp.delete(recursive: true); });

  ImmersionMiningEngine build({required GifExtractor gif, required AudioExtractor audio, required FrameExtractor frame}) =>
      ImmersionMiningEngine(gifExtractor: gif, audioExtractor: audio, frameExtractor: frame);

  final okGif = ({required String inputPath, required int startMs, required int endMs, required String outputPath, int fps = 8, int width = 320, FfmpegFailureReporter? onFailure}) async => outputPath;
  final nullGif = ({required String inputPath, required int startMs, required int endMs, required String outputPath, int fps = 8, int width = 320, FfmpegFailureReporter? onFailure}) async => null;
  final okAudio = ({required String inputPath, required int startMs, required int endMs, required String outputPath, int? audioStreamIndex, int? audioStreamCount, FfmpegFailureReporter? onFailure, int audioChannels = 1, String audioBitrate = '64k'}) async => outputPath;
  final nullAudio = ({required String inputPath, required int startMs, required int endMs, required String outputPath, int? audioStreamIndex, int? audioStreamCount, FfmpegFailureReporter? onFailure, int audioChannels = 1, String audioBitrate = '64k'}) async => null;
  final okFrame = ({required String inputPath, required String outputPath, double atSeconds = 10.0, FfmpegFailureReporter? onFailure}) async => outputPath;
  final nullFrame = ({required String inputPath, required String outputPath, double atSeconds = 10.0, FfmpegFailureReporter? onFailure}) async => null;

  test('gif+audio success builds context and calls mineEntry', () async {
    final repo = _FakeRepo();
    final res = await build(gif: okGif, audio: okAudio, frame: okFrame).mine(
      ImmersionMiningRequest(fields: const {'expression': '走る'}, mediaSource: '/fake/video.mp4', clipStartMs: 1000, clipEndMs: 3000, sentence: '走り出した。'),
      compression: MiningMediaCompression.compressed, tempDir: tmp.path, repo: repo);
    expect(res.aborted, false);
    expect(repo.minedContext!.sentence, '走り出した。');
    expect(repo.minedContext!.coverPath, endsWith('.gif'));
    expect(repo.minedContext!.sasayakiAudioPath, isNotNull);
    expect(repo.minedContext!.source, AnkiMiningSource.video);
  });

  test('gif fails -> frame fallback yields still cover', () async {
    final repo = _FakeRepo();
    final res = await build(gif: nullGif, audio: okAudio, frame: okFrame).mine(
      ImmersionMiningRequest(fields: const {'expression': 'x'}, mediaSource: '/v.mp4', clipStartMs: 0, clipEndMs: 2000, sentence: 's'),
      compression: MiningMediaCompression.compressed, tempDir: tmp.path, repo: repo);
    expect(res.degradedToStill, true);
    expect(repo.minedContext!.coverPath, endsWith('.jpg'));
  });

  test('requireAudio && audio missing -> abort, no mine', () async {
    final repo = _FakeRepo();
    final res = await build(gif: okGif, audio: nullAudio, frame: nullFrame).mine(
      ImmersionMiningRequest(fields: const {'expression': 'x'}, mediaSource: '/v.mp4', clipStartMs: 0, clipEndMs: 2000, sentence: 's'),
      compression: MiningMediaCompression.compressed, tempDir: tmp.path, repo: repo);
    expect(res.aborted, true);
    expect(repo.minedContext, isNull);
  });

  test('requireAudio=false (netflix 2A) allows still-only card', () async {
    final repo = _FakeRepo();
    final res = await build(gif: nullGif, audio: nullAudio, frame: okFrame).mine(
      ImmersionMiningRequest(fields: const {'expression': 'x'}, mediaSource: '/v.mp4', clipStartMs: 0, clipEndMs: 2000, sentence: 's', requireAudio: false),
      compression: MiningMediaCompression.compressed, tempDir: tmp.path, repo: repo);
    expect(res.aborted, false);
    expect(repo.minedContext!.sasayakiAudioPath, isNull);
    expect(repo.minedContext!.coverPath, endsWith('.jpg'));
  });

  test('updateNoteId routes to updateMinedNote', () async {
    final repo = _FakeRepo();
    await build(gif: okGif, audio: okAudio, frame: okFrame).mine(
      ImmersionMiningRequest(fields: const {'expression': 'x'}, mediaSource: '/v.mp4', clipStartMs: 0, clipEndMs: 2000, sentence: 's', updateNoteId: 7),
      compression: MiningMediaCompression.compressed, tempDir: tmp.path, repo: repo);
    expect(repo.updatedNoteId, 7);
  });
}
```

- [ ] **Step 2: 运行测试确认失败** → （在 `hibiki/`）`flutter test test/mining/immersion_mining_engine_test.dart`（FAIL：文件不存在）。

- [ ] **Step 3: 写引擎**

```dart
// hibiki/lib/src/mining/immersion_mining_engine.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:hibiki_anki/hibiki_anki.dart';
import '../utils/misc/desktop_audio_clipper.dart';
import 'immersion_mining_request.dart';

/// 注入式抽取器（默认指向 desktop_audio_clipper.dart 真身，测试注入假件）。逐参对齐真身。
typedef GifExtractor = Future<String?> Function({required String inputPath, required int startMs, required int endMs, required String outputPath, int fps, int width, FfmpegFailureReporter? onFailure});
typedef AudioExtractor = Future<String?> Function({required String inputPath, required int startMs, required int endMs, required String outputPath, int? audioStreamIndex, int? audioStreamCount, FfmpegFailureReporter? onFailure, int audioChannels, String audioBitrate});
typedef FrameExtractor = Future<String?> Function({required String inputPath, required String outputPath, double atSeconds, FfmpegFailureReporter? onFailure});

/// 统一沉浸制卡引擎。降级阶梯与 _mineVideoCard（L285-441）一致：GIF 主 → 单帧降级 →
/// 当前解码帧兜底；音频段；requireAudio 且缺音频则中止；组 context 落卡。
/// 媒体抽取全走「输入路径/URL + 毫秒」，绝不 seek/干扰前台播放器。
class ImmersionMiningEngine {
  ImmersionMiningEngine({GifExtractor? gifExtractor, AudioExtractor? audioExtractor, FrameExtractor? frameExtractor})
      : _gif = gifExtractor ?? extractClipGifViaFfmpeg,
        _audio = audioExtractor ?? extractAudioSegmentViaFfmpeg,
        _frame = frameExtractor ?? extractVideoFrameViaFfmpeg;

  final GifExtractor _gif;
  final AudioExtractor _audio;
  final FrameExtractor _frame;

  Future<ImmersionMiningResult> mine(ImmersionMiningRequest req, {required MiningMediaCompression compression, required String tempDir, required BaseAnkiRepository repo, FfmpegFailureReporter? onFailure}) async {
    String? coverPath;
    bool degradedToStill = false;
    if (req.providedCoverBytes != null) {
      coverPath = await _writeBytes(tempDir, req.providedCoverName ?? 'immersion_cover.gif', req.providedCoverBytes!);
    }
    final String? src = req.mediaSource;
    if (coverPath == null && src != null && req.hasRange) {
      coverPath = await _gif(inputPath: src, startMs: req.clipStartMs, endMs: req.clipEndMs, outputPath: '$tempDir/immersion_clip.gif', fps: compression.gifFps, width: compression.gifWidth, onFailure: onFailure);
    }
    if (coverPath == null && src != null) {
      final String? framePath = await _frame(inputPath: src, outputPath: '$tempDir/immersion_frame.jpg', atSeconds: req.clipStartMs / 1000.0, onFailure: onFailure);
      if (framePath != null) { coverPath = framePath; degradedToStill = true; }
    }
    if (coverPath == null && req.stillFallback != null) {
      final Uint8List? shot = await req.stillFallback!();
      if (shot != null) {
        final Uint8List small = downsampleCardScreenshot(shot, maxLongEdge: compression.screenshotMaxLongEdge, quality: compression.screenshotQuality);
        coverPath = await _writeBytes(tempDir, 'immersion_shot.jpg', small);
        degradedToStill = true;
      }
    }
    String? audioPath;
    if (req.providedAudioBytes != null) {
      audioPath = await _writeBytes(tempDir, req.providedAudioName ?? 'immersion_audio.aac', req.providedAudioBytes!);
    } else if (src != null && req.hasRange) {
      audioPath = await _audio(inputPath: src, startMs: req.clipStartMs, endMs: req.clipEndMs, outputPath: '$tempDir/immersion_audio.aac', audioStreamIndex: req.audioStreamIndex, audioStreamCount: req.audioStreamCount, audioChannels: compression.audioChannels, audioBitrate: compression.audioBitrate, onFailure: onFailure);
    }
    if (req.requireAudio && req.hasRange && audioPath == null) {
      return const ImmersionMiningResult(aborted: true);
    }
    final AnkiMiningContext context = AnkiMiningContext(sentence: req.sentence, cueSentence: req.cueSentence, documentTitle: req.documentTitle, coverPath: coverPath, sasayakiAudioPath: audioPath, source: req.source, bookTitleTag: req.bookTitleTag);
    final MineOutcome outcome = req.updateNoteId == null
        ? await repo.mineEntry(rawPayloadJson: jsonEncode(req.fields), context: context)
        : await repo.updateMinedNote(noteId: req.updateNoteId!, rawPayloadJson: jsonEncode(req.fields), context: context);
    return ImmersionMiningResult(aborted: false, outcome: outcome, degradedToStill: degradedToStill);
  }

  Future<String> _writeBytes(String dir, String name, Uint8List bytes) async {
    final File f = File('$dir/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }
}
```

> 落地核对：`downsampleCardScreenshot` 真实所在（grep `downsampleCardScreenshot`）——不在 desktop_audio_clipper.dart 则改 import。AnkiMiningContext 必填字段以 anki_models.dart:371 为准。

- [ ] **Step 4: 运行测试确认通过** → `flutter test test/mining/immersion_mining_engine_test.dart`（PASS，5 tests）。
- [ ] **Step 5: 提交**

```
git add hibiki/lib/src/mining/immersion_mining_engine.dart hibiki/test/mining/immersion_mining_engine_test.dart
git commit -m "feat(mining): add injectable ImmersionMiningEngine (extracted mine ladder) (TODO-1000)"
```

### Task 0.3：`_mineVideoCard` 委托引擎（零行为变更 + 回归守卫）

**Files:** Modify `hibiki/lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart:269-464`

- [ ] **Step 1: 改 `_mineVideoCard`**：保留 `_resolveVideoMiningRange`/OSD/`_recordMinedForVideo`/`describeMineOutcome`/deckName 取法 不变；把 L285-441 的媒体抽取+落卡替换为构造 `ImmersionMiningRequest`（mediaSource: controller.videoPath（Task 1.3 后改 controller.miningSource）、stillFallback: controller.screenshot、requireAudio: true、audioStreamIndex: controller.currentAudioStreamIndex、audioStreamCount: controller.realAudioStreamCount、bookTitleTag: appModel.autoAddBookNameToTags ? BaseAnkiRepository.sanitizeTitleTag(_title) : null、updateNoteId）→ `ImmersionMiningEngine().mine(..., compression: MiningMediaCompression.forCompressionEnabled(appModel.compressMiningMedia), tempDir: (await getTemporaryDirectory()).path, repo: ref.read(ankiRepositoryProvider), onFailure: _showOsd)`；res.aborted → return const MinePopupResult()；成功且 updateNoteId==null → _recordMinedForVideo()；describeMineOutcome + _showOsd 保持原样。
- [ ] **Step 2: 现有视频/制卡测试** → （在 `hibiki/`）`flutter test test/media/video/ test/mining/`（PASS，不回归）。
- [ ] **Step 3: analyze** → `flutter analyze lib/src/pages/implementations/video_hibiki/ lib/src/mining/`（No issues）。
- [ ] **Step 4: 提交**

```
git add hibiki/lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart
git commit -m "refactor(video): route _mineVideoCard through ImmersionMiningEngine (TODO-1000)"
```

---

## Phase 1（第一层）：本地 + YouTube 内嵌

本地已由 Phase 0 收口。本阶段做 YouTube：解析出可播放流 URL + 字幕喂现有原生播放器，复用原生查词 + 引擎制卡（mediaSource=流URL，ffmpeg 从可 seek 的流 URL 裁，零回放）。

### Task 1.1：加依赖

**Files:** Modify `hibiki/pubspec.yaml`

- [ ] **Step 1: 加依赖**（dependencies 段）

```yaml
  youtube_explode_dart: ^2.3.6
  html_unescape: ^2.0.0
```

- [ ] **Step 2: 拉依赖** → （在 `hibiki/`）`flutter pub get`（解析成功）。
- [ ] **Step 3: 提交**

```
git add hibiki/pubspec.yaml hibiki/pubspec.lock
git commit -m "build(deps): add youtube_explode_dart + html_unescape (TODO-1000)"
```

### Task 1.2：YouTube 解析器（流 URL + 字幕 cue）

**Files:** Create `hibiki/lib/src/media/video/youtube_source_resolver.dart`；Test `hibiki/test/media/video/youtube_source_resolver_test.dart`

- [ ] **Step 1: 写失败测试**（纯函数：URL 识别 + timedtext XML→cue）

```dart
// hibiki/test/media/video/youtube_source_resolver_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/youtube_source_resolver.dart';

void main() {
  group('isYoutubeUrl', () {
    test('accepts watch and youtu.be', () {
      expect(isYoutubeUrl('https://www.youtube.com/watch?v=abc123'), true);
      expect(isYoutubeUrl('https://youtu.be/abc123'), true);
    });
    test('rejects non-youtube', () {
      expect(isYoutubeUrl('https://www.netflix.com/watch/1'), false);
      expect(isYoutubeUrl('/local/file.mp4'), false);
    });
  });
  group('parseYoutubeTimedTextToCues', () {
    test('converts timedtext XML to cues with ms bounds', () {
      const xml = '<transcript><text start="1.5" dur="2.0">走り出した</text><text start="4.0" dur="1.5">こんにちは</text></transcript>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:abc');
      expect(cues.length, 2);
      expect(cues[0].text, '走り出した');
      expect(cues[0].startMs, 1500);
      expect(cues[0].endMs, 3500);
      expect(cues[1].startMs, 4000);
      expect(cues[1].endMs, 5500);
    });
    test('decodes entities and skips empty', () {
      const xml = '<transcript><text start="0" dur="1">&amp;#39;</text><text start="1" dur="1"></text></transcript>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:x');
      expect(cues.length, 1);
      expect(cues[0].text, "'");
    });
  });
}
```

- [ ] **Step 2: 运行确认失败** → `flutter test test/media/video/youtube_source_resolver_test.dart`（FAIL）。

- [ ] **Step 3: 写实现**

```dart
// hibiki/lib/src/media/video/youtube_source_resolver.dart
import 'package:html_unescape/html_unescape.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import 'package:hibiki_audio/hibiki_audio.dart' show AudioCue;

class YoutubeResolvedSource {
  const YoutubeResolvedSource({required this.streamUrl, required this.title, required this.httpHeaders, required this.cues});
  final String streamUrl;
  final String title;
  final Map<String, String> httpHeaders;
  final List<AudioCue> cues;
}

/// 纯函数：识别 YouTube URL（watch / youtu.be / shorts / nocookie）。
bool isYoutubeUrl(String url) {
  final Uri? u = Uri.tryParse(url.trim());
  if (u == null || !u.hasScheme) return false;
  final String host = u.host.toLowerCase();
  return host.endsWith('youtube.com') || host == 'youtu.be' || host.endsWith('youtube-nocookie.com');
}

final HtmlUnescape _unescape = HtmlUnescape();

AudioCue _cue(String bookKey, int index, String text, int startMs, int endMs) => AudioCue()
  ..bookKey = bookKey
  ..chapterHref = 'youtube://$bookKey'
  ..sentenceIndex = index
  ..textFragmentId = 'yt-$index'
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

/// 纯函数：YouTube timedtext XML → List<AudioCue>。start/dur 秒 → 毫秒。
List<AudioCue> parseYoutubeTimedTextToCues({required String content, required String bookKey}) {
  final List<AudioCue> cues = <AudioCue>[];
  final RegExp re = RegExp(r'<text start="([\d.]+)"(?: dur="([\d.]+)")?[^>]*>(.*?)</text>', dotAll: true);
  int index = 0;
  for (final RegExpMatch m in re.allMatches(content)) {
    final double start = double.tryParse(m.group(1) ?? '') ?? 0;
    final double dur = double.tryParse(m.group(2) ?? '') ?? 0;
    final String raw = _unescape.convert((m.group(3) ?? '').replaceAll(RegExp(r'<[^>]+>'), '')).trim();
    if (raw.isEmpty) continue;
    cues.add(_cue(bookKey, index, raw, (start * 1000).round(), ((start + dur) * 1000).round()));
    index++;
  }
  return cues;
}

/// IO：youtube_explode 解析可播放流 URL + 日文字幕 + 标题。优先 muxed（音视频合一）。
Future<YoutubeResolvedSource> resolveYoutubeSource(String url, {String preferSubtitleLang = 'ja'}) async {
  final yt.YoutubeExplode client = yt.YoutubeExplode();
  try {
    final yt.Video video = await client.videos.get(url);
    final yt.StreamManifest manifest = await client.videos.streamsClient.getManifest(video.id);
    final yt.MuxedStreamInfo muxed = manifest.muxed.withHighestBitrate();
    final String bookKey = 'yt:${video.id.value}';
    List<AudioCue> cues = <AudioCue>[];
    final yt.ClosedCaptionManifest cc = await client.videos.closedCaptions.getManifest(video.id);
    yt.ClosedCaptionTrackInfo? track;
    for (final t in cc.tracks) {
      if (t.language.code.startsWith(preferSubtitleLang)) { track = t; break; }
    }
    track ??= cc.tracks.isNotEmpty ? cc.tracks.first : null;
    if (track != null) {
      final yt.ClosedCaptionTrack captions = await client.videos.closedCaptions.get(track);
      int i = 0;
      for (final c in captions.captions) {
        if (c.text.trim().isEmpty) continue;
        cues.add(_cue(bookKey, i, c.text.trim(), c.offset.inMilliseconds, (c.offset + c.duration).inMilliseconds));
        i++;
      }
    }
    return YoutubeResolvedSource(streamUrl: muxed.url.toString(), title: video.title, httpHeaders: const {'User-Agent': 'Mozilla/5.0'}, cues: cues);
  } finally {
    client.close();
  }
}
```

> 落地核对：youtube_explode_dart 锁定版 API（muxed.withHighestBitrate / videos.closedCaptions / ClosedCaptionTrackInfo.language.code）按 pub 实际签名核对；有出入按真实 API 调整（不影响纯函数测试）。

- [ ] **Step 4: 运行确认通过** → PASS（纯函数 4 tests；resolveYoutubeSource IO 留真机验证）。
- [ ] **Step 5: 提交**

```
git add hibiki/lib/src/media/video/youtube_source_resolver.dart hibiki/test/media/video/youtube_source_resolver_test.dart
git commit -m "feat(video): YouTube source resolver (stream url + timedtext cues) (TODO-1000)"
```

### Task 1.3：接进现有视频播放路径 + miningSource 覆盖

**Files:** Modify `hibiki/lib/src/media/video/video_player_controller.dart`、视频源装配处（grep isPlayableStreamUrl / UrlStreamVideoClient 定位）、Phase 0 的 mediaSource。

- [ ] **Step 1: VideoPlayerController 加 miningSource 覆盖**

```dart
// video_player_controller.dart（字段区 + getter 区）
String? _miningSourceOverride;
void setMiningSourceOverride(String? source) => _miningSourceOverride = source;
/// 制卡 ffmpeg 抽取源：YouTube 用可 seek 流 URL 覆盖，其余用本地 videoPath。
String? get miningSource => _miningSourceOverride ?? videoPath;
```

- [ ] **Step 2: Phase 0 的 mediaSource 改用 controller.miningSource**（lookup_mining.part.dart）。
- [ ] **Step 3: 视频源装配处加 YouTube 分支**：在 isPlayableStreamUrl(url) 附近加 `if (isYoutubeUrl(url)) { final r = await resolveYoutubeSource(url); await applyHttpHeaderFieldsToPlayer(player, r.httpHeaders); await player.open(Media(r.streamUrl, httpHeaders: r.httpHeaders), play: true); controller.setCues(r.cues); controller.setMiningSourceOverride(r.streamUrl); /* title=r.title */ }`（按真实装配点适配 Media 构造与 player 获取）。
- [ ] **Step 4: analyze + 现有视频测试** → `flutter analyze lib/src/media/video/ && flutter test test/media/video/`（No issues + PASS）。
- [ ] **Step 5: 提交**

```
git add hibiki/lib/src/media/video/ hibiki/lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart
git commit -m "feat(video): play YouTube via resolved stream + cues; mine from stream url (TODO-1000)"
```

- [ ] **Step 6: 真机验证（声明「修好了」前必做）**：桌面/模拟器打开日文字幕 YouTube → 字幕显示 → shift-hover/点词弹 Hibiki 词典卡 → 一键制卡 → Anki 卡带 GIF+音频+句子，制卡时视频不回放。留证据（docs/agent/integration-testing.md）。

---

## Phase 2A（第二层A）：Netflix — 字幕+timestamp+shift-hover 查词 + 文本/截图不回放制卡

复用 `tools/browser-extension/` 现有 MVP（已有 shift-hover 取词 + /api/lookup/dictionary + /api/mine）。新增：字幕轨读取 + `<video>.currentTime` timestamp + 截图（不回放）+ server `_handleMine` 携带截图/timestamp 走引擎。

### Task 2A.1：per-site 字幕适配器（Netflix 首发）

**Files:** Create `tools/browser-extension/subtitle-adapters.js`；Test `tools/browser-extension/subtitle-adapters.test.js`

- [ ] **Step 1: 写失败测试**

```js
// tools/browser-extension/subtitle-adapters.test.js
const test = require('node:test');
const assert = require('node:assert');
const { extractNetflixCueText, currentVideoTimeMs, netflixVideoIdFromPath } = require('./subtitle-adapters.js');

test('extractNetflixCueText joins span lines', () => {
  const container = { querySelectorAll: () => [{ textContent: '走り' }, { textContent: '出した' }] };
  assert.strictEqual(extractNetflixCueText(container), '走り出した');
});
test('extractNetflixCueText null container -> empty', () => {
  assert.strictEqual(extractNetflixCueText(null), '');
});
test('currentVideoTimeMs seconds -> ms; null-safe', () => {
  assert.strictEqual(currentVideoTimeMs({ currentTime: 12.34 }), 12340);
  assert.strictEqual(currentVideoTimeMs(null), null);
});
test('netflixVideoIdFromPath extracts /watch/<id>', () => {
  assert.strictEqual(netflixVideoIdFromPath('/watch/81234567'), '81234567');
  assert.strictEqual(netflixVideoIdFromPath('/browse'), null);
});
```

- [ ] **Step 2: 运行确认失败** → （在 `tools/browser-extension/`）`node --test subtitle-adapters.test.js`（FAIL）。

- [ ] **Step 3: 写实现**

```js
// tools/browser-extension/subtitle-adapters.js
// per-site 字幕 + 时间戳读取。Netflix 字幕是明文 DOM（非 DRM），可直接读。
function extractNetflixCueText(container) {
  if (!container) return '';
  const spans = container.querySelectorAll('.player-timedtext-text-container span, span');
  return Array.from(spans).map((s) => s.textContent || '').join('').trim();
}
function currentVideoTimeMs(video) {
  if (!video || typeof video.currentTime !== 'number') return null;
  return Math.round(video.currentTime * 1000);
}
function netflixVideoIdFromPath(pathname) {
  const m = /\/watch\/(\d+)/.exec(pathname || '');
  return m ? m[1] : null;
}
// 浏览器运行时入口（非测试）
function netflixSubtitleContainer() { return document.querySelector('.player-timedtext'); }
function netflixVideoEl() { return document.querySelector('video'); }

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { extractNetflixCueText, currentVideoTimeMs, netflixVideoIdFromPath, netflixSubtitleContainer, netflixVideoEl };
}
```

- [ ] **Step 4: 运行确认通过** → PASS（4 tests）。
- [ ] **Step 5: 提交**

```
git add tools/browser-extension/subtitle-adapters.js tools/browser-extension/subtitle-adapters.test.js
git commit -m "feat(webext): per-site subtitle+timestamp adapters (netflix) (TODO-1000)"
```

### Task 2A.2：content.js/background.js 上报字幕+timestamp + 截图制卡

**Files:** Modify `tools/browser-extension/manifest.json`（注入 subtitle-adapters.js + activeTab 权限）、`tools/browser-extension/content.js`、`tools/browser-extension/background.js`

- [ ] **Step 1: manifest**：content_scripts[0].js 里在 scan.js 前加 `"subtitle-adapters.js"`；permissions 加 `"activeTab"`（供 captureVisibleTab）。
- [ ] **Step 2: content.js 制卡携带字幕+timestamp+videoId**：挖词处（现有发 {type:'mine'} 的位置）扩展：`const v = netflixVideoEl(); chrome.runtime.sendMessage({ type:'mine', fields, sentence: extractNetflixCueText(netflixSubtitleContainer()), timestampMs: currentVideoTimeMs(v), netflixVideoId: netflixVideoIdFromPath(location.pathname) });`
- [ ] **Step 3: background.js 截图 + 转发**：type:'mine' 分支 `let shot=null; try{shot=await chrome.tabs.captureVisibleTab(null,{format:'jpeg',quality:85});}catch(_){}` → `const base64 = shot ? shot.split(',')[1] : null;` → POST base+'/api/mine' body {fields:msg.fields, sentence:msg.sentence||'', timestampMs:msg.timestampMs??null, netflixVideoId:msg.netflixVideoId??null, screenshotBase64:base64}。黑帧不阻塞（仍出文本卡）。
- [ ] **Step 4: 提交**

```
git add tools/browser-extension/manifest.json tools/browser-extension/content.js tools/browser-extension/background.js
git commit -m "feat(webext): report subtitle+timestamp+screenshot on mine (netflix 2A) (TODO-1000)"
```

### Task 2A.3：server `/api/mine` 消费截图 + timestamp（走引擎，requireAudio=false）

**Files:** Create `hibiki/lib/src/sync/immersion_mine_payload.dart`；Modify `hibiki/lib/src/sync/hibiki_sync_server.dart:655`（`_handleMine`）+ HibikiRemoteMiningService（若需 seam）；Test `hibiki/test/sync/immersion_mine_payload_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/sync/immersion_mine_payload_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/immersion_mine_payload.dart';

void main() {
  test('parses fields+sentence+timestamp+screenshot', () {
    final b64 = base64Encode(<int>[1, 2, 3]);
    final p = ImmersionMinePayload.fromJson({
      'fields': {'expression': '走る'}, 'sentence': 's', 'timestampMs': 1234,
      'netflixVideoId': '81', 'screenshotBase64': b64,
    });
    expect(p.fields['expression'], '走る');
    expect(p.sentence, 's');
    expect(p.timestampMs, 1234);
    expect(p.netflixVideoId, '81');
    expect(p.screenshotBytes, <int>[1, 2, 3]);
  });
  test('missing optionals -> nulls, sentence falls back to fields', () {
    final p = ImmersionMinePayload.fromJson({'fields': {'sentence': 'fromfield'}});
    expect(p.timestampMs, isNull);
    expect(p.screenshotBytes, isNull);
    expect(p.sentence, 'fromfield');
  });
  test('non-map fields throws FormatException', () {
    expect(() => ImmersionMinePayload.fromJson({'fields': 'x'}), throwsFormatException);
  });
}
```

- [ ] **Step 2: 运行确认失败** → `flutter test test/sync/immersion_mine_payload_test.dart`（FAIL）。

- [ ] **Step 3: 写解析器**

```dart
// hibiki/lib/src/sync/immersion_mine_payload.dart
import 'dart:convert';
import 'dart:typed_data';

/// server /api/mine 的扩展 body 解析（沉浸制卡：可带 timestamp + 截图字节 + netflix id + clip 区间）。
/// 向后兼容：纯 {fields,sentence} 也能解析（timestamp/screenshot 为 null）。
class ImmersionMinePayload {
  const ImmersionMinePayload({
    required this.fields, required this.sentence,
    this.cueSentence, this.documentTitle, this.timestampMs,
    this.clipStartMs, this.clipEndMs, this.netflixVideoId, this.screenshotBytes,
  });

  final Map<String, String> fields;
  final String sentence;
  final String? cueSentence;
  final String? documentTitle;
  final int? timestampMs;
  final int? clipStartMs;
  final int? clipEndMs;
  final String? netflixVideoId;
  final Uint8List? screenshotBytes;

  static ImmersionMinePayload fromJson(Map<String, dynamic> json) {
    final Object? rawFields = json['fields'];
    if (rawFields is! Map) throw const FormatException('fields must be an object');
    final Map<String, String> fields = <String, String>{
      for (final MapEntry<Object?, Object?> e in rawFields.entries) '${e.key}': '${e.value}',
    };
    final Object? b64 = json['screenshotBase64'];
    return ImmersionMinePayload(
      fields: fields,
      sentence: (json['sentence'] as String?) ?? (fields['sentence'] ?? ''),
      cueSentence: json['cueSentence'] as String?,
      documentTitle: json['documentTitle'] as String?,
      timestampMs: (json['timestampMs'] as num?)?.round(),
      clipStartMs: (json['clipStartMs'] as num?)?.round(),
      clipEndMs: (json['clipEndMs'] as num?)?.round(),
      netflixVideoId: json['netflixVideoId'] as String?,
      screenshotBytes: b64 is String && b64.isNotEmpty ? base64Decode(b64) : null,
    );
  }
}
```

- [ ] **Step 4: 运行确认通过** → PASS（3 tests）。

- [ ] **Step 5: `_handleMine` 走引擎**（截图字节作封面、requireAudio=false）：`_handleMine` 解析 ImmersionMinePayload；若 screenshotBytes!=null || timestampMs!=null 走沉浸路径——`ImmersionMiningEngine().mine(ImmersionMiningRequest(fields: payload.fields, mediaSource: null, clipStartMs: 0, clipEndMs: 0, sentence: payload.sentence, providedCoverBytes: payload.screenshotBytes, providedCoverName: 'netflix_shot.jpg', requireAudio: false, source: AnkiMiningSource.video, documentTitle: payload.documentTitle ?? 'Netflix'), compression: MiningMediaCompression.forCompressionEnabled(true), tempDir: Directory.systemTemp.path, repo: <miningService 提供的 repo>)`；否则回落现有 svc.mineEntry(fields, sentence)（向后兼容）。响应仍 {result: <MineResult name>}。
  > 落地核对：server 侧拿 BaseAnkiRepository——HibikiRemoteMiningService（hibiki_sync_server.dart 构造注入）若未暴露 repo，给它加 `Future<MineResult> mineImmersion(ImmersionMinePayload payload)` seam（内部调引擎），保持 server 只解析+转发，不在 server 层直接 new 引擎。

- [ ] **Step 6: analyze + server 测试** → `flutter analyze lib/src/sync/ && flutter test test/sync/`（No issues + PASS；纯文本挖词向后兼容不回归）。
- [ ] **Step 7: 提交**

```
git add hibiki/lib/src/sync/immersion_mine_payload.dart hibiki/lib/src/sync/hibiki_sync_server.dart hibiki/test/sync/immersion_mine_payload_test.dart
git commit -m "feat(sync): /api/mine consumes screenshot+timestamp via engine (netflix 2A) (TODO-1000)"
```

- [ ] **Step 8: 真机验证**：真 Chrome 装扩展 + Hibiki + Anki → Netflix 日文字幕 shift-hover 查 Hibiki 词典卡 → 一键制卡 → Anki 卡带截图（关硬件加速时非黑）+ 句子，视频不回放。留证据。

---

## Phase 2B（第二层B）：Netflix — 后台专用软解实例抓音频/GIF（不回放前台）

前台满血 L1 看片；一键制卡时把 {netflixVideoId, clipStartMs, clipEndMs} 交给 Hibiki，起一个**独立软解 WebView2 实例**（硬件加速关、持久化该实例的 Netflix 登录），deep-link `?t=` seek 播那段、抓帧序列做 GIF + 抓音频 → 经引擎 providedCoverBytes/providedAudioBytes 落卡。异步，前台不动。

> **诚实上限（写进设计，不隐瞒）**：Netflix 音画受 DRM，后台实例须软解才非黑；本阶段是可选进阶，失败（黑帧/静音/未登录）时降级为 2A 的截图卡并 OSD 告知。

### Task 2B.0：M-Probe（先验证再实现，gate 整个 2B）

- [ ] **Step 1: 探针**：手工做一个隐藏、禁 GPU 的 WebView2（`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--disable-gpu --disable-accelerated-video-decode`），登录 Netflix，Navigate(watch/<id>?t=<sec>)，用注入脚本运行 canvas `drawImage(video)` + `toDataURL` 取一帧，落盘查看是否**非黑**。
- [ ] **Step 2: 结论落文档**：非黑 → 2B 成立，继续 2B.1；黑 → 2B 不可行，**止步于 2A**，在本计划与设计文档标注「Netflix 音频/GIF 受 DRM 输出保护，后台软解仍黑，2B 关闭」。**不硬做。**

### Task 2B.1：Dart↔native 通道 + 后台实例骨架（Windows）

**Files:** Create `hibiki/lib/src/mining/immersion_capture_channel.dart`；Create `hibiki/windows/runner/immersion_capture_window.h` / `.cpp`；Modify `hibiki/windows/runner/flutter_window.cpp`

- [ ] **Step 1: Dart 通道**

```dart
// hibiki/lib/src/mining/immersion_capture_channel.dart
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// 第二层B：驱动后台软解 WebView2 实例抓 Netflix 片段音画。仅 Windows。
abstract final class ImmersionCaptureChannel {
  static const MethodChannel _c = MethodChannel('app.hibiki.reader/immersion_capture');

  static Future<ImmersionCaptureResult> capture({
    required String netflixVideoId, required int clipStartMs, required int clipEndMs,
    int fps = 8, int width = 320,
  }) async {
    try {
      final Map<Object?, Object?>? r = await _c.invokeMethod('capture', <String, Object?>{
        'videoId': netflixVideoId, 'startMs': clipStartMs, 'endMs': clipEndMs, 'fps': fps, 'width': width,
      });
      return ImmersionCaptureResult.fromMap(r ?? const <Object?, Object?>{});
    } on PlatformException catch (e) {
      return ImmersionCaptureResult(error: e.message ?? 'capture failed');
    } on MissingPluginException {
      return const ImmersionCaptureResult(error: 'immersion_capture unavailable');
    }
  }
}

class ImmersionCaptureResult {
  const ImmersionCaptureResult({this.gifBytes, this.audioBytes, this.error});
  final Uint8List? gifBytes;
  final Uint8List? audioBytes;
  final String? error;
  static ImmersionCaptureResult fromMap(Map<Object?, Object?> m) => ImmersionCaptureResult(
    gifBytes: m['gifBytes'] as Uint8List?, audioBytes: m['audioBytes'] as Uint8List?, error: m['error'] as String?,
  );
}
```

- [ ] **Step 2: native 实例**（复用 `global_lookup_window.cpp` 的 WebView2 环境创建范式）：隐藏 WS_EX_NOACTIVATE 屏外窗，独立 User Data Folder（持久化 Netflix 登录），--disable-gpu；capture → Navigate(watch/<id>?t=<startSec>) → 等 <video> 播放 → 定时用注入脚本运行 canvas.toDataURL(video) 抓帧序列 → 交 Dart 端 ffmpeg 合 GIF；音频经注入 Web Audio MediaRecorder 录段（失败静音则只出 GIF）。每步失败降级不崩、绝不回放前台。
- [ ] **Step 3: 注册 channel**：`flutter_window.cpp` 仿 RegisterGlobalLookupChannel()（L753）注册 immersion_capture。
- [ ] **Step 4: 提交**

```
git add hibiki/lib/src/mining/immersion_capture_channel.dart hibiki/windows/runner/immersion_capture_window.* hibiki/windows/runner/flutter_window.cpp
git commit -m "feat(mining): background software-decode capture instance (netflix 2B) (TODO-1000)"
```

### Task 2B.2：server 沉浸挖词接后台实例（带降级）

**Files:** Modify `hibiki/lib/src/sync/hibiki_sync_server.dart`（`_handleMine` 沉浸分支 / mineImmersion seam）；Test `hibiki/test/sync/immersion_mine_payload_test.dart`（补降级路径单测）

- [ ] **Step 1: 带 clip 区间 + videoId 时调后台实例**：沉浸分支若 netflixVideoId!=null && clipStartMs!=null && clipEndMs!=null，`final cap = await ImmersionCaptureChannel.capture(...)`；cap.error==null → 引擎 providedCoverBytes: cap.gifBytes ?? payload.screenshotBytes, providedAudioBytes: cap.audioBytes, requireAudio: cap.audioBytes!=null；cap.error!=null → 降级用 payload.screenshotBytes（2A 截图卡），响应标 degraded:true。把这段抽成可注入 capture 函数的纯逻辑 `resolveImmersionMedia(payload, captureFn)` 便于单测。
- [ ] **Step 2: 降级路径单测**（注入 fake capture 返 error → 断言回落 screenshotBytes、requireAudio=false）。
- [ ] **Step 3: analyze + server 测试** → `flutter analyze lib/src/sync/ lib/src/mining/ && flutter test test/sync/`（No issues + PASS）。
- [ ] **Step 4: 提交**

```
git add hibiki/lib/src/sync/hibiki_sync_server.dart hibiki/test/sync/immersion_mine_payload_test.dart
git commit -m "feat(sync): route netflix clip mine to background capture w/ screenshot fallback (2B) (TODO-1000)"
```

- [ ] **Step 5: 真机验证**：Netflix 一键制卡 → 后台实例出 GIF+音频卡（软解 720p），前台视频不回放；后台失败降级截图卡 + OSD。留证据。

---

## Self-Review

**1. Spec 覆盖：**
- 第一层 本地：Phase 0（引擎抽取，`_mineVideoCard` 委托，mediaSource=miningSource）✅
- 第一层 YouTube：Phase 1（youtube_explode 流 URL + 字幕 → 原生播放器 + 引擎从流 URL 裁）✅
- 第二层A Netflix：Phase 2A（扩展字幕+timestamp+截图 + server `_handleMine` 走引擎 requireAudio=false）✅
- 第二层B Netflix：Phase 2B（M-Probe gate → 后台软解实例 + 引擎 providedCover/AudioBytes + 降级）✅
- 查词用 Hibiki 不用 Yomitan：本地/YouTube 走原生查词；Netflix 走扩展 /api/lookup/dictionary（Hibiki 词库）✅
- 不回放：所有媒体抽取以 路径/URL+时间戳 为输入，前台播放器只读 ✅

**2. 占位符扫描：** 引擎/解析器/payload 均给完整代码 + TDD；YouTube IO（resolveYoutubeSource）、扩展 content/background 接线、native 2B 明确标注「真机/探针/按真实 API 适配」——外部系统/平台组件的合理裁量点，非代码留白。2B 高风险区用 M-Probe（Task 2B.0）显式 gate，失败即止步 2A，不硬做。

**3. 类型一致：** ImmersionMiningRequest 字段在各 Phase 一致；引擎注入 typedef（GifExtractor/AudioExtractor/FrameExtractor）逐参对齐 desktop_audio_clipper.dart 真身；AudioCue 用 late 级联构造对齐 audiobook_model.dart:64；MineOutcome.result==MineResult.success + noteId 对齐 anki_models.dart；controller.miningSource 在 Task 0.3/1.3 一致；server 沉浸路径 ImmersionMinePayload→ImmersionMiningEngine 一致；ImmersionCaptureResult 在 2B.1/2B.2 一致。

**4. 已知风险（交审查重点核）：**
- (a) 2B native 隐藏软解 WebView2 播 Netflix + canvas 取非黑帧 → **M-Probe 先行**，失败止于 2A。
- (b) youtube_explode_dart 锁定版 API 签名需按 pub 实际核对。
- (c) HibikiRemoteMiningService 是否能拿 BaseAnkiRepository；不能则加 mineImmersion seam。
- (d) captureVisibleTab 需 activeTab 权限，Netflix 非黑帧依赖用户关硬件加速（平台约束，doc 已证实）。
- (e) downsampleCardScreenshot 真实 import 路径需 grep 核对。
- (f) YouTube 播放走 libmpv 直吃流 URL 的稳定性（清晰度/限流/过期链接）需真机验证。
