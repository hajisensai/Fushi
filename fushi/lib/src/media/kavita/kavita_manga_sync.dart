/// Kavita 漫画（`OnlineMangaRuntimeKind.kavita`）的阅读进度双向同步：
/// 开章时拉取 + 阅读中推送。模板是 `kavita_epub_sync.dart`。
///
/// 位置映射（**无损**）：一个 Kavita chapter 就是 Fushi 的一章（章 key = Kavita
/// chapterId 的十进制串），两侧页号都是 0 起；本地章进度在 `manga_chapter_states`
/// （`lastPage` / `updatedAt`）。
///
/// 「上次成功同步时刻」没有现成列可放（`manga_chapter_states` 无此列，且不改
/// schema），所以落在设备本地偏好 [kKavitaMangaSyncStatePref]（JSON：
/// `"<bookUid>|<chapterKey>" → {"at": epoch 毫秒, "page": 两侧一致的页}`），见
/// [KavitaMangaSyncStampStore]。它不含任何凭据或 URL，只有书 uid、章 key、时刻与页号。
///
/// 流程：
/// 1. [KavitaMangaSyncSession.attach] 在阅读器读章进度**之前**调用：拉服务器进度 →
///    与本地章进度按 `resolveKavitaProgress` 决策 → 采用服务器（写本地章进度，
///    阅读器随后按章进度自然落到那一页）/ 推本地 / 冲突时询问 / 不动。拉取有短
///    超时，离线直接放行，不卡开章；服务器不可达会被 [KavitaReachability] 记住，
///    之后开章 / 换章不再等这次拉取（后台照发），直到服务器对任何一个请求答上话；
/// 2. 阅读中每次章进度落库后调 [KavitaMangaSyncSession.onPageSaved]，由
///    `KavitaProgressSync` 防抖上报，读到最后一页推成功后标已读；
/// 3. 换章 / 关书时 [KavitaMangaSyncSession.close]：限时 flush 再释放。
///
/// 非 Kavita 条目、服务器未配置 / 已停用、章 key 不是 chapterId 时 attach 返回
/// null，阅读器按普通在线章处理。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';
import 'package:fushi_engine/media/metadata/credential_redaction.dart'
    show redactCredentialsInText;

import 'package:fushi/src/media/kavita/kavita_progress_resolver.dart';
import 'package:fushi/src/media/kavita/kavita_progress_sync.dart';
import 'package:fushi/src/media/kavita/kavita_reachability.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

export 'package:fushi/src/media/kavita/kavita_reachability.dart';

/// 设备本地偏好：Kavita 漫画每章「上次成功同步」时刻（JSON 对象）。
///
/// 已登记进 `kKnownPreferenceKeys` 与 `SyncRepository.deviceLocalPrefKeys`
/// （同步时刻只对这台设备的本地进度有意义，漂到别的设备会让决策基线错位）。
const String kKavitaMangaSyncStatePref = 'kavita_manga_sync_state';

/// 同步路径上被吞掉的失败留一条可查的记录。文本过 `redactCredentialsInText`
/// （Kavita 的图片 URL 带 apiKey，异常文本里可能带出整条 URL）。
void _logSyncError(String stage, Object error, StackTrace stack) {
  ErrorLogService.instance.log(
    'KavitaMangaSync.$stage',
    redactCredentialsInText('$error'),
    stack,
  );
}

/// 两侧都动过时询问用户：返回 [KavitaSyncAction.adoptServer] /
/// [KavitaSyncAction.pushLocal]，其它值（或抛错）按「保留本地、不推送」处理。
typedef KavitaMangaConflictPrompt =
    Future<KavitaSyncAction> Function(
      KavitaProgress server,
      MangaChapterStateRow local,
    );

/// 一章的同步基线：上次成功同步的本地时刻 + 那时两侧一致的页（未知为 null）。
typedef KavitaMangaSyncStamp = ({int at, int? page});

/// 每章「上次成功同步」基线的存取。
abstract interface class KavitaMangaSyncStampStore {
  KavitaMangaSyncStamp? stampOf(String bookUid, String chapterKey);

  /// 一本书全部章的基线（chapterKey → 基线），一次读出（gap-mangamisc-3：
  /// 作品页对账 / 批量标记逐章 [stampOf] 时，偏好实现每章都要整份解码一次）。
  Map<String, KavitaMangaSyncStamp> stampsOfBook(String bookUid);

  /// 记一次成功同步。[page] 是这次同步后两侧一致的页；拉取后两侧仍不一致时传
  /// null，保留旧的页级基线。实现不得抛错（同步路径上的记账失败不能影响阅读）。
  Future<void> record(String bookUid, String chapterKey, int at, {int? page});

  /// 一次记多章（语义逐项同 [record]），偏好实现只读写一次。不得抛错。
  Future<void> recordAll(String bookUid, List<KavitaMangaSyncRecord> records);
}

/// [KavitaMangaSyncStampStore.recordAll] 的一项。
typedef KavitaMangaSyncRecord = ({String chapterKey, int at, int? page});

Map<String, KavitaMangaSyncStamp> _stampsOfBook(
  Map<String, KavitaMangaSyncStamp> all,
  String bookUid,
) {
  final String prefix = '$bookUid|';
  return <String, KavitaMangaSyncStamp>{
    for (final MapEntry<String, KavitaMangaSyncStamp> e in all.entries)
      if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
  };
}

/// 纯内存实现（测试 / 无偏好可用时）。
class InMemoryKavitaMangaSyncStampStore implements KavitaMangaSyncStampStore {
  final Map<String, KavitaMangaSyncStamp> stamps =
      <String, KavitaMangaSyncStamp>{};

  /// 只读时刻（测试 / 诊断用）。
  int? lastSyncAt(String bookUid, String chapterKey) =>
      stampOf(bookUid, chapterKey)?.at;

  @override
  KavitaMangaSyncStamp? stampOf(String bookUid, String chapterKey) =>
      stamps[_stampKey(bookUid, chapterKey)];

  @override
  Map<String, KavitaMangaSyncStamp> stampsOfBook(String bookUid) =>
      _stampsOfBook(stamps, bookUid);

  @override
  Future<void> record(
    String bookUid,
    String chapterKey,
    int at, {
    int? page,
  }) async {
    final String key = _stampKey(bookUid, chapterKey);
    stamps[key] = (at: at, page: page ?? stamps[key]?.page);
  }

  @override
  Future<void> recordAll(
    String bookUid,
    List<KavitaMangaSyncRecord> records,
  ) async {
    for (final KavitaMangaSyncRecord r in records) {
      await record(bookUid, r.chapterKey, r.at, page: r.page);
    }
  }
}

/// 落在 [kKavitaMangaSyncStatePref] 的实现：读写都经调用方给的偏好读写函数
/// （测试缝；生产传 `PreferencesRepository.getPref` / `setPref`）。
///
/// 条目数封顶 [maxEntries]，超出时丢最旧的时刻——丢掉只意味着那一章下次开时按
/// 「从没同步过」比较时间戳，不会丢进度。
class PrefKavitaMangaSyncStampStore implements KavitaMangaSyncStampStore {
  PrefKavitaMangaSyncStampStore({
    required String Function() read,
    required Future<void> Function(String value) write,
    this.maxEntries = 2000,
  }) : _read = read,
       _write = write;

  final String Function() _read;
  final Future<void> Function(String value) _write;
  final int maxEntries;

  Map<String, KavitaMangaSyncStamp> _load() {
    try {
      final Object? decoded = jsonDecode(_read());
      if (decoded is! Map<String, Object?>) {
        return <String, KavitaMangaSyncStamp>{};
      }
      final Map<String, KavitaMangaSyncStamp> out =
          <String, KavitaMangaSyncStamp>{};
      for (final MapEntry<String, Object?> e in decoded.entries) {
        final Object? value = e.value;
        if (value is Map<String, Object?> && value['at'] is int) {
          out[e.key] = (
            at: value['at']! as int,
            page: value['page'] is int ? value['page']! as int : null,
          );
        }
      }
      return out;
    } on Object {
      return <String, KavitaMangaSyncStamp>{};
    }
  }

  /// 只读时刻（测试 / 诊断用）。
  int? lastSyncAt(String bookUid, String chapterKey) =>
      stampOf(bookUid, chapterKey)?.at;

  @override
  KavitaMangaSyncStamp? stampOf(String bookUid, String chapterKey) =>
      _load()[_stampKey(bookUid, chapterKey)];

  @override
  Map<String, KavitaMangaSyncStamp> stampsOfBook(String bookUid) =>
      _stampsOfBook(_load(), bookUid);

  @override
  Future<void> record(String bookUid, String chapterKey, int at, {int? page}) =>
      recordAll(bookUid, <KavitaMangaSyncRecord>[
        (chapterKey: chapterKey, at: at, page: page),
      ]);

  @override
  Future<void> recordAll(
    String bookUid,
    List<KavitaMangaSyncRecord> records,
  ) async {
    if (records.isEmpty) return;
    try {
      final Map<String, KavitaMangaSyncStamp> stamps = _load();
      for (final KavitaMangaSyncRecord r in records) {
        final String key = _stampKey(bookUid, r.chapterKey);
        stamps[key] = (at: r.at, page: r.page ?? stamps[key]?.page);
      }
      if (stamps.length > maxEntries) {
        final List<MapEntry<String, KavitaMangaSyncStamp>> sorted =
            stamps.entries.toList()..sort(
              (
                MapEntry<String, KavitaMangaSyncStamp> a,
                MapEntry<String, KavitaMangaSyncStamp> b,
              ) => a.value.at.compareTo(b.value.at),
            );
        for (final MapEntry<String, KavitaMangaSyncStamp> e in sorted.take(
          stamps.length - maxEntries,
        )) {
          stamps.remove(e.key);
        }
      }
      await _write(
        jsonEncode(<String, Object?>{
          for (final MapEntry<String, KavitaMangaSyncStamp> e in stamps.entries)
            e.key: <String, Object?>{
              'at': e.value.at,
              if (e.value.page != null) 'page': e.value.page,
            },
        }),
      );
    } on Object catch (e, stack) {
      // 记账失败：下次开章按「从没同步过」比较，不影响阅读。
      _logSyncError('recordStamp', e, stack);
    }
  }
}

String _stampKey(String bookUid, String chapterKey) => '$bookUid|$chapterKey';

/// 开章时按离线放行、随后探针在拉取预算内答上话且对账结论是「采用服务器进度」时，
/// 问阅读器能不能现在跳到 [page]（0 起，已按页数钳过）。阅读器只在本章已装好、
/// 用户还停在落点没翻过页时返回 true（并自行安排跳页，读完的章不跳）；返回 false
/// 则本章维持离线放行的状态，什么都不写。
typedef KavitaLateAdoptHandler = bool Function(int page);

/// 一次对账落到本地之后的结果（开章与探针迟到时共用）。
typedef _KavitaSyncApplied = ({
  int? adoptedPage,
  int? lastPushedPage,
  bool pushLocal,
  int? syncedPage,
});

/// 服务器进度与本地章进度按 `resolveKavitaProgress` 裁决；两侧都动过时询问
/// （没有询问入口或本地没有记录时按「不动」）。
Future<KavitaSyncAction> _decideKavitaSync({
  required KavitaProgress remote,
  required MangaChapterStateRow? local,
  required KavitaMangaSyncStamp? stamp,
  required KavitaMangaConflictPrompt? promptConflict,
}) async {
  final KavitaSyncDecision decision = resolveKavitaProgress(
    serverPage: remote.lastModifiedUtc == null ? null : remote.pageNum,
    serverModifiedAt: remote.lastModifiedUtc?.millisecondsSinceEpoch,
    localPage: local?.lastPage,
    localUpdatedAt: local?.updatedAt,
    lastSyncAt: stamp?.at,
    // 标已读等同页落库也会刷新 updatedAt；本地仍停在上次一致的页就不算动过。
    lastSyncedPage: stamp?.page,
  );
  if (decision.action != KavitaSyncAction.conflict) return decision.action;
  if (promptConflict == null || local == null) return KavitaSyncAction.none;
  try {
    return await promptConflict(remote, local);
  } on Object {
    return KavitaSyncAction.none;
  }
}

/// 采用服务器进度时落到本地的页：按本章页数钳过。
int _kavitaAdoptPage(KavitaProgress remote, int pages) {
  final int maxPage = pages > 0 ? pages - 1 : remote.pageNum;
  return remote.pageNum.clamp(0, maxPage < 0 ? 0 : maxPage);
}

/// 把裁决 [action] 落进本地章进度（只有采用服务器才写库）。
Future<_KavitaSyncApplied> _applyKavitaSync({
  required KavitaSyncAction action,
  required FushiDatabase db,
  required String bookUid,
  required String chapterKey,
  required KavitaProgress remote,
  required MangaChapterStateRow? local,
  required int pages,
  required int Function() now,
}) async {
  switch (action) {
    case KavitaSyncAction.adoptServer:
      final int page = _kavitaAdoptPage(remote, pages);
      await db.saveMangaChapterState(
        bookUid: bookUid,
        chapterKey: chapterKey,
        lastPage: page,
        pageCount: pages > 0 ? pages : null,
        // 服务器读到末页 = 那边读完了：本地也记已读（已读标记只增不减）。
        readAt: isKavitaChapterFinished(page: page, totalPages: pages)
            ? now()
            : null,
      );
      // 服务器上这章不是「读完」（含被网页端标未读回到第 0 页）：本地的已读标记
      // 也要撤掉，否则作品页仍显示已读。只在用户已确认采用服务器（冲突弹窗 /
      // 本机没动过）时走到这里，所以不会静默丢本机进度。
      if (local?.readAt != null &&
          !isKavitaChapterFinished(page: page, totalPages: pages)) {
        await db.clearMangaChapterRead(
          bookUid: bookUid,
          chapterKey: chapterKey,
        );
      }
      return (
        adoptedPage: page,
        lastPushedPage: page,
        pushLocal: false,
        syncedPage: page,
      );
    case KavitaSyncAction.pushLocal:
      return (
        adoptedPage: null,
        lastPushedPage: null,
        pushLocal: local != null,
        syncedPage: null,
      );
    case KavitaSyncAction.none:
    case KavitaSyncAction.conflict:
      final bool same = local != null && local.lastPage == remote.pageNum;
      return (
        adoptedPage: null,
        lastPushedPage: same ? remote.pageNum : null,
        pushLocal: false,
        syncedPage: same ? remote.pageNum : null,
      );
  }
}

class KavitaMangaSyncSession {
  KavitaMangaSyncSession._({
    required KavitaProgressSync sync,
    required this.bookUid,
    required this.chapterKey,
    required this.pageCount,
    this.adoptedPage,
  }) : _sync = sync;

  final KavitaProgressSync _sync;

  /// 已 [close]：迟到的探针对账不再动任何东西。
  bool _closed = false;

  /// 开章按离线放行后，探针在拉取预算内答上话、对账结论是采用服务器进度时调用
  /// （见 [KavitaLateAdoptHandler]）。阅读器在拿到会话后设置；没设置 = 不补采用。
  KavitaLateAdoptHandler? onLateAdopt;

  Future<void> _lateReconcile = Future<void>.value();

  /// 探针迟到对账（没有探针时立即完成）。只给测试等待用。
  Future<void> get lateReconcileDone => _lateReconcile;
  final String bookUid;

  /// 本会话对应的章 key（= Kavita chapterId 十进制串）。
  final String chapterKey;

  /// 本章总页数（chapter-info / 描述符给出；未知为 0）。
  final int pageCount;

  /// 打开时采用了服务器进度：已写进本地章进度的页（已按页数钳过）；否则 null。
  final int? adoptedPage;

  /// 拉取超时：开章路径上的网络等待上限。
  static const Duration kPullTimeout = Duration(seconds: 4);

  /// 关章时 flush 的等待上限。
  static const Duration kCloseFlushTimeout = Duration(seconds: 5);

  /// [entry] 是不是 Kavita 条目（阅读器用它决定要不要走同步）。
  static bool appliesTo(OnlineMangaLibraryEntry? entry) =>
      entry != null && entry.runtime == OnlineMangaRuntimeKind.kavita;

  /// 为 [entry] 的 [chapter] 建同步会话（含打开时的拉取与决策）；不适用返回 null。
  ///
  /// 网络 / 解析失败不抛错，按「不同步本章」或「离线放行」处理。
  ///
  /// [reachability] 记着这台服务器不可达时不等拉取（见 [KavitaReachability]）；
  /// 缺省用进程级的 [KavitaReachability.session]。
  static Future<KavitaMangaSyncSession?> attach({
    required FushiDatabase db,
    required String bookUid,
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    required List<KavitaServerConfig> servers,
    required KavitaApi Function(KavitaServerConfig) apiFor,
    required KavitaMangaSyncStampStore stamps,
    KavitaMangaConflictPrompt? promptConflict,
    KavitaReachability? reachability,
    Duration pullTimeout = kPullTimeout,
    Duration debounce = const Duration(seconds: 10),
    int Function()? nowMs,
  }) async {
    if (!appliesTo(entry) || bookUid.isEmpty) return null;
    final int? seriesId = int.tryParse(entry.series.key);
    final int? chapterId = int.tryParse(chapter.key);
    if (seriesId == null || chapterId == null) return null;
    KavitaServerConfig? server;
    for (final KavitaServerConfig s in servers) {
      if (s.id == entry.sourceId) server = s;
    }
    if (server == null || !server.isUsable) return null;

    final int Function() now =
        nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
    final KavitaApi api = apiFor(server);
    final String chapterKey = chapter.key;

    // 推送目标优先取描述符里刷新时存下的 id（不多一次往返）；缺字段才问 chapter-info。
    int? volumeId = _asInt(chapter.raw['volumeId']);
    int? libraryId = _asInt(entry.series.raw['libraryId']);
    int pages = _asInt(chapter.raw['pages']) ?? 0;
    final bool needInfo = volumeId == null || libraryId == null || pages <= 0;

    final KavitaReachability reach = reachability ?? KavitaReachability.session;
    final String serverId = server.id;
    KavitaProgress? remote;
    KavitaChapterInfo? info;
    final Stopwatch pullClock = Stopwatch()..start();
    final Future<List<Object?>> pull = Future.wait<Object?>(<Future<Object?>>[
      api.getProgress(chapterId),
      if (needInfo) api.getChapterInfo(chapterId),
    ]);
    Future<List<Object?>>? probe;
    if (reach.isUnreachable(serverId, api, within: pullTimeout)) {
      // 已知不可达：不等。请求照发、当探针——服务器答上来（哪怕答的是错误状态）
      // 协议层的答话计数就动，标记随之失效，下一次开章恢复完整对账。本章先按离线
      // 放行；探针若在拉取预算内带回了进度，会话建好后补做这一章的对账（见下）。
      // 探针自己的失败不用处理。
      probe = pull;
      unawaited(pull.then<void>((List<Object?> _) {}, onError: (Object _) {}));
    } else {
      try {
        final List<Object?> results = await pull.timeout(pullTimeout);
        remote = results[0] as KavitaProgress?;
        if (needInfo) info = results[1] as KavitaChapterInfo?;
      } on Object catch (e, stack) {
        remote = null; // 离线 / 超时 / 服务器错误：放行。
        info = null;
        if (isKavitaUnreachableError(e)) {
          // 离线是常态：每次断开只记一条诊断，不逐章刷屏。
          if (reach.markUnreachable(serverId, api)) {
            ErrorLogService.instance.logDiagnostic(
              'KavitaMangaSync.pull',
              'server unreachable, skipping pull waits until it answers: '
                  '${redactCredentialsInText('$e')}',
            );
          }
        } else {
          _logSyncError('pull', e, stack);
        }
      }
    }
    if (info != null) {
      volumeId = info.volumeId;
      libraryId = info.libraryId;
      if (info.pages > 0) pages = info.pages;
    }

    final MangaChapterStateRow? local = await db.getMangaChapterState(
      bookUid: bookUid,
      chapterKey: chapterKey,
    );
    if (pages <= 0) pages = local?.pageCount ?? 0;
    if (volumeId == null || libraryId == null) {
      // 离线且描述符缺 id：本章推不出去（ProgressDto 要全套 id），不建会话。
      return null;
    }

    int? lastPushedPage;
    bool pushLocalNow = false;
    int? adoptedPage;
    final KavitaMangaSyncStamp? stamp = stamps.stampOf(bookUid, chapterKey);
    int? lastSync = stamp?.at;
    if (remote != null) {
      final KavitaSyncAction action = await _decideKavitaSync(
        remote: remote,
        local: local,
        stamp: stamp,
        promptConflict: promptConflict,
      );
      final _KavitaSyncApplied applied = await _applyKavitaSync(
        action: action,
        db: db,
        bookUid: bookUid,
        chapterKey: chapterKey,
        remote: remote,
        local: local,
        pages: pages,
        now: now,
      );
      adoptedPage = applied.adoptedPage;
      lastPushedPage = applied.lastPushedPage;
      pushLocalNow = applied.pushLocal;
      lastSync = now();
      await stamps.record(
        bookUid,
        chapterKey,
        lastSync,
        page: applied.syncedPage,
      );
    }

    final KavitaProgressSync sync = KavitaProgressSync(
      api: api,
      target: KavitaProgressTarget(
        seriesId: seriesId,
        volumeId: volumeId,
        chapterId: chapterId,
        libraryId: libraryId,
        totalPages: pages,
      ),
      debounce: debounce,
      lastPushedPage: lastPushedPage,
      lastSyncAt: lastSync,
      // 拉取成功并决策过 = 已确认服务器状态，推送前不必再校验。
      serverVerified: remote != null,
      nowMs: now,
      onPushed: (int page, String? scrollId, int at) {
        unawaited(stamps.record(bookUid, chapterKey, at, page: page));
      },
      onPushFailed: (Object error, StackTrace stack) => reportKavitaSyncFailure(
        source: 'KavitaMangaSync.push',
        error: error,
        stack: stack,
        reachability: reach,
        serverId: serverId,
        api: api,
      ),
    );
    final KavitaMangaSyncSession session = KavitaMangaSyncSession._(
      sync: sync,
      bookUid: bookUid,
      chapterKey: chapterKey,
      pageCount: pages,
      adoptedPage: adoptedPage,
    );
    if (pushLocalNow && local != null) {
      sync.reportPage(local.lastPage);
      unawaited(sync.flush());
    }
    if (probe != null) {
      // 服务器其实已经回来了：探针在拉取预算内（= 不跳过等待时本来就会用上的
      // 时间）带回了进度，就按开章时读到的本地状态补做这一章的对账，免得「恢复
      // 后的第一次开章仍按离线放行」。答得比预算慢的只让下一次开章恢复对账。
      session._lateReconcile = probe.then<void>((List<Object?> results) async {
        if (pullClock.elapsed > pullTimeout) return;
        final KavitaProgress? late = results[0] as KavitaProgress?;
        if (late == null) return;
        try {
          await session._reconcileLate(
            remote: late,
            db: db,
            stamps: stamps,
            local: local,
            stamp: stamp,
            pages: pages,
            promptConflict: promptConflict,
            now: now,
          );
        } on Object catch (e, stack) {
          _logSyncError('lateReconcile', e, stack);
        }
      }, onError: (Object _) {});
    }
    return session;
  }

  /// 开章按离线放行之后，探针及时带回了服务器进度：用开章时读到的 [local] /
  /// [stamp] 补做对账（阅读器之后落的页不参与裁决——那是落点，不是用户的改动）。
  ///
  /// - 采用服务器：先问 [onLateAdopt]，阅读器同意（本章已装好、用户没翻过页）才
  ///   写库并让它跳页；不同意就什么都不写，维持离线放行。
  /// - 推本地：推开章时的本地页；阅读器已经报过页（待推）就让那一页去推。
  /// - 其余：只记同步基线、此后推送不再做「服务器更新」校验。
  Future<void> _reconcileLate({
    required KavitaProgress remote,
    required FushiDatabase db,
    required KavitaMangaSyncStampStore stamps,
    required MangaChapterStateRow? local,
    required KavitaMangaSyncStamp? stamp,
    required int pages,
    required KavitaMangaConflictPrompt? promptConflict,
    required int Function() now,
  }) async {
    if (_closed) return;
    final KavitaSyncAction action = await _decideKavitaSync(
      remote: remote,
      local: local,
      stamp: stamp,
      promptConflict: promptConflict,
    );
    if (_closed) return;
    if (action == KavitaSyncAction.adoptServer) {
      final KavitaLateAdoptHandler? handler = onLateAdopt;
      if (handler == null || !handler(_kavitaAdoptPage(remote, pages))) return;
      // 阅读器跳页后会把这一页报回来：先把它记成已推，免得原样推回服务器。
      _sync.acceptServerState(
        lastPushedPage: _kavitaAdoptPage(remote, pages),
        syncedAt: now(),
      );
    }
    final _KavitaSyncApplied applied = await _applyKavitaSync(
      action: action,
      db: db,
      bookUid: bookUid,
      chapterKey: chapterKey,
      remote: remote,
      local: local,
      pages: pages,
      now: now,
    );
    final int at = now();
    _sync.acceptServerState(
      lastPushedPage: applied.lastPushedPage,
      syncedAt: at,
    );
    await stamps.record(bookUid, chapterKey, at, page: applied.syncedPage);
    if (applied.pushLocal && local != null && !_closed) {
      if (!_sync.hasPending) _sync.reportPage(local.lastPage);
      unawaited(_sync.flush());
    }
  }

  /// 阅读器每次章进度落库后调用；[chapterKey] 不是本会话的章时忽略
  /// （换章过程中旧章的迟到写入不能被记到新章头上）。
  void onPageSaved(String chapterKey, int page) {
    if (chapterKey != this.chapterKey) return;
    _sync.reportPage(page);
  }

  bool get hasPending => _sync.hasPending;

  /// 关章：限时 flush 待推进度，然后释放。永不抛错（关书路径不能被网络拖住）。
  Future<void> close() async {
    _closed = true;
    onLateAdopt = null;
    try {
      await _sync.flush().timeout(kCloseFlushTimeout);
    } on TimeoutException {
      // 推送挂过了关章上限（服务器慢 / 不可达）：未推出的进度下次打开时由本地章进度
      // 与服务器对账。推送本身的失败由 onPushFailed 记账，这里不重复记。
    } on Object catch (e, stack) {
      _logSyncError('close', e, stack);
    } finally {
      _sync.dispose();
    }
  }
}

int? _asInt(Object? value) => switch (value) {
  final int v => v,
  final num v => v.toInt(),
  final String v => int.tryParse(v),
  _ => null,
};

/// 作品页刷新后把服务器的逐章已读状态并进本地章进度（`manga_chapter_states`）。
///
/// 只处理**本机还没有记录**的章（别的设备读过、这台从没打开）和「服务器已读完而
/// 本机没标已读」的章；本机已有进度的章（半途页号）不动——它们的新旧由开章时的
/// [KavitaMangaSyncSession.attach] 逐章精确裁决（含冲突询问），这里没有服务器时刻
/// 可比。读完的章只增不减，与阅读器的已读标记规则一致。
///
/// 服务器把某章标未读（pagesRead 回 0）而本机仍是已读的情形**不在这里处理**：
/// 这里既没有服务器时刻也没有同步基线，分不出「服务器被重置」和「本机离线读完、
/// 还没推上去」，贸然清掉会丢本机进度。该情形由开章时的 attach 按页基线裁决
/// （本机没动过 → 冲突弹窗，用户选采用服务器才清已读），与 EPUB 一致。
////// [chapters] 是描述符章表（`raw` 里有刷新时存的 `pages` / `pagesRead`）。返回
/// 写入的章数。永不抛错。
///
/// [stamps] 给了时，本机有**未推上去**的改动（章进度页 != 同步基线页，例如离线时
/// 标的已读 / 未读）的章也跳过：服务器那份是旧的，按它改会把本机的标记撤销；这些
/// 章在开章时由 attach 按基线判成「本地动过」推上去。
Future<int> reconcileKavitaChapterStates({
  required FushiDatabase db,
  required String bookUid,
  required List<OnlineMangaChapter> chapters,
  KavitaMangaSyncStampStore? stamps,
  int Function()? nowMs,
}) async {
  if (bookUid.isEmpty) return 0;
  final int Function() now =
      nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
  int written = 0;
  try {
    final Map<String, MangaChapterStateRow> states = await db
        .getMangaChapterStates(bookUid);
    // 基线一次读全（gap-mangamisc-3），不逐章整份解码偏好。
    final Map<String, KavitaMangaSyncStamp> baselines =
        stamps?.stampsOfBook(bookUid) ?? const <String, KavitaMangaSyncStamp>{};
    final int readAt = now();
    final List<MangaChapterStateWrite> writes = <MangaChapterStateWrite>[];
    for (final OnlineMangaChapter chapter in chapters) {
      final int pages = _asInt(chapter.raw['pages']) ?? 0;
      final int pagesRead = _asInt(chapter.raw['pagesRead']) ?? 0;
      if (pages <= 0 || pagesRead <= 0) continue;
      final MangaChapterStateRow? local = states[chapter.key];
      final int? baseline = baselines[chapter.key]?.page;
      if (local != null && baseline != null && local.lastPage != baseline) {
        continue;
      }
      final bool serverFinished = pagesRead >= pages;
      if (local != null && !(serverFinished && local.readAt == null)) continue;
      final int page = (serverFinished ? pages - 1 : pagesRead).clamp(
        0,
        pages - 1,
      );
      writes.add((
        chapterKey: chapter.key,
        lastPage: serverFinished ? (local?.lastPage ?? page) : page,
        pageCount: pages,
        readAt: serverFinished ? readAt : null,
        clearRead: false,
      ));
    }
    // 一个事务、同一时间戳（gap-mangamisc-2）：逐章写时最后写的最旧那章 updatedAt
    // 最大，「继续阅读」会落到它上面。
    await db.saveMangaChapterStates(bookUid: bookUid, writes: writes);
    written = writes.length;
  } on Object catch (e, stack) {
    // 对账失败不影响作品页展示；下次刷新再来。
    _logSyncError('reconcile', e, stack);
  }
  return written;
}

/// [alignKavitaMangaChapterMarks] 的一项：章 key + 本章总页数（未知 0）+ 作品页最近
/// 一次从服务器取到的这一章进度页（未知 null）。
typedef KavitaChapterMarkTarget = ({
  String chapterKey,
  int totalPages,
  int? knownServerPage,
});

/// 在 Fushi 里手动把一章标已读 / 未读（Kavita 条目；服务器那边已由调用方标好）后，
/// 对齐本地章进度与同步基线。单章版，见 [alignKavitaMangaChapterMarks]。
Future<void> alignKavitaMangaChapterMark({
  required FushiDatabase db,
  required KavitaMangaSyncStampStore stamps,
  required String bookUid,
  required String chapterKey,
  required bool read,
  int totalPages = 0,
  bool serverConfirmed = true,
  int? knownServerPage,
  int Function()? nowMs,
}) =>
    alignKavitaMangaChapterMarks(
      db: db,
      stamps: stamps,
      bookUid: bookUid,
      chapters: <KavitaChapterMarkTarget>[
        (
          chapterKey: chapterKey,
          totalPages: totalPages,
          knownServerPage: knownServerPage,
        ),
      ],
      read: read,
      serverConfirmed: serverConfirmed,
      nowMs: nowMs,
    );

/// 在 Fushi 里手动把一批章标已读 / 未读（Kavita 条目；服务器那边已由调用方标好）
/// 后，对齐本地章进度与同步基线。
///
/// 位置与基线必须一起改：只改服务器，下次开章时本地旧页 != 基线会被
/// [resolveKavitaProgress] 判成「本地动过」，把旧进度推回去，等于标记被撤销。
/// - 标未读：`readAt` 清空、`lastPage` 回 0、基线页 0；
/// - 标已读：`readAt` 记现在、`lastPage` 落最后一页（`totalPages` 未知则不动页）、
///   基线页同步。
///
/// 整批一个事务、同一时间戳（gap-mangamisc-2）：逐章写时最后写的最旧那章
/// `updatedAt` 最大，「继续阅读」会落到已读过的旧章上。基线一次读、一次写
/// （gap-mangamisc-3）。
///
/// [serverConfirmed] = false：服务器没标成（离线 / 出错）。本机照样生效，但基线
/// **不**前移到新页——基线留在服务器上一次已知的页（已有基线不动；从没有基线时用
/// `knownServerPage`，即作品页最近一次从服务器取到的这一章进度），于是本机页 !=
/// 基线 = 「本地动过、还没推」：开章时 attach 把它推上去，作品页刷新时的
/// [reconcileKavitaChapterStates] 也不会按服务器的旧状态把它改回去。
/// 永不抛错。
Future<void> alignKavitaMangaChapterMarks({
  required FushiDatabase db,
  required KavitaMangaSyncStampStore stamps,
  required String bookUid,
  required List<KavitaChapterMarkTarget> chapters,
  required bool read,
  bool serverConfirmed = true,
  int Function()? nowMs,
}) async {
  final List<KavitaChapterMarkTarget> targets = <KavitaChapterMarkTarget>[
    for (final KavitaChapterMarkTarget c in chapters)
      if (c.chapterKey.isNotEmpty) c,
  ];
  if (bookUid.isEmpty || targets.isEmpty) return;
  final int now = (nowMs ?? () => DateTime.now().millisecondsSinceEpoch)();
  try {
    final Map<String, MangaChapterStateRow> existing = await db
        .getMangaChapterStates(bookUid);
    final List<MangaChapterStateWrite> writes = <MangaChapterStateWrite>[];
    for (final KavitaChapterMarkTarget c in targets) {
      final MangaChapterStateRow? row = existing[c.chapterKey];
      final int pages = c.totalPages > 0 ? c.totalPages : (row?.pageCount ?? 0);
      final int page = read ? (pages > 0 ? pages - 1 : row?.lastPage ?? 0) : 0;
      writes.add((
        chapterKey: c.chapterKey,
        lastPage: page,
        pageCount: pages > 0 ? pages : null,
        readAt: read ? now : null,
        clearRead: !read,
      ));
    }
    await db.saveMangaChapterStates(bookUid: bookUid, writes: writes);
    if (serverConfirmed) {
      await stamps.recordAll(bookUid, <KavitaMangaSyncRecord>[
        for (final MangaChapterStateWrite w in writes)
          (chapterKey: w.chapterKey, at: now, page: w.lastPage),
      ]);
    } else {
      final Map<String, KavitaMangaSyncStamp> baselines = stamps.stampsOfBook(
        bookUid,
      );
      await stamps.recordAll(bookUid, <KavitaMangaSyncRecord>[
        for (final KavitaChapterMarkTarget c in targets)
          if (baselines[c.chapterKey]?.page == null &&
              c.knownServerPage != null)
            (
              chapterKey: c.chapterKey,
              at: baselines[c.chapterKey]?.at ?? now,
              page: c.knownServerPage,
            ),
      ]);
    }
  } on Object catch (e, stack) {
    // 对齐失败：下次开章由逐章对账兜底。
    _logSyncError('alignMark', e, stack);
  }
}
