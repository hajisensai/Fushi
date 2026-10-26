import 'dart:io';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show
        AudiobookAlignmentMessages,
        AudiobookAlignmentResult,
        alignAndPersistAudiobook;
import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart'
    show audiobookTitleForAudioPaths;
import 'package:fushi_engine/media/audiobook/subtitle_rematch_policy.dart';

import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/media/audiobook/subtitle_rematch.dart';
import 'package:fushi/src/media/import/srt_book_reimport.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/ops/ctl_library_tasks.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 有声书路由：给书附着 / 替换音频与字幕、重新匹配、设备端转录任务（CLI：
/// `fushi_cli audiobook ...`）。全部落到库页 / 阅读器入口背后的同一个方法：
///
/// - 字幕书（无 `audiobooks` 行）换音频 / 字幕：[reimportSrtBook]（字幕书「重新导入」
///   对话框同一函数，换字幕时连带重建由 cue 生成的正文）；
/// - EPUB 书挂有声书 / 换字幕：[alignAndPersistAudiobook]（导入书 + 字幕 + 音频时的
///   对齐落库同一函数）；只换音频：[AudiobookStorage.syncAudioFiles] +
///   [AudiobookRepository.replaceAudio]（有声书导入对话框「只换音频」同一组原语）；
///   判据与书架 `_openSrtBookReimport` 一致——看该 bookKey 有没有 `audiobooks` 行；
/// - 重新匹配：[rematchStoredAudiobookCues]（Sasayaki 重匹配本体）；
/// - 挂载 / 替换 / 重新匹配都是短时后台任务（[LibraryCtlTaskRegistry]）：立即返回
///   任务，可查进度；在写盘之前的检查点可取消，进入提交阶段后不可取消；`wait`
///   时等到结束再返回；
/// - 转录：[AppModel.audiobookTranscribeImportQueue]（发现页「转录后入库」同一队列，
///   落盘、单并发、重启续跑；任务的进度 / 取消 / 重试都是队列自己的方法）。
List<CtlRoute> buildAudiobookCtlRoutes(OpContext context) {
  final _AudiobookHandlers h = _AudiobookHandlers(context);
  return <CtlRoute>[
    CtlRoute.post('$kAudiobookCtlItemsPath/:key/audiobook', h.attach),
    CtlRoute.post('$kAudiobookCtlItemsPath/:key/audiobook/rematch', h.rematch),
    CtlRoute.get(kAudiobookCtlTasksPath, h.listTasks),
    CtlRoute.get('$kAudiobookCtlTasksPath/:id', h.getTask),
    CtlRoute.post('$kAudiobookCtlTasksPath/:id/cancel', h.cancelTask),
    CtlRoute.get(kAudiobookCtlJobsPath, h.listJobs),
    CtlRoute.post(kAudiobookCtlJobsPath, h.transcribe),
    CtlRoute.get('$kAudiobookCtlJobsPath/:id', h.getJob),
    CtlRoute.post('$kAudiobookCtlJobsPath/:id/cancel', h.cancelJob),
    CtlRoute.post('$kAudiobookCtlJobsPath/:id/retry', h.retryJob),
    CtlRoute.delete('$kAudiobookCtlJobsPath/:id', h.removeJob),
  ];
}

const String kAudiobookCtlItemsPath = '/api/admin/library/items';
const String kAudiobookCtlJobsPath = '/api/admin/library/audiobook/jobs';

/// 挂载 / 替换 / 重新匹配的短时后台任务（内存登记，见 [LibraryCtlTaskRegistry]）。
const String kAudiobookCtlTasksPath = '/api/admin/library/audiobook/tasks';

/// 对齐各步骤在任务进度里的阶段名（引擎把它当步骤文案回传给 onProgress）。
const AudiobookAlignmentMessages kAudiobookCtlAlignmentPhases =
    AudiobookAlignmentMessages(
      readingIdb: 'reading',
      parsing: 'parsing',
      matching: 'matching',
      persisting: 'copying',
      saving: 'saving',
      done: 'done',
    );

/// 挂载 / 匹配任务的失败原因 → 命令行文案（认得的异常换成中文，其余原样）。
String describeAudiobookCtlTaskError(Object error) => switch (error) {
  SrtBookReimportEmptyCuesException() => '这份字幕解析不出任何句子，没有替换',
  SubtitleRematchException(:final SubtitleRematchFailure reason) =>
    switch (reason) {
      SubtitleRematchFailure.noStoredCues => '库里没有存好的字幕句（先挂字幕）',
      SubtitleRematchFailure.noChapters => '正文解析不出章节',
      SubtitleRematchFailure.allWindowsZero => '所有窗口的匹配率都是 0，字幕与正文可能不是同一本',
    },
  _ => '$error',
};

/// 对齐用字幕的扩展名（有声书导入对话框 `_alignmentExtensions` 中 matcher 管线的那组
/// 加 smil / json 锚点格式）。
const Set<String> kAudiobookCtlSubtitleExtensions = <String>{
  'srt',
  'lrc',
  'vtt',
  'ass',
  'ssa',
  'smil',
  'json',
};

/// 转录任务 → 线上 JSON。
Map<String, Object?> audiobookCtlJobJson(AudiobookTranscribeJob job) =>
    <String, Object?>{
      'id': job.id,
      'title': job.title,
      'status': job.status.name,
      if (job.phase != null) 'phase': job.phase!.name,
      if (job.progress != null) 'progress': (job.progress! * 1000).round() / 10,
      'audioFiles': job.audioPaths.length,
      if (job.contentPath != null) 'contentPath': job.contentPath,
      if (job.targetBookKey != null)
        'into': LibraryCtlKey(LibraryCtlStore.book, job.targetBookKey!).wire,
      if (job.error != null) 'error': job.error,
      if (job.resultKey != null) 'resultKey': job.resultKey,
      'createdAt': job.createdAt,
      'updatedAt': job.updatedAt,
    };

class _AudiobookHandlers {
  _AudiobookHandlers(this._context);

  final OpContext _context;

  AppModel get _app => _context.appModel;
  FushiDatabase get _db => _app.database;

  void _requireWritable() {
    if (_app.isMigrationReadonly) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
    }
  }

  LibraryCtlKey _key(CtlCall call) {
    final String raw = call.params['key'] ?? '';
    final LibraryCtlKey? key = LibraryCtlKey.tryParse(raw);
    if (key == null) {
      throw CtlFailure.badRequest('条目键「$raw」格式不对（见 library ls）');
    }
    if (key.store != LibraryCtlStore.book && key.store != LibraryCtlStore.srt) {
      throw const CtlFailure.rejected('有声书只挂在书（book:）或字幕书（srt:）上');
    }
    return key;
  }

  void _requireListening() {
    if (!_app.moduleVisibility.isEnabled(LibraryCtlKind.audiobook.module)) {
      throw const CtlFailure.rejected('书架模块已在设置里关闭');
    }
  }

  List<String> _existingFiles(CtlCall call, String name) {
    final List<String> paths = call.stringList(name);
    for (final String path in paths) {
      if (!File(path).isAbsolute) {
        throw CtlFailure.badRequest('路径必须是绝对路径：$path');
      }
      if (!File(path).existsSync()) {
        throw CtlFailure.notFound('文件不存在：$path');
      }
    }
    return paths;
  }

  void _refreshShelf() {
    _context.ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    _context.ref.invalidate(srtBooksProvider);
  }

  // ── 附着 / 替换 ──────────────────────────────────────────────────────

  /// 起一个短时后台任务；`wait: true` 时等它结束再返回（返回的仍是任务 JSON，
  /// 结果在 `result`、失败原因在 `error`）。同一条目上已有未结束任务时 409。
  Future<Object?> _startTask(
    CtlCall call, {
    required String kind,
    required LibraryCtlKey key,
    required Future<Map<String, Object?>> Function(LibraryCtlTask task) run,
  }) async {
    final LibraryCtlTaskRegistry registry = LibraryCtlTaskRegistry.instance;
    final LibraryCtlTask? busy = registry.activeFor(key.wire);
    if (busy != null) {
      throw CtlFailure.conflict('${key.wire} 上已有未结束的任务 ${busy.id}');
    }
    final LibraryCtlTask task = registry.start(
      kind: kind,
      key: key.wire,
      run: run,
      describe: describeAudiobookCtlTaskError,
    );
    if (call.optBool('wait') == true) await task.whenDone;
    return task.toJson();
  }

  Future<Object?> attach(CtlCall call) async {
    _requireWritable();
    _requireListening();
    final LibraryCtlKey key = _key(call);
    final List<String> audio = _existingFiles(call, 'audio');
    for (final String path in audio) {
      if (!AudiobookStorage.isAudioFile(path)) {
        throw CtlFailure.badRequest('不是音频文件：$path');
      }
    }
    final List<String> subtitleList = _existingFiles(call, 'subtitle');
    if (subtitleList.length > 1) {
      throw const CtlFailure.badRequest('subtitle 只能给一个文件');
    }
    final String? subtitle = subtitleList.isEmpty ? null : subtitleList.first;
    if (subtitle != null) {
      final String ext = subtitle.split('.').last.toLowerCase();
      if (!kAudiobookCtlSubtitleExtensions.contains(ext)) {
        throw CtlFailure.badRequest('不支持的字幕格式：.$ext');
      }
    }
    if (audio.isEmpty && subtitle == null) {
      throw const CtlFailure.badRequest('audio 与 subtitle 至少给一个');
    }

    // 先把会失败的判据全部同步做完（参数错直接 4xx），任务里只剩真正的执行。
    final SrtBookRepository srtRepo = SrtBookRepository(_db);
    String bookKey;
    SrtBook? srt;
    if (key.store == LibraryCtlStore.srt) {
      srt = await srtRepo.findByUid(key.id);
      if (srt == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
      bookKey = srt.bookKey;
    } else {
      bookKey = key.id;
    }
    final AudiobookRepository audiobookRepo = AudiobookRepository(_db);
    final Audiobook? existing = bookKey.isEmpty
        ? null
        : await audiobookRepo.findByBookKey(bookKey);
    // 正在播的就是这本时先停：换音频会删 / 换持久目录里的文件，句柄不放掉必失败。
    Future<void> stopPlayback() => _app.audiobookSession.stopIfPlayingAny(
      <String>[key.id, if (bookKey.isNotEmpty) bookKey],
    );

    if (srt != null && existing == null) {
      // 播放侧读 SrtBooks 的字幕书：交给字幕书重新导入（换字幕连带重建正文）。
      final String uid = srt.uid;
      return _startTask(
        call,
        kind: 'attach',
        key: key,
        run: (LibraryCtlTask task) async {
          await stopPlayback();
          final SrtBookReimportOutcome outcome = await reimportSrtBook(
            db: _db,
            repo: srtRepo,
            uid: uid,
            audioPaths: audio.isEmpty ? null : audio,
            subtitlePath: subtitle,
            isCancelled: () => task.cancelRequested,
            onProgress: (double fraction, String _) {
              // 0.3 起是正文重建 / 持久化 / 写库：提交阶段。
              if (fraction >= 0.3) task.markCommitting();
              task.report(
                phase: fraction >= 0.3 ? 'saving' : 'parsing',
                progress: fraction,
              );
            },
          );
          _refreshShelf();
          return <String, Object?>{
            'key': key.wire,
            'mode': 'srt_reimport',
            'audioReplaced': outcome.audioReplaced,
            'subtitleReplaced': outcome.subtitleReplaced,
            'bodyRebuilt': outcome.bodyRebuilt,
            if (outcome.subtitleReplaced) 'cues': outcome.cueCount,
          };
        },
      );
    }

    final EpubBookRow? row = await _db.getEpubBook(bookKey);
    if (row == null) throw CtlFailure.notFound('书架里没有 book:$bookKey');
    if (BookFormat.parseOrEpub(row.format) != BookFormat.epub) {
      throw const CtlFailure.rejected('有声书只支持 EPUB 书（PDF / 漫画不能挂音频）');
    }

    if (subtitle == null) {
      // 只换音频：必须已经是有声书（否则没有字幕可对齐）。
      if (existing == null) {
        throw const CtlFailure.badRequest(
          '这本书还不是有声书：第一次挂音频要连同字幕一起给（--subtitle），'
          '没有字幕可用 audiobook transcribe --into 先转录再挂',
        );
      }
      return _startTask(
        call,
        kind: 'attach',
        key: key,
        run: (LibraryCtlTask task) async {
          // 这条路只有「同步持久目录 + 写库」两步，开始即提交，不可取消。
          task
            ..markCommitting()
            ..report(phase: 'copying');
          await stopPlayback();
          final Directory persistDir = await AudiobookStorage.ensurePersistDir(
            bookKey,
          );
          final List<String> persisted = await AudiobookStorage.syncAudioFiles(
            persistDir,
            audio,
            onProgress: (int copied, int total) =>
                task.report(progress: total > 0 ? copied / total : null),
          );
          await audiobookRepo.replaceAudio(
            bookKey: bookKey,
            audioPaths: persisted,
          );
          _refreshShelf();
          return <String, Object?>{
            'key': key.wire,
            'mode': 'audio_replace',
            'audioFiles': persisted.length,
          };
        },
      );
    }

    // 挂字幕（首次附着或换字幕）：导入书 + 字幕 + 音频时的同一对齐落库函数。
    List<String> audioForAlign = audio;
    if (audio.isEmpty) {
      if (existing == null) {
        throw const CtlFailure.badRequest('第一次挂有声书需要音频（--audio）');
      }
      final List<String>? kept = existing.audioPaths;
      if (kept == null || kept.isEmpty) {
        // 旧版目录模式（audioRoot）的音频不在持久目录里，单换字幕会让持久目录被
        // 同步成空集——要求连同音频一起给。
        throw const CtlFailure.badRequest('这本有声书是旧版目录模式，换字幕时请连同音频一起给');
      }
      audioForAlign = kept;
    }
    final String title = row.title;
    final String? author = row.author;
    return _startTask(
      call,
      kind: 'attach',
      key: key,
      run: (LibraryCtlTask task) async {
        await stopPlayback();
        final AudiobookAlignmentResult result = await alignAndPersistAudiobook(
          db: _db,
          repo: srtRepo,
          audiobookRepo: audiobookRepo,
          bookKey: bookKey,
          title: title,
          author: author,
          subtitlePath: subtitle,
          audioPaths: audioForAlign,
          isCancelled: () => task.cancelRequested,
          messages: kAudiobookCtlAlignmentPhases,
          onProgress: (double fraction, String phase) {
            // 0.8 起是持久化 + 写库：提交阶段（引擎在那之前的最后一个检查点）。
            if (fraction >= 0.8) task.markCommitting();
            task.report(
              phase: phase.isEmpty ? null : phase,
              progress: fraction,
            );
          },
        );
        _refreshShelf();
        return <String, Object?>{
          'key': key.wire,
          'mode': existing == null ? 'attach' : 'subtitle_replace',
          'cues': result.cueCount,
          'audioFiles': result.persistedAudioPaths.length,
          'health': result.health.kind.name,
          if (result.health.reason != null)
            'healthReason': result.health.reason,
        };
      },
    );
  }

  // ── 重新匹配 ─────────────────────────────────────────────────────────

  Future<Object?> rematch(CtlCall call) async {
    _requireWritable();
    _requireListening();
    final LibraryCtlKey key = _key(call);
    String bookKey = key.id;
    if (key.store == LibraryCtlStore.srt) {
      final SrtBook? srt = await SrtBookRepository(_db).findByUid(key.id);
      if (srt == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
      bookKey = srt.bookKey;
    }
    final AudiobookRepository repo = AudiobookRepository(_db);
    final Audiobook? ab = bookKey.isEmpty
        ? null
        : await repo.findByBookKey(bookKey);
    if (ab == null) {
      throw const CtlFailure.rejected('只有挂在 EPUB 正文上的有声书才能重新匹配');
    }
    if (!SubtitleRematchPolicy.isEligible(ab)) {
      throw const CtlFailure.rejected('SMIL / JSON 对齐自带时间锚点，不需要重新匹配');
    }
    final EpubBookRow? row = await _db.getEpubBook(bookKey);
    if (row == null || row.extractDir.isEmpty) {
      throw const CtlFailure.rejected('这本有声书没有绑定正文，无法重新匹配');
    }
    final int? window = call.optInt('window');
    if (window != null && (window < 1 || window > 100000)) {
      throw const CtlFailure.badRequest('window 必须是正整数');
    }
    final Object? rawThreshold =
        call.body['threshold'] ?? call.query['threshold'];
    final double threshold = rawThreshold == null
        ? EpubSrtMatcher.defaultSimilarityThreshold
        : (rawThreshold is num
              ? rawThreshold.toDouble()
              : double.tryParse('$rawThreshold') ?? -1);
    if (threshold <= 0 || threshold > 1) {
      throw const CtlFailure.badRequest('threshold 必须在 (0, 1] 之间');
    }
    final String extractDir = row.extractDir;
    return _startTask(
      call,
      kind: 'rematch',
      key: key,
      run: (LibraryCtlTask task) async {
        final SubtitleRematchOutcome outcome = await rematchStoredAudiobookCues(
          repo: repo,
          bookKey: bookKey,
          extractDir: extractDir,
          searchWindow: window,
          similarityThreshold: threshold,
          isCancelled: () => task.cancelRequested,
          onPhase: (String phase) {
            if (phase == 'saving') task.markCommitting();
            task.report(phase: phase);
          },
        );
        return <String, Object?>{
          'key': key.wire,
          'matched': outcome.result.matchedCues,
          'total': outcome.result.totalCues,
          'rate': (outcome.result.matchRate * 10000).round() / 100,
          'window': outcome.searchWindow,
          'threshold': outcome.similarityThreshold,
        };
      },
    );
  }

  // ── 挂载 / 匹配任务 ──────────────────────────────────────────────────

  LibraryCtlTask _requireTask(CtlCall call) {
    final String id = call.params['id'] ?? '';
    final LibraryCtlTask? task = LibraryCtlTaskRegistry.instance.byId(id);
    if (task == null) throw CtlFailure.notFound('没有这个任务：$id');
    return task;
  }

  Future<Object?> listTasks(CtlCall call) async => <String, Object?>{
    'tasks': <Map<String, Object?>>[
      for (final LibraryCtlTask task in LibraryCtlTaskRegistry.instance.tasks)
        task.toJson(),
    ],
  };

  Future<Object?> getTask(CtlCall call) async {
    final LibraryCtlTask task = _requireTask(call);
    if (call.optBool('wait') == true) await task.whenDone;
    return task.toJson();
  }

  Future<Object?> cancelTask(CtlCall call) async {
    final LibraryCtlTask task = _requireTask(call);
    switch (LibraryCtlTaskRegistry.instance.cancel(task)) {
      case LibraryCtlCancelOutcome.requested:
        return task.toJson();
      case LibraryCtlCancelOutcome.committing:
        throw const CtlFailure.conflict('任务已进入写入阶段，不能取消（中途停下会留下残缺数据）');
      case LibraryCtlCancelOutcome.finished:
        throw CtlFailure.conflict('任务已经结束（${task.status.name}）');
    }
  }

  // ── 转录任务 ─────────────────────────────────────────────────────────

  AudiobookTranscribeImportQueue _queue() {
    if (!isAsrSupported) {
      throw const CtlFailure.unsupported('本机不支持设备端语音转录');
    }
    return _app.audiobookTranscribeImportQueue;
  }

  Future<AudiobookTranscribeJob> _requireJob(CtlCall call) async {
    final AudiobookTranscribeImportQueue queue = _queue();
    await queue.load();
    final String id = call.params['id'] ?? '';
    for (final AudiobookTranscribeJob job in queue.jobs) {
      if (job.id == id) return job;
    }
    throw CtlFailure.notFound('没有这个转录任务：$id');
  }

  Future<Object?> listJobs(CtlCall call) async {
    final AudiobookTranscribeImportQueue queue = _queue();
    await queue.load();
    return <String, Object?>{
      'jobs': <Map<String, Object?>>[
        for (final AudiobookTranscribeJob job in queue.jobs)
          audiobookCtlJobJson(job),
      ],
    };
  }

  Future<Object?> getJob(CtlCall call) async =>
      audiobookCtlJobJson(await _requireJob(call));

  /// 排一个转录任务：音频（必给，按给出顺序）+ 可选正文（有正文转完对齐，没有就
  /// 成独立字幕书），或 `into` 指定库里已有的书（转完挂到它上面）。同一组音频已有
  /// 未结束任务时队列返回那个，不重复排。
  Future<Object?> transcribe(CtlCall call) async {
    _requireWritable();
    _requireListening();
    final AudiobookTranscribeImportQueue queue = _queue();
    final List<String> audio = _existingFiles(call, 'audio');
    if (audio.isEmpty) throw const CtlFailure.badRequest('audio 缺失');
    for (final String path in audio) {
      if (!AudiobookStorage.isAudioFile(path)) {
        throw CtlFailure.badRequest('不是音频文件：$path');
      }
    }
    final List<String> text = _existingFiles(call, 'text');
    if (text.length > 1) throw const CtlFailure.badRequest('text 只能给一个文件');
    final String? contentPath = text.isEmpty ? null : text.first;
    final String? intoRaw = call.optString('into');
    String? targetBookKey;
    String? targetTitle;
    if (intoRaw != null) {
      if (contentPath != null) {
        throw const CtlFailure.badRequest('into（挂到已有书）与 text（导入新正文）只给一个');
      }
      final (String bookKey, String title) = await _transcribeTarget(intoRaw);
      targetBookKey = bookKey;
      targetTitle = title;
    }
    final AudiobookTranscribeJob job = await queue.enqueue(
      audioPaths: audio,
      contentPath: contentPath,
      targetBookKey: targetBookKey,
      title:
          call.optString('title') ??
          targetTitle ??
          audiobookTitleForAudioPaths(audio),
    );
    return audiobookCtlJobJson(job);
  }

  /// `into` 键 → (EPUB bookKey, 书名)。纯字幕书没有正文可对齐（重新转录等于换字幕，
  /// 用 attach --subtitle）。
  Future<(String, String)> _transcribeTarget(String raw) async {
    final LibraryCtlKey? key = LibraryCtlKey.tryParse(raw);
    if (key == null ||
        (key.store != LibraryCtlStore.book &&
            key.store != LibraryCtlStore.srt)) {
      throw CtlFailure.badRequest(
        'into 应为 book:<bookKey> 或 srt:<uid>，收到「$raw」',
      );
    }
    String bookKey = key.id;
    if (key.store == LibraryCtlStore.srt) {
      final SrtBook? srt = await SrtBookRepository(_db).findByUid(key.id);
      if (srt == null) throw CtlFailure.notFound('书架里没有 ${key.wire}');
      if (srt.bookKey.isEmpty) {
        throw const CtlFailure.rejected(
          '纯字幕书没有正文可对齐；换字幕用 audiobook attach --subtitle',
        );
      }
      bookKey = srt.bookKey;
    }
    final EpubBookRow? row = await _db.getEpubBook(bookKey);
    if (row == null) throw CtlFailure.notFound('书架里没有 book:$bookKey');
    if (BookFormat.parseOrEpub(row.format) != BookFormat.epub) {
      throw const CtlFailure.rejected('有声书只支持 EPUB 书（PDF / 漫画不能挂音频）');
    }
    return (bookKey, row.title);
  }

  Future<Object?> cancelJob(CtlCall call) async {
    final AudiobookTranscribeJob job = await _requireJob(call);
    if (job.isTerminal) {
      throw CtlFailure.conflict('任务已经结束（${job.status.name}）');
    }
    await _queue().cancel(job.id);
    return audiobookCtlJobJson(job);
  }

  Future<Object?> retryJob(CtlCall call) async {
    final AudiobookTranscribeJob job = await _requireJob(call);
    if (job.status != AudiobookTranscribeJobStatus.failed &&
        job.status != AudiobookTranscribeJobStatus.cancelled) {
      throw CtlFailure.conflict('只有失败 / 已取消的任务能重试（当前 ${job.status.name}）');
    }
    await _queue().retry(job.id);
    return audiobookCtlJobJson(job);
  }

  Future<Object?> removeJob(CtlCall call) async {
    final AudiobookTranscribeJob job = await _requireJob(call);
    if (!job.isTerminal) {
      throw const CtlFailure.conflict('任务还没结束，先取消');
    }
    await _queue().remove(job.id);
    return <String, Object?>{'deleted': true, 'id': job.id};
  }
}
