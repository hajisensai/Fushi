/// 服务器曲目（Jellyfin / Subsonic）在离线 / 服务器配置删了时的播放上报与收藏：记进设备本地的
/// 补发队列（v174 `music_server_pending_actions`），那台服务器重新配上、连得通时补发。
///
/// - **什么时候入队**：一次听够门槛（[musicScrobbleThresholdReached]）的播放没送达服务器——
///   服务器连不上（[musicServerUnreachable]），或这台设备上已经没有那台服务器的配置（离线副本
///   照样能放，播放项带着 v174 存下的服务器身份）；收藏切换同理（「正在播放」的心形照样能点，
///   显示切换后的状态）。播放上报接线在 `music_server_playback_reporter.dart`，收藏在
///   `music_server_favorites.dart`。
/// - **补发**：[flushAll]（app 启动接上库时）、[flushServer]（打开那台服务器的页面、以及对它
///   的任何一次上报 / 收藏请求成功之后）。Jellyfin 播放走 `PlayedItems?datePlayed=`（播放次数
///   +1、最近播放时刻 = 原来的开播时刻），Subsonic 走 `scrobble time= submission=true`
///   （[MusicServerPlayMarking]）；收藏走各自的收藏接口，每首只发最后一次切换。按时间从旧到新
///   发，一台服务器途中连不上就停下、条目留着。
/// - **去重 / 上限 / 过期**：同一次播放（服务器 + 曲目 + 开播时刻）只记一条，收藏每首一条；
///   总数超过 [kMusicServerPendingCap] 丢最旧的播放；服务器回了错误（不是连不上，例如条目在
///   服务器上删了）的条目试 [kMusicServerPendingMaxAttempts] 次后丢；服务器一直没配回来的条目
///   过了 [kMusicServerPendingOrphanTtl]（180 天）才丢——临时删掉配置再加回来、或换了令牌重登，
///   都还来得及补发。
/// - **凭据**：表里只有服务器配置身份与条目 id；补发时由当时配置的客户端现建请求，失败日志只
///   记异常类型。
///
/// 同一张设备本地表旁边是 `music_server_track_states`：收藏的最后已知状态也记在那里（[lastKnownFavorite]），
/// 服务器连不上时心形按它显示。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

import 'package:fushi/src/media/music/server/music_server_playback_reporter.dart'
    show musicServerReportUnreachable;

/// 队列总条数上限（超过丢最旧的播放）。一首 4 分钟的歌，2000 条约 130 小时的离线收听。
const int kMusicServerPendingCap = 2000;

/// 服务器回了错误（不是连不上）的条目最多试几次。
const int kMusicServerPendingMaxAttempts = 5;

/// 服务器一直没配回来的条目留多久（按入队时刻算）。
const Duration kMusicServerPendingOrphanTtl = Duration(days: 180);

/// 「连不上服务器」类错误的判定（app 装配时补上 Jellyfin 传输层自己的异常类型）。播放上报、
/// 收藏、补发三处共用这一个判据。
bool Function(Object error) musicServerUnreachable =
    musicServerReportUnreachable;

/// 可以离线记账的服务器种类（有收藏 / 补记播放接口、能作为服务器曲目入库的）。
bool musicServerKindQueueable(MusicServerKind kind) =>
    kind == MusicServerKind.jellyfin || kind == MusicServerKind.subsonic;

/// 补发时找当前配置的服务器（app 装配：Jellyfin 媒体服务器配置 + 启用的 Subsonic）。
typedef MusicServerQueueBrowsers = Future<List<MusicServerBrowser>> Function();

/// 一条收藏补发成功（[MusicServerFavoriteStore] 记成服务器确认过的值）。
typedef MusicServerFavoriteApplied =
    void Function(String serverId, String itemId, bool favorite);

class MusicServerOfflineQueue extends ChangeNotifier {
  MusicServerOfflineQueue({int Function()? clock}) : _clock = clock ?? _now;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  /// app 内共享的一份（`AppModel` 接上用户库时 [attach]）。
  static final MusicServerOfflineQueue instance = MusicServerOfflineQueue();

  final int Function() _clock;

  FushiDatabase? _db;
  MusicServerQueueBrowsers? _browsers;
  StreamSubscription<List<MusicServerPendingActionRow>>? _sub;

  /// 收藏补发成功的回调（app 装配：收藏的本机状态记成服务器确认过的值）。
  MusicServerFavoriteApplied? onFavoriteApplied;

  /// trackUid → 待送达的收藏状态（Drift watch 的快照）。
  Map<String, bool> _pendingFavorites = const <String, bool>{};

  /// 本机写进队列、watch 还没推回那一版的收藏切换：trackUid → 写进去的值与入队时刻。
  /// watch 的快照可能是上一次写之后查出来的（连续切换时晚到），没见到这一版之前以它为准，
  /// 不让晚到的旧快照把心形打回去。
  final Map<String, ({bool favorite, int at})> _unconfirmed =
      <String, ({bool favorite, int at})>{};

  /// 正在补发的服务器（同一台同时只有一轮；轮内再来的请求合并成「跑完再看一遍」）。
  final Map<String, Future<void>> _flushing = <String, Future<void>>{};
  final Set<String> _again = <String>{};

  bool get attached => _db != null;

  /// 接到 [db]（同一个库重复调用只换 [browsers]）。
  void attach(FushiDatabase db, {required MusicServerQueueBrowsers browsers}) {
    _browsers = browsers;
    if (identical(_db, db)) return;
    unawaited(_sub?.cancel());
    _db = db;
    _sub = db.watchMusicServerPendingFavorites().listen((
      List<MusicServerPendingActionRow> rows,
    ) {
      final Map<String, MusicServerPendingActionRow> byUid =
          <String, MusicServerPendingActionRow>{
            for (final MusicServerPendingActionRow r in rows)
              if (r.favorite != null) r.trackUid: r,
          };
      final Map<String, bool> next = <String, bool>{
        for (final MapEntry<String, MusicServerPendingActionRow> e
            in byUid.entries)
          e.key: e.value.favorite!,
      };
      _unconfirmed.removeWhere((String uid, ({bool favorite, int at}) w) {
        final MusicServerPendingActionRow? row = byUid[uid];
        if (row != null &&
            row.createdAt == w.at &&
            row.favorite == w.favorite) {
          return true;
        }
        next[uid] = w.favorite;
        return false;
      });
      _pendingFavorites = next;
      notifyListeners();
    });
  }

  /// 队列里那一版收藏切换已经处理完（送达 / 丢弃）：不再压着 watch 快照。
  void _settleFavorite(MusicServerPendingActionRow r) {
    final ({bool favorite, int at})? w = _unconfirmed[r.trackUid];
    if (w != null && w.at == r.createdAt && w.favorite == r.favorite) {
      _unconfirmed.remove(r.trackUid);
    }
  }

  /// 这首有没有待送达的收藏切换（有 = 要设成的值）。
  bool? pendingFavorite(String trackUid) => _pendingFavorites[trackUid];

  /// 记一次没送达的播放（开播时刻 [playedAtMs]）。没接库 / 种类不支持时什么都不做。
  Future<void> enqueuePlay(
    MusicServerTrackRef ref, {
    required int playedAtMs,
  }) async {
    final FushiDatabase? db = _db;
    if (db == null || !musicServerKindQueueable(ref.kind)) return;
    await db.enqueueMusicServerPendingPlay(
      serverKind: ref.kind.wire,
      serverId: ref.serverId,
      itemId: ref.trackId,
      trackUid: ref.trackUid,
      playedAt: playedAtMs,
      at: _clock(),
    );
    debugPrint('[music-offline] play queued for later delivery');
  }

  /// 记一次没送达的收藏切换（同一首只留最后一次），并记成最后已知状态。
  Future<void> enqueueFavorite({
    required MusicServerKind kind,
    required String serverId,
    required String itemId,
    required bool favorite,
  }) async {
    final FushiDatabase? db = _db;
    if (db == null || !musicServerKindQueueable(kind)) return;
    final String uid = musicServerTrackUid(serverId, itemId);
    // 先改内存快照：心形立刻按新值显示，不等 watch 推回来。
    final int at = _clock();
    _unconfirmed[uid] = (favorite: favorite, at: at);
    _pendingFavorites = <String, bool>{..._pendingFavorites, uid: favorite};
    notifyListeners();
    try {
      await db.enqueueMusicServerPendingFavorite(
        serverKind: kind.wire,
        serverId: serverId,
        itemId: itemId,
        trackUid: uid,
        favorite: favorite,
        at: at,
      );
    } on Object {
      if (_unconfirmed[uid] == (favorite: favorite, at: at)) {
        _unconfirmed.remove(uid);
      }
      rethrow;
    }
    await rememberFavorite(
      kind: kind,
      serverId: serverId,
      itemId: itemId,
      favorite: favorite,
    );
    debugPrint('[music-offline] favorite queued for later delivery');
  }

  /// 这首在本机记下的最后已知收藏状态；不知道为 null。
  Future<bool?> lastKnownFavorite(String trackUid) async =>
      (await _db?.getMusicServerTrackState(trackUid))?.favorite;

  /// 记下最后已知的收藏状态（服务器报的 / 服务器确认过的 / 本机最后一次切换）。
  Future<void> rememberFavorite({
    required MusicServerKind kind,
    required String serverId,
    required String itemId,
    required bool favorite,
  }) async {
    final FushiDatabase? db = _db;
    if (db == null || !musicServerKindQueueable(kind)) return;
    await db.writeMusicServerTrackFavorite(
      trackUid: musicServerTrackUid(serverId, itemId),
      serverKind: kind.wire,
      serverId: serverId,
      itemId: itemId,
      favorite: favorite,
      at: _clock(),
    );
  }

  /// 修剪队列并对当前配置的每台服务器补发一轮（app 启动接上库时）。不抛。
  Future<void> flushAll() async {
    final FushiDatabase? db = _db;
    final MusicServerQueueBrowsers? load = _browsers;
    if (db == null || load == null) return;
    try {
      final List<MusicServerBrowser> browsers = await load();
      final int dropped = await db.pruneMusicServerPendingActions(
        configuredServerIds: <String>{
          for (final MusicServerBrowser b in browsers) b.serverId,
        },
        orphanBefore: _clock() - kMusicServerPendingOrphanTtl.inMilliseconds,
        cap: kMusicServerPendingCap,
      );
      if (dropped > 0) {
        debugPrint('[music-offline] pruned $dropped pending entries');
      }
      await Future.wait(<Future<void>>[
        for (final MusicServerBrowser b in browsers) flushServer(b),
      ]);
    } on Object catch (e) {
      debugPrint('[music-offline] flush failed: ${e.runtimeType}');
    }
  }

  /// 补发 [browser] 那台服务器的待送达条目。同一台已在补发时合并成「跑完再看一遍」。不抛。
  Future<void> flushServer(MusicServerBrowser browser) {
    if (_db == null || !musicServerKindQueueable(browser.kind)) {
      return Future<void>.value();
    }
    final String id = browser.serverId;
    final Future<void>? running = _flushing[id];
    if (running != null) {
      _again.add(id);
      return running;
    }
    final Future<void> run = () async {
      try {
        do {
          _again.remove(id);
          await _flushOnce(browser);
        } while (_again.contains(id));
      } on Object catch (e) {
        debugPrint('[music-offline] flush failed: ${e.runtimeType}');
      } finally {
        _flushing.remove(id);
      }
    }();
    _flushing[id] = run;
    return run;
  }

  Future<void> _flushOnce(MusicServerBrowser browser) async {
    final FushiDatabase? db = _db;
    if (db == null) return;
    final List<MusicServerPendingActionRow> rows = await db
        .listMusicServerPendingActions(serverId: browser.serverId);
    if (rows.isEmpty) return;
    int sent = 0;
    for (final MusicServerPendingActionRow r in rows) {
      if (r.serverKind != browser.kind.wire) continue;
      try {
        switch (r.action) {
          case 'play':
            final int? at = r.playedAt;
            if (browser is! MusicServerPlayMarking || at == null) {
              await db.deleteMusicServerPendingActions(<String>[r.dedupeKey]);
              continue;
            }
            await (browser as MusicServerPlayMarking).markPlayed(
              r.itemId,
              DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
            );
          case 'favorite':
            final bool? fav = r.favorite;
            if (browser is! MusicServerFavoriteEditing || fav == null) {
              await db.deleteMusicServerPendingActions(<String>[r.dedupeKey]);
              _settleFavorite(r);
              continue;
            }
            await (browser as MusicServerFavoriteEditing).setFavorite(
              MusicServerItemKind.track,
              r.itemId,
              favorite: fav,
            );
            await rememberFavorite(
              kind: browser.kind,
              serverId: browser.serverId,
              itemId: r.itemId,
              favorite: fav,
            );
            onFavoriteApplied?.call(browser.serverId, r.itemId, fav);
          default:
            await db.deleteMusicServerPendingActions(<String>[r.dedupeKey]);
            continue;
        }
        await db.deleteMusicServerPendingActionIfUnchanged(r);
        if (r.action == 'favorite') _settleFavorite(r);
        sent++;
      } on Object catch (e) {
        if (musicServerUnreachable(e)) {
          // 还是连不上：这一轮到此为止，条目都留着。
          debugPrint('[music-offline] server still unreachable; kept pending');
          break;
        }
        final int? attempts = await db.bumpMusicServerPendingAttempt(
          r.dedupeKey,
          at: _clock(),
        );
        debugPrint(
          '[music-offline] server rejected a pending ${r.action} '
          '(${e.runtimeType}, attempt $attempts)',
        );
        if (attempts != null && attempts >= kMusicServerPendingMaxAttempts) {
          await db.deleteMusicServerPendingActions(<String>[r.dedupeKey]);
          if (r.action == 'favorite') _settleFavorite(r);
        }
      }
    }
    if (sent > 0) {
      debugPrint('[music-offline] delivered $sent pending entries');
    }
  }

  /// 测试用：等所有在跑的补发结束。
  Future<void> get idle => Future.wait(_flushing.values.toList());

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
