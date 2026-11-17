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
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_facts.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart'
    show LibraryOrganizeFacts;
import 'package:fushi_engine/media/collections/library_organize/library_organize_service.dart'
    show chunkOrganizeEntries;
import 'package:fushi_engine/media/library_curate/library_curate_run.dart';
import 'package:fushi_engine/media/links/work_graph.dart';
import 'package:fushi_engine/media/links/work_graph_loader.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';

export 'package:fushi_engine/media/library_curate/library_curate_run.dart';

/// 编排器调用的目录操作 id（app 与服务端目录里同名）。
abstract final class LibraryCurateOps {
  static const String organizeRun = 'library.organize.run';
  static const String videoWorkList = 'video.work.list';
  static const String videoWorkCandidates = 'video.work.candidates';
  static const String videoWorkIdentify = 'video.work.identify';
  static const String linksInfer = 'library.curate.links.infer';
  static const String linksMusic = 'library.curate.links.music';
}

/// 各步自己的 AI 指派是否可用（spec §9：不新增 `AiFeature`，每步用它自己的指派；
/// 没指派的那一步跳过，其余照跑）。宿主每次现算（AI 模块门也折进来）。
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
    this.autoMaxLinkEndpoints = 60,
    this.linkBatchSize = 10,
  });

  /// 自动路径一趟最多发多少次 AI 请求（按各阶段估算扣减；超了的阶段只跑不花钱的
  /// 部分，标 `request_cap`，下一趟接着做）。
  final int autoMaxRequests;

  /// 自动路径一趟最多查几部待确认视频作品（每部一次资料源搜索）。
  final int autoMaxScrapeWorks;

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
    this.limits = const LibraryCurateLimits(),
    this.onWorksChanged,
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
  final LibraryCurateLimits limits;

  /// 作品层重算后通知宿主（宿主的作品图缓存本就随表变更失效，这里只是让界面立即
  /// 刷新；可空）。
  final void Function()? onWorksChanged;
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
    LibraryCurateStage.scrape => _scrape(ctx),
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

  // ── ③ 认身份 + 刮削（视频待确认作品） ──────────────────────────────

  /// spec §6：单候选且标题强匹配 → 直接认领；多候选 → AI 在候选键里选、达到自动
  /// 采用门槛才认领；其余留在待确认。批量刮削已经问过 AI 且被拒（`declined`）的
  /// 不再重问。书 / 漫画 / 游戏不在这一步（见回报：书的写回不落外部身份、游戏写回
  /// 不可撤销）。
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
    final WorkGraph graph = await loadWorkGraph(db);
    if (ctx.run.changes > 0) onWorksChanged?.call();
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
  /// 不再把同一部作品原样认领回来、不再对同一端点重推。
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
      case LibraryCurateOps.linksInfer:
        for (final Object? e in (args['items'] as List?) ?? const <Object?>[]) {
          yield 'links:$e';
        }
    }
  }
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
}
