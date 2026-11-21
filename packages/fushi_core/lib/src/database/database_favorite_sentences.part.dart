// 收藏句表（v166）。模型、内容身份与增删语义在 fushi_audio 的
// `FavoriteSentenceRepository`；本文件只放表读写原语与 v166 迁移。
part of 'database.dart';

/// 统计计数面只用到的三列（不读句子正文）：来源、收藏日、收藏时刻。
typedef FavoriteSentenceStatRow = ({
  String source,
  String? dateKey,
  DateTime createdAt,
});

mixin _FushiDbFavoriteSentences on _$FushiDatabase, _FushiDbInfra {
  /// 全部收藏句，新收藏在前（与旧 JSON 仓库 `getAll` 的排序一致；同一时刻按 id 定序）。
  Future<List<FavoriteSentenceRow>> getAllFavoriteSentenceRows() =>
      (select(favoriteSentences)..orderBy(_newestFirst)).get();

  /// 统计计数面：每条收藏句只取来源 / 收藏日 / 收藏时刻三列。
  Future<List<FavoriteSentenceStatRow>> getFavoriteSentenceStatRows() async {
    final $FavoriteSentencesTable t = favoriteSentences;
    final List<TypedResult> rows =
        await (selectOnly(t)..addColumns(<Expression<Object>>[
              t.source,
              t.dateKey,
              t.createdAtUs,
            ]))
            .get();
    return <FavoriteSentenceStatRow>[
      for (final TypedResult r in rows)
        (
          source: r.read(t.source)!,
          dateKey: r.read(t.dateKey),
          createdAt: DateTime.fromMicrosecondsSinceEpoch(
            r.read(t.createdAtUs)!,
          ),
        ),
    ];
  }

  /// 按 id 取一条（没有 = null）。
  Future<FavoriteSentenceRow?> getFavoriteSentenceRowById(String id) => (select(
    favoriteSentences,
  )..where(($FavoriteSentencesTable t) => t.id.equals(id))).getSingleOrNull();

  /// 按内容四元组（正文 + 出处 + 章节 + 锚点；可空字段 null 只匹配 null）取**最新**
  /// 收藏的一条——与旧仓库在「新收藏在前」的列表里取第一条匹配同一口径。
  Future<FavoriteSentenceRow?> findFavoriteSentenceByContent({
    required String text,
    required String? bookKey,
    required int? sectionIndex,
    required int? normCharOffset,
  }) =>
      (select(favoriteSentences)
            ..where(
              ($FavoriteSentencesTable t) =>
                  t.sentence.equals(text) &
                  _nullableEquals<String>(t.bookKey, bookKey) &
                  _nullableEquals<int>(t.sectionIndex, sectionIndex) &
                  _nullableEquals<int>(t.normCharOffset, normCharOffset),
            )
            ..orderBy(_newestFirst)
            ..limit(1))
          .getSingleOrNull();

  /// 插入一条；同 id 已存在则不动并返回 false。
  Future<bool> insertFavoriteSentenceRow(FavoriteSentencesCompanion row) =>
      transaction(() async {
        if (await getFavoriteSentenceRowById(row.id.value) != null) {
          return false;
        }
        await into(favoriteSentences).insert(row);
        return true;
      });

  /// 改一条收藏句的颜色并记下改色时刻（[colorUpdatedAtUs]，颜色的 LWW 时钟，见
  /// `FavoriteSentences.colorUpdatedAtUs`）。返回改到的行数（id 不存在 = 0）。
  Future<int> updateFavoriteSentenceColor(
    String id, {
    required String color,
    required int colorUpdatedAtUs,
  }) =>
      (update(
        favoriteSentences,
      )..where(($FavoriteSentencesTable t) => t.id.equals(id))).write(
        FavoriteSentencesCompanion(
          color: Value<String?>(color),
          colorUpdatedAtUs: Value<int?>(colorUpdatedAtUs),
        ),
      );

  /// 按 id 删，返回删掉的行数。
  Future<int> deleteFavoriteSentenceById(String id) => (delete(
    favoriteSentences,
  )..where(($FavoriteSentencesTable t) => t.id.equals(id))).go();

  /// 清空全部收藏句。
  Future<int> deleteAllFavoriteSentences() => delete(favoriteSentences).go();

  /// 整表换成 [rows]（同步合并 / 备份合并的结果），一个事务。id 撞了的（BUG-494 之前
  /// 的旧数据可能同 id 不同内容）后来者改名保留，不丢句子。
  Future<void> replaceAllFavoriteSentenceRows(
    List<FavoriteSentencesCompanion> rows,
  ) => transaction(() async {
    await delete(favoriteSentences).go();
    final List<FavoriteSentencesCompanion> unique =
        _withUniqueFavoriteSentenceIds(rows);
    if (unique.isEmpty) return;
    await batch((Batch b) => b.insertAll(favoriteSentences, unique));
  });

  /// 收藏句表有写入就发一次（任何写入者：仓库增删、同步合并、备份合并、音乐别名改写）。
  Stream<void> watchFavoriteSentencesChanged() =>
      tableUpdates(TableUpdateQuery.onTable(favoriteSentences)).map((_) {});

  /// v166：偏好 `favorite_sentences` 里的 JSON 列表搬进表，搬完删偏好行。重跑时已搬过
  /// 的（同 id 同正文同时刻）跳过。JSON 坏了不动偏好（原样留着可人工救回），也不建
  /// 半截数据。用冻结的 v166 列清单写原生 SQL：以后给表加列时这一步照样能跑。
  Future<void> _migrateFavoriteSentencesPrefToTable() async {
    // 迁移测试常用只建了几张表的残库，没有偏好表就没有可搬的。
    if (!await _tableExists('preferences')) return;
    final List<QueryRow> prefRows = await customSelect(
      'SELECT value FROM preferences WHERE key = ?',
      variables: <Variable<Object>>[
        const Variable<String>(kFavoriteSentencesPrefKey),
      ],
    ).get();
    if (prefRows.isEmpty) return;
    final String raw = prefRows.first.read<String>('value');
    final List<Map<String, Object?>> items = <Map<String, Object?>>[];
    if (raw.isNotEmpty) {
      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException catch (e) {
        fushiDebugPrint('v166: favorite_sentences JSON 无法解析，偏好原样保留：$e');
        return;
      }
      if (decoded is! List<Object?>) {
        fushiDebugPrint('v166: favorite_sentences 不是列表，偏好原样保留');
        return;
      }
      for (final Object? e in decoded) {
        if (e is Map<String, Object?>) items.add(e);
      }
    }
    final Set<String> ids = <String>{
      for (final QueryRow r in await customSelect(
        'SELECT id FROM favorite_sentences',
      ).get())
        r.read<String>('id'),
    };
    int generated = 0;
    for (final Map<String, Object?> e in items) {
      final Object? text = e['text'];
      final Object? createdAt = e['createdAt'];
      if (text is! String || createdAt is! String) continue;
      final DateTime? created = DateTime.tryParse(createdAt);
      if (created == null) continue;
      final int createdUs = created.microsecondsSinceEpoch;
      final Object? rawId = e['id'];
      final bool hasId = rawId is String && rawId.isNotEmpty;
      String id = hasId ? rawId : 'hl_v166_${generated++}';
      if (ids.contains(id)) {
        if (hasId) {
          final bool alreadyMoved = await customSelect(
            'SELECT 1 FROM favorite_sentences WHERE id = ? AND sentence = ? '
            'AND created_at_us = ?',
            variables: <Variable<Object>>[
              Variable<String>(id),
              Variable<String>(text),
              Variable<int>(createdUs),
            ],
          ).get().then((List<QueryRow> r) => r.isNotEmpty);
          if (alreadyMoved) continue;
        }
        // 旧数据同 id 不同内容（BUG-494）：改名保留。
        id = _nextFreeFavoriteSentenceId(id, ids);
      }
      ids.add(id);
      String? str(String k) {
        final Object? v = e[k];
        return v is String ? v : null;
      }

      int? integer(String k) {
        final Object? v = e[k];
        return v is int ? v : null;
      }

      await customStatement(
        'INSERT INTO favorite_sentences (id, sentence, book_title, '
        'chapter_label, created_at_us, book_key, section_index, '
        'norm_char_offset, norm_char_length, color, source, date_key, '
        'expression, reading) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          id,
          text,
          str('bookTitle') ?? '',
          str('chapterLabel'),
          createdUs,
          str('bookKey'),
          integer('sectionIndex'),
          integer('normCharOffset'),
          integer('normCharLength'),
          str('color'),
          str('source') ?? 'book',
          str('dateKey'),
          str('expression'),
          str('reading'),
        ],
      );
    }
    await customStatement('DELETE FROM preferences WHERE key = ?', <Object?>[
      kFavoriteSentencesPrefKey,
    ]);
  }
}

final List<OrderClauseGenerator<$FavoriteSentencesTable>> _newestFirst =
    <OrderClauseGenerator<$FavoriteSentencesTable>>[
      ($FavoriteSentencesTable t) => OrderingTerm.desc(t.createdAtUs),
      ($FavoriteSentencesTable t) => OrderingTerm.asc(t.id),
    ];

Expression<bool> _nullableEquals<T extends Object>(
  GeneratedColumn<T> column,
  T? value,
) => value == null ? column.isNull() : column.equals(value);

String _nextFreeFavoriteSentenceId(String id, Set<String> taken) {
  int n = 1;
  while (taken.contains('${id}_$n')) {
    n++;
  }
  return '${id}_$n';
}

List<FavoriteSentencesCompanion> _withUniqueFavoriteSentenceIds(
  List<FavoriteSentencesCompanion> rows,
) {
  final Set<String> seen = <String>{};
  final List<FavoriteSentencesCompanion> out = <FavoriteSentencesCompanion>[];
  for (final FavoriteSentencesCompanion row in rows) {
    final String original = row.id.value;
    final String id = seen.contains(original)
        ? _nextFreeFavoriteSentenceId(original, seen)
        : original;
    seen.add(id);
    out.add(id == original ? row : row.copyWith(id: Value<String>(id)));
  }
  return out;
}
