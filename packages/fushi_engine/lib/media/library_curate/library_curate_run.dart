/// AI 库管家的运行记录、水位与本机状态（spec
/// `docs/specs/2026-11-18-ai-library-curator-design.md` §3 / §9）。
///
/// 纯数据 + JSON：app 存进设备本地偏好（`library_curate_state`），无头服务端存进数据
/// 目录里的一个 JSON 文件。**不落库、不同步**：库管家的每一处写入本身都经操作目录
/// 记进 `ai_agent_actions`（会话 id `curator:<runId>`），这里只记「这一趟跑了哪些阶段、
/// 各阶段什么结论」与增量水位。
library;

import 'dart:convert';

/// 一趟是谁触发的。
enum LibraryCurateTrigger {
  /// 入库 / 扫描后去抖自动跑（没有人看着：只落高置信，有单趟请求上限）。
  auto,

  /// 用户手动「立即整理」/ AI 助手技能 / CLI（中置信也生效，不设请求上限）。
  manual;

  static LibraryCurateTrigger parse(String raw) => switch (raw) {
    'auto' => LibraryCurateTrigger.auto,
    _ => LibraryCurateTrigger.manual,
  };
}

/// 编排的阶段（spec §3 的 ①～⑤；① 规则归组与 ② AI 归合集在
/// `library.organize.run` 里是同一次调用，按书架域拆成四段）。顺序即执行顺序。
enum LibraryCurateStage {
  organizeBooks('organize.books'),
  organizeManga('organize.manga'),
  organizeVideo('organize.video'),
  organizeGames('organize.games'),

  /// 视频摆放纠正（spec §15.2）：挂在某部剧特别篇（第 0 季）下的电影长度文件拆成
  /// 独立作品，再按电影识别。排在 ③ 之前：拆出来的文件要先成为作品单元。
  videoStructure('video.structure'),

  /// ③ 认身份 + 刮削（视频待确认作品）。
  scrape('scrape'),

  /// ③ 书 / 漫画刮削（缺元数据的书，系列按合集查一次）。
  scrapeBooks('scrape.books'),

  /// ③ 游戏刮削（没有资料源快照的游戏）。
  scrapeGames('scrape.games'),

  /// ④ 跨媒体关系推断（视频合集 / 书 / 游戏端点）。
  links('links'),

  /// ④ 的音乐部分（全库批量：专辑 / 曲目 → 动画合集 / 游戏）。
  music('music'),

  /// ⑤ 作品层重算（纯派生，不写库）。
  works('works');

  const LibraryCurateStage(this.wire);

  final String wire;

  static LibraryCurateStage? tryParse(String raw) {
    for (final LibraryCurateStage s in values) {
      if (s.wire == raw) return s;
    }
    return null;
  }
}

/// 一个阶段的结论。
enum LibraryCurateStageStatus {
  /// 该做的全做完（推进这一阶段的水位）。
  done,

  /// 做了一部分：AI 那一步没指派提供商只跑了规则、碰到单趟请求上限、或部分条目
  /// 失败。水位不推进，没处理到的下一趟接着做（已处理的记进进度，不重做）。
  partial,

  /// 一点没做：所需操作当前不可用（模块关 / 平台 / 合规门）或需要的 AI 没指派。
  skipped,

  /// 整段失败（错误短码在 [LibraryCurateStageResult.error]）；后面的阶段照跑。
  failed,

  /// 用户取消。
  cancelled,
}

/// 一条留给用户处理的事（待确认）。
class LibraryCuratePendingItem {
  const LibraryCuratePendingItem({
    required this.stage,
    required this.kind,
    required this.title,
    this.ref,
    this.reason,
    this.candidates,
    this.ai,
  });

  final LibraryCurateStage stage;

  /// `structure_pending`（视频放错了位置但不能自动纠正，`reason` 是审计的问题种类
  /// 或 `pinned_by_user` / `needs_identify` / `no_candidates` / `ambiguous`）、
  /// `scrape_pending`（视频作品没认出来）、`book_scrape_pending` /
  /// `game_scrape_pending`（书 / 游戏没认出来）、`needs_confirmation`（这一步的操作要
  /// 用户确认，自动编排不执行）、`organize_proposal`（合集级建议）等。
  final String kind;
  final String title;

  /// 定位用的键（作品 id、端点、建议 id）。
  final String? ref;
  final String? reason;

  /// 书 / 游戏刮削待确认：资料源给了几个候选（旧记录没有为 null）。
  final int? candidates;

  /// 书 / 游戏刮削待确认：AI 那一步的结论（`PendingIdentityAiOutcome.wire`；旧记录
  /// 没有为 null）。
  final String? ai;

  Map<String, Object?> toJson() => <String, Object?>{
    'stage': stage.wire,
    'kind': kind,
    'title': title,
    if (ref != null) 'ref': ref,
    if (reason != null) 'reason': reason,
    if (candidates != null) 'candidates': candidates,
    if (ai != null) 'ai': ai,
  };

  static LibraryCuratePendingItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final LibraryCurateStage? stage = LibraryCurateStage.tryParse(
      '${raw['stage']}',
    );
    if (stage == null) return null;
    return LibraryCuratePendingItem(
      stage: stage,
      kind: '${raw['kind'] ?? ''}',
      title: '${raw['title'] ?? ''}',
      ref: raw['ref'] as String?,
      reason: raw['reason'] as String?,
      candidates: (raw['candidates'] as num?)?.toInt(),
      ai: raw['ai'] as String?,
    );
  }
}

/// 一个阶段跑完的结论。
class LibraryCurateStageResult {
  const LibraryCurateStageResult({
    required this.stage,
    required this.status,
    this.changes = 0,
    this.pending = 0,
    this.requests = 0,
    this.error,
    this.note,
  });

  final LibraryCurateStage stage;
  final LibraryCurateStageStatus status;

  /// 落了几处改动（合集改动、认领、生效 / 建议的连接）。
  final int changes;

  /// 留给用户确认的条数。
  final int pending;

  /// 这一阶段发出的 AI 请求数（估计值以各操作报告为准）。
  final int requests;

  /// 失败 / 跳过的短码（`unavailable`、`no_provider`、`request_cap`……）。
  final String? error;

  /// 补充说明（如 `rules_only`）。
  final String? note;

  Map<String, Object?> toJson() => <String, Object?>{
    'stage': stage.wire,
    'status': status.name,
    'changes': changes,
    'pending': pending,
    'requests': requests,
    if (error != null) 'error': error,
    if (note != null) 'note': note,
  };

  static LibraryCurateStageResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final LibraryCurateStage? stage = LibraryCurateStage.tryParse(
      '${raw['stage']}',
    );
    if (stage == null) return null;
    return LibraryCurateStageResult(
      stage: stage,
      status: LibraryCurateStageStatus.values.firstWhere(
        (LibraryCurateStageStatus s) => s.name == raw['status'],
        orElse: () => LibraryCurateStageStatus.failed,
      ),
      changes: (raw['changes'] as num?)?.toInt() ?? 0,
      pending: (raw['pending'] as num?)?.toInt() ?? 0,
      requests: (raw['requests'] as num?)?.toInt() ?? 0,
      error: raw['error'] as String?,
      note: raw['note'] as String?,
    );
  }
}

/// 一趟的整体结论。
enum LibraryCurateRunStatus { running, done, partial, cancelled, failed }

/// 一趟库管家运行。
class LibraryCurateRun {
  LibraryCurateRun({
    required this.id,
    required this.trigger,
    required this.startedAt,
    this.finishedAt,
    this.status = LibraryCurateRunStatus.running,
    List<LibraryCurateStageResult>? stages,
    List<LibraryCuratePendingItem>? pendingItems,
    this.undoneAt,
    this.full = false,
    this.target,
  }) : stages = stages ?? <LibraryCurateStageResult>[],
       pendingItems = pendingItems ?? <LibraryCuratePendingItem>[];

  /// 运行 id（开始时刻的毫秒戳，保证单调）。
  final int id;
  final LibraryCurateTrigger trigger;
  final int startedAt;
  int? finishedAt;
  LibraryCurateRunStatus status;
  final List<LibraryCurateStageResult> stages;
  final List<LibraryCuratePendingItem> pendingItems;
  int? undoneAt;

  /// 忽略水位、对全库跑（手动「整理整个库」/ CLI `--full`）。
  final bool full;

  /// 单条重试（待确认队列「AI 重试」）的目标条目键；正常一趟为 null。
  final String? target;

  /// 写操作的记账会话（`ai_agent_actions.session_id`）。
  String get sessionId => libraryCurateSessionId(id);

  int get changes => stages.fold<int>(
    0,
    (int sum, LibraryCurateStageResult s) => sum + s.changes,
  );

  int get pending => stages.fold<int>(
    0,
    (int sum, LibraryCurateStageResult s) => sum + s.pending,
  );

  int get requests => stages.fold<int>(
    0,
    (int sum, LibraryCurateStageResult s) => sum + s.requests,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'trigger': trigger.name,
    'startedAt': startedAt,
    if (finishedAt != null) 'finishedAt': finishedAt,
    'status': status.name,
    if (full) 'full': true,
    if (target != null) 'target': target,
    'changes': changes,
    'pending': pending,
    'requests': requests,
    'stages': <Object?>[
      for (final LibraryCurateStageResult s in stages) s.toJson(),
    ],
    'pendingItems': <Object?>[
      for (final LibraryCuratePendingItem p in pendingItems) p.toJson(),
    ],
    if (undoneAt != null) 'undoneAt': undoneAt,
  };

  static LibraryCurateRun? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final int? id = (raw['id'] as num?)?.toInt();
    final int? startedAt = (raw['startedAt'] as num?)?.toInt();
    if (id == null || startedAt == null) return null;
    return LibraryCurateRun(
      id: id,
      trigger: LibraryCurateTrigger.parse('${raw['trigger']}'),
      startedAt: startedAt,
      finishedAt: (raw['finishedAt'] as num?)?.toInt(),
      // 读回来还是 running = 进程在跑的半路被杀（正在跑的那一趟只在内存里看），
      // 算失败；不认识的值同样算失败。
      status: LibraryCurateRunStatus.values.firstWhere(
        (LibraryCurateRunStatus s) =>
            s.name == raw['status'] && s != LibraryCurateRunStatus.running,
        orElse: () => LibraryCurateRunStatus.failed,
      ),
      full: raw['full'] == true,
      target: raw['target'] as String?,
      stages: <LibraryCurateStageResult>[
        for (final Object? s in (raw['stages'] as List?) ?? const <Object?>[])
          ?LibraryCurateStageResult.fromJson(s),
      ],
      pendingItems: <LibraryCuratePendingItem>[
        for (final Object? p
            in (raw['pendingItems'] as List?) ?? const <Object?>[])
          ?LibraryCuratePendingItem.fromJson(p),
      ],
      undoneAt: (raw['undoneAt'] as num?)?.toInt(),
    );
  }
}

/// 库管家记账会话 id。
String libraryCurateSessionId(int runId) => 'curator:$runId';

/// 记录里最多留几趟（更早的只剩 `ai_agent_actions` 里的操作记录）。
const int kLibraryCurateRunHistoryLimit = 30;

/// 本机状态：运行记录 + 增量水位 + 进度 + 抑制清单。
///
/// **水位方案**（spec §9「自动路径只看新条目」）：每个阶段一个水位
/// [watermarks]（毫秒），值 = 该阶段上次**做完**（[LibraryCurateStageStatus.done]）的那
/// 一趟的**开始**时刻。下一趟只处理 `入库 / 刮到身份的时刻 > 水位` 的条目——用开始
/// 时刻而不是结束时刻，跑的过程中新入库的条目下一趟还会看到。阶段没做完（部分 /
/// 失败 / 取消 / 请求上限）水位不动；这一趟已经处理过的键记进 [progress]，下一趟同一
/// 水位下跳过它们，不重复花钱；阶段做完时清掉该阶段的进度。没有水位（首趟）= 全量。
///
/// [suppressed]：整趟撤销时记下的「撤销过、别再自动做回来」的键
/// （`scrape:<作品 id>`、`scrape.books:book:<bookKey>`、`scrape.games:<游戏 id>`、
/// `links:<端点>`、`structure:<视频 uid>`）。合集移出与连接本身另有跨端的「只做一次」
/// 语义（成员 `pinned_by_user`、连接否决墓碑），这里只兜本机认领与推断入口。
///
/// [seen]：自动路径查过但留在待确认的视频作品 / 书单元 / 游戏（`scrape:<作品 id>`、
/// `scrape.books:<单元>`、`scrape.games:<游戏 id>`）——没有新证据不再每趟重问；手动
/// 触发照样重看。另记已经写回过的书（`scrape.books.done:book:<bookKey>`）：书的
/// override 封面不改 `epub_books.cover_path`，不记的话全量跑会把它当缺封面再查一遍。
class LibraryCurateState {
  LibraryCurateState({
    List<LibraryCurateRun>? runs,
    Map<String, int>? watermarks,
    Map<String, Set<String>>? progress,
    Set<String>? suppressed,
    Set<String>? seen,
  }) : runs = runs ?? <LibraryCurateRun>[],
       watermarks = watermarks ?? <String, int>{},
       progress = progress ?? <String, Set<String>>{},
       suppressed = suppressed ?? <String>{},
       seen = seen ?? <String>{};

  /// 新的在前。
  final List<LibraryCurateRun> runs;
  final Map<String, int> watermarks;
  final Map<String, Set<String>> progress;
  final Set<String> suppressed;
  final Set<String> seen;

  LibraryCurateRun? runById(int id) {
    for (final LibraryCurateRun r in runs) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// 上一趟（任意结论）——运行 id 单调用。
  int get lastRunId => runs.isEmpty ? 0 : runs.first.id;

  void upsertRun(LibraryCurateRun run) {
    runs.removeWhere((LibraryCurateRun r) => r.id == run.id);
    runs.insert(0, run);
    runs.sort((LibraryCurateRun a, LibraryCurateRun b) => b.id - a.id);
    if (runs.length > kLibraryCurateRunHistoryLimit) {
      runs.removeRange(kLibraryCurateRunHistoryLimit, runs.length);
    }
  }

  String encode() => jsonEncode(<String, Object?>{
    'v': kLibraryCurateStateVersion,
    'runs': <Object?>[for (final LibraryCurateRun r in runs) r.toJson()],
    'watermarks': watermarks,
    'progress': <String, Object?>{
      for (final MapEntry<String, Set<String>> e in progress.entries)
        e.key: (e.value.toList()..sort()),
    },
    'suppressed': suppressed.toList()..sort(),
    'seen': seen.toList()..sort(),
  });

  /// 坏值当空（设备本地偏好，丢了只是下一趟当首趟全量跑）。
  static LibraryCurateState decode(String? raw) {
    if (raw == null || raw.isEmpty) return LibraryCurateState();
    final Object? data;
    try {
      data = jsonDecode(raw);
    } on FormatException {
      return LibraryCurateState();
    }
    if (data is! Map) return LibraryCurateState();
    Set<String> strings(Object? v) => <String>{
      if (v is List)
        for (final Object? s in v)
          if (s is String) s,
    };
    final LibraryCurateState state = LibraryCurateState(
      runs: <LibraryCurateRun>[
        for (final Object? r in (data['runs'] as List?) ?? const <Object?>[])
          ?LibraryCurateRun.fromJson(r),
      ],
      watermarks: <String, int>{
        if (data['watermarks'] is Map)
          for (final MapEntry<Object?, Object?> e
              in (data['watermarks'] as Map).entries)
            if (e.value is num) '${e.key}': (e.value! as num).toInt(),
      },
      progress: <String, Set<String>>{
        if (data['progress'] is Map)
          for (final MapEntry<Object?, Object?> e
              in (data['progress'] as Map).entries)
            '${e.key}': strings(e.value),
      },
      suppressed: strings(data['suppressed']),
      seen: strings(data['seen']),
    );
    final int version = (data['v'] as num?)?.toInt() ?? 1;
    if (version < 3) state._resetBookScrapeVerdicts();
    return state;
  }

  /// v1 → v2（BUG-5366）：书 / 漫画补刮换了判据（按系列身份归组、按系列名查、唯一
  /// 同名候选直接认、唯一不同名候选也交 AI），旧判据下「查过没认出来」的结论作废：
  /// 清掉该阶段的水位与进度、`seen` 里的 `scrape.books:<单元>`，以及运行记录里的
  /// `book_scrape_pending` 待确认项——下一趟自动路径按新判据把缺资料的书全量重看
  /// 一遍。撤销抑制（[suppressed]）保留：那是用户意思，不是判据结论。
  ///
  /// → v3（BUG-5390）：「认出了、但候选没带缺的字段所以什么都没写」的卷以前也记成
  /// 做完（`scrape.books.done:`；Bangumi 搜索候选当时不带作者，v2 头一趟把一整批
  /// 只缺作者的漫画这样标掉），这些书从待确认里消失、作者却还空着。做完记号一起
  /// 清掉重看：真写过的书再查一次只会被 `onlyEmpty` 滤掉，不会改动。
  void _resetBookScrapeVerdicts() {
    final String stage = LibraryCurateStage.scrapeBooks.wire;
    watermarks.remove(stage);
    progress.remove(stage);
    seen.removeWhere(
      (String k) => k.startsWith('$stage:') || k.startsWith('$stage.done:'),
    );
    for (final LibraryCurateRun run in runs) {
      run.pendingItems.removeWhere(
        (LibraryCuratePendingItem p) => p.kind == 'book_scrape_pending',
      );
    }
  }
}

/// [LibraryCurateState.encode] 写的格式版本。升版 = 某阶段换了判据、旧结论要作废，
/// 迁移写在 [LibraryCurateState.decode] 里。
const int kLibraryCurateStateVersion = 3;

/// 状态的读写（app：偏好；服务端：JSON 文件；测试：内存）。
abstract interface class LibraryCurateStore {
  Future<LibraryCurateState> load();
  Future<void> save(LibraryCurateState state);
}

/// 以一段 JSON 文本为载体的 store（偏好 / 文件都是它）。
class JsonLibraryCurateStore implements LibraryCurateStore {
  JsonLibraryCurateStore({required this.read, required this.write});

  final Future<String?> Function() read;
  final Future<void> Function(String json) write;

  @override
  Future<LibraryCurateState> load() async =>
      LibraryCurateState.decode(await read());

  @override
  Future<void> save(LibraryCurateState state) => write(state.encode());
}

/// 内存 store（测试 / 没有持久化位置时）。
class MemoryLibraryCurateStore implements LibraryCurateStore {
  String? _raw;

  @override
  Future<LibraryCurateState> load() async => LibraryCurateState.decode(_raw);

  @override
  Future<void> save(LibraryCurateState state) async => _raw = state.encode();
}
