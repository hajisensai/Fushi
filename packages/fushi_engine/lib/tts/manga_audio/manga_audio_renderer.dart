/// 漫画有声成品的生成端：按 [planMangaRender] 的计划逐句出音频、写
/// [MangaRenderManifest]，并负责补回未配音的句子与单句换种子重生成。
///
/// - 真正的合成 / 剪辑 / 写静音由注入的 [MangaRenderBackend] 做（app 里是 TTS 缓存 +
///   引擎 + ffmpeg），本类不碰引擎与 ffmpeg，测试用假后端即可覆盖全部编排；
/// - **一句失败不让整卷失败，也不悄悄跳过**：失败的句子写一段按字数估长的静音占位
///   （`placeholder: true`），记进 [CastVoicingLedger]；只有取消与「占位静音都写不出」
///   这类整卷级问题才往外抛；
/// - 重跑时音频没变的句子（文字 / 声音 / 种子都相同、文件还在）原样沿用，不重录；
/// - 清单写完后清掉目录里清单不再引用的音频（换过声音的旧文件、被取代的占位、没保留的
///   候选）。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_narrator.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:fushi_engine/tts/tts_types.dart';

/// 一句出不了声的原因（[code] 进未配音账本，界面按它出文案）。
class MangaLineFailure implements Exception {
  const MangaLineFailure(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail == null
      ? 'MangaLineFailure($code)'
      : 'MangaLineFailure($code: $detail)';
}

/// 生成端口。所有方法写到给定的 `outputPath`（调用方负责原子改名），返回写出的音频
/// 时长（毫秒）。一句级的失败抛 [MangaLineFailure] / [TtsFailure] /
/// [TtsRenderFailure]；取消抛 [TtsRenderCancelled]。
abstract interface class MangaRenderBackend {
  /// 同时合成几句（引擎并发上限；自建 GPU 服务通常是 1）。
  int get parallelism;

  /// 用声音 [voice] 依次合成 [segments]，拼成一个文件并裁掉首尾静音。[seed] 与短句
  /// 定长只在引擎支持时生效（`tts_direction.dart`）。
  Future<int> synthesizeLine({
    required String voice,
    required int seed,
    required List<String> segments,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  });

  /// 从关联有声书里剪出 [clip]（不裁静音：边界就是 cue 边界）。
  Future<int> cutClip({
    required MangaAudiobookClip clip,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  });

  /// 写一段 [ms] 毫秒的静音。
  Future<int> writeSilence({required int ms, required String outputPath});

  /// 能不能用参考音频克隆旁白音色（`manga_audio_narrator.dart`）。不能 = 合成句照旧用
  /// 各自指派的声音。
  bool get canCloneNarrator;

  /// 把 [narrator] 的参考片段做成参考音频并登记这个声音，之后 [synthesizeLine] 可以
  /// 用 `voice: narrator.id`。参考片段剪不出来（书已不在、文件丢了）返回 false，本次
  /// 不克隆；只有取消可以往外抛。
  Future<bool> prepareNarrator({
    required MangaNarratorVoice narrator,
    required TtsRenderCancelToken cancel,
  });

  /// 整卷生成开跑前把这次要出的句子（不含原样沿用的）交给后端一次：能整批合成的
  /// 引擎（Irodori 批处理 worker：按参考音频组成批、模型只加载一次）在这里先批量合成
  /// 进缓存，之后逐句的 [synthesizeLine] 直接命中；批里失败的句子由 [synthesizeLine]
  /// 抛一句级失败（走占位 + 未配音账本）。不支持批量的后端什么都不做。只有取消可以
  /// 往外抛。
  Future<void> prepare({
    required List<MangaRenderItem> items,
    required TtsRenderCancelToken cancel,
  });
}

/// 整卷生成的结果。
class MangaRenderOutcome {
  const MangaRenderOutcome({
    required this.manifest,
    required this.produced,
    required this.reused,
    required this.placeholders,
    required this.notRead,
  });

  final MangaRenderManifest manifest;

  /// 这次新出音频的句数（不含占位）。
  final int produced;

  /// 原样沿用的句数。
  final int reused;

  /// 这次结束时仍是占位的句子（行身份）。
  final List<String> placeholders;

  /// 按音源策略不读的句子。
  final List<String> notRead;
}

/// 补回一句的请求（三种补法可以叠用：换声音 + 手动填写）。
class MangaBackfillRequest {
  const MangaBackfillRequest({
    required this.lineId,
    this.voice,
    this.say,
    this.nextRetryVoice = false,
  });

  final String lineId;

  /// 手动指定的声音；null = 不指定。
  final String? voice;

  /// 手动填写的要念的文字；null = 照原文。
  final String? say;

  /// 「切配置重试」：换成重试候选里下一个没失败过的声音（[voice] 为空时才看）。
  final bool nextRetryVoice;
}

enum MangaBackfillStatus {
  /// 配上音了（占位已换成真音频、已从账本删掉）。
  voiced,

  /// 又失败了（账本里追加了这次尝试，占位不动）。
  failed,

  /// 「切配置重试」但没有可换的声音（候选都失败过）：只能手动指定或手动填写。
  noRetryVoice,

  /// 演出稿或清单里已经没有这句。
  lineMissing,
}

/// 单句换种子重生成的候选（试听后 [MangaAudioRenderer.keepCandidate] 或
/// [MangaAudioRenderer.discardCandidate]）。
class MangaRegenerateCandidate {
  const MangaRegenerateCandidate({
    required this.lineId,
    required this.seed,
    required this.file,
    required this.durationMs,
    required this.voice,
    required this.text,
  });

  final String lineId;
  final int seed;

  /// 候选文件名（相对清单目录）。
  final String file;
  final int durationMs;
  final String voice;
  final String text;
}

class MangaAudioRenderer {
  MangaAudioRenderer({
    required this.backend,
    required this.manifestFile,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final MangaRenderBackend backend;

  /// 清单文件（`MangaRenderManifest.fileFor`）；音频放在同目录。
  final File manifestFile;
  final DateTime Function() _now;

  Directory get directory => manifestFile.parent;

  String _pathOf(String file) => p.join(directory.path, file);

  /// 本卷这次要用的旁白声音（后端不能克隆、没有合格片段、参考音频准备失败 → null）。
  Future<MangaNarratorVoice?> _narrator(
    MangaAudioScript script,
    List<List<MokuroBlock>> pageBlocks,
    TtsRenderCancelToken cancel,
  ) async {
    if (!backend.canCloneNarrator) return null;
    final MangaNarratorVoice? narrator = mangaNarratorFor(
      script: script,
      pageCount: pageBlocks.length,
    );
    if (narrator == null) return null;
    final bool ready = await backend.prepareNarrator(
      narrator: narrator,
      cancel: cancel,
    );
    cancel.throwIfCancelled();
    return ready ? narrator : null;
  }

  /// 整卷生成。[previous] 是上一次的清单（沿用没变的句子）；[ledger] 原地更新（调用方
  /// 负责落盘）。清单写到 [manifestFile]。
  Future<MangaRenderOutcome> render({
    required MangaAudioScript script,
    required List<List<MokuroBlock>> pageBlocks,
    required String defaultVoice,
    required MangaRenderManifest? previous,
    required CastVoicingLedger ledger,
    required void Function(int done, int total) onProgress,
    required TtsRenderCancelToken cancel,
  }) async {
    await directory.create(recursive: true);
    final MangaRenderPlan plan = planMangaRender(
      script: script,
      pageBlocks: pageBlocks,
      defaultVoice: defaultVoice,
      narrator: await _narrator(script, pageBlocks, cancel),
    );
    final Map<String, MangaRenderedLine> before = <String, MangaRenderedLine>{
      for (final MangaRenderedLine l
          in previous?.lines ?? <MangaRenderedLine>[])
        l.lineId: l,
    };
    final List<MangaRenderItem> items = plan.items;
    final List<MangaRenderedLine?> results = List<MangaRenderedLine?>.filled(
      items.length,
      null,
    );
    int produced = 0;
    int reused = 0;
    int done = 0;
    int next = 0;
    Object? fatal;
    StackTrace? fatalStack;
    onProgress(0, items.length);

    Future<void> worker() async {
      while (fatal == null) {
        if (cancel.isCancelled || next >= items.length) return;
        final int i = next++;
        final MangaRenderItem item = items[i];
        try {
          final MangaRenderedLine? old = before[item.lineId];
          if (old != null &&
              item.canReuse(old) &&
              await File(_pathOf(old.file)).exists()) {
            ledger.resolve(item.lineId);
            reused++;
            results[i] = item.rendered(
              file: old.file,
              durationMs: old.durationMs,
            );
          } else {
            results[i] = await _renderOne(item, old, ledger, cancel);
            if (!results[i]!.placeholder) produced++;
          }
          done++;
          onProgress(done, items.length);
        } catch (e, stack) {
          fatal ??= e;
          fatalStack ??= stack;
          return;
        }
      }
    }

    // 先把要新出的句子整批交给后端（批处理引擎在这里一次合成完）。
    final List<MangaRenderItem> pending = <MangaRenderItem>[];
    for (final MangaRenderItem item in items) {
      final MangaRenderedLine? old = before[item.lineId];
      final bool reusable =
          old != null &&
          item.canReuse(old) &&
          await File(_pathOf(old.file)).exists();
      if (!reusable) pending.add(item);
    }
    if (pending.isNotEmpty) {
      await backend.prepare(items: pending, cancel: cancel);
    }
    cancel.throwIfCancelled();

    final int workers = backend.parallelism.clamp(1, 8);
    await Future.wait(<Future<void>>[
      for (int w = 0; w < workers; w++) worker(),
    ]);
    if (fatal case final Object error) {
      Error.throwWithStackTrace(error, fatalStack ?? StackTrace.current);
    }
    cancel.throwIfCancelled();

    final List<MangaRenderedLine> lines = <MangaRenderedLine>[
      for (final MangaRenderedLine? l in results) l!,
    ];
    ledger.retainOnly(plan.lineIds);
    final MangaRenderManifest manifest = MangaRenderManifest(
      pageCount: pageBlocks.length,
      lines: lines,
      pages: Map<int, MangaPageDirective>.of(script.pages),
      engineSignature: script.engineSignature,
    );
    await manifest.save(manifestFile);
    await sweepUnreferenced(manifest);
    return MangaRenderOutcome(
      manifest: manifest,
      produced: produced,
      reused: reused,
      placeholders: <String>[
        for (final MangaRenderedLine l in lines)
          if (l.placeholder) l.lineId,
      ],
      notRead: plan.notRead,
    );
  }

  /// 出一句；一句级失败 → 记账 + 占位静音。
  Future<MangaRenderedLine> _renderOne(
    MangaRenderItem item,
    MangaRenderedLine? old,
    CastVoicingLedger ledger,
    TtsRenderCancelToken cancel,
  ) async {
    try {
      final ({String file, int durationMs}) r = await _produce(
        item,
        mangaLineFileName(item.lineId),
        cancel,
      );
      ledger.resolve(item.lineId);
      return item.rendered(file: r.file, durationMs: r.durationMs);
    } catch (e, stack) {
      final MangaLineFailure failure = _lineFailure(e, stack, cancel);
      final CastVoicingEntry entry = ledger.recordFailure(
        lineId: item.lineId,
        text: item.text,
        voice: item.assignedVoice,
        code: failure.code,
        detail: failure.detail,
        now: _now(),
      );
      final String file = mangaPlaceholderFileName(item.lineId);
      final File target = File(_pathOf(file));
      int ms = entry.placeholderMs;
      final bool sameSilence =
          old != null &&
          old.placeholder &&
          old.file == file &&
          old.durationMs == ms &&
          await target.exists();
      if (!sameSilence) {
        final File part = File('${target.path}.part');
        ms = await backend.writeSilence(ms: ms, outputPath: part.path);
        await _publish(part, target);
      }
      return item.rendered(file: file, durationMs: ms, placeholder: true);
    }
  }

  /// 按计划出一句音频到 [fileName]（先写 `.part` 再改名）。
  Future<({String file, int durationMs})> _produce(
    MangaRenderItem item,
    String fileName,
    TtsRenderCancelToken cancel,
  ) async {
    cancel.throwIfCancelled();
    final File target = File(_pathOf(fileName));
    final File part = File('${target.path}.part');
    if (await part.exists()) await part.delete();
    final int ms;
    try {
      switch (item.source) {
        case MangaRenderSynth(
          :final String voice,
          :final int seed,
          :final List<String> segments,
        ):
          if (segments.isEmpty) throw const MangaLineFailure('empty_text');
          ms = await backend.synthesizeLine(
            voice: voice,
            seed: seed,
            segments: segments,
            outputPath: part.path,
            cancel: cancel,
          );
        case MangaRenderClip(:final MangaAudiobookClip clip):
          ms = await backend.cutClip(
            clip: clip,
            outputPath: part.path,
            cancel: cancel,
          );
      }
      // 裁完首尾静音什么都不剩 = 引擎出了一段静音（坏输出），按失败处理。
      if (ms <= 0 || !await part.exists()) {
        throw const MangaLineFailure('silent_output');
      }
      await _publish(part, target);
    } finally {
      if (await part.exists()) await part.delete();
    }
    return (file: fileName, durationMs: ms);
  }

  static Future<void> _publish(File part, File target) async {
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
  }

  /// 把异常归成一句级失败；取消原样抛出。
  MangaLineFailure _lineFailure(
    Object e,
    StackTrace stack,
    TtsRenderCancelToken cancel,
  ) {
    if (e is TtsRenderCancelled) throw e;
    if (cancel.isCancelled) throw const TtsRenderCancelled();
    return switch (e) {
      MangaLineFailure() => e,
      TtsFailure(:final TtsFailureCode code, :final String? detail) =>
        MangaLineFailure('tts_${code.name}', detail),
      TtsRenderFailure(:final String code, :final String? detail) =>
        MangaLineFailure(code, detail),
      _ => _internal(e, stack),
    };
  }

  static MangaLineFailure _internal(Object e, StackTrace stack) {
    engineLog.log('MangaAudioRenderer.line', e, stack);
    return MangaLineFailure('internal', e.runtimeType.toString());
  }

  /// 补回账本里的句子。成功的句子：声音 / 手填文字写回演出稿那一行（[script] 原地改，
  /// 调用方落盘）、清单换成真音频（写到 [manifestFile]）、从 [ledger] 删掉。
  Future<Map<String, MangaBackfillStatus>> backfill({
    required MangaAudioScript script,
    required List<List<MokuroBlock>> pageBlocks,
    required String defaultVoice,
    required MangaRenderManifest manifest,
    required CastVoicingLedger ledger,
    required List<MangaBackfillRequest> requests,
    required void Function(int done, int total) onProgress,
    required TtsRenderCancelToken cancel,
  }) async {
    final Map<String, MangaBackfillStatus> out =
        <String, MangaBackfillStatus>{};
    onProgress(0, requests.length);
    final MangaNarratorVoice? narrator = requests.isEmpty
        ? null
        : await _narrator(script, pageBlocks, cancel);
    for (int i = 0; i < requests.length; i++) {
      cancel.throwIfCancelled();
      final MangaBackfillRequest req = requests[i];
      out[req.lineId] = await _backfillOne(
        script: script,
        pageBlocks: pageBlocks,
        defaultVoice: defaultVoice,
        narrator: narrator,
        manifest: manifest,
        ledger: ledger,
        req: req,
        cancel: cancel,
      );
      onProgress(i + 1, requests.length);
    }
    await manifest.save(manifestFile);
    await sweepUnreferenced(manifest);
    return out;
  }

  Future<MangaBackfillStatus> _backfillOne({
    required MangaAudioScript script,
    required List<List<MokuroBlock>> pageBlocks,
    required String defaultVoice,
    required MangaNarratorVoice? narrator,
    required MangaRenderManifest manifest,
    required CastVoicingLedger ledger,
    required MangaBackfillRequest req,
    required TtsRenderCancelToken cancel,
  }) async {
    final MangaScriptLine? line = script.lineById(req.lineId);
    final bool inManifest = manifest.lines.any(
      (MangaRenderedLine l) => l.lineId == req.lineId,
    );
    if (line == null || !inManifest) return MangaBackfillStatus.lineMissing;
    final String assigned = mangaSynthVoiceFor(
      script,
      line,
      defaultVoice,
      narrator,
    );
    final String? voice =
        req.voice ??
        (req.nextRetryVoice
            ? (ledger.entries[req.lineId] ??
                      CastVoicingEntry(lineId: req.lineId, placeholderMs: 0))
                  .nextRetryVoice(assigned, script.retryVoices)
            : assigned);
    if (voice == null) return MangaBackfillStatus.noRetryVoice;
    final String? say = (req.say?.trim().isEmpty ?? true) ? null : req.say;
    final MangaScriptLine probe = say == null ? line : line.copyWith(say: say);
    final String text = mangaLineText(
      probe,
      pageBlocks,
      substitutions: script.substitutions,
    );
    final int seed = line.effectiveSeed(script.defaultSeed);
    final MangaRenderItem item = MangaRenderItem(
      line: probe,
      text: text,
      source: MangaRenderSynth(
        voice: voice,
        seed: seed,
        segments: splitMangaLineSegments(text),
      ),
    );
    try {
      final ({String file, int durationMs}) r = await _produce(
        item,
        mangaLineFileName(req.lineId),
        cancel,
      );
      script.replaceLine(
        req.lineId,
        (MangaScriptLine l) => l.copyWith(
          voice: voice != assigned ? voice : null,
          say: say,
          audio: l.audio is MangaAudiobookClip
              ? const MangaSynthesized()
              : null,
        ),
      );
      manifest.replaceLine(
        req.lineId,
        (MangaRenderedLine l) => l.replaced(
          file: r.file,
          durationMs: r.durationMs,
          placeholder: false,
          voice: voice,
          seed: seed,
          text: text,
        ),
      );
      ledger.resolve(req.lineId);
      return MangaBackfillStatus.voiced;
    } catch (e, stack) {
      final MangaLineFailure failure = _lineFailure(e, stack, cancel);
      ledger.recordFailure(
        lineId: req.lineId,
        text: text,
        voice: voice,
        code: failure.code,
        detail: failure.detail,
        now: _now(),
      );
      return MangaBackfillStatus.failed;
    }
  }

  /// 单句换种子重生成：出一个候选文件，不动清单。失败抛 [MangaLineFailure]。
  Future<MangaRegenerateCandidate> regenerate({
    required MangaAudioScript script,
    required List<List<MokuroBlock>> pageBlocks,
    required String defaultVoice,
    required String lineId,
    required int seed,
    required TtsRenderCancelToken cancel,
  }) async {
    final MangaScriptLine? line = script.lineById(lineId);
    if (line == null) throw const MangaLineFailure('line_missing');
    final String text = mangaLineText(
      line,
      pageBlocks,
      substitutions: script.substitutions,
    );
    final String voice = mangaSynthVoiceFor(
      script,
      line,
      defaultVoice,
      await _narrator(script, pageBlocks, cancel),
    );
    final MangaRenderItem item = MangaRenderItem(
      line: line,
      text: text,
      source: MangaRenderSynth(
        voice: voice,
        seed: seed,
        segments: splitMangaLineSegments(text),
      ),
    );
    await directory.create(recursive: true);
    try {
      final ({String file, int durationMs}) r = await _produce(
        item,
        mangaCandidateFileName(lineId, seed),
        cancel,
      );
      return MangaRegenerateCandidate(
        lineId: lineId,
        seed: seed,
        file: r.file,
        durationMs: r.durationMs,
        voice: voice,
        text: text,
      );
    } catch (e, stack) {
      throw _lineFailure(e, stack, cancel);
    }
  }

  /// 保留候选：清单这句换成候选文件，种子写回演出稿那一行（[script] 原地改，调用方
  /// 落盘），从 [ledger] 删掉（候选是真音频）。找不到这句返回 false。
  Future<bool> keepCandidate({
    required MangaAudioScript script,
    required MangaRenderManifest manifest,
    required CastVoicingLedger ledger,
    required MangaRegenerateCandidate candidate,
  }) async {
    final bool replaced = manifest.replaceLine(
      candidate.lineId,
      (MangaRenderedLine l) => l.replaced(
        file: candidate.file,
        durationMs: candidate.durationMs,
        placeholder: false,
        voice: candidate.voice,
        seed: candidate.seed,
        text: candidate.text,
      ),
    );
    if (!replaced) {
      await discardCandidate(candidate);
      return false;
    }
    script.replaceLine(
      candidate.lineId,
      (MangaScriptLine l) => l.copyWith(
        seed: candidate.seed,
        audio: l.audio is MangaAudiobookClip ? const MangaSynthesized() : null,
      ),
    );
    ledger.resolve(candidate.lineId);
    await manifest.save(manifestFile);
    await sweepUnreferenced(manifest);
    return true;
  }

  /// 撤回候选：删掉候选文件，清单与演出稿都不动。
  Future<void> discardCandidate(MangaRegenerateCandidate candidate) async {
    final File f = File(_pathOf(candidate.file));
    if (await f.exists()) await f.delete();
  }

  /// 删掉目录里 [manifest] 不再引用的音频与残留的 `.part`（清单本身与它的临时文件
  /// 不动）。删不掉（Windows 上被占用）只记日志，下次再删。
  Future<void> sweepUnreferenced(MangaRenderManifest manifest) async {
    if (!await directory.exists()) return;
    final Set<String> keep = <String>{
      p.basename(manifestFile.path),
      '${p.basename(manifestFile.path)}.tmp',
      for (final MangaRenderedLine l in manifest.lines) l.file,
    };
    for (final FileSystemEntity e in directory.listSync()) {
      if (e is! File || keep.contains(p.basename(e.path))) continue;
      try {
        await e.delete();
      } on FileSystemException catch (err, stack) {
        engineLog.log('MangaAudioRenderer.sweep', err, stack);
      }
    }
  }
}
