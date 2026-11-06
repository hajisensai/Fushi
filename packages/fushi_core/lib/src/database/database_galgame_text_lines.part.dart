// 游戏台词（v134，作品图谱 L4 跟进）。表语义见 galgame_text_line_tables.dart。
part of 'database.dart';

/// 「我库里的例句」把一个游戏的台词按 id 分块成语料文档（每块一份，part = id ~/ 块大小），
/// 新台词只让最后一块变化，不必为一行新台词把整部游戏重新分词。
const int kGalgameTextLineChunkSize = 500;

/// 一个游戏的一块台词的概况（语料对账用：数量 / 最大 id 变了就重建这一块）。
typedef GalgameTextLineChunk = ({
  String gameId,
  int part,
  int count,
  int maxId,
});

mixin _FushiDbGalgameTextLines on _$FushiDatabase {
  /// 写入一批台词：同一游戏里已有同一句的跳过（INSERT OR IGNORE，按 (game_id, text)
  /// 唯一键）。游戏已不在库里的行同样跳过（外键约束失败不让整批失败）。返回实际写入数。
  Future<int> insertGalgameTextLines(
    String gameId,
    List<({String text, int receivedAt})> lines,
  ) async {
    if (lines.isEmpty) return 0;
    return transaction(() async {
      final bool gameExists =
          await (select(galgames)
                ..where(($GalgamesTable t) => t.id.equals(gameId)))
              .getSingleOrNull() !=
          null;
      if (!gameExists) return 0;
      // INSERT OR IGNORE 被忽略时 SQLite 的 last_insert_rowid 不变（返回的是上一行的 id），
      // 所以写入数按前后行数差算。
      final int before = await countGalgameTextLines(gameId);
      for (final ({String text, int receivedAt}) line in lines) {
        final String text = line.text.trim();
        if (text.isEmpty) continue;
        await into(galgameTextLines).insert(
          GalgameTextLinesCompanion.insert(
            gameId: gameId,
            lineText: text,
            receivedAt: line.receivedAt,
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
      return await countGalgameTextLines(gameId) - before;
    });
  }

  /// 全部游戏台词按块的概况（一次聚合查询）。
  Future<List<GalgameTextLineChunk>> galgameTextLineChunks() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT game_id, id / $kGalgameTextLineChunkSize AS part, '
      'COUNT(*) AS n, MAX(id) AS max_id '
      'FROM galgame_text_lines GROUP BY game_id, part',
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{galgameTextLines},
    ).get();
    return <GalgameTextLineChunk>[
      for (final QueryRow r in rows)
        (
          gameId: r.read<String>('game_id'),
          part: r.read<int>('part'),
          count: r.read<int>('n'),
          maxId: r.read<int>('max_id'),
        ),
    ];
  }

  /// 一个游戏某一块的台词，按 id 升序。
  Future<List<GalgameTextLineRow>> galgameTextLinesInChunk(
    String gameId,
    int part,
  ) =>
      (select(galgameTextLines)
            ..where(
              ($GalgameTextLinesTable t) =>
                  t.gameId.equals(gameId) &
                  t.id.isBetweenValues(
                    part * kGalgameTextLineChunkSize,
                    (part + 1) * kGalgameTextLineChunkSize - 1,
                  ),
            )
            ..orderBy(<OrderClauseGenerator<$GalgameTextLinesTable>>[
              ($GalgameTextLinesTable t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  /// 一个游戏的台词数。
  Future<int> countGalgameTextLines(String gameId) async {
    final Expression<int> n = galgameTextLines.id.count();
    final TypedResult row =
        await (selectOnly(galgameTextLines)
              ..addColumns(<Expression<Object>>[n])
              ..where(galgameTextLines.gameId.equals(gameId)))
            .getSingle();
    return row.read(n) ?? 0;
  }
}
