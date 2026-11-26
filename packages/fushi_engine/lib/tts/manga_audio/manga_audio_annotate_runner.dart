/// 漫画演出稿 AI 标注的流程（设计 §4，三遍）：角色表 → 逐页 → 整场复核。
///
/// 纯 Dart，不碰文件与提供商解析：请求经 [MangaAnnotateAsk] 发出（应用层接
/// `AiChatClient.complete`，限频 / 退避 / 错误脱敏都在那一层），页图经
/// [MangaAnnotateImageLoader] 取（应用层负责读盘与缩图），每标完一页调
/// [MangaAnnotateRunner.checkpoint] 让应用层落盘（中途取消 / 失败已标的页不丢）。
///
/// 失败分两种：
/// - **这一处失败**（网络重试几轮仍失败、回复不是约定 JSON、整页被校验丢光、页图读不出）
///   → 记进 [MangaAnnotationLedger]，接着标下一页，整卷不失败。
/// - **整次运行没法继续**（鉴权被拒、提供商没配全等非临时性失败——后面每页都会一样）
///   → 当前页记账后抛 [MangaAnnotateAbort]；没轮到的页保持「未标注」，下次运行接着标。
/// 取消（[MangaAnnotateRunner.isCancelled] 或客户端已关）抛 [MangaAnnotateAbort]
/// `cancelled`，不记账。
library;

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/cast_prompt_roster.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

/// 发一次请求，回模型的原文；失败抛 [AiChatFailure]。
typedef MangaAnnotateAsk =
    Future<String> Function(List<AiChatMessage> messages);

/// 取第 [page] 页（0 起）缩好的页图；读不出返回 null。
typedef MangaAnnotateImageLoader = Future<AiChatImage?> Function(int page);

/// 整次运行停下（[code]：`cancelled` 或 AI 客户端的脱敏短码）。
class MangaAnnotateAbort implements Exception {
  const MangaAnnotateAbort(this.code);
  final String code;

  @override
  String toString() => 'MangaAnnotateAbort($code)';
}

/// 进度阶段。
enum MangaAnnotatePhase { roster, pages, review }

/// 一次运行的结果摘要。
class MangaAnnotateRunSummary {
  const MangaAnnotateRunSummary({
    required this.annotatedPages,
    required this.failedPages,
    required this.rejectedLines,
    required this.reviewedLines,
  });

  /// 本次标成功的页（含没文字、无需请求的页）。
  final List<int> annotatedPages;

  /// 本次失败、已记账的页。
  final List<int> failedPages;

  /// 本次被本地校验丢弃的行数（已存进账本供复核界面列出）。
  final int rejectedLines;

  /// 整场复核改动的行数。
  final int reviewedLines;
}

class MangaAnnotateRunner {
  MangaAnnotateRunner({
    required this.payload,
    required this.script,
    required this.ledger,
    required this.seriesRoster,
    required this.ask,
    required this.imageFor,
    required this.providerId,
    required this.model,
    required this.checkpoint,
    required this.isCancelled,
    this.onProgress,
    this.substitutions = const <CastTextSubstitution>[],
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MokuroPayload payload;
  final MangaAudioScript script;
  final MangaAnnotationLedger ledger;

  /// 系列角色表（`SeriesCastProfile.roster`）；只读，学回系列由调用方做
  /// （[workingRoster] 是本次运行结束时的完整角色表）。
  final Map<String, TtsCastCharacter> seriesRoster;

  final List<CastTextSubstitution> substitutions;

  final MangaAnnotateAsk ask;
  final MangaAnnotateImageLoader imageFor;

  /// 本次用的提供商 id / 模型名（写进失败账本，切配置重试据此跳过试过的）。
  final String providerId;
  final String model;

  final Future<void> Function() checkpoint;
  final bool Function() isCancelled;
  final void Function(MangaAnnotatePhase phase, int done, int total)?
  onProgress;
  final DateTime Function() _clock;

  late final Map<String, TtsCastCharacter> workingRoster = mergedMangaRoster(
    series: seriesRoster,
    volume: script.roster,
  );

  int get pageCount => payload.images.length;

  /// 一句的台词文本（按 OCR 块拼，手填的 `say` 优先）。
  String textOf(MangaScriptLine line) {
    if (line.page < 0 || line.page >= payload.images.length) return '';
    final String text = resolveMangaLineText(
      line,
      payload.images[line.page].blocks,
    );
    return line.say != null
        ? text
        : applyCastSubstitutions(text, substitutions);
  }

  void _throwIfCancelled() {
    if (isCancelled()) throw const MangaAnnotateAbort('cancelled');
  }

  /// 发请求；失败转成账本短码。非临时性失败（后面都会一样）记账后由调用方中止。
  Future<({String? reply, String? code, String? detail, bool fatal})> _ask(
    String system,
    String user, {
    List<AiChatImage> images = const <AiChatImage>[],
  }) async {
    try {
      final String reply = await ask(<AiChatMessage>[
        AiChatMessage.system(system, cacheable: true),
        AiChatMessage.user(user, images: images),
      ]);
      return (reply: reply, code: null, detail: null, fatal: false);
    } on AiChatFailure catch (e) {
      if (e.message == 'cancelled' || isCancelled()) {
        throw const MangaAnnotateAbort('cancelled');
      }
      return (
        reply: null,
        code: e.isTransient
            ? MangaAnnotateFailureCode.network
            : MangaAnnotateFailureCode.aiFailed,
        detail: e.message,
        // 空回复 / 思考把输出额度用光（BUG-5469）只记这一页失败，不中止整卷。
        fatal:
            !e.isTransient &&
            e.message != 'empty_response' &&
            e.message != kAiOutputLimitCode,
      );
    }
  }

  void _record(
    MangaAnnotateStage stage,
    int page,
    String code, {
    String? detail,
    List<int> scene = const <int>[],
  }) => ledger.recordFailure(
    stage: stage,
    page: page,
    providerId: providerId,
    model: model,
    code: code,
    detail: detail,
    scene: scene,
    now: _clock(),
  );

  /// 跑一次：[pages] = 要标的页（升序处理）；[withRoster] 先跑角色表；[withReview]
  /// 最后对本次标成功的页做整场复核。OCR 签名记进演出稿。
  Future<MangaAnnotateRunSummary> run({
    required List<int> pages,
    bool withRoster = true,
    bool withReview = true,
  }) async {
    script.engineSignature = mangaPayloadOcrSignature(payload);
    final List<int> todo =
        pages.where((int p) => p >= 0 && p < pageCount).toSet().toList()
          ..sort();
    if (withRoster) await _rosterPass();

    final List<int> annotated = <int>[];
    final List<int> failed = <int>[];
    int rejected = 0;
    onProgress?.call(MangaAnnotatePhase.pages, 0, todo.length);
    for (int i = 0; i < todo.length; i++) {
      _throwIfCancelled();
      final int page = todo[i];
      final ({bool ok, int rejected}) r = await _pagePass(page);
      (r.ok ? annotated : failed).add(page);
      rejected += r.rejected;
      _syncRoster();
      await checkpoint();
      onProgress?.call(MangaAnnotatePhase.pages, i + 1, todo.length);
    }

    final int reviewed = withReview
        ? await reviewScenes(chunkMangaScenes(script, annotated))
        : 0;
    return MangaAnnotateRunSummary(
      annotatedPages: annotated,
      failedPages: failed,
      rejectedLines: rejected,
      reviewedLines: reviewed,
    );
  }

  /// 本次运行里认识的人全写回本卷角色表（系列的由调用方学）。
  void _syncRoster() => mergeCastRoster(script.roster, workingRoster.values);

  Future<void> _rosterPass() async {
    onProgress?.call(MangaAnnotatePhase.roster, 0, 1);
    _throwIfCancelled();
    final List<int> rosterPages = mangaRosterImagePages(payload.images);
    if (rosterPages.isEmpty) {
      onProgress?.call(MangaAnnotatePhase.roster, 1, 1);
      return;
    }
    final List<AiChatImage> images = <AiChatImage>[];
    final AiChatImage? cover = await imageFor(0);
    if (cover != null) images.add(cover);
    final List<({int page, MokuroImage image})> withImages =
        <({int page, MokuroImage image})>[];
    for (final int p in rosterPages) {
      final AiChatImage? img = await imageFor(p);
      if (img == null) continue;
      images.add(img);
      withImages.add((page: p, image: payload.images[p]));
    }
    if (withImages.isEmpty) {
      _record(MangaAnnotateStage.roster, -1, MangaAnnotateFailureCode.image);
      await checkpoint();
      return;
    }
    final CastPromptRoster promptRoster = CastPromptRoster(
      roster: workingRoster.values,
      substitutions: substitutions,
    );
    final ({String? reply, String? code, String? detail, bool fatal}) r =
        await _ask(
          kMangaRosterSystemPrompt,
          buildMangaRosterUserPrompt(
            roster: workingRoster.values,
            pages: withImages,
            hasCover: cover != null,
            substitutions: substitutions,
            promptRoster: promptRoster,
          ),
          images: images,
        );
    if (r.reply == null) {
      _record(MangaAnnotateStage.roster, -1, r.code!, detail: r.detail);
      await checkpoint();
      if (r.fatal) throw MangaAnnotateAbort(r.detail ?? r.code!);
      return;
    }
    final List<TtsCastCharacter>? found = parseMangaRosterReply(
      r.reply!,
      promptRoster: promptRoster,
    );
    if (found == null) {
      _record(
        MangaAnnotateStage.roster,
        -1,
        MangaAnnotateFailureCode.badOutput,
      );
    } else {
      mergeCastRoster(workingRoster, found);
      _syncRoster();
      ledger.resolve(MangaAnnotateStage.roster, -1);
    }
    await checkpoint();
    onProgress?.call(MangaAnnotatePhase.roster, 1, 1);
  }

  Future<({bool ok, int rejected})> _pagePass(int page) async {
    final MokuroImage image = payload.images[page];
    if (image.blocks.isEmpty) {
      // 没字的页不发请求：时间表按无台词页处理（默认停留）。
      script.mergeAiPage(page, const <MangaScriptLine>[]);
      ledger.clearPage(page);
      return (ok: true, rejected: 0);
    }
    final AiChatImage? img = await imageFor(page);
    if (img == null) {
      _record(MangaAnnotateStage.page, page, MangaAnnotateFailureCode.image);
      return (ok: false, rejected: 0);
    }
    final CastPromptRoster promptRoster = CastPromptRoster(
      roster: workingRoster.values,
      substitutions: substitutions,
    );
    final ({String? reply, String? code, String? detail, bool fatal}) r =
        await _ask(
          kMangaPageSystemPrompt,
          buildMangaPageUserPrompt(
            page: page,
            pageCount: pageCount,
            image: image,
            roster: workingRoster.values,
            previous: mangaPreviousLines(script, page, textOf),
            substitutions: substitutions,
            promptRoster: promptRoster,
          ),
          images: <AiChatImage>[img],
        );
    if (r.reply == null) {
      _record(MangaAnnotateStage.page, page, r.code!, detail: r.detail);
      if (r.fatal) {
        await checkpoint();
        throw MangaAnnotateAbort(r.detail ?? r.code!);
      }
      return (ok: false, rejected: 0);
    }
    final MangaPageAnnotation? parsed = parseMangaPageReply(
      r.reply!,
      page: page,
      blockCount: image.blocks.length,
      roster: workingRoster,
      promptRoster: promptRoster,
    );
    if (parsed == null) {
      _record(
        MangaAnnotateStage.page,
        page,
        MangaAnnotateFailureCode.badOutput,
      );
      return (ok: false, rejected: 0);
    }
    final int rejected = parsed.validation.rejected.length;
    ledger.setRejected(page, parsed.validation.rejected);
    if (parsed.allRejected) {
      _record(
        MangaAnnotateStage.page,
        page,
        MangaAnnotateFailureCode.validation,
        detail: parsed.validation.rejected.first.reason.name,
      );
      return (ok: false, rejected: rejected);
    }
    script.mergeAiPage(
      page,
      parsed.validation.accepted,
      directive: parsed.directive,
    );
    ledger.resolve(MangaAnnotateStage.page, page);
    return (ok: true, rejected: rejected);
  }

  /// 整场复核 [scenes]；失败的场记账（按该场第一页）。返回改动的行数。
  Future<int> reviewScenes(List<MangaScene> scenes) async {
    int changed = 0;
    onProgress?.call(MangaAnnotatePhase.review, 0, scenes.length);
    for (int i = 0; i < scenes.length; i++) {
      _throwIfCancelled();
      final MangaScene scene = scenes[i];
      final CastPromptRoster promptRoster = CastPromptRoster(
        roster: workingRoster.values,
        substitutions: substitutions,
      );
      final ({String? reply, String? code, String? detail, bool fatal}) r =
          await _ask(
            kMangaSceneReviewSystemPrompt,
            buildMangaSceneReviewUserPrompt(
              script: script,
              scene: scene,
              roster: workingRoster.values,
              textOf: textOf,
              substitutions: substitutions,
              promptRoster: promptRoster,
            ),
          );
      if (r.reply == null) {
        _record(
          MangaAnnotateStage.review,
          scene.first,
          r.code!,
          detail: r.detail,
          scene: scene,
        );
        await checkpoint();
        if (r.fatal) throw MangaAnnotateAbort(r.detail ?? r.code!);
        continue;
      }
      final List<MangaReviewEdit>? edits = parseMangaSceneReviewReply(
        r.reply!,
        roster: workingRoster,
        promptRoster: promptRoster,
      );
      if (edits == null) {
        _record(
          MangaAnnotateStage.review,
          scene.first,
          MangaAnnotateFailureCode.badOutput,
          scene: scene,
        );
      } else {
        changed += applyMangaSceneReview(script, scene, edits);
        ledger.resolve(MangaAnnotateStage.review, scene.first);
      }
      await checkpoint();
      onProgress?.call(MangaAnnotatePhase.review, i + 1, scenes.length);
    }
    return changed;
  }

  /// 按账本重试一处失败：角色表 / 某页（标完对该页做复核）/ 某场复核。
  Future<MangaAnnotateRunSummary> retry(MangaAnnotateFailure failure) async {
    switch (failure.stage) {
      case MangaAnnotateStage.roster:
        return run(pages: const <int>[], withRoster: true, withReview: false);
      case MangaAnnotateStage.page:
        return run(pages: <int>[failure.page], withRoster: false);
      case MangaAnnotateStage.review:
        final List<int> scene = failure.scene.isEmpty
            ? <int>[failure.page]
            : failure.scene;
        final int changed = await reviewScenes(<MangaScene>[scene]);
        return MangaAnnotateRunSummary(
          annotatedPages: const <int>[],
          failedPages: const <int>[],
          rejectedLines: 0,
          reviewedLines: changed,
        );
    }
  }
}

/// 要标的页：[only] 非空就是这些页；否则全卷，[skipAnnotated] 时跳过已标过的页。
List<int> mangaPagesToAnnotate(
  MangaAudioScript script,
  int pageCount, {
  Set<int> only = const <int>{},
  bool skipAnnotated = true,
}) => <int>[
  for (int p = 0; p < pageCount; p++)
    if (only.isNotEmpty
        ? only.contains(p)
        : !skipAnnotated || !script.annotatedPages.contains(p))
      p,
];

/// OCR 重跑过（签名不一致）时整卷重新标注：块下标已不可信，所有行（含用户手改的）、
/// 页指令、已标页与失败账本一起清掉；角色表与声音指派保留。返回是否清过。
bool resetStaleMangaScript(
  MangaAudioScript script,
  MangaAnnotationLedger ledger,
  String? currentEngineSignature,
) {
  if (script.freshness(currentEngineSignature) ==
      MangaScriptFreshness.upToDate) {
    return false;
  }
  script.lines.clear();
  script.pages.clear();
  script.annotatedPages.clear();
  script.engineSignature = currentEngineSignature;
  ledger.clear();
  return true;
}
