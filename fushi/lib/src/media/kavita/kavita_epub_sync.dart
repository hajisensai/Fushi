/// Kavita EPUB 的阅读进度双向同步（打开时拉取 + 阅读中推送）。
///
/// 位置映射（**有损，已接受**）：Kavita 的 EPUB 进度是 `pageNum`（脊柱页下标，
/// 0 起）+ 可选 `bookScrollId`；Fushi 存的是 `sectionIndex`（同样的脊柱章下标）+
/// 章内字符偏移。脊柱下标两侧一一对应，所以章级位置能精确往返；章内偏移没有共同
/// 单位，只留在本地（`bookScrollId` v1 不产生也不消费）。采用服务器进度时落在目标章
/// 的章首。
///
/// 流程：
/// 1. [attach] 在阅读器恢复位置**之前**调用：拉服务器进度 → 与本地阅读位置按
///    `resolveKavitaProgress` 决策 → 采用服务器（写本地位置，阅读器随后自然恢复到
///    那里）/ 推本地 / 冲突时询问 / 不动。拉取有短超时，离线直接放行，不卡开书；
/// 2. 阅读中每次位置落库后调 [onPositionSaved]，由 `KavitaProgressSync` 防抖上报；
/// 3. 关书时 [close]：限时 flush 再释放。
///
/// 非 Kavita 书（`sourceMetadata` 不是绑定）或服务器未配置 / 已停用时 [attach] 返回
/// null，阅读器按普通书处理。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';

import 'package:fushi/src/media/kavita/kavita_book_binding.dart';
import 'package:fushi/src/media/kavita/kavita_book_service.dart';
import 'package:fushi/src/media/kavita/kavita_progress_resolver.dart';
import 'package:fushi/src/media/kavita/kavita_progress_sync.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';

/// 两侧都动过时询问用户：返回 [KavitaSyncAction.adoptServer] /
/// [KavitaSyncAction.pushLocal]，其它值（或抛错）按「保留本地、不推送」处理。
typedef KavitaConflictPrompt =
    Future<KavitaSyncAction> Function(
      KavitaProgress server,
      ReaderPositionRow? local,
    );

class KavitaEpubSyncSession {
  KavitaEpubSyncSession._({
    required KavitaProgressSync sync,
    required this.bookKey,
  }) : _sync = sync;

  final KavitaProgressSync _sync;
  final String bookKey;

  /// 拉取超时：开书路径上的网络等待上限。
  static const Duration kPullTimeout = Duration(seconds: 4);

  /// 关书时 flush 的等待上限。
  static const Duration kCloseFlushTimeout = Duration(seconds: 5);

  /// 为 [row] 建同步会话（含打开时的拉取与决策）；不适用返回 null。
  static Future<KavitaEpubSyncSession?> attach({
    required FushiDatabase db,
    required EpubBookRow row,
    required List<KavitaServerConfig> servers,
    required KavitaApi Function(KavitaServerConfig) apiFor,
    KavitaConflictPrompt? promptConflict,
    void Function(int serverSections, int localSections)?
    onSectionCountMismatch,
    Duration pullTimeout = kPullTimeout,
    Duration debounce = const Duration(seconds: 10),
    int Function()? nowMs,
  }) async {
    final KavitaBookBinding? binding = KavitaBookBinding.tryParse(
      row.sourceMetadata,
    );
    if (binding == null || row.uid.isEmpty) return null;
    KavitaServerConfig? server;
    for (final KavitaServerConfig s in servers) {
      if (s.id == binding.serverConfigId) server = s;
    }
    if (server == null || !server.isUsable) return null;

    final int Function() now =
        nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
    final KavitaApi api = apiFor(server);
    final KavitaBookService store = KavitaBookService(db: db, nowMs: now);
    final int lastSection = row.chapterCount > 0 ? row.chapterCount - 1 : 0;

    KavitaProgress? remote;
    KavitaChapterInfo? info;
    try {
      final List<Object?> results = await Future.wait<Object?>(
        <Future<Object?>>[
          api.getProgress(binding.chapterId),
          // 页数只用来核对两侧的脊柱下标是否对得上；拿不到就当未知放行。
          api
              .getChapterInfo(binding.chapterId)
              .then<Object?>(
                (KavitaChapterInfo i) => i,
                onError: (Object _) => null,
              ),
        ],
      ).timeout(pullTimeout);
      remote = results[0] as KavitaProgress?;
      info = results[1] as KavitaChapterInfo?;
    } on Object {
      remote = null; // 离线 / 超时 / 服务器错误：放行，稍后首次推送前再校验。
      info = null;
    }
    // Kavita 的 pageNum 与本地 sectionIndex 都是脊柱下标，只有两侧章数一致才一一
    // 对应。不一致（Fushi 丢了非 HTML / 缺文件的脊柱项，或 Kavita 跳过了某些项）时
    // 任何拉取 / 推送都会落到错的一章，宁可整本不同步——但不能静默：交给调用方
    // 告诉用户这本书的进度不会同步（阅读器弹提示）。
    if (info != null &&
        info.pages > 0 &&
        row.chapterCount > 0 &&
        info.pages != row.chapterCount) {
      debugPrint(
        '[kavita-sync] ${row.bookKey}: server lists ${info.pages} sections, '
        'local copy has ${row.chapterCount}; progress sync disabled',
      );
      onSectionCountMismatch?.call(info.pages, row.chapterCount);
      return null;
    }

    int? lastPushedPage = binding.lastPushedPage;
    bool pushLocalNow = false;
    int? localPageToPush;
    if (remote != null) {
      final ReaderPositionRow? local = await db.getReaderPosition(row.uid);
      final KavitaSyncDecision decision = decideKavitaEpubSync(
        binding: binding,
        remote: remote,
        local: local,
      );
      KavitaSyncAction action = decision.action;
      if (action == KavitaSyncAction.conflict) {
        action = KavitaSyncAction.none;
        if (promptConflict != null) {
          try {
            action = await promptConflict(remote, local);
          } on Object {
            action = KavitaSyncAction.none;
          }
        }
      }
      switch (action) {
        case KavitaSyncAction.adoptServer:
          final int page = remote.pageNum.clamp(0, lastSection);
          await ReaderPositionRepository(
            db,
          ).save(bookUid: row.uid, sectionIndex: page, normCharOffset: 0);
          lastPushedPage = page;
          await store.recordSync(row.bookKey, pulled: true, page: page);
        case KavitaSyncAction.pushLocal:
          pushLocalNow = local != null;
          localPageToPush = local?.sectionIndex;
          await store.recordSync(row.bookKey, pulled: true);
        case KavitaSyncAction.none:
        case KavitaSyncAction.conflict:
          final bool agreed =
              local != null && local.sectionIndex == remote.pageNum;
          if (agreed) lastPushedPage = remote.pageNum;
          await store.recordSync(
            row.bookKey,
            pulled: true,
            page: agreed ? remote.pageNum : null,
          );
      }
    }

    final KavitaBookBinding fresh =
        await store.bindingFor(row.bookKey) ?? binding;
    final KavitaProgressSync sync = KavitaProgressSync(
      api: api,
      target: KavitaProgressTarget(
        seriesId: binding.seriesId,
        volumeId: binding.volumeId,
        chapterId: binding.chapterId,
        libraryId: binding.libraryId,
        totalPages: row.chapterCount,
      ),
      debounce: debounce,
      lastPushedPage: lastPushedPage,
      lastSyncAt: _maxOrNull(fresh.lastPushedAt, fresh.lastPulledAt),
      // 拉取成功并决策过 = 已确认服务器状态，推送前不必再校验。
      serverVerified: remote != null,
      nowMs: now,
      onPushed: (int page, String? scrollId, int at) {
        unawaited(
          store
              .recordSync(row.bookKey, pushed: true, page: page)
              .catchError((Object _) {}),
        );
      },
    );
    final KavitaEpubSyncSession session = KavitaEpubSyncSession._(
      sync: sync,
      bookKey: row.bookKey,
    );
    if (pushLocalNow && localPageToPush != null) {
      sync.reportPage(localPageToPush);
      unawaited(sync.flush());
    }
    return session;
  }

  /// 阅读器每次位置落库后调用；[sectionIndex] 即脊柱页下标。
  void onPositionSaved(int sectionIndex) => _sync.reportPage(sectionIndex);

  bool get hasPending => _sync.hasPending;

  /// 关书：限时 flush 待推进度，然后释放。永不抛错（关书路径不能被网络拖住）。
  Future<void> close() async {
    try {
      await _sync.flush().timeout(kCloseFlushTimeout);
    } on Object {
      // 超时 / 离线：未推出的进度下次打开时由本地位置与服务器对账。
    } finally {
      _sync.dispose();
    }
  }
}

/// 打开时与后台对账共用的决策：服务器进度 [remote] 对本地位置 [local]，以绑定里的
/// 同步戳与 `lastPushedPage` 为基线。
KavitaSyncDecision decideKavitaEpubSync({
  required KavitaBookBinding binding,
  required KavitaProgress remote,
  required ReaderPositionRow? local,
}) {
  return resolveKavitaProgress(
    serverPage: remote.lastModifiedUtc == null ? null : remote.pageNum,
    serverModifiedAt: remote.lastModifiedUtc?.millisecondsSinceEpoch,
    localPage: local?.sectionIndex,
    localUpdatedAt: local?.updatedAt,
    lastSyncAt: _maxOrNull(binding.lastPushedAt, binding.lastPulledAt),
    // 章内滚动也会刷新 updatedAt；本地仍停在上次一致的那章就不算动过。
    lastSyncedPage: binding.lastPushedPage,
  );
}

int? _maxOrNull(int? a, int? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a > b ? a : b;
}
