// 合集身份快照：删合集前把「这个合集是谁」整份记下，撤销时按原 id 还原。
part of 'database.dart';

/// [FushiDatabase.captureMediaCollectionSnapshot] 的格式版本。
const int kMediaCollectionSnapshotVersion = 1;

/// 快照不收的子表：成员归属由调用方按自己的语义（pinned、墓碑、顺序）还原。
const Set<String> _kCollectionSnapshotExcludedTables = <String>{
  'media_collection_items',
};

/// 查询结果里临时带出的 rowid 列名（不落进快照的行数据）。
const String _kSnapshotRowidColumn = '__fushi_snapshot_rowid';

/// `PRAGMA foreign_key_list` 的一行：[child].[from] 引用 [parent].[to]。
typedef _ForeignKeyEdge = ({
  String child,
  String from,
  String parent,
  String to,
  String onDelete,
});

/// 合集身份的快照与还原（BUG-5461）。
///
/// 合集的本地身份是 `media_collections.id`：作品图谱的 `video_collection` 端点、合集
/// 标签、刮削资料（`collection_scrape_meta`）、附加图、系列关系、视频作品元数据……
/// 全都挂在这个 id 上，FK cascade 随删行一起消失。整理器移空 / 合并掉一个合集后
/// 撤销，如果只按名字重建，得到的是一个**新 id** 的空壳，挂在旧 id 上的一切都丢了
/// （作品图谱里还剩一张「不在库中」的死卡）。
///
/// 快照按外键图**通用地**收集：从 `media_collections` 出发，沿全部 `ON DELETE
/// CASCADE` 边收下随删行消失的子行（含子表的子表），沿 `ON DELETE SET NULL` 边记下
/// 被置空的引用，再加上没有外键、按合集 id 字符串挂着的两类引用（合集标签、作品图谱
/// 连接）。以后新加挂在合集上的表只要声明了外键就自动纳入，不用回来改这里。
mixin _FushiDbCollectionIdentity
    on _$FushiDatabase, _FushiDbTagsSync, _FushiDbLibrary {
  List<_ForeignKeyEdge>? _foreignKeyEdgesCache;
  final Map<String, Set<String>> _tableColumnsCache = <String, Set<String>>{};

  /// 删合集前记下它的完整身份：合集行（全部列）、随删行 cascade 消失的子行、被置空
  /// 的引用、合集标签与作品图谱连接。成员行不收（见
  /// [_kCollectionSnapshotExcludedTables]）。合集不存在返回 null。
  ///
  /// 返回值可直接 `jsonEncode`（BLOB 列编码成 `{"b64": ...}`），交
  /// [restoreMediaCollectionSnapshot] 还原。
  Future<Map<String, Object?>?> captureMediaCollectionSnapshot(
    int id,
  ) => transaction(() async {
    final List<QueryRow> head = await customSelect(
      'SELECT * FROM media_collections WHERE id = ?',
      variables: <Variable<Object>>[Variable<int>(id)],
    ).get();
    if (head.isEmpty) return null;
    final List<_ForeignKeyEdge> edges = await _foreignKeyEdges();
    final List<Map<String, Object?>> cascade = <Map<String, Object?>>[];
    final List<Map<String, Object?>> relink = <Map<String, Object?>>[];
    final Set<String> seen = <String>{};
    final List<({String table, List<Map<String, Object?>> rows})> queue =
        <({String table, List<Map<String, Object?>> rows})>[
          (
            table: 'media_collections',
            rows: <Map<String, Object?>>[head.single.data],
          ),
        ];
    while (queue.isNotEmpty) {
      final ({String table, List<Map<String, Object?>> rows}) parent = queue
          .removeAt(0);
      for (final _ForeignKeyEdge e in edges) {
        if (e.parent != parent.table) continue;
        if (_kCollectionSnapshotExcludedTables.contains(e.child)) continue;
        final List<Object> keys = <Object>{
          for (final Map<String, Object?> r in parent.rows)
            if (r[e.to] case final Object v) v,
        }.toList(growable: false);
        if (keys.isEmpty) continue;
        final List<Map<String, Object?>> found = <Map<String, Object?>>[];
        final List<List<Object>> setNullRows = <List<Object>>[];
        for (final List<Object> chunk in _chunkForSqlVariables<Object>(
          keys,
          500,
        )) {
          final String marks = List<String>.filled(
            chunk.length,
            '?',
          ).join(', ');
          final List<Variable<Object>> vars = <Variable<Object>>[
            for (final Object v in chunk) Variable<Object>(v),
          ];
          if (e.onDelete == 'CASCADE') {
            for (final QueryRow r in await customSelect(
              'SELECT rowid AS $_kSnapshotRowidColumn, * FROM "${e.child}" '
              'WHERE "${e.from}" IN ($marks)',
              variables: vars,
            ).get()) {
              final Map<String, Object?> data = Map<String, Object?>.of(r.data);
              final Object? rowid = data.remove(_kSnapshotRowidColumn);
              if (!seen.add('${e.child}\u0000$rowid')) continue;
              found.add(data);
            }
          } else if (e.onDelete == 'SET NULL') {
            for (final QueryRow r in await customSelect(
              'SELECT rowid AS $_kSnapshotRowidColumn, "${e.from}" AS v '
              'FROM "${e.child}" WHERE "${e.from}" IN ($marks)',
              variables: vars,
            ).get()) {
              setNullRows.add(<Object>[
                r.data[_kSnapshotRowidColumn]! as Object,
                r.data['v']! as Object,
              ]);
            }
          }
        }
        for (final Map<String, Object?> data in found) {
          cascade.add(<String, Object?>{
            't': e.child,
            'r': _encodeSnapshotRow(data),
          });
        }
        if (setNullRows.isNotEmpty) {
          relink.add(<String, Object?>{
            't': e.child,
            'c': e.from,
            'p': e.parent,
            'rows': setNullRows,
          });
        }
        if (found.isNotEmpty) queue.add((table: e.child, rows: found));
      }
    }
    final String key = collectionTagEntryKey(id);
    final List<QueryRow> tags = await customSelect(
      'SELECT * FROM tag_assignments WHERE media_kind = ? AND entry_key = ?',
      variables: <Variable<Object>>[
        Variable<String>(TagHostKind.collection.dbValue),
        Variable<String>(key),
      ],
    ).get();
    final String kind = MediaLinkKind.videoCollection.dbValue;
    final List<QueryRow> links = await customSelect(
      'SELECT * FROM media_links WHERE (from_kind = ? AND from_key = ?) '
      'OR (to_kind = ? AND to_key = ?)',
      variables: <Variable<Object>>[
        Variable<String>(kind),
        Variable<String>(key),
        Variable<String>(kind),
        Variable<String>(key),
      ],
    ).get();
    return <String, Object?>{
      'v': kMediaCollectionSnapshotVersion,
      'row': _encodeSnapshotRow(head.single.data),
      'cascade': cascade,
      'relink': relink,
      'tags': <Map<String, Object?>>[
        for (final QueryRow r in tags) _encodeSnapshotRow(r.data),
      ],
      'links': <Map<String, Object?>>[
        for (final QueryRow r in links) _encodeSnapshotRow(r.data),
      ],
    };
  });

  /// 按 [captureMediaCollectionSnapshot] 的快照把合集还原回来，返回它现在的 id；
  /// 快照读不懂（版本 / 结构不对）返回 null。
  ///
  /// - 同自然键 `(name, collection_type)` 的合集已经在（撤销前被同步 / 别的路径重建
  ///   了）：就用它，只把快照里的合集标签与作品图谱连接挂回它身上（自然键就是合集的
  ///   跨端身份，作品图谱同步也按它对齐）；它自己的封面 / 刮削资料等不覆盖；
  /// - 否则按**原 id** 插回合集行（全部列原样），清合集级删除墓碑，再插回 cascade
  ///   子行、恢复被置空的引用、挂回标签与连接——挂在原 id 上的一切都回来了；原 id
  ///   已被别的行占用（理论上不会：自增主键不复用）时插成新 id，子行里指向原 id 的
  ///   外键列改指新 id。
  ///
  /// 子行插入用 `INSERT OR IGNORE`（还在的行不动），插入前逐个外键核对父行：父行已
  /// 不在的子行（例如它引用的人物条目已被清掉）跳过，不硬塞违反外键的行。列按当前
  /// 表结构取交集（快照之后升级过 schema 也能还原）。成员不在这里还原。
  Future<int?> restoreMediaCollectionSnapshot(Map<String, Object?> snapshot) =>
      transaction(() async {
        if (snapshot['v'] != kMediaCollectionSnapshotVersion) return null;
        final Object? rawRow = snapshot['row'];
        if (rawRow is! Map) return null;
        final Map<String, Object?> row = _decodeSnapshotRow(rawRow);
        final Object? origId = row['id'];
        final Object? name = row['name'];
        final Object? type = row['collection_type'];
        if (origId is! int || name is! String || type is! String) return null;

        final MediaCollectionRow? existing =
            await getMediaCollectionByNaturalKey(name, type);
        final int id;
        if (existing != null) {
          id = existing.id;
        } else {
          await _clearCollectionDeletionTombstone(name, type);
          final bool idFree = await getMediaCollectionById(origId) == null;
          final Map<String, Object?> values = Map<String, Object?>.of(row);
          if (!idFree) values.remove('id');
          final int inserted = await _insertSnapshotRow(
            'media_collections',
            values,
          );
          id = idFree ? origId : inserted;
          await _restoreSnapshotDependents(snapshot, origId: origId, id: id);
        }

        final String oldKey = collectionTagEntryKey(origId);
        final String newKey = collectionTagEntryKey(id);
        for (final Object? raw in _snapshotList(snapshot['tags'])) {
          if (raw is! Map) continue;
          final Map<String, Object?> tag = _decodeSnapshotRow(raw)
            ..['entry_key'] = newKey;
          await _insertSnapshotRowIfParentsPresent('tag_assignments', tag);
        }
        final String kind = MediaLinkKind.videoCollection.dbValue;
        for (final Object? raw in _snapshotList(snapshot['links'])) {
          if (raw is! Map) continue;
          final Map<String, Object?> link = _decodeSnapshotRow(raw);
          for (final String side in const <String>['from', 'to']) {
            if (link['${side}_kind'] == kind && link['${side}_key'] == oldKey) {
              link['${side}_key'] = newKey;
            }
          }
          await _insertSnapshotRowIfParentsPresent('media_links', link);
        }
        return id;
      });

  Future<void> _restoreSnapshotDependents(
    Map<String, Object?> snapshot, {
    required int origId,
    required int id,
  }) async {
    final List<_ForeignKeyEdge> edges = await _foreignKeyEdges();
    // 指向合集行的外键列（每张子表各自的列名）：原 id 被占用、插成新 id 时改指新 id。
    final Map<String, Set<String>> collectionFkColumns = <String, Set<String>>{
      for (final _ForeignKeyEdge e in edges)
        if (e.parent == 'media_collections')
          e.child: <String>{
            for (final _ForeignKeyEdge f in edges)
              if (f.child == e.child && f.parent == 'media_collections') f.from,
          },
    };
    Object? remap(String table, String column, Object? value) =>
        value == origId &&
            (collectionFkColumns[table]?.contains(column) ?? false)
        ? id
        : value;

    for (final Object? raw in _snapshotList(snapshot['cascade'])) {
      if (raw is! Map || raw['t'] is! String || raw['r'] is! Map) continue;
      final String table = raw['t'] as String;
      final Map<String, Object?> data = _decodeSnapshotRow(raw['r'] as Map);
      for (final String column in data.keys.toList(growable: false)) {
        data[column] = remap(table, column, data[column]);
      }
      await _insertSnapshotRowIfParentsPresent(table, data);
    }
    for (final Object? raw in _snapshotList(snapshot['relink'])) {
      if (raw is! Map ||
          raw['t'] is! String ||
          raw['c'] is! String ||
          raw['rows'] is! List) {
        continue;
      }
      final String table = raw['t'] as String;
      final String column = raw['c'] as String;
      if (!(await _tableColumns(table)).contains(column)) continue;
      for (final Object? pair in raw['rows'] as List<Object?>) {
        if (pair is! List || pair.length != 2) continue;
        final Object? rowid = pair[0];
        final Object? value = remap(table, column, pair[1]);
        if (rowid is! int || value == null) continue;
        await customUpdate(
          'UPDATE "$table" SET "$column" = ? WHERE rowid = ? '
          'AND "$column" IS NULL',
          variables: <Variable<Object>>[
            Variable<Object>(value),
            Variable<int>(rowid),
          ],
          updates: _tablesNamed(table),
        );
      }
    }
  }

  /// 外键检查过才插：[table] 的每条外键，值非 null 时父行必须在。返回是否插了。
  Future<bool> _insertSnapshotRowIfParentsPresent(
    String table,
    Map<String, Object?> values,
  ) async {
    final Set<String> columns = await _tableColumns(table);
    if (columns.isEmpty) return false;
    for (final _ForeignKeyEdge e in await _foreignKeyEdges()) {
      if (e.child != table || !columns.contains(e.from)) continue;
      final Object? v = values[e.from];
      if (v == null) continue;
      final List<QueryRow> parent = await customSelect(
        'SELECT 1 FROM "${e.parent}" WHERE "${e.to}" = ? LIMIT 1',
        variables: <Variable<Object>>[Variable<Object>(v)],
      ).get();
      if (parent.isEmpty) return false;
    }
    await _insertSnapshotRow(table, values);
    return true;
  }

  /// `INSERT OR IGNORE` 一行（列取 [values] 与当前表结构的交集），返回 rowid。
  Future<int> _insertSnapshotRow(
    String table,
    Map<String, Object?> values,
  ) async {
    final Set<String> columns = await _tableColumns(table);
    final List<String> names = <String>[
      for (final String c in values.keys)
        if (columns.contains(c)) c,
    ];
    return customInsert(
      'INSERT OR IGNORE INTO "$table" '
      '(${names.map((String c) => '"$c"').join(', ')}) '
      'VALUES (${List<String>.filled(names.length, '?').join(', ')})',
      variables: <Variable<Object>>[
        for (final String c in names) Variable<Object>(values[c]),
      ],
      updates: _tablesNamed(table),
    );
  }

  Set<TableInfo<Table, Object?>> _tablesNamed(String table) =>
      <TableInfo<Table, Object?>>{
        for (final TableInfo<Table, Object?> t in allTables)
          if (t.actualTableName == table) t,
      };

  Future<Set<String>> _tableColumns(String table) async {
    final Set<String>? cached = _tableColumnsCache[table];
    if (cached != null) return cached;
    final Set<String> columns = <String>{
      for (final QueryRow r in await customSelect(
        'PRAGMA table_info("$table")',
      ).get())
        r.read<String>('name'),
    };
    return _tableColumnsCache[table] = columns;
  }

  Future<List<_ForeignKeyEdge>> _foreignKeyEdges() async {
    final List<_ForeignKeyEdge>? cached = _foreignKeyEdgesCache;
    if (cached != null) return cached;
    final List<_ForeignKeyEdge> edges = <_ForeignKeyEdge>[];
    for (final QueryRow t in await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%'",
    ).get()) {
      final String child = t.read<String>('name');
      for (final QueryRow r in await customSelect(
        'PRAGMA foreign_key_list("$child")',
      ).get()) {
        edges.add((
          child: child,
          from: r.read<String>('from'),
          parent: r.read<String>('table'),
          // 省略被引用列 = 引用父表主键（本库的表都是单列整数主键 = rowid）。
          to: r.readNullable<String>('to') ?? 'rowid',
          onDelete: r.read<String>('on_delete').toUpperCase(),
        ));
      }
    }
    return _foreignKeyEdgesCache = edges;
  }
}

List<Object?> _snapshotList(Object? raw) =>
    raw is List ? raw.cast<Object?>() : const <Object?>[];

/// 一行原始列值 → 可 JSON 编码的 map（BLOB 编码成 `{"b64": ...}`）。
Map<String, Object?> _encodeSnapshotRow(
  Map<String, Object?> data,
) => <String, Object?>{
  for (final MapEntry<String, Object?> e in data.entries)
    e.key: switch (e.value) {
      final Uint8List bytes => <String, Object?>{'b64': base64Encode(bytes)},
      final Object? v => v,
    },
};

/// [_encodeSnapshotRow] 的反向。
Map<String, Object?> _decodeSnapshotRow(Map<Object?, Object?> raw) =>
    <String, Object?>{
      for (final MapEntry<Object?, Object?> e in raw.entries)
        if (e.key case final String k)
          k: switch (e.value) {
            {'b64': final String b64} => base64Decode(b64),
            final Object? v => v,
          },
    };
