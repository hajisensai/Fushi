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
///    超时，离线直接放行，不卡开章；
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

import 'package:fushi/src/media/kavita/kavita_progress_resolver.dart';
import 'package:fushi/src/media/kavita/kavita_progress_sync.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 设备本地偏好：Kavita 漫画每章「上次成功同步」时刻（JSON 对象）。
///
/// 已登记进 `kKnownPreferenceKeys` 与 `SyncRepository.deviceLocalPrefKeys`
/// （同步时刻只对这台设备的本地进度有意义，漂到别的设备会让决策基线错位）。
const String kKavitaMangaSyncStatePref = 'kavita_manga_sync_state';

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

  /// 记一次成功同步。[page] 是这次同步后两侧一致的页；拉取后两侧仍不一致时传
  /// null，保留旧的页级基线。实现不得抛错（同步路径上的记账失败不能影响阅读）。
  Future<void> record(String bookUid, String chapterKey, int at, {int? page});
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
  Future<void> record(
    String bookUid,
    String chapterKey,
    int at, {
    int? page,
  }) async {
    final String key = _stampKey(bookUid, chapterKey);
    stamps[key] = (at: at, page: page ?? stamps[key]?.page);
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
  Future<void> record(
    String bookUid,
    String chapterKey,
    int at, {
    int? page,
  }) async {
    try {
      final Map<String, KavitaMangaSyncStamp> stamps = _load();
      final String key = _stampKey(bookUid, chapterKey);
      stamps[key] = (at: at, page: page ?? stamps[key]?.page);
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
    } on Object {
      // 记账失败：下次开章按「从没同步过」比较，不影响阅读。
    }
  }
}

String _stampKey(String bookUid, String chapterKey) => '$bookUid|$chapterKey';

class KavitaMangaSyncSession {
  KavitaMangaSyncSession._({
    required KavitaProgressSync sync,
    required this.bookUid,
    required this.chapterKey,
    required this.pageCount,
    this.adoptedPage,
  }) : _sync = sync;

  final KavitaProgressSync _sync;
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
  /// 永不抛错：任何网络 / 解析失败都按「不同步本章」或「离线放行」处理。
  static Future<KavitaMangaSyncSession?> attach({
    required FushiDatabase db,
    required String bookUid,
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    required List<KavitaServerConfig> servers,
    required KavitaApi Function(KavitaServerConfig) apiFor,
    required KavitaMangaSyncStampStore stamps,
    KavitaMangaConflictPrompt? promptConflict,
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

    KavitaProgress? remote;
    KavitaChapterInfo? info;
    try {
      final List<Object?> results = await Future.wait<Object?>(
        <Future<Object?>>[
          api.getProgress(chapterId),
          if (needInfo) api.getChapterInfo(chapterId),
        ],
      ).timeout(pullTimeout);
      remote = results[0] as KavitaProgress?;
      if (needInfo) info = results[1] as KavitaChapterInfo?;
    } on Object {
      remote = null; // 离线 / 超时 / 服务器错误：放行。
      info = null;
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
    int? syncedPage;
    if (remote != null) {
      final KavitaSyncDecision decision = resolveKavitaProgress(
        serverPage: remote.lastModifiedUtc == null ? null : remote.pageNum,
        serverModifiedAt: remote.lastModifiedUtc?.millisecondsSinceEpoch,
        localPage: local?.lastPage,
        localUpdatedAt: local?.updatedAt,
        lastSyncAt: lastSync,
        // 标已读等同页落库也会刷新 updatedAt；本地仍停在上次一致的页就不算动过。
        lastSyncedPage: stamp?.page,
      );
      KavitaSyncAction action = decision.action;
      if (action == KavitaSyncAction.conflict) {
        action = KavitaSyncAction.none;
        if (promptConflict != null && local != null) {
          try {
            action = await promptConflict(remote, local);
          } on Object {
            action = KavitaSyncAction.none;
          }
        }
      }
      switch (action) {
        case KavitaSyncAction.adoptServer:
          final int maxPage = pages > 0 ? pages - 1 : remote.pageNum;
          final int page = remote.pageNum.clamp(0, maxPage < 0 ? 0 : maxPage);
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
          adoptedPage = page;
          lastPushedPage = page;
          syncedPage = page;
        case KavitaSyncAction.pushLocal:
          pushLocalNow = local != null;
        case KavitaSyncAction.none:
        case KavitaSyncAction.conflict:
          if (local != null && local.lastPage == remote.pageNum) {
            lastPushedPage = remote.pageNum;
            syncedPage = remote.pageNum;
          }
      }
      lastSync = now();
      await stamps.record(bookUid, chapterKey, lastSync, page: syncedPage);
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
    return session;
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
    try {
      await _sync.flush().timeout(kCloseFlushTimeout);
    } on Object {
      // 超时 / 离线：未推出的进度下次打开时由本地章进度与服务器对账。
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
