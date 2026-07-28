/// 游戏库的 app 侧仓储：Drift 表 ↔ UI 视图模型 [GalgameEntry] 的唯一桥。
///
/// v55 起真相源是 `galgames` / `galgame_sources` / `galgame_sessions` 三张表
/// （契约 `docs/design/galgame-library-reina-parity.md` §1），不再是偏好表单一 JSON key。
/// 旧 pref key `galgame_library` 的回填**已在 DB 层迁移里做完**，本层只读表、不做迁移。
///
/// 读取一律「一次批量取全量」：`getAllGalgames` + `getAllGalgameSources` +
/// `getGalgamePlayTotals` 三个查询拼出整库，**绝不 per-game 再查**（N+1 是书架页
/// 踩过的坑）。
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_source.dart';

/// 某游戏的游玩聚合（[HibikiDatabase.getGalgamePlayTotals] 的一行）。
typedef GalgamePlayTotals = (
  int totalSeconds,
  int sessionCount,
  int lastPlayedMs
);

/// 纯函数：把一行 `galgames` + 它的多源快照 + 游玩聚合合成 UI 视图模型。
///
/// - [sources] 里 source 键无法识别（未来源 / 脏数据）的行**跳过**，不崩。
/// - 元数据按契约 §2.4 合并并叠加 `customDataJson` 覆盖层（§1.3）。
/// - [playTotals] 为 null 表示该游戏一条会话都没有 → 时长/次数/最后游玩全 0。
GalgameEntry galgameEntryFromRow(
  GalgameRow row, {
  List<GalgameSourceRow> sources = const <GalgameSourceRow>[],
  GalgamePlayTotals? playTotals,
}) {
  final Map<GalgameMetadataSource, GalgameMetadataDraft> bySource =
      <GalgameMetadataSource, GalgameMetadataDraft>{};
  for (final GalgameSourceRow source in sources) {
    final GalgameMetadataSource? key =
        GalgameMetadataSource.fromKey(source.source);
    if (key == null) {
      continue; // 未知源：留着不动（DB 里仍在），但不参与本次合并。
    }
    bySource[key] = GalgameMetadataDraft.decode(source.dataJson);
  }
  final GalgameCustomData custom = GalgameCustomData.decode(row.customDataJson);
  return GalgameEntry(
    id: row.id,
    name: row.name,
    exePath: row.exePath,
    workdir: row.workdir,
    launchArgs: row.launchArgs,
    upscalingMode: row.upscalingMode,
    coverPath: (row.coverPath?.isEmpty ?? true) ? null : row.coverPath,
    addedAt: DateTime.fromMillisecondsSinceEpoch(row.addedAt),
    playStatus: GalgamePlayStatus.fromValue(row.playStatus),
    primarySource: row.primarySource,
    releaseDate: row.releaseDate,
    customData: custom,
    metadata: mergeDrafts(bySource, custom: custom),
    sortOrder: row.sortOrder,
    totalPlaySeconds: playTotals?.$1 ?? 0,
    sessionCount: playTotals?.$2 ?? 0,
    lastPlayedMs: playTotals?.$3 ?? 0,
  );
}

/// 纯函数：视图模型 → 整行写入 companion。
///
/// **只写 `galgames` 自己的列**：合并后的元数据属于 `galgame_sources`，游玩聚合属于
/// `galgame_sessions`，都不能从这里反写回去（否则一次列表覆写就把源快照抹平了）。
/// `customDataJson` 全空时写 null 而不是 `{}`——空 map 与「没有覆盖」语义相同，
/// 留 null 让 DB 里少一堆噪音。
GalgamesCompanion galgamesCompanionFromEntry(GalgameEntry entry) {
  final String? customJson =
      entry.customData.isEmpty ? null : entry.customData.encode();
  return GalgamesCompanion.insert(
    id: entry.id,
    name: entry.name,
    exePath: entry.exePath,
    workdir: entry.workdir,
    launchArgs: Value<String>(entry.launchArgs),
    upscalingMode: Value<String>(entry.upscalingMode),
    coverPath: Value<String?>(entry.coverPath),
    addedAt: entry.addedAt.millisecondsSinceEpoch,
    playStatus: Value<int>(entry.playStatus.value),
    primarySource: Value<String?>(entry.primarySource),
    releaseDate: Value<String?>(entry.releaseDate),
    customDataJson: Value<String?>(customJson),
    sortOrder: Value<int>(entry.sortOrder),
  );
}

/// 游戏库仓储。缓存整库列表供同步读取（[games]），每次写入后重载并 notify。
///
/// 整库规模是几百条，全量重载三个查询在 SQLite 上是毫秒级；换来「缓存与表恒一致」，
/// 不用维护一套增量更新 + 校验兜底（就是契约 §1.4 拒绝统计投影表的同一个理由）。
class GalgameRepository extends ChangeNotifier {
  GalgameRepository(this._db, {this.onPlayStatusChanged});

  final HibikiDatabase _db;

  /// 游玩状态落库后的通知钩子（可选，测试与纯本地场景可不接）。
  ///
  /// 用回调而不是直接依赖媒体记录服务：游戏库不该知道有没有外部同步这回事，
  /// 接线由 AppModel 统一负责。
  final void Function(String id, GalgamePlayStatus status)? onPlayStatusChanged;

  List<GalgameEntry> _games = const <GalgameEntry>[];

  /// 是否已从 DB 载入过一次（false 时 [games] 是空表而非「库为空」）。
  bool _loaded = false;

  /// 当前缓存的整库列表（按添加时间升序，与旧 JSON 列表的天然顺序一致）。
  List<GalgameEntry> get games => _games;

  bool get isLoaded => _loaded;

  /// 按 id 取一条（缓存内查找，无 IO）。
  GalgameEntry? byId(String id) {
    for (final GalgameEntry game in _games) {
      if (game.id == id) return game;
    }
    return null;
  }

  /// 按启动 exe 路径找游戏（大小写不敏感 —— Windows 路径语义），缓存内查找，无 IO。
  ///
  /// galgame hook 会话只有启动路径有稳定身份（进程 PID 会变、窗口标题会变、
  /// 启动器与真实游戏还可能是两个进程），它拿到的就是这个 exe 全路径。要把会话
  /// 反查回库条目（读该游戏的启动期配置，如超分档位）只能靠它。
  ///
  /// 归一化复用与去重/[findGalgameByExePath] 同一套（`/` ↔ `\`、大小写无关），
  /// 所以 `D:/Games/a.exe` 与 `D:\games\A.EXE` 认作同一个游戏。空串/找不到返回 null。
  GalgameEntry? byExePath(String exePath) =>
      findGalgameByExePath(_games, exePath);

  /// 从 DB 全量重载（三个批量查询，无 N+1）。
  Future<List<GalgameEntry>> load() async {
    final List<GalgameRow> rows = await _db.getAllGalgames();
    final Map<String, List<GalgameSourceRow>> sources =
        await _db.getAllGalgameSources();
    final Map<String, GalgamePlayTotals> totals =
        await _db.getGalgamePlayTotals();
    _games = <GalgameEntry>[
      for (final GalgameRow row in rows)
        galgameEntryFromRow(
          row,
          sources: sources[row.id] ?? const <GalgameSourceRow>[],
          playTotals: totals[row.id],
        ),
    ];
    _loaded = true;
    notifyListeners();
    return _games;
  }

  /// 整表覆写（旧 `AppModel.setGalgames` 语义：调用方组装好整列表后写入）。
  ///
  /// 列表里没有的 id 视为删除（`galgame_sources` / `galgame_sessions` 经 FK cascade
  /// 连带清理）；其余整行 upsert。一个事务里做完，中途失败不留半套。
  Future<void> setGames(List<GalgameEntry> next) async {
    final Set<String> keep = <String>{
      for (final GalgameEntry game in next) game.id,
    };
    final List<String> removed = <String>[];
    await _db.transaction(() async {
      for (final GalgameRow row in await _db.getAllGalgames()) {
        if (!keep.contains(row.id)) {
          await _db.deleteGalgame(row.id);
          removed.add(row.id);
        }
      }
      for (final GalgameEntry game in next) {
        await _db.upsertGalgame(galgamesCompanionFromEntry(game));
      }
    });
    // 同 [remove]：合集引用是逻辑外键无 cascade，批量删除后逐条清理
    // （#346 删除传播）。在主事务外做：清理自身已是事务，且本体
    // 删除成功后引用清理失败可由读取期过滤兜底，不应回滚本体。
    for (final String id in removed) {
      await _db.removeEntryFromAllCollections(MediaKind.game, id);
    }
    await load();
  }

  /// 追加若干新游戏（不动既有行，比整表覆写省写入）。
  Future<void> addAll(List<GalgameEntry> added) async {
    if (added.isEmpty) return;
    await _db.transaction(() async {
      for (final GalgameEntry game in added) {
        await _db.upsertGalgame(galgamesCompanionFromEntry(game));
      }
    });
    await load();
  }

  /// 整行覆盖一条（详情页改显示名 / exe 路径 / 工作目录 / 覆盖层）。
  Future<void> updateEntry(GalgameEntry entry) async {
    await _db.upsertGalgame(galgamesCompanionFromEntry(entry));
    await load();
  }

  /// 删除一条。除本体行（源快照/会话经 FK cascade 连带）外，还主动清其全部
  /// 合集引用（`media_collection_items.entryKey` 是逻辑外键无 DB cascade，
  /// 对齐 #346 删除传播惯例）；被清空的合集随之自删，不留孤儿成员。
  Future<void> remove(String id) async {
    await _db.deleteGalgame(id);
    await _db.removeEntryFromAllCollections(MediaKind.game, id);
    await load();
  }

  /// 只改游玩状态。
  ///
  /// 落库后通知 [onPlayStatusChanged]（媒体记录据此上报 Bangumi 收藏状态）。回调
  /// 失败不影响本地状态：外部服务不可用时本地照常改，后续同步会重试。
  Future<void> setPlayStatus(String id, GalgamePlayStatus status) async {
    await _db.setGalgamePlayStatus(id, status.value);
    await load();
    onPlayStatusChanged?.call(id, status);
  }

  /// 只改用户覆盖层（全空 → 写 null 清空自定义）。
  Future<void> setCustomData(String id, GalgameCustomData custom) async {
    await _db.setGalgameCustomData(id, custom.isEmpty ? null : custom.encode());
    await load();
  }

  /// 只改本地封面路径（null / 空串 = 回落默认手柄图标）。
  Future<void> setCoverPath(String id, String? path) async {
    await _db.setGalgameCoverPath(
        id, (path == null || path.isEmpty) ? null : path);
    await load();
  }

  /// 只改该游戏的窗口超分档位（`auto` / `installed_only` / `off`；空串 = 未设置，
  /// 解析层回落到关闭）。列非空，清空写空串而不是 null。
  Future<void> setUpscalingMode(String id, String modeKey) async {
    await _db.setGalgameUpscalingMode(id, modeKey);
    await load();
  }

  /// 落一次刮削结果：写该源快照 + 回写主显示源与发行日。
  ///
  /// [primarySource] 由调用方决定（单源刮削 = 该源 key；多源 = `mixed`）；
  /// 发行日取 draft 的完整日期，缺就保持原值不动（不用 null 抹掉已有值）。
  Future<void> saveScrapeResult({
    required String gameId,
    required GalgameMetadataSource source,
    required GalgameMetadataDraft draft,
    required String primarySource,
    DateTime? now,
  }) async {
    final int fetchedAt = (now ?? DateTime.now()).millisecondsSinceEpoch;
    await _db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: gameId,
        source: source.key,
        externalId: Value<String?>(draft.externalId),
        dataJson: draft.encode(),
        score: Value<double?>(draft.score),
        rank: Value<int?>(draft.rank),
        fetchedAt: fetchedAt,
      ),
    );
    final String? releaseDate = draft.releaseDate ?? byId(gameId)?.releaseDate;
    await _db.setGalgameScrapeResult(
      gameId,
      primarySource: primarySource,
      releaseDate: releaseDate,
    );
    await load();
  }

  /// 移除某游戏的某个源快照（「换数据源」）。
  Future<void> removeSource(String gameId, GalgameMetadataSource source) async {
    await _db.deleteGalgameSource(gameId, source.key);
    await load();
  }

  /// 某游戏的原始源快照行（详情页展示外链 / 源 ID 用）。
  Future<List<GalgameSourceRow>> sourcesOf(String gameId) =>
      _db.getGalgameSources(gameId);

  /// 某游戏的会话流水（详情页时间线）。
  Future<List<GalgameSessionRow>> sessions(
    String gameId, {
    int limit = 50,
    int offset = 0,
  }) =>
      _db.getGalgameSessions(gameId, limit: limit, offset: offset);

  /// 删除单条会话，并重载（聚合 KPI 现算，删完 KPI 立即跟着变）。
  Future<void> deleteSession(int sessionId) async {
    await _db.deleteGalgameSession(sessionId);
    await load();
  }

  /// 某游戏在 [fromDateKey]..[toDateKey] 闭区间内按天的秒数（详情页柱状图）。
  Future<Map<String, int>> dailySeconds(
    String gameId, {
    required String fromDateKey,
    required String toDateKey,
  }) =>
      _db.getGalgameDailySeconds(
        gameId,
        fromDateKey: fromDateKey,
        toDateKey: toDateKey,
      );
}
