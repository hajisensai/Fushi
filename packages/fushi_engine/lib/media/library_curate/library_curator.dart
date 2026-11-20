/// AI 库管家的编排器（spec `docs/specs/2026-11-18-ai-library-curator-design.md` §3）。
///
/// **编排是代码，不是模型**：阶段顺序、每阶段喂什么、什么情况落盘全部写死在这里，
/// 模型只在各操作内部回答受限的问题（这几个是不是一组、这个候选是不是它、这两个是
/// 不是同一作品）。
///
/// **不另写一套执行与撤销**：每一处写入都经 [AgentToolbox]（app 的 `AiAgentToolbox` /
/// 服务端的 `ServerAgentToolbox`）以 model 身份调操作目录，记账会话 id 是
/// `curator:<runId>`——记账、凭据脱敏、撤销、可用性判定（模块门、iOS 合规门、平台）
/// 全部沿用目录的；整趟撤销就是按会话把这些记录倒序撤掉（[LibraryCurator.undoRun]）。
/// 需要用户确认的操作（`irreversible` / `confirm`）在编排里一律不执行，收进待确认。
///
/// 本文件纯 Dart（不 import flutter / 插件 / `package:fushi`）。
library;

import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_media_identity_assistant.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/collections/book_series_grouper.dart'
    show isOnlineMangaSourceMetadata;
import 'package:fushi_engine/media/collections/library_organize/library_organize_facts.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart'
    show LibraryOrganizeFacts;
import 'package:fushi_engine/media/collections/library_organize/library_organize_service.dart'
    show chunkOrganizeEntries;
import 'package:fushi_engine/media/library_curate/library_curate_run.dart';
import 'package:fushi_engine/media/links/work_graph.dart';
import 'package:fushi_engine/media/links/work_graph_loader.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart'
    show DlsiteWorkId;
import 'package:fushi_engine/media/video/metadata/video_collection_relation_sync.dart'
    show CollectionRelationBackfillResult;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi_engine/media/video/organize/video_placement_ai.dart';
import 'package:fushi_engine/media/video/organize/video_placement_audit.dart'
    show kVideoEpisodeOccupiedCode;

export 'package:fushi_engine/media/library_curate/library_curate_run.dart';

/// 编排器调用的目录操作 id（app 与服务端目录里同名）。
abstract final class LibraryCurateOps {
  static const String organizeRun = 'library.organize.run';
  static const String videoWorkList = 'video.work.list';
  static const String videoWorkCandidates = 'video.work.candidates';
  static const String videoWorkIdentify = 'video.work.identify';
  static const String videoLibraryAudit = 'video.library.audit';
  static const String videoWorkRegroup = 'video.work.regroup';
  static const String videoEpisodePin = 'video.episode.pin';
  static const String linksInfer = 'library.curate.links.infer';
  static const String linksMusic = 'library.curate.links.music';
  static const String bookScrapeSearch = 'book.scrape.search';
  static const String bookScrapeApply = 'book.scrape.apply';
  static const String gameScrapeSearch = 'game.scrape.search';
  static const String gameScrapeApply = 'game.scrape.apply';
}

/// 各步自己的 AI 指派是否可用（spec §9：不新增 `AiFeature`，每步用它自己的指派；
/// 没指派的那一步跳过，其余照跑）。宿主每次现算（AI 模块门也折进来）。
///
/// 书 / 游戏刮削的 AI 消歧与视频刮削同一件事（在刮削候选里认作品），共用
/// [videoIdentify] 这一项指派；没指派时这两步只做规则认领（不发 AI 请求）。
typedef LibraryCurateAiAvailability = ({
  bool organize,
  bool videoIdentify,
  bool mediaLinks,
});

/// 没有任何 AI 的可用性（测试 / 服务端没配 AI）。
const LibraryCurateAiAvailability kLibraryCurateNoAi = (
  organize: false,
  videoIdentify: false,
  mediaLinks: false,
);

/// 单趟上限（spec §9「自动路径有单趟请求上限」；手动触发不限）。
class LibraryCurateLimits {
  const LibraryCurateLimits({
    this.autoMaxRequests = 40,
    this.autoMaxScrapeWorks = 10,
    this.autoMaxBookUnits = 10,
    this.autoMaxGameUnits = 10,
    this.autoMaxLinkEndpoints = 60,
    this.linkBatchSize = 10,
  });

  /// 自动路径一趟最多发多少次 AI 请求（按各阶段估算扣减；超了的阶段只跑不花钱的
  /// 部分，标 `request_cap`，下一趟接着做）。
  final int autoMaxRequests;

  /// 自动路径一趟最多查几部待确认视频作品（每部一次资料源搜索）。
  final int autoMaxScrapeWorks;

  /// 自动路径一趟最多查几个书单元（系列 / 单书；每个一次资料源搜索，系列另按卷
  /// 取封面）。
  final int autoMaxBookUnits;

  /// 自动路径一趟最多查几款游戏（每款一次资料源搜索）。
  final int autoMaxGameUnits;

  /// 自动路径一趟最多推断几个端点（每个最多一次 AI 裁决，可能查 MAL / Wikidata）。
  final int autoMaxLinkEndpoints;

  /// 每次 `library.curate.links.infer` 带几个端点（一条操作记录）。
  final int linkBatchSize;
}

/// 编排器要读的库事实（只读；默认实现 [DatabaseLibraryCurateFacts]）。
abstract interface class LibraryCurateFacts {
  /// [domain] 里入库时刻晚于 [sinceMs] 的整理条目键（成员行键）；[sinceMs] 为 null
  /// （首趟 / 全量）返回 null = 全域。
  Future<Set<String>?> organizeEntriesSince(
    CollectionShelfDomain domain,
    int? sinceMs,
  );

  /// 对 [only]（null = 全域）跑 AI 整理大约要几次请求（= 分块数）。
  Future<int> organizeRequestEstimate(
    CollectionShelfDomain domain,
    Set<String>? only,
  );

  /// 要做关系推断的端点（wire `<kind>:<key>`，确定性顺序）：晚于 [sinceMs] 入库，或
  /// 晚于它刚拿到外部 id 的视频合集；null = 全库。
  Future<List<String>> linkEndpointsSince(int? sinceMs);

  /// 音乐库在 [sinceMs] 之后有没有变化（null = 有没有音乐）。
  Future<bool> musicChangedSince(int? sinceMs);

  /// 要刮削的书单元（缺元数据的书，系列按合集归一个单元，确定性顺序）；[sinceMs]
  /// 非 null 时只要含晚于它入库的书的单元。
  Future<List<LibraryCurateBookUnit>> bookScrapeUnits(int? sinceMs);

  /// 要刮削的游戏（没有任何资料源快照的）；[sinceMs] 非 null 时只要晚于它入库的。
  Future<List<LibraryCurateGameUnit>> gameScrapeUnits(int? sinceMs);
}

/// 进度回调：正在跑第 [index] 个阶段（共 [total] 个）。
typedef LibraryCurateProgress =
    void Function(LibraryCurateStage stage, int index, int total);

/// 一趟的费用预估（spec §9：请求数 = 各域分桶数 + 待消歧作品数 + 连接候选批数）。
class LibraryCurateEstimate {
  const LibraryCurateEstimate({
    required this.requestsByStage,
    required this.itemsByStage,
    required this.full,
  });

  /// 各阶段大约要发几次 AI 请求（没指派 AI 的阶段为 0）。
  final Map<LibraryCurateStage, int> requestsByStage;

  /// 各阶段待处理的条目数。
  final Map<LibraryCurateStage, int> itemsByStage;
  final bool full;

  int get requests =>
      requestsByStage.values.fold<int>(0, (int a, int b) => a + b);

  int get items => itemsByStage.values.fold<int>(0, (int a, int b) => a + b);

  Map<String, Object?> toJson() => <String, Object?>{
    'full': full,
    'requests': requests,
    'items': items,
    'stages': <Object?>[
      for (final LibraryCurateStage s in LibraryCurateStage.values)
        if (itemsByStage.containsKey(s) || requestsByStage.containsKey(s))
          <String, Object?>{
            'stage': s.wire,
            'items': itemsByStage[s] ?? 0,
            'requests': requestsByStage[s] ?? 0,
          },
    ],
  };
}

/// 整趟撤销的结论。
class LibraryCurateUndoResult {
  const LibraryCurateUndoResult({
    required this.runId,
    required this.undone,
    required this.superseded,
    required this.failed,
    required this.skipped,
  });

  final int runId;

  /// 撤掉的操作记录数（含部分撤销）。
  final int undone;

  /// 之后又被改过、保留现值的。
  final int superseded;
  final int failed;

  /// 不可撤销 / 早已撤销过的。
  final int skipped;

  Map<String, Object?> toJson() => <String, Object?>{
    'runId': runId,
    'undone': undone,
    'superseded': superseded,
    'failed': failed,
    'skipped': skipped,
  };
}

/// 已有一趟在跑。
class LibraryCurateBusy implements Exception {
  const LibraryCurateBusy(this.runId);

  final int runId;

  @override
  String toString() => 'LibraryCurateBusy($runId)';
}

/// 库管家编排器。一个宿主进程一个实例（同一时刻只跑一趟）。
class LibraryCurator {
  LibraryCurator({
    required this.db,
    required this.toolbox,
    required this.store,
    required this.facts,
    required this.ai,
    this.videoDecider,
    this.mediaDecider,
    this.placementJudge,
    this.limits = const LibraryCurateLimits(),
    this.onWorksChanged,
    this.seriesRelationBackfill,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final FushiDatabase db;
  final AgentToolbox toolbox;
  final LibraryCurateStore store;
  final LibraryCurateFacts facts;
  final LibraryCurateAiAvailability Function() ai;

  /// 待确认视频作品多候选时的 AI 消歧（复用 `videoIdentify` 的提示词结构：AI 只在
  /// 候选键里选，不产生任何 id）。null 或返回 null = 不问。
  final AiVideoIdentityDecider? Function()? videoDecider;

  /// 书 / 游戏多候选时的 AI 消歧（同一判定契约：只在候选键里选）。null 或返回
  /// null = 不问，只做规则认领。
  final AiMediaIdentityDecider? Function()? mediaDecider;

  /// 「挂在第 0 季的文件是不是真的特别篇」的判定器（`video_placement_ai.dart`）。
  /// null 或返回 null = 不问，退回时长判据。
  final AiVideoPlacementJudge? Function()? placementJudge;
  final LibraryCurateLimits limits;

  /// 作品层重算后通知宿主（宿主的作品图缓存本就随表变更失效，这里只是让界面立即
  /// 刷新；可空）。
  final void Function()? onWorksChanged;

  /// ⑤ 作品层重算之前的系列关系存量补填（不联网：AniDB 读已落盘 XML、其余读
  /// details 快照，见 `backfillScrapedCollectionRelations`）。null = 不补。幂等，
  /// 每趟都跑：新落盘的 XML / 新入库的目标作品在下一趟补上、升级绑定。
  final Future<CollectionRelationBackfillResult> Function()?
  seriesRelationBackfill;
  final DateTime Function() _clock;

  LibraryCurateRun? _current;
  LibraryCurateStage? _currentStage;

  /// 正在跑的那一趟（没有为 null）。
  LibraryCurateRun? get current => _current;

  /// 正在跑的阶段。
  LibraryCurateStage? get currentStage => _currentStage;

  bool get isRunning => _busy;

  /// 本机运行记录（新的在前）。
  Future<List<LibraryCurateRun>> runs() async => (await store.load()).runs;

  // ─────────────────────────────────────────────────────────────────────
  // 运行
  // ─────────────────────────────────────────────────────────────────────

  /// 跑一趟。已有一趟在跑抛 [LibraryCurateBusy]。[full] = 忽略水位对全库跑。
  Future<LibraryCurateRun> run({
    required LibraryCurateTrigger trigger,
    bool full = false,
    bool Function()? isCancelled,
    LibraryCurateProgress? onProgress,
    void Function(LibraryCurateRun run)? onStarted,
  }) async {
    // 同步占位：两个调用方同一帧进来时第二个立刻得到 busy（下面第一个 await 之前）。
    if (_busy) throw LibraryCurateBusy(_current?.id ?? 0);
    _busy = true;
    try {
      return await _runLocked(
        trigger: trigger,
        full: full,
        isCancelled: isCancelled,
        onProgress: onProgress,
        onStarted: onStarted,
      );
    } finally {
      _busy = false;
    }
  }

  bool _busy = false;

  Future<LibraryCurateRun> _runLocked({
    required LibraryCurateTrigger trigger,
    required bool full,
    required bool Function()? isCancelled,
    required LibraryCurateProgress? onProgress,
    required void Function(LibraryCurateRun run)? onStarted,
  }) async {
    final LibraryCurateState state = await store.load();
    final int now = _clock().millisecondsSinceEpoch;
    final LibraryCurateRun run = LibraryCurateRun(
      id: now > state.lastRunId ? now : state.lastRunId + 1,
      trigger: trigger,
      startedAt: now,
      full: full,
    );
    _current = run;
    state.upsertRun(run);
    await store.save(state);
    onStarted?.call(run);
    final _RunContext ctx = _RunContext(
      run: run,
      state: state,
      ai: ai(),
      budget: trigger == LibraryCurateTrigger.auto
          ? limits.autoMaxRequests
          : null,
      isCancelled: isCancelled ?? () => false,
    );
    const List<LibraryCurateStage> stages = LibraryCurateStage.values;
    try {
      for (int i = 0; i < stages.length; i++) {
        final LibraryCurateStage stage = stages[i];
        _currentStage = stage;
        onProgress?.call(stage, i, stages.length);
        LibraryCurateStageResult result;
        if (ctx.isCancelled()) {
          result = LibraryCurateStageResult(
            stage: stage,
            status: LibraryCurateStageStatus.cancelled,
          );
        } else {
          try {
            result = await _runStage(stage, ctx);
          } on Object catch (error, stack) {
            // 单阶段失败不拖垮整趟：记下失败短码，后面的阶段照跑（结论里如实
            // 带上这一阶段的状态）。
            engineLog.log('libraryCurate.${stage.wire}', error, stack);
            result = LibraryCurateStageResult(
              stage: stage,
              status: LibraryCurateStageStatus.failed,
              error: 'internal_error',
            );
          }
        }
        run.stages.add(result);
        if (result.status == LibraryCurateStageStatus.done) {
          // 水位 = 这一趟的开始时刻；进度清空（下一趟从新水位重新数）。
          state.watermarks[stage.wire] = run.startedAt;
          state.progress.remove(stage.wire);
        }
        state.upsertRun(run);
        await store.save(state);
      }
    } finally {
      run.finishedAt = _clock().millisecondsSinceEpoch;
      run.status = _overall(run);
      state.upsertRun(run);
      await store.save(state);
      _current = null;
      _currentStage = null;
    }
    return run;
  }

  static LibraryCurateRunStatus _overall(LibraryCurateRun run) {
    final Iterable<LibraryCurateStageStatus> s = run.stages.map(
      (LibraryCurateStageResult r) => r.status,
    );
    if (s.contains(LibraryCurateStageStatus.cancelled)) {
      return LibraryCurateRunStatus.cancelled;
    }
    if (s.isNotEmpty &&
        s.every(
          (LibraryCurateStageStatus x) => x == LibraryCurateStageStatus.failed,
        )) {
      return LibraryCurateRunStatus.failed;
    }
    if (s.any(
      (LibraryCurateStageStatus x) =>
          x == LibraryCurateStageStatus.failed ||
          x == LibraryCurateStageStatus.partial,
    )) {
      return LibraryCurateRunStatus.partial;
    }
    return LibraryCurateRunStatus.done;
  }

  Future<LibraryCurateStageResult> _runStage(
    LibraryCurateStage stage,
    _RunContext ctx,
  ) => switch (stage) {
    LibraryCurateStage.organizeBooks => _organize(
      stage,
      CollectionShelfDomain.books,
      ctx,
    ),
    LibraryCurateStage.organizeManga => _organize(
      stage,
      CollectionShelfDomain.manga,
      ctx,
    ),
    LibraryCurateStage.organizeVideo => _organize(
      stage,
      CollectionShelfDomain.video,
      ctx,
    ),
    LibraryCurateStage.organizeGames => _organize(
      stage,
      CollectionShelfDomain.games,
      ctx,
    ),
    LibraryCurateStage.videoStructure => _videoStructure(ctx),
    LibraryCurateStage.scrape => _scrape(ctx),
    LibraryCurateStage.scrapeBooks => _scrapeBooks(ctx),
    LibraryCurateStage.scrapeGames => _scrapeGames(ctx),
    LibraryCurateStage.links => _links(ctx),
    LibraryCurateStage.music => _music(ctx),
    LibraryCurateStage.works => _works(ctx),
  };

  int? _since(LibraryCurateStage stage, _RunContext ctx) =>
      ctx.run.full ? null : ctx.state.watermarks[stage.wire];

  // ── 写入 ────────────────────────────────────────────────────────────

  /// 以 model 身份经工具箱执行一条写操作，记账会话 = 本趟。当前不可用返回
  /// [_Write.unavailable]；需要用户确认的不执行，返回 [_Write.needsConfirmation]。
  Future<_Write> _write(
    _RunContext ctx,
    String name,
    Map<String, Object?> args,
  ) async {
    final AgentToolSpec? spec = toolbox.describeTool(name);
    if (spec == null) return const _Write.unavailable();
    if (spec.needsConfirmation) return const _Write.needsConfirmation();
    final AgentToolResult result = await toolbox.execute(
      AgentToolInvocation(
        sessionId: ctx.run.sessionId,
        name: name,
        arguments: args,
      ),
    );
    return _Write.result(result);
  }

  /// 读操作（不记账）。
  Future<AgentToolResult?> _read(String name, Map<String, Object?> args) async {
    if (toolbox.describeTool(name) == null) return null;
    return toolbox.execute(
      AgentToolInvocation(sessionId: '', name: name, arguments: args),
    );
  }

  // ── ①② 合集归属 ──────────────────────────────────────────────────────

  Future<LibraryCurateStageResult> _organize(
    LibraryCurateStage stage,
    CollectionShelfDomain domain,
    _RunContext ctx,
  ) async {
    if (toolbox.describeTool(LibraryCurateOps.organizeRun) == null) {
      return LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'unavailable',
      );
    }
    final Set<String>? only = await facts.organizeEntriesSince(
      domain,
      _since(stage, ctx),
    );
    if (only != null && only.isEmpty) {
      return LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.done,
      );
    }
    // 没指派「AI 整理库」：只跑规则那一步（不发任何 AI 请求）。
    String? capped = ctx.ai.organize ? null : 'no_provider';
    if (capped == null && ctx.budget != null) {
      final int estimate = await facts.organizeRequestEstimate(domain, only);
      if (!ctx.spend(estimate)) capped = 'request_cap';
    }
    final _Write w =
        await _write(ctx, LibraryCurateOps.organizeRun, <String, Object?>{
          'domain': domain.name,
          'trigger': ctx.run.trigger == LibraryCurateTrigger.auto
              ? 'auto'
              : 'manual',
          if (only != null) 'entryKeys': only.toList()..sort(),
          'rulesOnly': capped != null,
        });
    if (w.unavailable) {
      return LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'unavailable',
      );
    }
    if (w.needsConfirmation) {
      ctx.run.pendingItems.add(
        LibraryCuratePendingItem(
          stage: stage,
          kind: 'needs_confirmation',
          title: LibraryCurateOps.organizeRun,
          ref: domain.name,
        ),
      );
      return LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        pending: 1,
        error: 'needs_confirmation',
      );
    }
    final AgentToolResult r = w.result!;
    if (r.isError) {
      return LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.failed,
        error: r.errorCode,
      );
    }
    final Map<String, Object?> data = _map(r.data);
    final int changes = _int(data['changes']);
    final int proposals = _int(data['proposals']);
    final int requests = _int(data['requests']);
    if (proposals > 0) {
      ctx.run.pendingItems.add(
        LibraryCuratePendingItem(
          stage: stage,
          kind: 'organize_proposal',
          title: domain.name,
          ref: '${data['runId']}',
          reason: '$proposals',
        ),
      );
    }
    final String status = '${data['status']}';
    return LibraryCurateStageResult(
      stage: stage,
      status: switch (status) {
        'done' when capped == null => LibraryCurateStageStatus.done,
        'done' || 'noProvider' => LibraryCurateStageStatus.partial,
        'cancelled' => LibraryCurateStageStatus.cancelled,
        _ => LibraryCurateStageStatus.failed,
      },
      changes: changes,
      pending: proposals,
      requests: requests,
      error: switch (status) {
        'done' || 'noProvider' => capped,
        _ => data['error'] as String? ?? status,
      },
      note: capped == null ? null : 'rules_only',
    );
  }

  // ── 视频摆放纠正（电影被挂成某部剧的第 0 季） ──────────────────────

  /// spec §15.2。`video.library.audit` 给出每部剧集作品里「挂在第 0 季 / 没绑到
  /// 任何一集」的本机文件与作品事实。
  ///
  /// **判断交给模型**（所有者 2026-11-20：「为什么不直接让 ai 看？」）：认身份的 AI
  /// 指派了就逐部作品问一次 [placementJudge]——每个文件是真特别篇、独立的电影、
  /// 还是正片的某一集；编排只负责执行与撤销：
  ///
  /// - `movie` → `video.work.regroup to=standalone` 拆成独立作品（文件自己就是一个
  ///   作品单元时不用拆），再按电影认领（搜索词用模型给的片名）；
  /// - `episode` → `video.episode.pin` 改绑到那一集；
  /// - `special` → 放得对，记下不再重问；
  /// - `unsure` / 置信度不到门槛 → 留待确认。
  ///
  /// 没指派 AI 时退回审计自带的时长判据（[_structureByRules]）：只拆「电影长度、且
  /// 有正片时长基线」的文件，不搜资料源（spec §9）。
  ///
  /// 审计是全库只读的，这一步不走水位；修好的文件自然不再出现在审计里。
  Future<LibraryCurateStageResult> _videoStructure(_RunContext ctx) async {
    const LibraryCurateStage stage = LibraryCurateStage.videoStructure;
    if (toolbox.describeTool(LibraryCurateOps.videoWorkRegroup) == null) {
      return const LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'unavailable',
      );
    }
    final AgentToolResult? listed = await _read(
      LibraryCurateOps.videoLibraryAudit,
      const <String, Object?>{'detail': true},
    );
    if (listed == null) {
      return const LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'unavailable',
      );
    }
    if (listed.isError) {
      return LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.failed,
        error: listed.errorCode,
      );
    }
    final _StructurePass pass = _StructurePass(
      ctx,
      canIdentify:
          ctx.ai.videoIdentify &&
          toolbox.describeTool(LibraryCurateOps.videoWorkIdentify) != null &&
          toolbox.describeTool(LibraryCurateOps.videoWorkCandidates) != null,
      decide: videoDecider?.call(),
    );
    final AiVideoPlacementJudge? judge = ctx.ai.videoIdentify
        ? placementJudge?.call()
        : null;
    if (judge == null) {
      await _structureByRules(pass, _list(listed.data, 'findings'));
    } else {
      await _structureByModel(pass, judge, _list(listed.data, 'works'));
    }
    return LibraryCurateStageResult(
      stage: stage,
      status: pass.incomplete
          ? LibraryCurateStageStatus.partial
          : LibraryCurateStageStatus.done,
      changes: pass.changes,
      pending: pass.pending,
      requests: pass.requests,
      error: pass.incomplete && ctx.capped ? 'request_cap' : null,
      note: judge == null ? 'rules_only' : null,
    );
  }

  /// 这个文件这一趟要不要看：撤销过的不再自动动；自动路径查过、留在待确认的不
  /// 每趟重报；模型判过「放得对」的不重问（全量跑照样重看）。
  bool _structureOpen(_RunContext ctx, String uid) {
    if (ctx.state.suppressed.contains('structure:$uid')) return false;
    if (ctx.run.trigger == LibraryCurateTrigger.auto &&
        ctx.state.seen.contains('structure:$uid')) {
      return false;
    }
    return ctx.run.full || !ctx.state.seen.contains('structure.ok:$uid');
  }

  Future<void> _structureByModel(
    _StructurePass pass,
    AiVideoPlacementJudge judge,
    List<Map<String, Object?>> works,
  ) async {
    final _RunContext ctx = pass.ctx;
    for (final Map<String, Object?> work in works) {
      if (ctx.isCancelled()) {
        pass.incomplete = true;
        return;
      }
      final String workId = '${work['work']}';
      final List<Map<String, Object?>> files = <Map<String, Object?>>[
        for (final Map<String, Object?> f in _list(work, 'files'))
          if (_structureOpen(ctx, '${f['uid']}')) f,
      ];
      if (files.isEmpty) continue;
      if (!ctx.spend(1)) {
        pass.incomplete = true;
        return;
      }
      pass.requests++;
      final Map<String, Map<String, Object?>> byKey =
          <String, Map<String, Object?>>{
            for (int i = 0; i < files.length; i++) 'f${i + 1}': files[i],
          };
      final Map<String, Object?> seasons = _map(work['seasons']);
      final List<AiVideoPlacementAnswer> answers;
      try {
        answers = await judge(
          AiVideoPlacementQuery(
            workTitle: '${work['title'] ?? ''}',
            originalTitle: work['originalTitle'] as String?,
            year: (work['year'] as num?)?.toInt(),
            regularEpisodeMinutes: (work['episodeMinutes'] as num?)?.toInt(),
            regularLocalFiles: _int(work['localRegularFiles']),
            regularSeasons: <int, int>{
              for (final MapEntry<String, Object?> e in seasons.entries)
                if (int.tryParse(e.key) case final int n) n: _int(e.value),
            },
            occupiedEpisodes: <int, List<int>>{
              for (final MapEntry<String, Object?> e in _map(
                work['occupied'],
              ).entries)
                if (int.tryParse(e.key) case final int n)
                  n: <int>[
                    for (final Object? v
                        in e.value is List
                            ? e.value! as List<Object?>
                            : const <Object?>[])
                      if (v is num) v.toInt(),
                  ],
            },
            files: <AiVideoPlacementFile>[
              for (final MapEntry<String, Map<String, Object?>> e
                  in byKey.entries)
                AiVideoPlacementFile(
                  key: e.key,
                  path: '${e.value['path'] ?? e.value['title']}',
                  minutes: (e.value['minutes'] as num?)?.toInt(),
                  boundTo: e.value['boundTo'] as String?,
                  episodeTitle: e.value['episodeTitle'] as String?,
                  episodeMinutes: (e.value['episodeMinutes'] as num?)?.toInt(),
                ),
            ],
          ),
        );
      } on Object catch (error, stack) {
        engineLog.log('libraryCurate.videoStructure.ai', error, stack);
        pass.incomplete = true;
        continue;
      }
      final Map<String, AiVideoPlacementAnswer> answerOf =
          <String, AiVideoPlacementAnswer>{
            for (final AiVideoPlacementAnswer a in answers) a.key: a,
          };
      for (final MapEntry<String, Map<String, Object?>> e in byKey.entries) {
        final Map<String, Object?> f = <String, Object?>{
          ...e.value,
          'work': workId,
        };
        final String uid = '${f['uid']}';
        final AiVideoPlacementAnswer? answer = answerOf[e.key];
        if (answer == null || !answer.isAutoAcceptable) {
          pass.park(f, answer == null ? 'no_answer' : 'unsure');
          continue;
        }
        switch (answer.verdict) {
          case AiVideoPlacementVerdict.unsure:
            pass.park(f, 'unsure');
          case AiVideoPlacementVerdict.special:
            ctx.state.seen.add('structure.ok:$uid');
          case AiVideoPlacementVerdict.episode:
            final _Write w = await _write(
              ctx,
              LibraryCurateOps.videoEpisodePin,
              <String, Object?>{
                'uid': uid,
                'season': answer.season,
                'episode': answer.episode,
                // 自动路径不抢已有绑定：那一集绑着别的本机文件就拒绝、留待确认。
                'ifFree': true,
              },
            );
            if (w.needsConfirmation) {
              pass.park(f, 'needs_confirmation');
            } else if (!w.unavailable &&
                w.result!.errorCode == kVideoEpisodeOccupiedCode) {
              pass.park(f, kVideoEpisodeOccupiedCode);
            } else if (w.unavailable || w.result!.isError) {
              pass.incomplete = true;
              pass.park(f, 'pin_failed');
            } else {
              pass.changes++;
            }
          case AiVideoPlacementVerdict.movie:
            if (workId.startsWith('collection:') && !await _splitOut(pass, f)) {
              continue;
            }
            await _claimAsMovie(pass, f, searchTitle: answer.title);
        }
      }
    }
  }

  Future<void> _structureByRules(
    _StructurePass pass,
    List<Map<String, Object?>> findings,
  ) async {
    final _RunContext ctx = pass.ctx;
    for (final Map<String, Object?> f in findings) {
      if (ctx.isCancelled()) {
        pass.incomplete = true;
        return;
      }
      final String uid = '${f['uid']}';
      if (!_structureOpen(ctx, uid)) continue;
      final String kind = '${f['kind']}';
      if (kind == 'feature_in_specials' && f['episodeMinutes'] != null) {
        if (!await _splitOut(pass, f)) continue;
      } else if (kind != 'movie_as_series') {
        pass.park(f, kind);
        continue;
      }
      await _claimAsMovie(pass, f);
    }
  }

  /// 把文件从它所在的作品合集里拆成独立作品。false = 没拆成（已记待确认 / 未完成）。
  Future<bool> _splitOut(_StructurePass pass, Map<String, Object?> f) async {
    final _Write w = await _write(
      pass.ctx,
      LibraryCurateOps.videoWorkRegroup,
      <String, Object?>{
        'items': <String>['${f['uid']}'],
        'to': 'standalone',
      },
    );
    if (w.needsConfirmation) {
      pass.park(f, 'needs_confirmation');
      return false;
    }
    if (w.unavailable) {
      pass.incomplete = true;
      return false;
    }
    if (w.result!.isError) {
      // 409 = 会把这部作品的成员全部挪走（整个合集都是电影）：留给人 / 助手逐个判断。
      pass.park(f, w.result!.errorCode ?? 'regroup_failed');
      return false;
    }
    if (_list(w.result!.data, 'moved').isEmpty) {
      pass.park(
        f,
        '${_list(w.result!.data, 'skipped').firstOrNull?['reason'] ?? 'unchanged'}',
      );
      return false;
    }
    pass.changes++;
    return true;
  }

  /// 文件自己是一个作品单元（`book:<uid>`）但还没有电影身份：与 ③ 同一口径认领——
  /// 只搜电影形态的候选，唯一且标题强匹配 → 直接认领；多候选 → AI 在候选键里选、
  /// 达到自动采用门槛才认领；其余留待确认。
  Future<void> _claimAsMovie(
    _StructurePass pass,
    Map<String, Object?> f, {
    String? searchTitle,
  }) async {
    final _RunContext ctx = pass.ctx;
    final String bookId = 'book:${f['uid']}';
    if (!pass.canIdentify || ctx.state.suppressed.contains('scrape:$bookId')) {
      pass.park(f, 'needs_identify', ref: bookId);
      return;
    }
    final String title = searchTitle ?? '${f['title'] ?? ''}';
    final AgentToolResult? found = await _read(
      LibraryCurateOps.videoWorkCandidates,
      <String, Object?>{'id': bookId, 'type': 'movie', 'q': ?searchTitle},
    );
    if (found == null || found.isError) {
      pass.incomplete = true;
      pass.park(f, 'needs_identify', ref: bookId);
      return;
    }
    final List<Map<String, Object?>> candidates = <Map<String, Object?>>[
      for (final Map<String, Object?> c in _list(found.data, 'candidates'))
        if (c['mediaKind'] == 'movie') c,
    ];
    Map<String, Object?>? pick;
    if (candidates.length == 1 && _strongTitleMatch(title, candidates[0])) {
      pick = candidates[0];
    } else if (candidates.length > 1 && pass.decide != null) {
      if (!ctx.spend(1)) {
        pass.incomplete = true;
        pass.park(f, 'needs_identify', ref: bookId);
        return;
      }
      pass.requests++;
      try {
        final AiVideoIdentityDecision? decision = await pass.decide!(
          _identityQuery(<String, Object?>{
            'title': title,
            'members': 1,
          }, candidates),
        );
        if (decision != null && decision.isAutoAcceptable) {
          for (final Map<String, Object?> c in candidates) {
            if ('${c['identity']}' == decision.key) pick = c;
          }
        }
      } on Object catch (error, stack) {
        engineLog.log('libraryCurate.videoStructure.identify', error, stack);
        pass.incomplete = true;
      }
    }
    if (pick == null) {
      pass.park(
        f,
        candidates.isEmpty ? 'no_candidates' : 'ambiguous',
        ref: bookId,
      );
      return;
    }
    final _Write w =
        await _write(ctx, LibraryCurateOps.videoWorkIdentify, <String, Object?>{
          'id': bookId,
          'provider': pick['provider'],
          'externalId': '${pick['externalId']}',
          'type': 'movie',
        });
    if (w.needsConfirmation) {
      pass.park(f, 'needs_confirmation', ref: bookId);
    } else if (w.unavailable || w.result!.isError) {
      pass.incomplete = true;
      pass.park(f, 'needs_identify', ref: bookId);
    } else {
      pass.changes++;
    }
  }

  // ── ③ 认身份 + 刮削（视频待确认作品） ──────────────────────────────

  /// spec §6：单候选且标题强匹配 → 直接认领；多候选 → AI 在候选键里选、达到自动
  /// 采用门槛才认领；其余留在待确认。批量刮削已经问过 AI 且被拒（`declined`）的
  /// 不再重问。书 / 漫画 / 游戏是紧接着的两个阶段（[_scrapeBooks] / [_scrapeGames]）。
  Future<LibraryCurateStageResult> _scrape(_RunContext ctx) async {
    const LibraryCurateStage stage = LibraryCurateStage.scrape;
    if (toolbox.describeTool(LibraryCurateOps.videoWorkIdentify) == null ||
        toolbox.describeTool(LibraryCurateOps.videoWorkCandidates) == null) {
      return const LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'unavailable',
      );
    }
    if (!ctx.ai.videoIdentify) {
      // spec §9：这一步的指派没配就跳过（资料源搜索也不发）。
      return const LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'no_provider',
      );
    }
    final AgentToolResult? listed = await _read(
      LibraryCurateOps.videoWorkList,
      const <String, Object?>{'pending': true},
    );
    if (listed == null) {
      return const LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'unavailable',
      );
    }
    if (listed.isError) {
      return LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.failed,
        error: listed.errorCode,
      );
    }
    final bool auto = ctx.run.trigger == LibraryCurateTrigger.auto;
    final Set<String> progress = ctx.progressOf(stage);
    final List<Map<String, Object?>> works = <Map<String, Object?>>[
      for (final Map<String, Object?> w in _list(listed.data, 'works'))
        if (!ctx.state.suppressed.contains('scrape:${w['id']}') &&
            !progress.contains('${w['id']}') &&
            !(auto && ctx.state.seen.contains('scrape:${w['id']}')))
          w,
    ];
    final AiVideoIdentityDecider? decide = videoDecider?.call();
    int changes = 0;
    int requests = 0;
    int pending = 0;
    bool incomplete = false;
    int examined = 0;
    for (final Map<String, Object?> work in works) {
      if (ctx.isCancelled()) {
        incomplete = true;
        break;
      }
      if (auto && examined >= limits.autoMaxScrapeWorks) {
        incomplete = true;
        break;
      }
      examined++;
      final String id = '${work['id']}';
      final String title = '${work['title'] ?? id}';
      final Map<String, Object?> note = _map(work['note']);
      final AgentToolResult? found = await _read(
        LibraryCurateOps.videoWorkCandidates,
        <String, Object?>{'id': id},
      );
      if (found == null || found.isError) {
        incomplete = true;
        continue;
      }
      final List<Map<String, Object?>> candidates = _list(
        found.data,
        'candidates',
      );
      Map<String, Object?>? pick;
      if (candidates.length == 1 && _strongTitleMatch(title, candidates[0])) {
        pick = candidates[0];
      } else if (candidates.length > 1 &&
          decide != null &&
          note['ai'] != 'declined') {
        if (!ctx.spend(1)) {
          incomplete = true;
          break;
        }
        requests++;
        final AiVideoIdentityDecision? decision;
        try {
          decision = await decide(_identityQuery(work, candidates));
        } on Object catch (error, stack) {
          engineLog.log('libraryCurate.scrape.ai', error, stack);
          incomplete = true;
          continue;
        }
        if (decision != null && decision.isAutoAcceptable) {
          for (final Map<String, Object?> c in candidates) {
            if ('${c['identity']}' == decision.key) pick = c;
          }
        }
      }
      if (pick == null) {
        pending++;
        ctx.state.seen.add('scrape:$id');
        progress.add(id);
        ctx.run.pendingItems.add(
          LibraryCuratePendingItem(
            stage: stage,
            kind: 'scrape_pending',
            title: title,
            ref: id,
            reason: candidates.isEmpty ? 'no_candidates' : 'ambiguous',
          ),
        );
        continue;
      }
      final _Write w = await _write(
        ctx,
        LibraryCurateOps.videoWorkIdentify,
        <String, Object?>{
          'id': id,
          'provider': pick['provider'],
          'externalId': '${pick['externalId']}',
          if (pick['mediaKind'] == 'movie' || pick['mediaKind'] == 'tv')
            'type': pick['mediaKind'],
        },
      );
      if (w.needsConfirmation) {
        pending++;
        ctx.run.pendingItems.add(
          LibraryCuratePendingItem(
            stage: stage,
            kind: 'needs_confirmation',
            title: title,
            ref: id,
          ),
        );
        progress.add(id);
        continue;
      }
      if (w.unavailable || w.result!.isError) {
        incomplete = true;
        continue;
      }
      changes++;
      progress.add(id);
    }
    return LibraryCurateStageResult(
      stage: stage,
      status: incomplete
          ? LibraryCurateStageStatus.partial
          : LibraryCurateStageStatus.done,
      changes: changes,
      pending: pending,
      requests: requests,
      error: incomplete && ctx.capped ? 'request_cap' : null,
    );
  }

  static bool _strongTitleMatch(String local, Map<String, Object?> candidate) {
    final String l = foldMediaTitle(local);
    if (l.isEmpty) return false;
    for (final Object? t in <Object?>[
      candidate['title'],
      candidate['originalTitle'],
    ]) {
      if (t is String && foldMediaTitle(t) == l) return true;
    }
    return false;
  }

  static AiVideoIdentityQuery _identityQuery(
    Map<String, Object?> work,
    List<Map<String, Object?>> candidates,
  ) => AiVideoIdentityQuery(
    localTitles: <String>['${work['title'] ?? ''}'],
    episodeCount: (work['members'] as num?)?.toInt(),
    candidates: <AiVideoIdentityCandidate>[
      for (final Map<String, Object?> c in candidates)
        AiVideoIdentityCandidate(
          key: '${c['identity']}',
          titles: <String>[
            if (c['title'] is String) c['title']! as String,
            if (c['originalTitle'] is String) c['originalTitle']! as String,
          ],
          mediaKind: c['mediaKind'] == 'movie'
              ? VideoMetadataMediaKind.movie
              : VideoMetadataMediaKind.tv,
          year: (c['year'] as num?)?.toInt(),
          episodeCount: (c['episodes'] as num?)?.toInt(),
        ),
    ],
  );

  // ── ③ 书 / 漫画刮削 ───────────────────────────────────────────────────

  /// spec §6：缺元数据的书（判据见 [looksLikeFileNameTitle] 与
  /// [DatabaseLibraryCurateFacts.bookScrapeUnits]）用 `book.scrape.search` 取候选：
  /// 候选唯一且标题规范化后一致（或按 ISBN / DLsite 编号精确查到唯一一条）→ 直接写回；
  /// 多候选 → AI 在候选键里选、达到自动采用门槛才写回；其余留「待确认」。
  ///
  /// 一套系列（同一合集里两本以上缺资料的书）按系列名只查一次、只问一次 AI；选中后
  /// 各卷各自按卷名查一次取封面（只认唯一强匹配，不问 AI）。写回一律带 `onlyEmpty`：
  /// 只填空缺字段，不覆盖显示名覆盖 / 已有作者 / 已有 override 封面（这三处都没有
  /// 「谁设的」标记，空着才填是唯一不碰用户值的口径）。
  Future<LibraryCurateStageResult> _scrapeBooks(_RunContext ctx) async {
    const LibraryCurateStage stage = LibraryCurateStage.scrapeBooks;
    if (toolbox.describeTool(LibraryCurateOps.bookScrapeSearch) == null ||
        toolbox.describeTool(LibraryCurateOps.bookScrapeApply) == null) {
      return const LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'unavailable',
      );
    }
    final bool auto = ctx.run.trigger == LibraryCurateTrigger.auto;
    final Set<String> progress = ctx.progressOf(stage);
    final List<LibraryCurateBookUnit> units = _openBookUnits(
      await facts.bookScrapeUnits(_since(stage, ctx)),
      ctx.state,
      progress: progress,
      auto: auto,
    );
    final AiMediaIdentityDecider? decide = ctx.ai.videoIdentify
        ? mediaDecider?.call()
        : null;
    int changes = 0;
    int requests = 0;
    int pending = 0;
    bool incomplete = false;
    int examined = 0;
    for (final LibraryCurateBookUnit unit in units) {
      if (ctx.isCancelled()) {
        incomplete = true;
        break;
      }
      if (auto && examined >= limits.autoMaxBookUnits) {
        incomplete = true;
        break;
      }
      examined++;
      final (String? source, String query, bool exact) = bookScrapeQueryOf(
        unit,
      );
      final List<Map<String, Object?>>? candidates = await _bookCandidates(
        source,
        query,
      );
      if (candidates == null) {
        incomplete = true;
        continue;
      }
      Map<String, Object?>? pick;
      String reason = candidates.isEmpty ? 'no_candidates' : 'ambiguous';
      if (candidates.length == 1 &&
          (exact || _strongBookMatch(unit.title, candidates[0]))) {
        pick = candidates[0];
      } else if (candidates.length > 1 && decide != null) {
        if (!ctx.spend(1)) {
          incomplete = true;
          break;
        }
        requests++;
        final AiVideoIdentityDecision? decision;
        try {
          decision = await decide(_bookQuery(unit, candidates));
        } on Object catch (error, stack) {
          engineLog.log('libraryCurate.scrapeBooks.ai', error, stack);
          incomplete = true;
          continue;
        }
        if (decision != null && decision.isAutoAcceptable) {
          for (final Map<String, Object?> c in candidates) {
            if (_bookCandidateKey(c) == decision.key) pick = c;
          }
        } else if (decision?.key != null) {
          reason = 'low_confidence';
        }
      }
      if (pick == null) {
        pending++;
        ctx.state.seen.add('scrape.books:${unit.id}');
        progress.add(unit.id);
        ctx.run.pendingItems.add(
          LibraryCuratePendingItem(
            stage: stage,
            kind: 'book_scrape_pending',
            title: unit.title,
            ref: unit.volumes.length == 1
                ? unit.volumes.single.shelfKey
                : unit.id,
            reason: reason,
          ),
        );
        continue;
      }
      bool unitFailed = false;
      for (final LibraryCurateBookVolume volume in unit.volumes) {
        if (ctx.isCancelled()) {
          unitFailed = true;
          break;
        }
        // 写哪条候选、写哪些字段：单本直接用选中的候选；系列里各卷按卷名再查一次
        // 取封面（唯一强匹配），作者用系列候选的。
        final List<(Map<String, Object?>, List<String>)> writes =
            <(Map<String, Object?>, List<String>)>[];
        if (!unit.isSeries) {
          writes.add((pick, _bookFields(volume, pick, title: true)));
        } else {
          Map<String, Object?>? own;
          if (volume.missingCover) {
            final List<Map<String, Object?>>? found = await _bookCandidates(
              source,
              volume.title,
            );
            if (found == null) {
              unitFailed = true;
              continue;
            }
            final List<Map<String, Object?>> strong = <Map<String, Object?>>[
              for (final Map<String, Object?> c in found)
                if (_strongBookMatch(volume.title, c)) c,
            ];
            if (strong.length == 1) own = strong.single;
          }
          if (own != null) {
            writes.add((own, _bookFields(volume, own, title: false)));
          } else {
            writes.add((
              pick,
              <String>[
                if (volume.missingAuthor && _hasText(pick['author'])) 'author',
              ],
            ));
          }
        }
        bool volumeFailed = false;
        for (final (Map<String, Object?> c, List<String> fields) in writes) {
          if (fields.isEmpty) continue;
          final _Write w = await _write(
            ctx,
            LibraryCurateOps.bookScrapeApply,
            <String, Object?>{
              'key': volume.shelfKey,
              'id': '${c['id']}',
              if (c['source'] is String) 'source': c['source'],
              'fields': fields,
              'onlyEmpty': true,
            },
          );
          if (w.needsConfirmation) {
            pending++;
            ctx.run.pendingItems.add(
              LibraryCuratePendingItem(
                stage: stage,
                kind: 'needs_confirmation',
                title: volume.title,
                ref: volume.shelfKey,
              ),
            );
            continue;
          }
          if (w.unavailable) {
            volumeFailed = true;
            continue;
          }
          final AgentToolResult r = w.result!;
          // 422：要写的字段都已有值（`onlyEmpty` 全滤掉了）——不是失败，没东西写。
          if (r.isError && r.errorCode != 'rejected') {
            volumeFailed = true;
            continue;
          }
          if (!r.isError) changes++;
        }
        if (volumeFailed) {
          unitFailed = true;
        } else {
          ctx.state.seen.add(_bookDoneKey(volume));
        }
      }
      if (unitFailed) {
        incomplete = true;
      } else {
        progress.add(unit.id);
      }
    }
    return LibraryCurateStageResult(
      stage: stage,
      status: incomplete
          ? LibraryCurateStageStatus.partial
          : LibraryCurateStageStatus.done,
      changes: changes,
      pending: pending,
      requests: requests,
      error: incomplete && ctx.capped ? 'request_cap' : null,
    );
  }

  /// 还要处理的书单元：去掉撤销过（抑制）/ 已经写回过的卷，去掉这一水位下已处理的
  /// 单元；自动路径另跳过查过但留在待确认的单元（手动照样重看）。
  static List<LibraryCurateBookUnit> _openBookUnits(
    List<LibraryCurateBookUnit> all,
    LibraryCurateState state, {
    required Set<String>? progress,
    required bool auto,
  }) => <LibraryCurateBookUnit>[
    for (final LibraryCurateBookUnit u in all)
      if (!(progress?.contains(u.id) ?? false) &&
          !(auto && state.seen.contains('scrape.books:${u.id}')))
        ?u.only(
          (LibraryCurateBookVolume v) =>
              !state.suppressed.contains('scrape.books:${v.shelfKey}') &&
              !state.seen.contains(_bookDoneKey(v)),
        ),
  ];

  static String _bookDoneKey(LibraryCurateBookVolume v) =>
      'scrape.books.done:${v.shelfKey}';

  /// `book.scrape.search` 一次；读不到 / 出错为 null。
  Future<List<Map<String, Object?>>?> _bookCandidates(
    String? source,
    String query,
  ) async {
    final AgentToolResult? found = await _read(
      LibraryCurateOps.bookScrapeSearch,
      <String, Object?>{'query': query, 'source': ?source},
    );
    if (found == null || found.isError) return null;
    return _list(found.data, 'candidates');
  }

  /// 单本要写的字段：只列空缺的、候选能给的。
  static List<String> _bookFields(
    LibraryCurateBookVolume volume,
    Map<String, Object?> c, {
    required bool title,
  }) => <String>[
    if (volume.missingCover && _hasText(c['coverUrl'])) 'cover',
    if (volume.missingAuthor && _hasText(c['author'])) 'author',
    if (title && volume.fileNameTitle && _hasText(c['title'])) 'title',
  ];

  static bool _hasText(Object? v) => v is String && v.trim().isNotEmpty;

  static String _bookCandidateKey(Map<String, Object?> c) =>
      '${c['source']}:${c['id']}';

  static bool _strongBookMatch(String local, Map<String, Object?> c) {
    final String l = foldMediaTitle(local);
    if (l.isEmpty) return false;
    for (final Object? t in <Object?>[c['title'], c['originalTitle']]) {
      if (t is String && foldMediaTitle(t) == l) return true;
    }
    return false;
  }

  static AiMediaIdentityQuery _bookQuery(
    LibraryCurateBookUnit unit,
    List<Map<String, Object?>> candidates,
  ) => AiMediaIdentityQuery(
    kind: AiMediaIdentityKind.book,
    localTitles: <String>[unit.title],
    creator: unit.author,
    volumeCount: unit.isSeries ? unit.volumes.length : null,
    candidates: <AiMediaIdentityCandidate>[
      for (final Map<String, Object?> c in candidates)
        AiMediaIdentityCandidate(
          key: _bookCandidateKey(c),
          titles: <String>[
            if (c['title'] is String) c['title']! as String,
            if (c['originalTitle'] is String) c['originalTitle']! as String,
          ],
          creator: c['author'] as String?,
          year: (c['year'] as num?)?.toInt(),
          series: c['series'] as String?,
          volume: c['volume'] == null ? null : '${c['volume']}',
        ),
    ],
  );

  // ── ③ 游戏刮削 ───────────────────────────────────────────────────────

  /// spec §6：没有任何资料源快照的游戏（已有来源快照的不重刮）用 `game.scrape.search`
  /// 取候选（各资料源一起查，同一款游戏会在不同源各出一条）：标题规范化后一致的
  /// 候选每个源至多一条 → 认第一条；否则多候选交 AI 选；其余留「待确认」。写回走
  /// `game.scrape.apply`（可撤销）且带 `keepCover`：游戏已有封面（用户导入 / 自动取的）
  /// 不替换，只在没有封面时补图。
  Future<LibraryCurateStageResult> _scrapeGames(_RunContext ctx) async {
    const LibraryCurateStage stage = LibraryCurateStage.scrapeGames;
    if (toolbox.describeTool(LibraryCurateOps.gameScrapeSearch) == null ||
        toolbox.describeTool(LibraryCurateOps.gameScrapeApply) == null) {
      return const LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'unavailable',
      );
    }
    final bool auto = ctx.run.trigger == LibraryCurateTrigger.auto;
    final Set<String> progress = ctx.progressOf(stage);
    final List<LibraryCurateGameUnit> units = <LibraryCurateGameUnit>[
      for (final LibraryCurateGameUnit g in await facts.gameScrapeUnits(
        _since(stage, ctx),
      ))
        if (!progress.contains(g.id) &&
            !ctx.state.suppressed.contains('scrape.games:${g.id}') &&
            !(auto && ctx.state.seen.contains('scrape.games:${g.id}')))
          g,
    ];
    final AiMediaIdentityDecider? decide = ctx.ai.videoIdentify
        ? mediaDecider?.call()
        : null;
    int changes = 0;
    int requests = 0;
    int pending = 0;
    bool incomplete = false;
    int examined = 0;
    for (final LibraryCurateGameUnit game in units) {
      if (ctx.isCancelled()) {
        incomplete = true;
        break;
      }
      if (auto && examined >= limits.autoMaxGameUnits) {
        incomplete = true;
        break;
      }
      examined++;
      final AgentToolResult? found = await _read(
        LibraryCurateOps.gameScrapeSearch,
        <String, Object?>{'id': game.id},
      );
      if (found == null || found.isError) {
        incomplete = true;
        continue;
      }
      final List<Map<String, Object?>> candidates = _list(
        found.data,
        'candidates',
      );
      Map<String, Object?>? pick = pickStrongGameCandidate(
        game.title,
        candidates,
      );
      String reason = candidates.isEmpty ? 'no_candidates' : 'ambiguous';
      if (pick == null && candidates.length > 1 && decide != null) {
        if (!ctx.spend(1)) {
          incomplete = true;
          break;
        }
        requests++;
        final AiVideoIdentityDecision? decision;
        try {
          decision = await decide(_gameQuery(game, candidates));
        } on Object catch (error, stack) {
          engineLog.log('libraryCurate.scrapeGames.ai', error, stack);
          incomplete = true;
          continue;
        }
        if (decision != null && decision.isAutoAcceptable) {
          for (final Map<String, Object?> c in candidates) {
            if ('${c['id']}' == decision.key) pick = c;
          }
        } else if (decision?.key != null) {
          reason = 'low_confidence';
        }
      }
      if (pick == null) {
        pending++;
        ctx.state.seen.add('scrape.games:${game.id}');
        progress.add(game.id);
        ctx.run.pendingItems.add(
          LibraryCuratePendingItem(
            stage: stage,
            kind: 'game_scrape_pending',
            title: game.title,
            ref: 'game:${game.id}',
            reason: reason,
          ),
        );
        continue;
      }
      final _Write w = await _write(
        ctx,
        LibraryCurateOps.gameScrapeApply,
        <String, Object?>{
          'id': game.id,
          'candidate': '${pick['id']}',
          'keepCover': true,
        },
      );
      if (w.needsConfirmation) {
        pending++;
        progress.add(game.id);
        ctx.run.pendingItems.add(
          LibraryCuratePendingItem(
            stage: stage,
            kind: 'needs_confirmation',
            title: game.title,
            ref: 'game:${game.id}',
          ),
        );
        continue;
      }
      if (w.unavailable || w.result!.isError) {
        incomplete = true;
        continue;
      }
      changes++;
      progress.add(game.id);
    }
    return LibraryCurateStageResult(
      stage: stage,
      status: incomplete
          ? LibraryCurateStageStatus.partial
          : LibraryCurateStageStatus.done,
      changes: changes,
      pending: pending,
      requests: requests,
      error: incomplete && ctx.capped ? 'request_cap' : null,
    );
  }

  static AiMediaIdentityQuery _gameQuery(
    LibraryCurateGameUnit game,
    List<Map<String, Object?>> candidates,
  ) => AiMediaIdentityQuery(
    kind: AiMediaIdentityKind.game,
    localTitles: <String>[game.title],
    candidates: <AiMediaIdentityCandidate>[
      for (final Map<String, Object?> c in candidates)
        AiMediaIdentityCandidate(
          key: '${c['id']}',
          titles: <String>[
            if (c['name'] is String) c['name']! as String,
            if (c['nameCn'] is String) c['nameCn']! as String,
          ],
          year: int.tryParse('${c['releaseDate'] ?? ''}'.split('-').first),
        ),
    ],
  );

  // ── ④ 关系推断 ────────────────────────────────────────────────────────

  Future<LibraryCurateStageResult> _links(_RunContext ctx) async {
    const LibraryCurateStage stage = LibraryCurateStage.links;
    if (toolbox.describeTool(LibraryCurateOps.linksInfer) == null) {
      return const LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'unavailable',
      );
    }
    if (!ctx.ai.mediaLinks) {
      return const LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'no_provider',
      );
    }
    final Set<String> progress = ctx.progressOf(stage);
    final List<String> endpoints = <String>[
      for (final String e in await facts.linkEndpointsSince(_since(stage, ctx)))
        if (!progress.contains(e) && !ctx.state.suppressed.contains('links:$e'))
          e,
    ];
    final bool auto = ctx.run.trigger == LibraryCurateTrigger.auto;
    int changes = 0;
    int pending = 0;
    int requests = 0;
    bool incomplete = false;
    int processed = 0;
    for (int i = 0; i < endpoints.length; i += limits.linkBatchSize) {
      if (ctx.isCancelled()) {
        incomplete = true;
        break;
      }
      List<String> batch = endpoints.sublist(
        i,
        (i + limits.linkBatchSize).clamp(0, endpoints.length),
      );
      if (auto) {
        final int room = limits.autoMaxLinkEndpoints - processed;
        if (room <= 0) {
          incomplete = true;
          break;
        }
        if (batch.length > room) batch = batch.sublist(0, room);
      }
      // 每个端点最多一次 AI 裁决：按端点数预扣。
      if (!ctx.spend(batch.length)) {
        incomplete = true;
        break;
      }
      final _Write w = await _write(
        ctx,
        LibraryCurateOps.linksInfer,
        <String, Object?>{'items': batch, 'trigger': auto ? 'auto' : 'manual'},
      );
      if (w.unavailable || w.needsConfirmation) {
        incomplete = true;
        break;
      }
      final AgentToolResult r = w.result!;
      if (r.isError) {
        incomplete = true;
        continue;
      }
      final Map<String, Object?> data = _map(r.data);
      changes += _int(data['applied']);
      pending += _int(data['suggested']);
      requests += _int(data['requests']);
      final Set<String> failed = <String>{
        for (final Object? f in (data['failed'] as List?) ?? const <Object?>[])
          '$f',
      };
      if (failed.isNotEmpty) incomplete = true;
      for (final String e in batch) {
        if (!failed.contains(e)) progress.add(e);
      }
      processed += batch.length;
    }
    // 被取消 / 单趟上限截断、或有端点失败：没进度的下一趟接着做。
    if (endpoints.any((String e) => !progress.contains(e))) incomplete = true;
    ctx.newLinkEndpoints += processed;
    return LibraryCurateStageResult(
      stage: stage,
      status: incomplete
          ? LibraryCurateStageStatus.partial
          : LibraryCurateStageStatus.done,
      changes: changes,
      pending: pending,
      requests: requests,
      error: incomplete && ctx.capped ? 'request_cap' : null,
    );
  }

  Future<LibraryCurateStageResult> _music(_RunContext ctx) async {
    const LibraryCurateStage stage = LibraryCurateStage.music;
    if (toolbox.describeTool(LibraryCurateOps.linksMusic) == null) {
      return const LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: 'unavailable',
      );
    }
    final int? since = _since(stage, ctx);
    if (since != null &&
        ctx.newLinkEndpoints == 0 &&
        !await facts.musicChangedSince(since)) {
      return const LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.done,
      );
    }
    // 声纹命中 / 本地标题的确定性部分不联网、不花钱，没指派 AI 也跑；AI 裁决只在
    // 指派了「作品关联」且没碰到单趟上限时开。
    final bool useAi = ctx.ai.mediaLinks && ctx.spend(1);
    final _Write w =
        await _write(ctx, LibraryCurateOps.linksMusic, <String, Object?>{
          'trigger': ctx.run.trigger == LibraryCurateTrigger.auto
              ? 'auto'
              : 'manual',
          'useAi': useAi,
        });
    if (w.unavailable || w.needsConfirmation) {
      return LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.skipped,
        error: w.unavailable ? 'unavailable' : 'needs_confirmation',
      );
    }
    final AgentToolResult r = w.result!;
    if (r.isError) {
      return LibraryCurateStageResult(
        stage: stage,
        status: LibraryCurateStageStatus.failed,
        error: r.errorCode,
      );
    }
    final Map<String, Object?> data = _map(r.data);
    final bool aiSkipped = ctx.ai.mediaLinks && !useAi;
    return LibraryCurateStageResult(
      stage: stage,
      status: aiSkipped
          ? LibraryCurateStageStatus.partial
          : LibraryCurateStageStatus.done,
      changes: _int(data['applied']),
      pending: _int(data['suggested']),
      requests: _int(data['requests']),
      error: aiSkipped ? 'request_cap' : null,
      note: useAi ? null : 'rules_only',
    );
  }

  // ── ⑤ 作品层 ─────────────────────────────────────────────────────────

  Future<LibraryCurateStageResult> _works(_RunContext ctx) async {
    final Future<CollectionRelationBackfillResult> Function()? backfill =
        seriesRelationBackfill;
    int relationRows = 0;
    if (backfill != null) {
      try {
        final CollectionRelationBackfillResult r = await backfill();
        relationRows = r.rows + r.bound;
        engineLog.logDiagnostic(
          'libraryCurate.works',
          'series relations backfill: works=${r.works} '
              'withRelations=${r.worksWithRelations} rows=${r.rows} '
              'bound=${r.bound}',
        );
      } on Object catch (error, stack) {
        // 补填失败不拖垮作品层重算（关系网只是少画几条系列边）。
        engineLog.log('libraryCurate.works.relations', error, stack);
      }
    }
    final WorkGraph graph = await loadWorkGraph(db);
    if (ctx.run.changes > 0 || relationRows > 0) onWorksChanged?.call();
    return LibraryCurateStageResult(
      stage: LibraryCurateStage.works,
      status: LibraryCurateStageStatus.done,
      note: '${graph.works.length}',
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // 费用预估
  // ─────────────────────────────────────────────────────────────────────

  /// 手动触发前的估算（只读：读库，不发 AI 请求、不联网）。视频待确认作品数经
  /// `video.work.list`（读本机待确认表）。
  Future<LibraryCurateEstimate> estimate({bool full = false}) async {
    final LibraryCurateState state = await store.load();
    final LibraryCurateAiAvailability a = ai();
    int? since(LibraryCurateStage s) => full ? null : state.watermarks[s.wire];
    final Map<LibraryCurateStage, int> requests = <LibraryCurateStage, int>{};
    final Map<LibraryCurateStage, int> items = <LibraryCurateStage, int>{};
    for (final (LibraryCurateStage stage, CollectionShelfDomain domain)
        in const <(LibraryCurateStage, CollectionShelfDomain)>[
          (LibraryCurateStage.organizeBooks, CollectionShelfDomain.books),
          (LibraryCurateStage.organizeManga, CollectionShelfDomain.manga),
          (LibraryCurateStage.organizeVideo, CollectionShelfDomain.video),
          (LibraryCurateStage.organizeGames, CollectionShelfDomain.games),
        ]) {
      if (toolbox.describeTool(LibraryCurateOps.organizeRun) == null) continue;
      final Set<String>? only = await facts.organizeEntriesSince(
        domain,
        since(stage),
      );
      if (only != null && only.isEmpty) continue;
      final int chunks = await facts.organizeRequestEstimate(domain, only);
      items[stage] = only?.length ?? chunks;
      if (a.organize) requests[stage] = chunks;
    }
    if (a.videoIdentify) {
      final AgentToolResult? listed = await _read(
        LibraryCurateOps.videoWorkList,
        const <String, Object?>{'pending': true},
      );
      if (listed != null && !listed.isError) {
        final int n = <Map<String, Object?>>[
          for (final Map<String, Object?> w in _list(listed.data, 'works'))
            if (!state.suppressed.contains('scrape:${w['id']}') &&
                _map(w['note'])['ai'] != 'declined')
              w,
        ].length;
        items[LibraryCurateStage.scrape] = n;
        requests[LibraryCurateStage.scrape] = n;
      }
    }
    if (toolbox.describeTool(LibraryCurateOps.videoWorkRegroup) != null) {
      final AgentToolResult? audit = await _read(
        LibraryCurateOps.videoLibraryAudit,
        // 预估只读已有时长缓存：探测留给真正执行的那一趟。
        const <String, Object?>{'detail': true, 'probe': false},
      );
      if (audit != null && !audit.isError) {
        bool open(Object? uid) =>
            !state.suppressed.contains('structure:$uid') &&
            (full || !state.seen.contains('structure.ok:$uid'));
        final bool model = a.videoIdentify && placementJudge?.call() != null;
        // 模型判断：每部有待看文件的作品一次请求；时长判据不花请求。
        final int worksToAsk = <Map<String, Object?>>[
          for (final Map<String, Object?> w in _list(audit.data, 'works'))
            if (_list(
              w,
              'files',
            ).any((Map<String, Object?> f) => open(f['uid'])))
              w,
        ].length;
        final int flagged = <Map<String, Object?>>[
          for (final Map<String, Object?> f in _list(audit.data, 'findings'))
            if (open(f['uid'])) f,
        ].length;
        final int n = model ? worksToAsk : flagged;
        if (n > 0) {
          items[LibraryCurateStage.videoStructure] = n;
          if (model) requests[LibraryCurateStage.videoStructure] = n;
        }
      }
    }
    // 书 / 游戏：每个单元一次资料源搜索，最多一次 AI 消歧（没指派 AI 时为 0）。
    if (toolbox.describeTool(LibraryCurateOps.bookScrapeSearch) != null &&
        toolbox.describeTool(LibraryCurateOps.bookScrapeApply) != null) {
      final int n = _openBookUnits(
        await facts.bookScrapeUnits(since(LibraryCurateStage.scrapeBooks)),
        state,
        progress: null,
        auto: false,
      ).length;
      if (n > 0) {
        items[LibraryCurateStage.scrapeBooks] = n;
        if (a.videoIdentify && mediaDecider?.call() != null) {
          requests[LibraryCurateStage.scrapeBooks] = n;
        }
      }
    }
    if (toolbox.describeTool(LibraryCurateOps.gameScrapeSearch) != null &&
        toolbox.describeTool(LibraryCurateOps.gameScrapeApply) != null) {
      final int n = <LibraryCurateGameUnit>[
        for (final LibraryCurateGameUnit g in await facts.gameScrapeUnits(
          since(LibraryCurateStage.scrapeGames),
        ))
          if (!state.suppressed.contains('scrape.games:${g.id}')) g,
      ].length;
      if (n > 0) {
        items[LibraryCurateStage.scrapeGames] = n;
        if (a.videoIdentify && mediaDecider?.call() != null) {
          requests[LibraryCurateStage.scrapeGames] = n;
        }
      }
    }
    if (a.mediaLinks &&
        toolbox.describeTool(LibraryCurateOps.linksInfer) != null) {
      final int n = <String>[
        for (final String e in await facts.linkEndpointsSince(
          since(LibraryCurateStage.links),
        ))
          if (!state.suppressed.contains('links:$e')) e,
      ].length;
      items[LibraryCurateStage.links] = n;
      requests[LibraryCurateStage.links] = n;
    }
    if (toolbox.describeTool(LibraryCurateOps.linksMusic) != null &&
        await facts.musicChangedSince(since(LibraryCurateStage.music))) {
      items[LibraryCurateStage.music] = 1;
      if (a.mediaLinks) requests[LibraryCurateStage.music] = 1;
    }
    return LibraryCurateEstimate(
      requestsByStage: requests,
      itemsByStage: items,
      full: full,
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // 整趟撤销
  // ─────────────────────────────────────────────────────────────────────

  /// 按 runId 撤销这一趟的全部写入：取 `ai_agent_actions` 里会话 `curator:<runId>`
  /// 的记录，**新的先撤**（连接 → 认领 → 合集改动，正好是写入的逆序：后一步可能
  /// 依赖前一步的结果，倒着撤才不会撤到一半撞上依赖）。每条照常走目录的撤销
  /// （之后被用户改过的部分报 superseded、保留现值）。
  ///
  /// 撤掉的认领与推断入口记进 [LibraryCurateState.suppressed]：下一趟（自动或手动）
  /// 不再把同一部作品 / 同一本书 / 同一款游戏原样认领回来、不再对同一端点重推。
  Future<LibraryCurateUndoResult> undoRun(int runId) async {
    if (_current?.id == runId) throw LibraryCurateBusy(runId);
    final List<AiAgentActionRow> actions = await db.listAiAgentActions(
      sessionId: libraryCurateSessionId(runId),
      limit: 1 << 30,
    );
    int undone = 0;
    int superseded = 0;
    int failed = 0;
    int skipped = 0;
    final Set<String> suppress = <String>{};
    for (final AiAgentActionRow row in actions) {
      if (row.undoPayloadJson == null || row.undoneAt != null) {
        skipped++;
        continue;
      }
      final AgentUndoResult r = await toolbox.undo('${row.id}');
      switch (r.status) {
        case AgentUndoStatus.done:
        case AgentUndoStatus.partial:
          undone++;
          suppress.addAll(_suppressionKeys(row));
        case AgentUndoStatus.superseded:
          superseded++;
        case AgentUndoStatus.failed:
          failed++;
        case AgentUndoStatus.notUndoable:
          skipped++;
      }
    }
    final LibraryCurateState state = await store.load();
    state.suppressed.addAll(suppress);
    final LibraryCurateRun? run = state.runById(runId);
    if (run != null && failed == 0) {
      run.undoneAt = _clock().millisecondsSinceEpoch;
      state.upsertRun(run);
    }
    await store.save(state);
    if (undone > 0) onWorksChanged?.call();
    return LibraryCurateUndoResult(
      runId: runId,
      undone: undone,
      superseded: superseded,
      failed: failed,
      skipped: skipped,
    );
  }

  static Iterable<String> _suppressionKeys(AiAgentActionRow row) sync* {
    final Map<String, Object?> args = _map(_decode(row.argsJson));
    switch (row.opId) {
      case LibraryCurateOps.videoWorkIdentify:
        if (args['id'] != null) yield 'scrape:${args['id']}';
      case LibraryCurateOps.videoWorkRegroup:
        for (final Object? e in (args['items'] as List?) ?? const <Object?>[]) {
          yield 'structure:$e';
        }
      case LibraryCurateOps.videoEpisodePin:
        if (args['uid'] != null) yield 'structure:${args['uid']}';
      case LibraryCurateOps.linksInfer:
        for (final Object? e in (args['items'] as List?) ?? const <Object?>[]) {
          yield 'links:$e';
        }
      case LibraryCurateOps.bookScrapeApply:
        if (args['key'] != null) yield 'scrape.books:${args['key']}';
      case LibraryCurateOps.gameScrapeApply:
        if (args['id'] != null) yield 'scrape.games:${args['id']}';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// ③ 书 / 游戏刮削的单元与判据
// ─────────────────────────────────────────────────────────────────────────

/// 一本缺元数据的书（`epub_books` 一行：EPUB / PDF / 漫画）。
class LibraryCurateBookVolume {
  const LibraryCurateBookVolume({
    required this.bookKey,
    required this.title,
    this.author,
    this.isbn,
    required this.missingCover,
    required this.fileNameTitle,
  });

  final String bookKey;
  final String title;
  final String? author;

  /// ISBN-13（包里解析出来的；没有为 null）。
  final String? isbn;

  /// 书本身没有封面（`epub_books.cover_path` 为空）。
  final bool missingCover;

  /// 书名明显是文件名（[looksLikeFileNameTitle]）。
  final bool fileNameTitle;

  bool get missingAuthor => author == null || author!.trim().isEmpty;

  /// 缺任何一项就算「缺元数据」。
  bool get missing => missingCover || missingAuthor || fileNameTitle;

  /// 书架键（`library.list` / `book.scrape.apply` 的 `key`）。
  String get shelfKey => 'book:$bookKey';
}

/// 一个刮削单元：一套系列（同一合集里两本以上缺资料的书，按合集查一次）或一本单书。
class LibraryCurateBookUnit {
  const LibraryCurateBookUnit({
    required this.id,
    required this.title,
    required this.volumes,
    this.author,
    this.isSeries = false,
  });

  /// `collection:<id>` / `book:<bookKey>`（进度 / 待确认的键）。
  final String id;

  /// 查询用的标题：系列 = 合集名，单书 = 书名。
  final String title;
  final String? author;
  final List<LibraryCurateBookVolume> volumes;
  final bool isSeries;

  /// 只留满足 [keep] 的卷；一卷不剩为 null。
  LibraryCurateBookUnit? only(bool Function(LibraryCurateBookVolume v) keep) {
    final List<LibraryCurateBookVolume> left = volumes.where(keep).toList();
    if (left.isEmpty) return null;
    if (left.length == volumes.length) return this;
    return LibraryCurateBookUnit(
      id: id,
      title: title,
      author: author,
      volumes: left,
      isSeries: isSeries,
    );
  }
}

/// 一款没有任何资料源快照的游戏。
class LibraryCurateGameUnit {
  const LibraryCurateGameUnit({required this.id, required this.title});

  final String id;

  /// 显示名（用户改过名就用改的名，否则 exe 派生的本地名）。
  final String title;
}

/// 书名明显是文件名：带书 / 压缩包扩展名，或以方括号标签开头（`[作者] 書名`、
/// `【xx】…` 这类扫描 / 发布组命名）。只认这两种确定的形态，不猜。
bool looksLikeFileNameTitle(String title) {
  final String t = title.trim();
  if (t.isEmpty) return true;
  if (_kFileNameExtension.hasMatch(t)) return true;
  return _kLeadingTag.hasMatch(t);
}

final RegExp _kFileNameExtension = RegExp(
  r'\.(epub|pdf|zip|cbz|cbr|rar|7z|txt|mobi|azw3?)$',
  caseSensitive: false,
);
final RegExp _kLeadingTag = RegExp(r'^\s*[\[【［][^\]】］]+[\]】］]');

/// 书单元的来源与搜索词（沿用「在线匹配封面」弹窗的初始源规则
/// `bookScrapeInitialState`，不新增默认来源、不碰要凭据的楽天）：单书有 ISBN →
/// openBD 按 ISBN；书名里带 DLsite 编号 → DLsite 按编号；否则默认来源（Bangumi）按
/// 标题。第三项 = 按编号精确查（唯一结果即可认，不要求标题一致）。
(String? source, String query, bool exact) bookScrapeQueryOf(
  LibraryCurateBookUnit unit,
) {
  if (!unit.isSeries) {
    final String? isbn = unit.volumes.single.isbn;
    if (isbn != null && isbn.isNotEmpty) return ('openbd', isbn, true);
  }
  final DlsiteWorkId? dlsite = DlsiteWorkId.findIn(unit.title);
  if (dlsite != null) return ('dlsite', dlsite.value, true);
  return (null, unit.title, false);
}

/// 游戏候选的规则认领：标题（`name` / `nameCn`）规范化后与本地显示名一致的候选，
/// 每个资料源至多一条（同一款游戏在 bgm / vndb / dlsite 各出一条是常态）→ 认第一条；
/// 没有或某个源里有两条一致的（同名不同作）→ null。
Map<String, Object?>? pickStrongGameCandidate(
  String local,
  List<Map<String, Object?>> candidates,
) {
  final String l = foldMediaTitle(local);
  if (l.isEmpty) return null;
  final List<Map<String, Object?>> strong = <Map<String, Object?>>[
    for (final Map<String, Object?> c in candidates)
      if (<Object?>[
        c['name'],
        c['nameCn'],
      ].any((Object? t) => t is String && foldMediaTitle(t) == l))
        c,
  ];
  if (strong.isEmpty) return null;
  final Set<String> sources = <String>{};
  for (final Map<String, Object?> c in strong) {
    if (!sources.add('${c['source']}')) return null;
  }
  return strong.first;
}

// ─────────────────────────────────────────────────────────────────────────
// 内部
// ─────────────────────────────────────────────────────────────────────────

class _RunContext {
  _RunContext({
    required this.run,
    required this.state,
    required this.ai,
    required this.budget,
    required this.isCancelled,
  });

  final LibraryCurateRun run;
  final LibraryCurateState state;
  final LibraryCurateAiAvailability ai;

  /// 剩余 AI 请求额度；null = 不限（手动）。
  int? budget;
  final bool Function() isCancelled;

  /// 本趟有没有因为额度不够少做了什么。
  bool capped = false;

  /// 本趟关系推断处理了几个新端点（音乐阶段据此决定要不要重跑）。
  int newLinkEndpoints = 0;

  /// 预扣 [n] 次请求；额度不够返回 false（并记下 [capped]）。
  bool spend(int n) {
    final int? b = budget;
    if (b == null || n <= 0) return true;
    if (n > b) {
      capped = true;
      return false;
    }
    budget = b - n;
    return true;
  }

  Set<String> progressOf(LibraryCurateStage stage) =>
      state.progress.putIfAbsent(stage.wire, () => <String>{});
}

/// 视频摆放纠正这一阶段的累计（两种判断路径共用）。
class _StructurePass {
  _StructurePass(this.ctx, {required this.canIdentify, required this.decide});

  final _RunContext ctx;

  /// 能不能按电影认领（认身份的 AI 指派了，且两条操作可用）。
  final bool canIdentify;
  final AiVideoIdentityDecider? decide;
  int changes = 0;
  int requests = 0;
  int pending = 0;
  bool incomplete = false;

  /// 留给用户：[finding] 是审计里的一个文件（`uid` / `title` / `work`）。
  void park(Map<String, Object?> finding, String reason, {String? ref}) {
    pending++;
    ctx.state.seen.add('structure:${finding['uid']}');
    ctx.run.pendingItems.add(
      LibraryCuratePendingItem(
        stage: LibraryCurateStage.videoStructure,
        kind: 'structure_pending',
        title: '${finding['title'] ?? finding['uid']}',
        ref: ref ?? '${finding['work']}',
        reason: reason,
      ),
    );
  }
}

class _Write {
  const _Write.unavailable()
    : unavailable = true,
      needsConfirmation = false,
      result = null;
  const _Write.needsConfirmation()
    : unavailable = false,
      needsConfirmation = true,
      result = null;
  const _Write.result(AgentToolResult this.result)
    : unavailable = false,
      needsConfirmation = false;

  final bool unavailable;
  final bool needsConfirmation;
  final AgentToolResult? result;
}

Map<String, Object?> _map(Object? raw) => raw is Map
    ? <String, Object?>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          '${e.key}': e.value,
      }
    : const <String, Object?>{};

List<Map<String, Object?>> _list(Object? data, String key) =>
    <Map<String, Object?>>[
      for (final Object? row in (_map(data)[key] as List?) ?? const <Object?>[])
        if (row is Map) _map(row),
    ];

int _int(Object? v) => v is num ? v.toInt() : 0;

Object? _decode(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 默认库事实
// ─────────────────────────────────────────────────────────────────────────

/// 读本机库的 [LibraryCurateFacts]。
class DatabaseLibraryCurateFacts implements LibraryCurateFacts {
  const DatabaseLibraryCurateFacts(
    this.db, {
    this.allowedKeys = _noAllowedKeys,
  });

  final FushiDatabase db;

  /// 设备本地「允许再次建议」的分组键（与 `library.organize.run` 同一份）。
  final Set<String> Function() allowedKeys;

  static Set<String> _noAllowedKeys() => const <String>{};

  @override
  Future<Set<String>?> organizeEntriesSince(
    CollectionShelfDomain domain,
    int? sinceMs,
  ) async =>
      sinceMs == null ? null : organizeEntryKeysAddedSince(db, domain, sinceMs);

  @override
  Future<int> organizeRequestEstimate(
    CollectionShelfDomain domain,
    Set<String>? only,
  ) async {
    final LibraryOrganizeFacts facts = await loadLibraryOrganizeFacts(
      db,
      domain,
      onlyEntryKeys: only,
      allowedKeys: allowedKeys(),
    );
    return chunkOrganizeEntries(facts.entries).length;
  }

  @override
  Future<List<String>> linkEndpointsSince(int? sinceMs) async {
    final int since = sinceMs ?? -1;
    final String video = MediaKind.video.dbValue;
    final List<(MediaLinkKind, String)> queries = <(MediaLinkKind, String)>[
      // 视频合集：新建的，或晚于水位刚刮到 / 换了身份的（spec §9：④ 另把上一趟
      // 之后新拿到外部 id 的作品算进来）。
      (
        MediaLinkKind.videoCollection,
        'SELECT DISTINCT c.id AS k FROM media_collections c '
            'JOIN media_collection_items i ON i.collection_id = c.id '
            "WHERE i.media_type = '$video' AND c.created_at > ?1 "
            'UNION SELECT collection_id AS k FROM video_metadata_works '
            'WHERE collection_id IS NOT NULL AND updated_at > ?1',
      ),
      (
        MediaLinkKind.book,
        "SELECT book_key AS k FROM epub_books WHERE book_key != '' "
            'AND local_added_at > ?1',
      ),
      (MediaLinkKind.game, 'SELECT id AS k FROM galgames WHERE added_at > ?1'),
    ];
    final List<String> out = <String>[];
    for (final (MediaLinkKind kind, String sql) in queries) {
      final List<String> keys = <String>[
        for (final QueryRow row
            in await db
                .customSelect(
                  sql,
                  variables: <Variable<Object>>[Variable<int>(since)],
                )
                .get())
          '${row.data['k']}',
      ]..sort();
      out.addAll(<String>{for (final String k in keys) '${kind.dbValue}:$k'});
    }
    return out;
  }

  @override
  Future<bool> musicChangedSince(int? sinceMs) async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT 1 FROM music_albums WHERE updated_at > ? LIMIT 1',
          variables: <Variable<Object>>[Variable<int>(sinceMs ?? -1)],
        )
        .get();
    return rows.isNotEmpty;
  }

  /// 「缺元数据」的书（[LibraryCurateBookVolume.missing]：没有封面 / 没有作者 / 书名是
  /// 文件名），按合集归成系列单元：同一个 `collection` 型合集里有两本以上缺资料的书
  /// → 一个系列单元（按合集名查）；其余每本一个单元。在线漫画源的书不算（资料归源站）。
  /// [sinceMs] 非 null 时只要含新入库（`local_added_at` 晚于它）书的单元。
  @override
  Future<List<LibraryCurateBookUnit>> bookScrapeUnits(int? sinceMs) async {
    final Map<String, (LibraryCurateBookVolume, String, int?)> missing =
        <String, (LibraryCurateBookVolume, String, int?)>{};
    for (final EpubBookRow book in await db.getAllEpubBooks()) {
      if (book.uid.isEmpty || book.bookKey.isEmpty) continue;
      if (isOnlineMangaSourceMetadata(book.sourceMetadata)) continue;
      final LibraryCurateBookVolume v = LibraryCurateBookVolume(
        bookKey: book.bookKey,
        title: book.title,
        author: book.author,
        isbn: book.isbn,
        missingCover: (book.coverPath ?? '').trim().isEmpty,
        fileNameTitle: looksLikeFileNameTitle(book.title),
      );
      if (!v.missing) continue;
      missing[book.uid] = (v, book.bookKey, book.localAddedAt);
    }
    if (missing.isEmpty) return const <LibraryCurateBookUnit>[];
    final String epub = MediaKind.epub.dbValue;
    final Map<int, String> names = <int, String>{};
    final Map<int, List<String>> members = <int, List<String>>{};
    final Map<String, String> uidByKey = <String, String>{
      for (final MapEntry<String, (LibraryCurateBookVolume, String, int?)> e
          in missing.entries)
        e.value.$2: e.key,
    };
    for (final QueryRow row
        in await db
            .customSelect(
              'SELECT c.id AS id, c.name AS name, i.entry_key AS k '
              'FROM media_collections c '
              'JOIN media_collection_items i ON i.collection_id = c.id '
              "WHERE c.collection_type = 'collection' AND i.media_type = ?1 "
              'ORDER BY c.id, i.sort_index',
              variables: <Variable<Object>>[Variable<String>(epub)],
            )
            .get()) {
      final String key = '${row.data['k']}';
      final String? uid = missing.containsKey(key) ? key : uidByKey[key];
      if (uid == null) continue;
      final int id = row.read<int>('id');
      names[id] = '${row.data['name']}';
      final List<String> list = members.putIfAbsent(id, () => <String>[]);
      if (!list.contains(uid)) list.add(uid);
    }
    final List<LibraryCurateBookUnit> out = <LibraryCurateBookUnit>[];
    final Set<String> placed = <String>{};
    bool fresh(Iterable<String> uids) =>
        sinceMs == null ||
        uids.any((String u) => (missing[u]!.$3 ?? 0) > sinceMs);
    for (final int id in members.keys.toList()..sort()) {
      final List<String> uids = <String>[
        for (final String u in members[id]!)
          if (!placed.contains(u)) u,
      ];
      if (uids.length < 2) continue;
      placed.addAll(uids);
      if (!fresh(uids)) continue;
      final List<LibraryCurateBookVolume> volumes = <LibraryCurateBookVolume>[
        for (final String u in uids) missing[u]!.$1,
      ];
      out.add(
        LibraryCurateBookUnit(
          id: 'collection:$id',
          title: names[id]!,
          author: volumes
              .map((LibraryCurateBookVolume v) => v.author)
              .firstWhere(
                (String? a) => a != null && a.trim().isNotEmpty,
                orElse: () => null,
              ),
          volumes: volumes,
          isSeries: true,
        ),
      );
    }
    final List<String> singles =
        <String>[
          for (final String u in missing.keys)
            if (!placed.contains(u) && fresh(<String>[u])) u,
        ]..sort(
          (String a, String b) =>
              missing[a]!.$1.bookKey.compareTo(missing[b]!.$1.bookKey),
        );
    for (final String u in singles) {
      final LibraryCurateBookVolume v = missing[u]!.$1;
      out.add(
        LibraryCurateBookUnit(
          id: v.shelfKey,
          title: v.title,
          author: v.missingAuthor ? null : v.author,
          volumes: <LibraryCurateBookVolume>[v],
        ),
      );
    }
    return out;
  }

  /// 没有任何资料源快照（`galgame_sources` 无行）的游戏；[sinceMs] 非 null 时只要
  /// `added_at` 晚于它的。
  @override
  Future<List<LibraryCurateGameUnit>> gameScrapeUnits(int? sinceMs) async {
    final List<LibraryCurateGameUnit> out = <LibraryCurateGameUnit>[];
    for (final QueryRow row
        in await db
            .customSelect(
              'SELECT g.id AS id, g.name AS name, '
              'g.custom_data_json AS custom FROM galgames g '
              'WHERE g.added_at > ?1 AND NOT EXISTS '
              '(SELECT 1 FROM galgame_sources s WHERE s.game_id = g.id) '
              'ORDER BY g.added_at, g.id',
              variables: <Variable<Object>>[Variable<int>(sinceMs ?? -1)],
            )
            .get()) {
      String title = '${row.data['name']}';
      final Object? custom = _decode('${row.data['custom'] ?? ''}');
      if (custom is Map && custom['name'] is String) {
        final String n = (custom['name'] as String).trim();
        if (n.isNotEmpty) title = n;
      }
      out.add(LibraryCurateGameUnit(id: '${row.data['id']}', title: title));
    }
    return out;
  }
}
