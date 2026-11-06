/// Kavita 绑定书的后台进度对账（首页 / 书架用）。
///
/// 打开书时 [KavitaEpubSyncSession.attach] 才会拉服务器进度；在 Kavita 网页端改了
/// 页码或标已读 / 未读后，首页「继续」卡与书架进度条在下次开书前一直显示旧值。
/// 这里在两个界面出现 / 回前台时，对最近用过的若干本绑定书做一次**静默**对账：
/// 拉服务器进度，用与打开时同一个决策（[decideKavitaEpubSync]），**只处理
/// adoptServer**——写本地阅读位置并记同步戳；冲突 / 推本地 / 无需动作一律不碰，
/// 留给开书时的 attach（那里有冲突对话框与推送）。
///
/// 采用写入由 [KavitaBookService.adoptServerProgress] 完成：在服务锁内按最新状态
/// 重新决策、比较后写入、时间戳取服务器进度时刻（不扰动「最近阅读」排序、不在
/// 互联同步里压过别的设备更晚的进度）；阅读器正开着的书整本跳过。
///
/// 离线 / 超时 / 服务器错误整本跳过；脊柱章数与服务器页数对不上的书也跳过（与
/// attach 同一道安全检查）。有节流，永不抛错、不阻塞渲染。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';

import 'package:fushi/src/media/kavita/kavita_book_binding.dart';
import 'package:fushi/src/media/kavita/kavita_book_service.dart';
import 'package:fushi/src/media/kavita/kavita_epub_sync.dart';
import 'package:fushi/src/media/kavita/kavita_open_books.dart';
import 'package:fushi/src/media/kavita/kavita_server_config.dart';

class KavitaProgressRefresher {
  KavitaProgressRefresher({
    this.maxBooks = 8,
    this.minInterval = const Duration(minutes: 3),
    this.pullTimeout = const Duration(seconds: 4),
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 进程内共享实例：首页与书架共用同一节流窗口。
  static final KavitaProgressRefresher shared = KavitaProgressRefresher();

  final int maxBooks;
  final Duration minInterval;
  final Duration pullTimeout;
  final int Function() _nowMs;

  bool _running = false;
  int? _lastRunAt;

  /// 对账一次，返回被采用服务器进度的书数（0 = 无变化 / 被节流 / 失败）。
  /// [force] 绕过节流（测试 / 手动刷新）。
  Future<int> refresh({
    required FushiDatabase db,
    required List<KavitaServerConfig> servers,
    required KavitaApi Function(KavitaServerConfig) apiFor,
    bool force = false,
  }) async {
    if (_running) return 0;
    final int now = _nowMs();
    final int? last = _lastRunAt;
    if (!force && last != null && now - last < minInterval.inMilliseconds) {
      return 0;
    }
    _running = true;
    try {
      final List<KavitaServerConfig> usable = <KavitaServerConfig>[
        for (final KavitaServerConfig s in servers)
          if (s.isUsable) s,
      ];
      if (usable.isEmpty) return 0; // 没配服务器：不占节流窗口。
      _lastRunAt = now;
      final List<({EpubBookRow row, KavitaBookBinding binding, int recency})>
      candidates = await _candidates(db, usable);
      int adopted = 0;
      for (final ({EpubBookRow row, KavitaBookBinding binding, int recency}) c
          in candidates) {
        try {
          final KavitaServerConfig server = usable.firstWhere(
            (KavitaServerConfig s) => s.id == c.binding.serverConfigId,
          );
          if (await _reconcile(db, c.row, c.binding, apiFor(server))) adopted++;
        } on Object {
          // 离线 / 超时 / 服务器错误：这本跳过，下个窗口再试。
        }
      }
      return adopted;
    } on Object {
      return 0;
    } finally {
      _running = false;
    }
  }

  Future<List<({EpubBookRow row, KavitaBookBinding binding, int recency})>>
  _candidates(FushiDatabase db, List<KavitaServerConfig> usable) async {
    final Set<String> ids = <String>{
      for (final KavitaServerConfig s in usable) s.id,
    };
    final List<({EpubBookRow row, KavitaBookBinding binding, int recency})>
    out = <({EpubBookRow row, KavitaBookBinding binding, int recency})>[];
    for (final EpubBookRow row in await db.getAllEpubBooks()) {
      final KavitaBookBinding? binding = KavitaBookBinding.tryParse(
        row.sourceMetadata,
      );
      if (binding == null || row.uid.isEmpty) continue;
      if (!ids.contains(binding.serverConfigId)) continue;
      // 阅读器开着的书归阅读器的同步会话管（写入前在锁内还会再查一次）。
      if (KavitaOpenBooks.isOpen(row.bookKey)) continue;
      final ReaderPositionRow? pos = await db.getReaderPosition(row.uid);
      int recency = row.importedAt;
      for (final int? v in <int?>[
        pos?.updatedAt,
        binding.lastPushedAt,
        binding.lastPulledAt,
      ]) {
        if (v != null && v > recency) recency = v;
      }
      out.add((row: row, binding: binding, recency: recency));
    }
    out.sort((a, b) => b.recency.compareTo(a.recency));
    return out.length > maxBooks ? out.sublist(0, maxBooks) : out;
  }

  Future<bool> _reconcile(
    FushiDatabase db,
    EpubBookRow row,
    KavitaBookBinding binding,
    KavitaApi api,
  ) async {
    // 网络在锁外：拉取可能要几秒，不能挡开书 / 删书那把锁。
    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      api.getProgress(binding.chapterId),
      api
          .getChapterInfo(binding.chapterId)
          .then<Object?>(
            (KavitaChapterInfo i) => i,
            onError: (Object _) => null,
          ),
    ]).timeout(pullTimeout);
    final KavitaProgress? remote = results[0] as KavitaProgress?;
    final KavitaChapterInfo? info = results[1] as KavitaChapterInfo?;
    if (remote == null) return false;
    if (info != null &&
        info.pages > 0 &&
        row.chapterCount > 0 &&
        info.pages != row.chapterCount) {
      // 与开书时同一道安全检查：脊柱章数对不上时页号落不到对的章，整本不同步。
      // 开书时阅读器会提示用户；后台这里只留痕。
      debugPrint(
        '[kavita-refresh] ${row.bookKey}: server lists ${info.pages} '
        'sections, local copy has ${row.chapterCount}; progress sync skipped',
      );
      return false;
    }
    // 决策与写入在服务的锁里、按锁内重读的最新状态做（见 adoptServerProgress）。
    return KavitaBookService(db: db, nowMs: _nowMs).adoptServerProgress(
      bookKey: row.bookKey,
      remote: remote,
      decide: (KavitaBookBinding fresh, ReaderPositionRow? local) =>
          decideKavitaEpubSync(binding: fresh, remote: remote, local: local),
    );
  }
}
