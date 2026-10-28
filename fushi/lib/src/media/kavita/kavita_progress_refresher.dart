/// Kavita 绑定书的后台进度对账（首页 / 书架用）。
///
/// 打开书时 [KavitaEpubSyncSession.attach] 才会拉服务器进度；在 Kavita 网页端改了
/// 页码或标已读 / 未读后，首页「继续」卡与书架进度条在下次开书前一直显示旧值。
/// 这里在两个界面出现 / 回前台时，对最近用过的若干本绑定书做一次**静默**对账：
/// 拉服务器进度，用与打开时同一个决策（[decideKavitaEpubSync]），**只处理
/// adoptServer**——写本地阅读位置并记同步戳；冲突 / 推本地 / 无需动作一律不碰，
/// 留给开书时的 attach（那里有冲突对话框与推送）。
///
/// 离线 / 超时 / 服务器错误整本跳过；脊柱章数与服务器页数对不上的书也跳过（与
/// attach 同一道安全检查）。有节流，永不抛错、不阻塞渲染。
library;

import 'dart:async';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/kavita/kavita_api.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';

import 'package:fushi/src/media/kavita/kavita_book_binding.dart';
import 'package:fushi/src/media/kavita/kavita_book_service.dart';
import 'package:fushi/src/media/kavita/kavita_epub_sync.dart';
import 'package:fushi/src/media/kavita/kavita_progress_resolver.dart';
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
      return false;
    }
    final ReaderPositionRow? local = await db.getReaderPosition(row.uid);
    final KavitaSyncDecision decision = decideKavitaEpubSync(
      binding: binding,
      remote: remote,
      local: local,
    );
    if (decision.action != KavitaSyncAction.adoptServer) return false;
    final int lastSection = row.chapterCount > 0 ? row.chapterCount - 1 : 0;
    final int page = remote.pageNum.clamp(0, lastSection);
    await ReaderPositionRepository(
      db,
    ).save(bookUid: row.uid, sectionIndex: page, normCharOffset: 0);
    await KavitaBookService(
      db: db,
      nowMs: _nowMs,
    ).recordSync(row.bookKey, pulled: true, page: page);
    return true;
  }
}
