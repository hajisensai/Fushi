/// AI 管库自动复查的本机状态与排程（纯数据 + 纯函数，不依赖操作上下文，设置页也能
/// import）。执行在 `library_agent_review.dart`；设计见 spec
/// `docs/specs/2026-11-22-ai-library-agent-design.md` §7.1。
///
/// BUG-5365 之后的三条约束：
///
/// - **全库复查分段**：按 `library.map` 的视图（books → manga → video → games → links）
///   与固定窗口（[kLibraryAgentReviewDomainWindow] / [kLibraryAgentReviewLinksWindow]）
///   切成多场互不相干的有界会话；每段跑完游标就落盘，下次从没跑完的那段接着来。
/// - **失败也记账**：每次尝试都落状态；失败按 [libraryAgentReviewBackoff] 指数退避，
///   连续 [kLibraryAgentReviewMaxFailures] 次就暂停自动复查，直到「AI 助手」换了
///   提供商 / 模型 / 地址，或用户把开关关了再开（[LibraryAgentReviewState.resumed]）。
/// - **token 上限**：单场会话 [kLibraryAgentReviewSessionTokens]，单趟复查
///   [kLibraryAgentReviewRunTokens]。
library;

import 'dart:convert';

import 'package:fushi_engine/media/library_agent/library_map.dart'
    show LibraryMapView;

/// 累积这么多新条目（自上次全库复查）就做一次全库复查。
const int kLibraryAgentReviewFullAfterItems = 100;

/// 距上次全库复查满这么久、且期间有新条目，就做一次全库复查。
const Duration kLibraryAgentReviewFullEvery = Duration(days: 30);

/// 全库复查依次走过的视图（一个视图按窗口切成若干段）。
const List<LibraryMapView> kLibraryAgentReviewFullViews = <LibraryMapView>[
  LibraryMapView.books,
  LibraryMapView.manga,
  LibraryMapView.video,
  LibraryMapView.games,
  LibraryMapView.links,
];

/// 库页视图一段的行数（合集行 + 条目行）。一行约 150～250 字符，100 行约 2 万字符
/// （≈ 1 万 token 以内）：模型读一次、改几批、复读核对，整场也留在会话上限里。
const int kLibraryAgentReviewDomainWindow = 100;

/// `links` 视图一段的作品数（一个作品连带它的全部边，行比库页视图胖）。
const int kLibraryAgentReviewLinksWindow = 50;

/// 单场复查会话的 token 上限（输入 + 输出 + 缓存读写合计，每次请求都把整段上下文
/// 再算一遍）。实测（BUG-5365）无界的全库会话累计到 45～68 万 token 时提供商回
/// `empty_response`；一段窗口的正常工作量远低于此，25 万留足余量又不至于让一段
/// 失控的会话烧到那个量级。
const int kLibraryAgentReviewSessionTokens = 250000;

/// 单趟复查（一次自动触发）最多花的 token：用满就不再开下一段，留给下次触发。
/// 约等于三段跑满上限。
const int kLibraryAgentReviewRunTokens = 750000;

/// 第一次失败后的等待；之后每失败一次翻倍，封顶 [kLibraryAgentReviewMaxBackoff]。
const Duration kLibraryAgentReviewBaseBackoff = Duration(hours: 1);

/// 退避上限：一天。自动路径约 1～2 小时触发一次，提供商的临时故障（限流、维护）
/// 通常几小时内恢复，退避到一天已足够把重试压到每天一次。
const Duration kLibraryAgentReviewMaxBackoff = Duration(days: 1);

/// 连续失败这么多次就暂停自动复查（1h、2h、4h、8h 之后的第 5 次；从第一次失败算起
/// 约 15 小时）。仍然失败多半是结构性的（模型 / 配额 / 地址不对），再试只是白烧。
const int kLibraryAgentReviewMaxFailures = 5;

/// 第 [failures] 次连续失败（≥ 1）之后要等多久。
Duration libraryAgentReviewBackoff(int failures) {
  final int exponent = failures <= 1 ? 0 : failures - 1;
  final int maxMs = kLibraryAgentReviewMaxBackoff.inMilliseconds;
  int ms = kLibraryAgentReviewBaseBackoff.inMilliseconds;
  for (int i = 0; i < exponent && ms < maxMs; i++) {
    ms *= 2;
  }
  return Duration(milliseconds: ms > maxMs ? maxMs : ms);
}

/// 一个视图一段的行数。
int libraryAgentReviewWindow(LibraryMapView view) =>
    view == LibraryMapView.links
    ? kLibraryAgentReviewLinksWindow
    : kLibraryAgentReviewDomainWindow;

/// 全库复查的游标：下一段从 [view] 的第 [offset] 行开始。
class LibraryAgentReviewCursor {
  const LibraryAgentReviewCursor(this.view, this.offset);

  final LibraryMapView view;
  final int offset;

  @override
  bool operator ==(Object other) =>
      other is LibraryAgentReviewCursor &&
      other.view == view &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(view, offset);

  @override
  String toString() => '${view.wireName}@$offset';
}

/// 自动复查的本机状态（偏好 `library_agent_review_state`，JSON）。新字段缺省即旧
/// 语义：旧版存的 / 空的状态都能读。
class LibraryAgentReviewState {
  const LibraryAgentReviewState({
    this.lastReviewAt,
    this.lastFullAt,
    this.itemsSinceFull = 0,
    this.fullStartedAt,
    this.cursor,
    this.failures = 0,
    this.retryAt,
    this.pausedFor,
  });

  /// 上一次跑完的复查开始的时刻（增量水位）；null = 还没复查过。
  final int? lastReviewAt;

  /// 上一次跑完的全库复查开始的时刻；null = 还没做过全库复查。
  final int? lastFullAt;

  /// 上次全库复查以来增量复查过的新条目数。
  final int itemsSinceFull;

  /// 正在分段进行的全库复查是什么时候开始的；null = 没有进行中的全库复查。
  final int? fullStartedAt;

  /// 进行中的全库复查下一段从哪开始；[fullStartedAt] 非 null 而它为 null = 各段
  /// 都跑完了，只差收尾。
  final LibraryAgentReviewCursor? cursor;

  /// 连续失败的次数（成功一次清零）。
  final int failures;

  /// 退避：这一刻（毫秒时间戳）之前不再尝试；null = 不退避。
  final int? retryAt;

  /// 熔断：连续失败到 [kLibraryAgentReviewMaxFailures] 次时「AI 助手」提供商的指纹
  /// （[libraryAgentReviewProviderKey]）；非 null = 暂停中。提供商换了就自动恢复。
  final String? pausedFor;

  bool get fullInProgress => fullStartedAt != null;

  bool get paused => pausedFor != null;

  static LibraryAgentReviewState parse(String raw) {
    if (raw.trim().isEmpty) return const LibraryAgentReviewState();
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return const LibraryAgentReviewState();
    }
    if (json is! Map) return const LibraryAgentReviewState();
    int? n(Object? v) => v is num ? v.toInt() : null;
    final int? fullStartedAt = n(json['fullStartedAt']);
    final Object? rawView = json['fullView'];
    final LibraryMapView? view = rawView is String
        ? LibraryMapView.tryParse(rawView)
        : null;
    final int offset = n(json['fullOffset']) ?? 0;
    final Object? pausedFor = json['pausedFor'];
    return LibraryAgentReviewState(
      lastReviewAt: n(json['lastReviewAt']),
      lastFullAt: n(json['lastFullAt']),
      itemsSinceFull: n(json['itemsSinceFull']) ?? 0,
      fullStartedAt: fullStartedAt,
      cursor:
          fullStartedAt != null &&
              view != null &&
              kLibraryAgentReviewFullViews.contains(view)
          ? LibraryAgentReviewCursor(view, offset < 0 ? 0 : offset)
          : null,
      failures: n(json['failures']) ?? 0,
      retryAt: n(json['retryAt']),
      pausedFor: pausedFor is String ? pausedFor : null,
    );
  }

  String encode() => jsonEncode(<String, Object?>{
    if (lastReviewAt != null) 'lastReviewAt': lastReviewAt,
    if (lastFullAt != null) 'lastFullAt': lastFullAt,
    'itemsSinceFull': itemsSinceFull,
    if (fullStartedAt != null) 'fullStartedAt': fullStartedAt,
    if (cursor != null) 'fullView': cursor!.view.wireName,
    if (cursor != null) 'fullOffset': cursor!.offset,
    if (failures > 0) 'failures': failures,
    if (retryAt != null) 'retryAt': retryAt,
    if (pausedFor != null) 'pausedFor': pausedFor,
  });

  LibraryAgentReviewState _copy({
    int? lastReviewAt,
    int? lastFullAt,
    int? itemsSinceFull,
    int? Function()? fullStartedAt,
    LibraryAgentReviewCursor? Function()? cursor,
    int? failures,
    int? Function()? retryAt,
    String? Function()? pausedFor,
  }) => LibraryAgentReviewState(
    lastReviewAt: lastReviewAt ?? this.lastReviewAt,
    lastFullAt: lastFullAt ?? this.lastFullAt,
    itemsSinceFull: itemsSinceFull ?? this.itemsSinceFull,
    fullStartedAt: fullStartedAt == null ? this.fullStartedAt : fullStartedAt(),
    cursor: cursor == null ? this.cursor : cursor(),
    failures: failures ?? this.failures,
    retryAt: retryAt == null ? this.retryAt : retryAt(),
    pausedFor: pausedFor == null ? this.pausedFor : pausedFor(),
  );

  /// 解除退避与熔断（提供商换了、用户把开关重新打开）。复查进度原样保留。
  LibraryAgentReviewState resumed() =>
      _copy(failures: 0, retryAt: () => null, pausedFor: () => null);

  /// 一次尝试成功：清掉失败计数与退避。
  LibraryAgentReviewState succeeded() => resumed();

  /// 一次尝试失败（[nowMs] 时刻；[providerKey] 见 [libraryAgentReviewProviderKey]）：
  /// 计数 +1、按 [libraryAgentReviewBackoff] 退避，够 [kLibraryAgentReviewMaxFailures]
  /// 次就熔断。复查进度（水位、游标）不动：下次从同一处重来。
  LibraryAgentReviewState failed({
    required int nowMs,
    required String providerKey,
  }) {
    final int count = failures + 1;
    return _copy(
      failures: count,
      retryAt: () => nowMs + libraryAgentReviewBackoff(count).inMilliseconds,
      pausedFor: () =>
          count >= kLibraryAgentReviewMaxFailures ? providerKey : null,
    );
  }

  /// 开始一趟分段全库复查（[startedAtMs]：之后入库的条目留给增量复查）。
  LibraryAgentReviewState startFull(int startedAtMs) => _copy(
    fullStartedAt: () => startedAtMs,
    cursor: () =>
        LibraryAgentReviewCursor(kLibraryAgentReviewFullViews.first, 0),
  );

  /// 游标所在的段跑完了（[total]：该视图当前的总行数）：前进一个窗口，越过视图末尾
  /// 就换下一个视图；最后一个视图也走完了，游标置空（待 [finishFull] 收尾）。
  LibraryAgentReviewState advanceCursor({required int total}) {
    final LibraryAgentReviewCursor? at = cursor;
    if (at == null) return this;
    final int next = at.offset + libraryAgentReviewWindow(at.view);
    if (next < total) {
      return _copy(cursor: () => LibraryAgentReviewCursor(at.view, next));
    }
    final int i = kLibraryAgentReviewFullViews.indexOf(at.view);
    return _copy(
      cursor: () => i + 1 < kLibraryAgentReviewFullViews.length
          ? LibraryAgentReviewCursor(kLibraryAgentReviewFullViews[i + 1], 0)
          : null,
    );
  }

  /// 各段都跑完：水位推到这趟全库复查开始的时刻。
  LibraryAgentReviewState finishFull() {
    final int? started = fullStartedAt;
    if (started == null) return this;
    return LibraryAgentReviewState(
      lastReviewAt: started,
      lastFullAt: started,
      failures: failures,
      retryAt: retryAt,
      pausedFor: pausedFor,
    );
  }

  /// 一次增量复查跑完（[startedAtMs]：它开始的时刻）。
  LibraryAgentReviewState finishIncremental({
    required int newItems,
    required int startedAtMs,
  }) => _copy(
    lastReviewAt: startedAtMs,
    itemsSinceFull: itemsSinceFull + newItems,
  );
}

/// 「AI 助手」提供商的指纹：熔断记住它，换了提供商 / 模型 / 地址就恢复。
String libraryAgentReviewProviderKey({
  required String id,
  required String model,
  required String baseUrl,
}) => '$id\u0000$model\u0000$baseUrl';

/// 此刻挡不挡自动复查：熔断着且提供商没换，或还在退避期内。
bool libraryAgentReviewBlocked(
  LibraryAgentReviewState state, {
  required int nowMs,
  required String providerKey,
}) {
  final String? pausedFor = state.pausedFor;
  if (pausedFor != null) return pausedFor == providerKey;
  final int? retryAt = state.retryAt;
  return retryAt != null && nowMs < retryAt;
}

enum LibraryAgentReviewKind { incremental, full }

/// 这一次该做什么复查（纯函数）：null = 不必跑（没有新条目、也不到全库复查）。
/// 进行中的分段全库复查优先接着跑。
LibraryAgentReviewKind? decideLibraryAgentReview({
  required LibraryAgentReviewState state,
  required int newItems,
  required int nowMs,
}) {
  if (state.fullInProgress) return LibraryAgentReviewKind.full;
  final int? lastFull = state.lastFullAt;
  if (state.lastReviewAt == null || lastFull == null) {
    return LibraryAgentReviewKind.full;
  }
  if (newItems <= 0) return null;
  if (state.itemsSinceFull + newItems >= kLibraryAgentReviewFullAfterItems ||
      nowMs - lastFull >= kLibraryAgentReviewFullEvery.inMilliseconds) {
    return LibraryAgentReviewKind.full;
  }
  return LibraryAgentReviewKind.incremental;
}
