/// 漫画有声成品的生成端：按 [planMangaRender] 的计划逐句出音频、写
/// [MangaRenderManifest]，并负责补回未配音的句子与单句换种子重生成。
///
/// - 真正的合成 / 剪辑 / 写静音由注入的 [MangaRenderBackend] 做（app 里是 TTS 缓存 +
///   引擎 + ffmpeg），本类不碰引擎与 ffmpeg，测试用假后端即可覆盖全部编排；
/// - **一句失败不让整卷失败，也不悄悄跳过**：失败的句子写一段按字数估长的静音占位
///   （`placeholder: true`），记进 [CastVoicingLedger]；只有取消与「占位静音都写不出」
///   这类整卷级问题才往外抛；
/// - 重跑时音频没变的句子（文字 / 声音 / 种子 / 整形版本都相同、文件还在）原样沿用，
///   不重录；整形版本由后端给（[MangaRenderBackend.shapeVersion]），历史清单没记版本的
///   句子按版本不符重出；
/// - 成品与清单一起提交（HBK-AUDIT-201 / 207）：一次操作新出的音频只写暂存文件
///   （[mangaStagedFileName]），不碰旧清单正在引用的任何文件；全部出完、没被取消才把
///   暂存文件改名到目标文件名、紧接着存清单，演出稿 / 账本的出账也只在这时落到内存
///   对象上。取消、整卷级失败或「全有或全无」里有一句失败时只删本次自己的暂存文件，
///   旧清单与它引用的音频原样可播；
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
import 'package:fushi_engine/tts/tts_silence.dart';
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

  /// [synthesizeLine] / [cutClip] 出的音频的整形版本：裁首尾静音、淡入淡出、响度归一与
  /// 编码参数的可比较指纹，参数一变它就变。写进清单行（[MangaRenderedLine.shape]），
  /// 重跑时与旧行比对，不同就不沿用旧音频（[MangaRenderItem.canReuse]）。
  String get shapeVersion;

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

  /// 把用户换上的一段本地音频（[sourcePath]，[MangaLocalAudio] 的保留副本）整形成
  /// 成品句：与有声书片段同一套整形（裁首尾静音、淡变、响度、编码），版本同样记作
  /// [shapeVersion]。读不了 / 解不出抛一句级失败。
  Future<int> shapeLocalAudio({
    required String sourcePath,
    required String outputPath,
    required TtsRenderCancelToken cancel,
  });

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
    this.seed,
  });

  final String lineId;

  /// 换种子重出（批量重生成）：用这个种子重新合成一句**已生成**的句子，成功后种子写回
  /// 演出稿、清单换成新文件（[mangaCandidateFileName]，与旧文件不同名）；失败时旧音频
  /// 原样保留、不记进未配音账本（它本来就配好了音）。null = 补回未配音的句子。
  final int? seed;

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

/// 补回一句的计划（[MangaAudioRenderer.backfill] 先整批算好、交后端预合成，再逐句出）。
typedef _BackfillPlan = ({
  MangaRenderItem item,
  String voice,
  String assigned,
  String? say,
  String text,
  int seed,
});

/// [MangaAudioRenderer.bindLocalAudio] 的结果。
class MangaLocalBindOutcome {
  const MangaLocalBindOutcome({
    required this.bound,
    required this.unchanged,
    required this.failures,
  });

  /// 换上了的句子 → 整形后的时长（毫秒）。有失败时为空（全有或全无）。
  final Map<String, int> bound;

  /// 已经是这段音频、原样没动的句子。
  final Set<String> unchanged;

  /// 没换成的句子与原因；非空 = 这次什么都没改。
  final Map<String, MangaLineFailure> failures;

  bool get ok => failures.isEmpty;
}

/// 单句换种子重生成的候选（试听后 [MangaAudioRenderer.keepCandidate] 或
/// [MangaAudioRenderer.discardCandidate]）。
class MangaRegenerateCandidate {
  MangaRegenerateCandidate({
    required this.lineId,
    required this.seed,
    required this.file,
    required this.durationMs,
    required this.voice,
    required this.text,
    required this.shape,
    String? spoken,
    String? stagedFile,
  }) : spoken = spoken ?? text,
       stagedFile = stagedFile ?? mangaStagedFileName(file);

  final String lineId;
  final int seed;

  /// 候选音频实际所在的暂存文件（相对清单目录；试听放它）。保留时才改名成 [file]：
  /// 同一个种子再出一次时 [file] 可能就是清单正在引用的文件，候选不能先占它。
  final String stagedFile;

  /// 出候选时后端的整形版本（[MangaRenderBackend.shapeVersion]），保留时写进清单。
  final String shape;

  /// 候选文件名（相对清单目录）。
  final String file;
  final int durationMs;
  final String voice;
  final String text;

  /// 实际合成的文字（含人名读法；见 [MangaRenderItem.spoken]）。
  final String spoken;
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
    final String shape = backend.shapeVersion;
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
    final _AudioBatch batch = _AudioBatch(directory);
    // 配上音的句子（沿用或新出），提交时才从账本出账：取消了它们仍是旧清单里的样子。
    final Set<String> resolved = <String>{};
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
              item.canReuse(old, shape: shape) &&
              await File(_pathOf(old.file)).exists()) {
            resolved.add(item.lineId);
            reused++;
            results[i] = item.rendered(
              file: old.file,
              durationMs: old.durationMs,
              shape: shape,
            );
          } else {
            results[i] = await _renderOne(
              item,
              old,
              shape,
              ledger,
              batch,
              resolved,
              cancel,
            );
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

    final List<MangaRenderedLine> lines;
    final MangaRenderManifest manifest;
    try {
      // 先把要新出的句子整批交给后端（批处理引擎在这里一次合成完）。
      final List<MangaRenderItem> pending = <MangaRenderItem>[];
      for (final MangaRenderItem item in items) {
        final MangaRenderedLine? old = before[item.lineId];
        final bool reusable =
            old != null &&
            item.canReuse(old, shape: shape) &&
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

      lines = <MangaRenderedLine>[
        for (final MangaRenderedLine? l in results) l!,
      ];
      manifest = MangaRenderManifest(
        pageCount: pageBlocks.length,
        lines: lines,
        pages: Map<int, MangaPageDirective>.of(script.pages),
        engineSignature: script.engineSignature,
      );
      await batch.publish();
      await manifest.save(manifestFile);
      resolved.forEach(ledger.resolve);
      ledger.retainOnly(plan.lineIds);
    } finally {
      await batch.discard();
    }
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
    String shape,
    CastVoicingLedger ledger,
    _AudioBatch batch,
    Set<String> resolved,
    TtsRenderCancelToken cancel,
  ) async {
    try {
      final ({String file, int durationMs}) r = await _produce(
        item,
        mangaLineFileName(item.lineId),
        batch,
        cancel,
      );
      resolved.add(item.lineId);
      return item.rendered(
        file: r.file,
        durationMs: r.durationMs,
        shape: shape,
      );
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
        final File staged = batch.stage(file);
        try {
          ms = await backend.writeSilence(ms: ms, outputPath: staged.path);
        } catch (_) {
          await batch.drop(file);
          rethrow;
        }
      }
      return item.rendered(
        file: file,
        durationMs: ms,
        shape: null,
        placeholder: true,
      );
    }
  }

  /// 按计划出一句音频，目标文件名 [fileName]：写进 [batch] 的暂存文件，提交时才改名
  /// 成目标文件（目标可能正被旧清单引用）。失败时这句的暂存文件删掉、往外抛。
  ///
  /// 整句都是纯标点的气泡（「……」「！」，[ttsTextIsSilent]）没有要念的内容：出一段
  /// 按字数估长的停顿（与小说整书制作同一口径），算配好了、不进未配音账本；文件是
  /// WAV，扩展名随之换成 `.wav`。只有部分片段纯标点时照常合成，那几段由合成入口
  /// （`ttsSynthesizeSplittingOnReject`）写成静音、在句中留出停顿。
  Future<({String file, int durationMs})> _produce(
    MangaRenderItem item,
    String fileName,
    _AudioBatch batch,
    TtsRenderCancelToken cancel,
  ) async {
    cancel.throwIfCancelled();
    final bool pause = switch (item.source) {
      MangaRenderSynth(:final List<String> segments) =>
        segments.isNotEmpty && segments.every(ttsTextIsSilent),
      MangaRenderClip() || MangaRenderLocal() => false,
    };
    final String file = pause ? p.setExtension(fileName, '.wav') : fileName;
    final File part = batch.stage(file);
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
          ms = pause
              ? await backend.writeSilence(
                  ms: estimatePlaceholderMs(item.text),
                  outputPath: part.path,
                )
              : await backend.synthesizeLine(
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
        case MangaRenderLocal(:final MangaLocalAudio audio):
          final String source = mangaLocalAudioSourcePath(
            directory.path,
            audio,
          );
          if (!await File(source).exists()) {
            throw const MangaLineFailure('local_audio_missing');
          }
          ms = await backend.shapeLocalAudio(
            sourcePath: source,
            outputPath: part.path,
            cancel: cancel,
          );
      }
      // 裁完首尾静音什么都不剩 = 引擎出了一段静音（坏输出），按失败处理。
      if (ms <= 0 || !await part.exists()) {
        throw const MangaLineFailure('silent_output');
      }
    } catch (_) {
      await batch.drop(file);
      rethrow;
    }
    return (file: file, durationMs: ms);
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
  ///
  /// 整批一起提交：逐句出的新音频先进暂存文件，全部出完才改名成目标文件、改清单 /
  /// 演出稿 / 账本并存清单。中途取消（抛 [TtsRenderCancelled]）时什么都不改——已出的
  /// 暂存文件删掉，旧清单引用的音频、时长、cue 文本原样（HBK-AUDIT-207）；这次各句的
  /// 失败尝试照常记在 [ledger] 里（调用方落盘，下次「切配置重试」跳过它们）。
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
    final List<Object> plans = <Object>[
      for (final MangaBackfillRequest req in requests)
        _planBackfill(
          script: script,
          pageBlocks: pageBlocks,
          defaultVoice: defaultVoice,
          narrator: narrator,
          manifest: manifest,
          ledger: ledger,
          req: req,
        ),
    ];
    // 与整卷生成一样先把要出的句子整批交给后端（批处理引擎在这里一次合成完）。
    final List<MangaRenderItem> pending = <MangaRenderItem>[
      for (final Object plan in plans)
        if (plan is _BackfillPlan) plan.item,
    ];
    final _AudioBatch batch = _AudioBatch(directory);
    // 配上音的句子提交时要做的改动（清单 / 演出稿 / 账本），按请求顺序。
    final List<void Function()> commits = <void Function()>[];
    try {
      if (pending.isNotEmpty) {
        await backend.prepare(items: pending, cancel: cancel);
      }
      for (int i = 0; i < requests.length; i++) {
        cancel.throwIfCancelled();
        final MangaBackfillRequest req = requests[i];
        out[req.lineId] = switch (plans[i]) {
          final _BackfillPlan plan => await _backfillOne(
            script: script,
            manifest: manifest,
            ledger: ledger,
            req: req,
            plan: plan,
            batch: batch,
            commits: commits,
            cancel: cancel,
          ),
          final MangaBackfillStatus status => status,
          _ => throw StateError('unreachable'),
        };
        onProgress(i + 1, requests.length);
      }
      cancel.throwIfCancelled();
      await batch.publish();
      for (final void Function() commit in commits) {
        commit();
      }
      await manifest.save(manifestFile);
    } finally {
      await batch.discard();
    }
    await sweepUnreferenced(manifest);
    return out;
  }

  /// 补回一句要怎么出：[_BackfillPlan]，或出不了时的 [MangaBackfillStatus]。
  Object _planBackfill({
    required MangaAudioScript script,
    required List<List<MokuroBlock>> pageBlocks,
    required String defaultVoice,
    required MangaNarratorVoice? narrator,
    required MangaRenderManifest manifest,
    required CastVoicingLedger ledger,
    required MangaBackfillRequest req,
  }) {
    final MangaScriptLine? line = script.lineById(req.lineId);
    final bool inManifest = manifest.lines.any(
      (MangaRenderedLine l) => l.lineId == req.lineId,
    );
    // 改成「不读」类型的句子不再进成品（与整卷生成同一判据），不补回、不重出。
    if (line == null || !inManifest || !line.kind.isAudible) {
      return MangaBackfillStatus.lineMissing;
    }
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
    final ({String text, String spoken}) texts = mangaLineTexts(
      probe,
      pageBlocks,
      substitutions: script.substitutions,
    );
    final String text = texts.text;
    final int seed = req.seed ?? line.effectiveSeed(script.defaultSeed);
    final MangaRenderItem item = MangaRenderItem(
      line: probe,
      text: text,
      spoken: texts.spoken,
      source: MangaRenderSynth(
        voice: voice,
        seed: seed,
        segments: splitMangaLineSegments(texts.spoken),
      ),
    );
    return (
      item: item,
      voice: voice,
      assigned: assigned,
      say: say,
      text: text,
      seed: seed,
    );
  }

  Future<MangaBackfillStatus> _backfillOne({
    required MangaAudioScript script,
    required MangaRenderManifest manifest,
    required CastVoicingLedger ledger,
    required MangaBackfillRequest req,
    required _BackfillPlan plan,
    required _AudioBatch batch,
    required List<void Function()> commits,
    required TtsRenderCancelToken cancel,
  }) async {
    final _BackfillPlan(
      :MangaRenderItem item,
      :String voice,
      :String assigned,
      :String? say,
      :String text,
      :int seed,
    ) = plan;
    try {
      final ({String file, int durationMs}) r = await _produce(
        item,
        req.seed == null
            ? mangaLineFileName(req.lineId)
            : mangaCandidateFileName(req.lineId, seed),
        batch,
        cancel,
      );
      final String shape = backend.shapeVersion;
      commits.add(() {
        script.replaceLine(
          req.lineId,
          (MangaScriptLine l) => l.copyWith(
            voice: voice != assigned ? voice : null,
            say: say,
            seed: req.seed,
            audio: l.audio is MangaSynthesized
                ? null
                : const MangaSynthesized(),
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
            spoken: item.spoken,
            shape: shape,
          ),
        );
        ledger.resolve(req.lineId);
      });
      return MangaBackfillStatus.voiced;
    } catch (e, stack) {
      final MangaLineFailure failure = _lineFailure(e, stack, cancel);
      // 换种子重出一句配好了音的句子：失败只是这次没换成，旧音频还在，不算未配音。
      final bool voicedBefore = manifest.lines.any(
        (MangaRenderedLine l) => l.lineId == req.lineId && !l.placeholder,
      );
      if (req.seed != null && voicedBefore) {
        engineLog.log('MangaAudioRenderer.reroll', failure, StackTrace.current);
        return MangaBackfillStatus.failed;
      }
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

  /// 单句换种子重生成：出一个候选（暂存文件，[MangaRegenerateCandidate.stagedFile]），
  /// 不动清单与清单引用的任何文件。失败抛 [MangaLineFailure]；这句已改成「不读」类型时
  /// 抛 `line_not_read`（不读的句子不该再出声，见 [dropUnreadLines]）。
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
    if (!line.kind.isAudible) throw const MangaLineFailure('line_not_read');
    final ({String text, String spoken}) texts = mangaLineTexts(
      line,
      pageBlocks,
      substitutions: script.substitutions,
    );
    final String text = texts.text;
    final String voice = mangaSynthVoiceFor(
      script,
      line,
      defaultVoice,
      await _narrator(script, pageBlocks, cancel),
    );
    final MangaRenderItem item = MangaRenderItem(
      line: line,
      text: text,
      spoken: texts.spoken,
      source: MangaRenderSynth(
        voice: voice,
        seed: seed,
        segments: splitMangaLineSegments(texts.spoken),
      ),
    );
    await directory.create(recursive: true);
    try {
      // 候选留在暂存文件里等用户定夺（[keepCandidate] 才改名、[discardCandidate] 删掉），
      // 所以不走批次的提交 / 回滚。
      final ({String file, int durationMs}) r = await _produce(
        item,
        mangaCandidateFileName(lineId, seed),
        _AudioBatch(directory),
        cancel,
      );
      return MangaRegenerateCandidate(
        lineId: lineId,
        seed: seed,
        file: r.file,
        durationMs: r.durationMs,
        voice: voice,
        text: text,
        spoken: texts.spoken,
        shape: backend.shapeVersion,
      );
    } catch (e, stack) {
      throw _lineFailure(e, stack, cancel);
    }
  }

  /// 保留候选：候选的暂存文件改名成正式文件名，清单这句换成它，种子写回演出稿那一行
  /// （[script] 原地改，调用方落盘），从 [ledger] 删掉（候选是真音频）。找不到这句
  /// 返回 false（候选删掉，什么都不改）。
  Future<bool> keepCandidate({
    required MangaAudioScript script,
    required MangaRenderManifest manifest,
    required CastVoicingLedger ledger,
    required MangaRegenerateCandidate candidate,
  }) async {
    if (!manifest.lines.any(
      (MangaRenderedLine l) => l.lineId == candidate.lineId,
    )) {
      await discardCandidate(candidate);
      return false;
    }
    await (_AudioBatch(
      directory,
    )..adopt(candidate.file, candidate.stagedFile)).publish();
    final bool replaced = manifest.replaceLine(
      candidate.lineId,
      (MangaRenderedLine l) => l.replaced(
        file: candidate.file,
        durationMs: candidate.durationMs,
        placeholder: false,
        voice: candidate.voice,
        seed: candidate.seed,
        text: candidate.text,
        spoken: candidate.spoken,
        shape: candidate.shape,
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
        audio: l.audio is MangaSynthesized ? null : const MangaSynthesized(),
      ),
    );
    ledger.resolve(candidate.lineId);
    await manifest.save(manifestFile);
    await sweepUnreferenced(manifest);
    return true;
  }

  /// 给已生成的句子换上用户的本地音频（[bindings]：lineId → 保留副本已放进
  /// [kMangaLocalAudioDirName] 的 [MangaLocalAudio]）。全有或全无：先逐句整形进暂存文件
  /// （目标是 [mangaLocalLineFileName]；同一段音频换了文件名再绑回来时，目标就是清单正在
  /// 引用的文件），有一句失败就只删这次的暂存文件，清单引用的音频、清单 /
  /// 演出稿 / 账本都不动，结果里带各句失败原因（HBK-AUDIT-201）；全部成功才把暂存文件
  /// 改名成目标文件、改清单（文件、时长、
  /// `file:` 标记、整形版本）、演出稿（音源）与账本（这些句子不再是未配音），存清单
  /// 并清掉不再引用的旧文件。清单里这句已经是同一段音频、同一整形版本且文件还在的
  /// 原样不动（记进 [MangaLocalBindOutcome.unchanged]）。[script] / [ledger] 原地改，
  /// 调用方落盘。
  Future<MangaLocalBindOutcome> bindLocalAudio({
    required MangaAudioScript script,
    required MangaRenderManifest manifest,
    required CastVoicingLedger ledger,
    required Map<String, MangaLocalAudio> bindings,
    required TtsRenderCancelToken cancel,
  }) async {
    final String shape = backend.shapeVersion;
    final Map<String, ({String file, int durationMs})> produced =
        <String, ({String file, int durationMs})>{};
    final Set<String> unchanged = <String>{};
    final Map<String, MangaLineFailure> failures = <String, MangaLineFailure>{};
    final _AudioBatch batch = _AudioBatch(directory);
    try {
      for (final MapEntry<String, MangaLocalAudio> e in bindings.entries) {
        final MangaScriptLine? line = script.lineById(e.key);
        MangaRenderedLine? old;
        for (final MangaRenderedLine l in manifest.lines) {
          if (l.lineId == e.key) old = l;
        }
        if (line == null || old == null) {
          failures[e.key] = const MangaLineFailure('line_missing');
          continue;
        }
        final String file = mangaLocalLineFileName(e.key, e.value);
        if (!old.placeholder &&
            old.file == file &&
            old.voice == mangaLocalVoiceTag(e.value) &&
            old.shape == shape &&
            line.audio == e.value &&
            await File(_pathOf(file)).exists()) {
          unchanged.add(e.key);
          continue;
        }
        try {
          produced[e.key] = await _produce(
            MangaRenderItem(
              line: line,
              text: old.text,
              source: MangaRenderLocal(e.value),
            ),
            file,
            batch,
            cancel,
          );
        } catch (err, stack) {
          failures[e.key] = _lineFailure(err, stack, cancel);
        }
      }
      if (failures.isNotEmpty) {
        return MangaLocalBindOutcome(
          bound: const <String, int>{},
          unchanged: unchanged,
          failures: failures,
        );
      }
      await batch.publish();
      for (final MapEntry<String, ({String file, int durationMs})> e
          in produced.entries) {
        final MangaLocalAudio audio = bindings[e.key]!;
        manifest.replaceLine(
          e.key,
          (MangaRenderedLine l) => l.replaced(
            file: e.value.file,
            durationMs: e.value.durationMs,
            placeholder: false,
            voice: mangaLocalVoiceTag(audio),
            shape: shape,
          ),
        );
        script.replaceLine(
          e.key,
          (MangaScriptLine l) => l.copyWith(audio: audio),
        );
        ledger.resolve(e.key);
      }
      await manifest.save(manifestFile);
      await sweepUnreferenced(manifest);
      return MangaLocalBindOutcome(
        bound: <String, int>{
          for (final MapEntry<String, ({String file, int durationMs})> e
              in produced.entries)
            e.key: e.value.durationMs,
        },
        unchanged: unchanged,
        failures: const <String, MangaLineFailure>{},
      );
    } finally {
      // 提交了就是空操作；没提交（有一句失败 / 取消）只删本次自己的暂存文件。
      await batch.discard();
    }
  }

  /// 撤回候选：只删候选的暂存文件，清单、演出稿与清单引用的音频都不动（同一个种子
  /// 再出一次时 [MangaRegenerateCandidate.file] 就是清单正在用的文件，不能删它）。
  Future<void> discardCandidate(MangaRegenerateCandidate candidate) async {
    final File f = File(_pathOf(candidate.stagedFile));
    if (await f.exists()) await f.delete();
  }

  /// 演出稿里已改成「不读」类型（或已删掉）的句子从成品清单里拿掉——与整卷生成同一
  /// 判据（[planMangaRender] 不让它们进计划），单句改动不用等整卷重跑（HBK-AUDIT-214）。
  /// 只看 [lineIds] 这几句；拿掉的句子从 [ledger] 出账，存清单并清掉它们的音频。返回
  /// 拿掉的行身份（空 = 清单没变、什么都没写）。[ledger] 原地改，调用方落盘；库要按
  /// 新清单整份重登记（句子数变了）。
  Future<List<String>> dropUnreadLines({
    required MangaAudioScript script,
    required MangaRenderManifest manifest,
    required CastVoicingLedger ledger,
    required Iterable<String> lineIds,
  }) async {
    final Set<String> wanted = lineIds.toSet();
    final List<String> dropped = <String>[
      for (final MangaRenderedLine l in manifest.lines)
        if (wanted.contains(l.lineId) &&
            !(script.lineById(l.lineId)?.kind.isAudible ?? false))
          l.lineId,
    ];
    if (dropped.isEmpty) return dropped;
    manifest.lines.removeWhere(
      (MangaRenderedLine l) => dropped.contains(l.lineId),
    );
    dropped.forEach(ledger.resolve);
    await manifest.save(manifestFile);
    await sweepUnreferenced(manifest);
    return dropped;
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
    // 本地音频的保留副本：清单里没有哪句还标着它（换回合成 / 换了另一段）就删。
    final Directory local = Directory(
      p.join(directory.path, kMangaLocalAudioDirName),
    );
    if (!await local.exists()) return;
    final Set<String> sigs = <String>{
      for (final MangaRenderedLine l in manifest.lines)
        if (l.voice case final String v
            when v.startsWith(kMangaLocalVoicePrefix))
          v.substring(kMangaLocalVoicePrefix.length),
    };
    for (final FileSystemEntity e in local.listSync()) {
      if (e is! File || sigs.contains(p.basenameWithoutExtension(e.path))) {
        continue;
      }
      try {
        await e.delete();
      } on FileSystemException catch (err, stack) {
        engineLog.log('MangaAudioRenderer.sweep', err, stack);
      }
    }
  }
}

/// 一次提交新出的音频（HBK-AUDIT-201 / 207）：目标文件名 → 暂存文件名（都相对
/// [directory]）。出音频只写暂存文件（[mangaStagedFileName]，清单从不引用）；
/// [publish] 把它们改名成目标文件（目标正被旧清单引用时整个换掉），调用方紧接着存
/// 清单；[discard] 只删本批自己还没发布的暂存文件，绝不碰目标文件。
class _AudioBatch {
  _AudioBatch(this.directory);

  final Directory directory;
  final Map<String, String> _staged = <String, String>{};

  /// 目标 [file] 的暂存文件（记进本批）；同一目标再出一次复用同一个暂存文件。
  File stage(String file) {
    final String staged = mangaStagedFileName(file);
    _staged[file] = staged;
    return File(p.join(directory.path, staged));
  }

  /// 收下别处已经出好的暂存文件（单句候选）。
  void adopt(String file, String staged) => _staged[file] = staged;

  /// 这一句没出成：删它的暂存文件、不再记在本批。
  Future<void> drop(String file) async {
    final String? staged = _staged.remove(file);
    if (staged == null) return;
    final File f = File(p.join(directory.path, staged));
    if (await f.exists()) await f.delete();
  }

  /// 暂存文件改名成目标文件。暂存文件已不在（被清扫掉）的跳过，目标保持原样。
  Future<void> publish() async {
    for (final MapEntry<String, String> e in _staged.entries.toList()) {
      final File staged = File(p.join(directory.path, e.value));
      _staged.remove(e.key);
      if (!await staged.exists()) continue;
      final File target = File(p.join(directory.path, e.key));
      if (await target.exists()) await target.delete();
      await staged.rename(target.path);
    }
  }

  /// 删掉本批还没发布的暂存文件（发布过的已不在表里）。
  Future<void> discard() async {
    for (final String staged in _staged.values.toList()) {
      final File f = File(p.join(directory.path, staged));
      if (await f.exists()) await f.delete();
    }
    _staged.clear();
  }
}
