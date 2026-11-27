// 媒体服务器剧名合集的存量清理与认领（BUG-5601 PR2，方案 B「懒收养」）。
//
// 从前视频库页每拿到一份 Jellyfin / Emby / 飞牛 / Plex 目录，就把整台服务器按剧名收养
// 成真合集（几千个合集、几万条成员行，经合集同步扩散到所有设备）。PR1 起这层分组只在
// 内存里叠加（`buildRemoteSeriesOverlay`），这里把存量里「没人动过」的那些删掉：
// - [_FushiDbRemoteSeriesPrune.claimRemoteSeriesCollections]：本机有视频行的成员置
//   pinned（「用户认领过」随同步各端可见，别的设备据此不删、同步里否决自动清理）；
// - [_FushiDbRemoteSeriesPrune.pruneUnusedRemoteSeriesCollections]：一条 SQL 选出候选，
//   一个事务里删，写带 `auto_pruned` 的合集级删除哨兵（v183）。
// 两步都幂等，由 [_FushiDbRemoteSeriesPrune.healRemoteSeriesCollections] 先认领后清理，
// 在三个合集同步入口读本地清单之前、以及开库后的后台工作里各跑一次。
part of 'database.dart';

/// 视频成员键是不是「媒体服务器条目 id」的形状（BUG-5601 存量清理的成员判据）。
///
/// 媒体服务器条目 id（Jellyfin 32 位十六进制、Plex / Emby 数字、飞牛 `e` + ULID）都是
/// 不带 `/` 和 `:` 的裸串；本机视频的命名族都带分隔符：本地文件 / 流 / 播放列表是
/// `video/…`（`url_stream_video.dart`），在线视频源 `anime-source:…`，作品花絮
/// `work-extra:…`。判据只在这里写一次，SQL 侧用 [_derivedRemoteSeriesEntryKeySql]，
/// 两者由测试对拍。
bool isDerivedRemoteSeriesEntryKey(String entryKey) =>
    entryKey.isNotEmpty && !entryKey.contains('/') && !entryKey.contains(':');

/// [isDerivedRemoteSeriesEntryKey] 的 SQL 形式（[column] 是成员键列表达式）。
String _derivedRemoteSeriesEntryKeySql(String column) =>
    "($column <> '' AND instr($column, '/') = 0 AND instr($column, ':') = 0)";

/// 「媒体服务器剧名合集」的形状：`playlist` 类型，成员至少一个、全是视频、成员键全是
/// 媒体服务器条目 id。认领与清理共用（[c] 是 `media_collections` 的别名）。
String _remoteSeriesCollectionShapeSql(String c) =>
    "$c.collection_type = 'playlist' "
    'AND EXISTS (SELECT 1 FROM media_collection_items i0 '
    'WHERE i0.collection_id = $c.id) '
    'AND NOT EXISTS (SELECT 1 FROM media_collection_items i1 '
    "WHERE i1.collection_id = $c.id AND (i1.media_type <> 'video' "
    'OR NOT ${_derivedRemoteSeriesEntryKeySql('i1.entry_key')}))';

/// 清理候选：「没人动过」的媒体服务器剧名合集（判据全在本机，方案 §4.1）。
///
/// A. 合集行：`origin = user`，封面 / AniList / 字幕音轨偏好 / 来源目录 / 分组键 /
///    别名全空，没手排过；
/// B. 成员（[_remoteSeriesCollectionShapeSql]）：没有一个被钉住，没有一个在本机有视频行；
/// C. 关联表都没有它：合集标签及其墓碑、刮削资料、图片、作品资料、作品关系（两端）、
///    用户确认过的作品图谱连接（AI 推断的不算）、下载任务 / 订阅、私密 / NSFW / 上锁
///    标记（含已取消的）、该自然键下的任何墓碑（用户移出过某一集）、AI 整理记录；
/// D. 自然键没有重名行（删一行写的合集级哨兵会连带删掉对端的另一行）。
const String _kRemoteSeriesPruneCandidatesSql =
    'SELECT c.id FROM media_collections c '
    "WHERE c.origin = 'user' "
    'AND c.cover_source IS NULL AND c.cover_path IS NULL '
    'AND c.anilist_id IS NULL '
    'AND c.subtitle_language IS NULL AND c.subtitle_release_group IS NULL '
    'AND c.audio_track_id IS NULL AND c.subtitle_delay_ms IS NULL '
    'AND c.secondary_subtitle_delay_ms IS NULL '
    'AND c.source_folder_path IS NULL '
    "AND c.organize_key IS NULL AND c.organize_aliases = '' "
    'AND c.order_updated_at = 0 '
    'AND NOT EXISTS (SELECT 1 FROM media_collection_items p '
    'WHERE p.collection_id = c.id AND (p.pinned_by_user <> 0 '
    'OR EXISTS (SELECT 1 FROM video_books v WHERE v.book_uid = p.entry_key))) '
    "AND NOT EXISTS (SELECT 1 FROM tag_assignments t WHERE t.media_kind = 'collection' "
    'AND t.entry_key = CAST(c.id AS TEXT)) '
    'AND NOT EXISTS (SELECT 1 FROM book_tag_membership_tombstones bt '
    "WHERE bt.media_type = 'collection' AND bt.item_key = CAST(c.id AS TEXT)) "
    'AND NOT EXISTS (SELECT 1 FROM collection_scrape_meta s '
    'WHERE s.collection_id = c.id) '
    'AND NOT EXISTS (SELECT 1 FROM media_images mi WHERE mi.collection_id = c.id) '
    'AND NOT EXISTS (SELECT 1 FROM video_metadata_works w '
    'WHERE w.collection_id = c.id) '
    'AND NOT EXISTS (SELECT 1 FROM collection_relations r '
    'WHERE r.collection_id = c.id OR r.target_collection_id = c.id) '
    'AND NOT EXISTS (SELECT 1 FROM media_links l WHERE l.deleted_at IS NULL '
    "AND (l.is_user_confirmed = 1 OR l.confirmed_by = 'user' "
    "OR l.source = 'manual') "
    "AND ((l.from_kind = 'video_collection' AND l.from_key = CAST(c.id AS TEXT)) "
    "OR (l.to_kind = 'video_collection' AND l.to_key = CAST(c.id AS TEXT)))) "
    'AND NOT EXISTS (SELECT 1 FROM video_download_jobs j '
    'WHERE j.collection_id = c.id) '
    'AND NOT EXISTS (SELECT 1 FROM video_download_subscriptions ds '
    'WHERE ds.collection_id = c.id) '
    'AND NOT EXISTS (SELECT 1 FROM media_privacy_flags f '
    "WHERE f.media_kind = 'collection' AND f.entry_key = CAST(c.id AS TEXT)) "
    'AND NOT EXISTS (SELECT 1 FROM media_nsfw_flags f '
    "WHERE f.media_kind = 'collection' AND f.entry_key = CAST(c.id AS TEXT)) "
    'AND NOT EXISTS (SELECT 1 FROM media_locked_flags f '
    "WHERE f.media_kind = 'collection' AND f.entry_key = CAST(c.id AS TEXT)) "
    'AND NOT EXISTS (SELECT 1 FROM collection_member_tombstones tm '
    'WHERE tm.collection_name = c.name '
    'AND tm.collection_type = c.collection_type) '
    'AND NOT EXISTS (SELECT 1 FROM library_organize_changes oc '
    'WHERE oc.collection_name = c.name '
    'AND oc.collection_type = c.collection_type) '
    'AND NOT EXISTS (SELECT 1 FROM media_collections d '
    'WHERE d.name = c.name AND d.collection_type = c.collection_type '
    'AND d.id <> c.id) '
    'AND ';

mixin _FushiDbRemoteSeriesPrune on _$FushiDatabase, _FushiDbLibrary {
  /// 先认领、再清理（方案 §4.4 的顺序：认领写进的 pinned 同一轮发出去，别的设备据此
  /// 保留它）。返回清理掉的合集数。两步都幂等，稳态各只有一次只读探测。
  Future<int> healRemoteSeriesCollections({int? nowMs}) async {
    await claimRemoteSeriesCollections();
    return pruneUnusedRemoteSeriesCollections(nowMs: nowMs);
  }

  /// 认领：媒体服务器剧名合集（[_remoteSeriesCollectionShapeSql]）里在本机有视频行的成员
  /// （「加入媒体库」或下载过）置 `pinned_by_user`。
  ///
  /// B 之前收养的合集没有「用户动过」的痕迹；本机看得到自己的视频行，别的设备看不到。
  /// pinned 随合集清单同步（取或），别的设备的清理判据见到它就不删，同步引擎也让带
  /// pinned 的活合集否决 `autoPruned` 删除。返回钉住的成员行数。
  Future<int> claimRemoteSeriesCollections() async {
    const String where =
        "i.media_type = 'video' AND i.pinned_by_user = 0 "
        'AND EXISTS (SELECT 1 FROM video_books v WHERE v.book_uid = i.entry_key)';
    final String inSeries =
        'i.collection_id IN (SELECT c.id FROM media_collections c '
        'WHERE ${_remoteSeriesCollectionShapeSql('c')})';
    final QueryRow? probe = await customSelect(
      'SELECT 1 AS hit FROM media_collection_items i '
      'WHERE $where AND $inSeries LIMIT 1',
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        mediaCollectionItems,
        mediaCollections,
        videoBooks,
      },
    ).getSingleOrNull();
    if (probe == null) return 0;
    return customUpdate(
      'UPDATE media_collection_items AS i SET pinned_by_user = 1 '
      'WHERE $where AND $inSeries',
      updates: <TableInfo<Table, dynamic>>{mediaCollectionItems},
      updateKind: UpdateKind.update,
    );
  }

  /// 存量清理：删掉「没人动过」的媒体服务器剧名合集（判据
  /// [_kRemoteSeriesPruneCandidatesSql]），写 `auto_pruned` 的合集级删除哨兵。
  ///
  /// 效果与逐个 `deleteMediaCollection(id, userIntent: false)` 相同（成员行、合集行、
  /// 以它为端点的作品图谱连接一起删；哨兵不带分组键，不算用户拒绝这个分组），只是
  /// 集合式地在一个事务里做完：用户库有三千多个候选，逐个删要几万次往返。候选按判据
  /// 本来就没有标签、私密 / 上锁标记、成员墓碑，删除路径里那几步在这里无事可做。
  ///
  /// 哨兵必须写：否则别的设备（和云端各设备的清单文件）里这个合集还活着，合并按
  /// 「单侧知识原样并入」又推回来。`auto_pruned` 让视频库照常临时分组（显示不变），
  /// 旧客户端照常当普通删除、被动收养被哨兵挡下，不再推回。
  ///
  /// 先只读探测，候选为空直接返回 0（不开写事务）；写事务里按同一判据重选，探测与
  /// 删除之间别的写入改了库也不会误删。幂等：删完再跑候选为空。返回删掉的合集数。
  Future<int> pruneUnusedRemoteSeriesCollections({int? nowMs}) async {
    final String candidatesSql =
        '$_kRemoteSeriesPruneCandidatesSql${_remoteSeriesCollectionShapeSql('c')}';
    final Set<ResultSetImplementation<dynamic, dynamic>> reads =
        <ResultSetImplementation<dynamic, dynamic>>{
          mediaCollections,
          mediaCollectionItems,
          videoBooks,
          collectionMemberTombstones,
          mediaLinks,
        };
    final QueryRow? probe = await customSelect(
      '$candidatesSql LIMIT 1',
      readsFrom: reads,
    ).getSingleOrNull();
    if (probe == null) return 0;
    return transaction(() async {
      final List<int> ids = <int>[
        for (final QueryRow r in await customSelect(
          candidatesSql,
          readsFrom: reads,
        ).get())
          r.read<int>('id'),
      ];
      if (ids.isEmpty) return 0;
      final String idsJson = jsonEncode(ids);
      final int deletedAt = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      const String idSet = '(SELECT value FROM json_each(?))';
      const String idTextSet = '(SELECT CAST(value AS TEXT) FROM json_each(?))';
      // 合集级哨兵：先清该自然键的全部墓碑（候选按判据没有，防御），再写哨兵。
      await customUpdate(
        'DELETE FROM collection_member_tombstones WHERE EXISTS ('
        'SELECT 1 FROM media_collections c WHERE c.id IN $idSet '
        'AND c.name = collection_member_tombstones.collection_name '
        'AND c.collection_type = collection_member_tombstones.collection_type)',
        variables: <Variable<Object>>[Variable<String>(idsJson)],
        updates: <TableInfo<Table, dynamic>>{collectionMemberTombstones},
        updateKind: UpdateKind.delete,
      );
      await customInsert(
        'INSERT INTO collection_member_tombstones (collection_name, '
        'collection_type, media_type, entry_key, deleted_at, organize_key, '
        'organize_merged, published_at, auto_pruned) '
        "SELECT c.name, c.collection_type, '', '', ?, NULL, 0, NULL, 1 "
        'FROM media_collections c WHERE c.id IN $idSet',
        variables: <Variable<Object>>[
          Variable<int>(deletedAt),
          Variable<String>(idsJson),
        ],
        updates: <TableInfo<Table, dynamic>>{collectionMemberTombstones},
      );
      // 同 `_dropMediaCollectionRow`：合集标签映射与以它为端点的作品图谱连接一起删。
      await customUpdate(
        "DELETE FROM tag_assignments WHERE media_kind = 'collection' "
        'AND entry_key IN $idTextSet',
        variables: <Variable<Object>>[Variable<String>(idsJson)],
        updates: <TableInfo<Table, dynamic>>{tagAssignments},
        updateKind: UpdateKind.delete,
      );
      await customUpdate(
        'DELETE FROM media_links WHERE '
        "(from_kind = 'video_collection' AND from_key IN $idTextSet) "
        "OR (to_kind = 'video_collection' AND to_key IN $idTextSet)",
        variables: <Variable<Object>>[
          Variable<String>(idsJson),
          Variable<String>(idsJson),
        ],
        updates: <TableInfo<Table, dynamic>>{mediaLinks},
        updateKind: UpdateKind.delete,
      );
      await customUpdate(
        'DELETE FROM media_collection_items WHERE collection_id IN $idSet',
        variables: <Variable<Object>>[Variable<String>(idsJson)],
        updates: <TableInfo<Table, dynamic>>{mediaCollectionItems},
        updateKind: UpdateKind.delete,
      );
      await customUpdate(
        'DELETE FROM media_collections WHERE id IN $idSet',
        variables: <Variable<Object>>[Variable<String>(idsJson)],
        updates: <TableInfo<Table, dynamic>>{mediaCollections},
        updateKind: UpdateKind.delete,
      );
      return ids.length;
    });
  }
}
