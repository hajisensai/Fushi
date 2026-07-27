import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// v37→v38 统一合集迁移测试（TODO 统一合集 Phase 1）。
///
/// 覆盖：① 旧 Series → collection 转换（成员/序/名/排序权重）+ seriesId 清空 + series
/// 删除；② 多集 playlist video_books 拆成 N 条独立集行 + playlist 合集；③ 每集进度
/// 迁入 last_position_ms；④ mined_sentences / favorite_sentences 集坐标改写；⑤ 标签
/// 复制到每集；⑥ 单视频与非视频数据不受影响；⑦ 迁移幂等（重复调用无副作用）。

/// 打开一个 user_version=37 的库，seed 迁移相关表，触发真实的 `if (from < 38)`
/// onUpgrade 分支。DDL 镜像 v37 生成 shape（仅迁移读写的列）。
Future<HibikiDatabase> _openV37Db() async {
  final db = HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('PRAGMA foreign_keys = OFF');
        rawDb.execute('''
CREATE TABLE series (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  cover_source TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)
''');
        rawDb.execute('''
CREATE TABLE shelf_entries (
  media_type TEXT NOT NULL,
  entry_key TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  series_id INTEGER,
  PRIMARY KEY (media_type, entry_key)
)
''');
        rawDb.execute('''
CREATE TABLE video_books (
  book_uid TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  video_path TEXT NOT NULL,
  subtitle_source TEXT,
  secondary_subtitle_source TEXT,
  subtitle_format TEXT,
  embedded_subtitle_track INTEGER,
  cover_path TEXT,
  last_position_ms INTEGER NOT NULL DEFAULT 0,
  imported_at INTEGER,
  playlist_json TEXT,
  current_episode INTEGER NOT NULL DEFAULT 0,
  audio_track_id TEXT,
  delay_ms INTEGER NOT NULL DEFAULT 0,
  completed_at INTEGER,
  source_id INTEGER,
  stream_spec_json TEXT
)
''');
        rawDb.execute('''
CREATE TABLE mined_sentences (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  expression TEXT NOT NULL,
  book_key TEXT,
  section_index INTEGER
)
''');
        rawDb.execute('''
CREATE TABLE book_tags (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL
)
''');
        rawDb.execute('''
CREATE TABLE video_book_tag_mappings (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  video_book_uid TEXT NOT NULL,
  tag_id INTEGER NOT NULL,
  UNIQUE (video_book_uid, tag_id)
)
''');
        rawDb.execute('''
CREATE TABLE preferences (
  key TEXT NOT NULL PRIMARY KEY,
  value TEXT NOT NULL
)
''');

        // ── seed ──
        // 系列 MySeries(sort=5)：成员 epub BookA / srt srt-1 / epub BookB（按 sort_order
        // 1/2/3 → 合集 sort_index 0/1/2）。散书 BookC(series=NULL, sort=9) 不入合集。
        rawDb.execute(
          'INSERT INTO series (id, name, sort_order, created_at) '
          "VALUES (1, 'MySeries', 5, 1000)",
        );
        rawDb.execute(
          'INSERT INTO shelf_entries (media_type, entry_key, sort_order, series_id) VALUES '
          "('epub', 'BookA', 1, 1), "
          "('srt', 'srt-1', 2, 1), "
          "('epub', 'BookB', 3, 1), "
          "('epub', 'BookC', 9, NULL), "
          "('video', 'video/playlist/MyShow', 7, NULL)",
        );

        // 多集 playlist 视频（3 集，各集进度 1000/2000/0，current_episode=1，
        // 共享 subtitle/delay/audio）。
        final String playlistJson = jsonEncode(<Map<String, dynamic>>[
          {'title': 'E1', 'path': '/v/MyShow E01.mkv', 'positionMs': 1000},
          {'title': 'E2', 'path': '/v/MyShow E02.mkv', 'positionMs': 2000},
          {'title': 'E3', 'path': '/v/MyShow E03.mkv', 'positionMs': 0},
        ]);
        rawDb.execute(
          'INSERT INTO video_books '
          '(book_uid, title, video_path, subtitle_source, subtitle_format, '
          'cover_path, last_position_ms, imported_at, playlist_json, '
          'current_episode, audio_track_id, delay_ms, completed_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            'video/playlist/MyShow',
            'MyShow',
            '/v/MyShow E01.mkv',
            'embedded:0',
            'srt',
            '/covers/myshow.jpg', // 整本封面：应只由第 0 集承接
            0,
            5000, // imported_at（drift 秒）→ 合集 created_at 应 ×1000
            playlistJson,
            1,
            '2',
            50,
            9999, // completed_at：整本完成标记，拆集后每集应变 NULL
          ],
        );
        // 单视频（不应被拆）。
        rawDb.execute(
          'INSERT INTO video_books (book_uid, title, video_path, imported_at) '
          "VALUES ('video/single1', 'Single', '/v/single.mkv', 6000)",
        );

        // 制卡：section 0 / 2 / NULL 属 playlist 父；另 1 条非视频对照。
        rawDb.execute(
          'INSERT INTO mined_sentences (expression, book_key, section_index) VALUES '
          "('sent-e1', 'video/playlist/MyShow', 0), "
          "('sent-e3', 'video/playlist/MyShow', 2), "
          "('sent-null', 'video/playlist/MyShow', NULL), "
          "('sent-oob', 'video/playlist/MyShow', 5), " // 真越界 → 末集 catch-all
          "('sent-neg', 'video/playlist/MyShow', -1), " // 负下标 → 末集 catch-all
          "('sent-book', 'BookA', 0)",
        );

        // 标签：父视频挂 tag 1。
        rawDb.execute("INSERT INTO book_tags (id, name) VALUES (1, 'fav')");
        rawDb.execute(
          'INSERT INTO video_book_tag_mappings (video_book_uid, tag_id) '
          "VALUES ('video/playlist/MyShow', 1)",
        );

        // 收藏句 pref：视频收藏(section=1) 应改写；书籍收藏应原样。
        final String favJson = jsonEncode(<Map<String, dynamic>>[
          {
            'id': 'a',
            'text': 'fav-e2',
            'bookTitle': 'MyShow',
            'createdAt': '2026-01-01T00:00:00.000',
            'bookKey': 'video/playlist/MyShow',
            'sectionIndex': 1,
            'source': 'video',
          },
          {
            'id': 'b',
            'text': 'book-fav',
            'bookTitle': 'BookA',
            'createdAt': '2026-01-01T00:00:00.000',
            'bookKey': 'BookA',
            'sectionIndex': 0,
            'source': 'book',
          },
          {
            // 旧格式视频收藏：无 source 字段，bookKey 指向被拆父 → 仍须改写（不靠 source）。
            'id': 'c',
            'text': 'fav-e1-nosource',
            'bookTitle': 'MyShow',
            'createdAt': '2026-01-01T00:00:00.000',
            'bookKey': 'video/playlist/MyShow',
            'sectionIndex': 0,
          },
        ]);
        rawDb.execute(
          "INSERT INTO preferences (key, value) VALUES ('favorite_sentences', ?)",
          <Object?>[favJson],
        );

        rawDb.execute('PRAGMA user_version = 37');
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

/// 拆集后每集 bookUid（与迁移内 coreSingleVideoBookUid 一致）。
const String _e1 = 'video/MyShow E01';
const String _e2 = 'video/MyShow E02';
const String _e3 = 'video/MyShow E03';

Future<Map<String, dynamic>> _videoRow(HibikiDatabase db, String uid) async {
  final row = await db.customSelect(
    'SELECT * FROM video_books WHERE book_uid = ?',
    variables: [Variable.withString(uid)],
  ).getSingleOrNull();
  return row?.data ?? <String, dynamic>{};
}

void main() {
  test('v38: Series 转成 collection，成员/序/名/排序权重照搬，seriesId 清空', () async {
    final HibikiDatabase db = await _openV37Db();
    // 触发 onUpgrade。
    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();

    final MediaCollectionRow series =
        collections.firstWhere((c) => c.name == 'MySeries');
    expect(series.collectionType, 'collection');
    expect(series.sortOrder, 5);
    expect(series.createdAt, 1000);

    final List<MediaCollectionItemRow> members =
        await db.getCollectionItems(series.id);
    expect(
        members.map((m) => '${m.mediaType}|${m.entryKey}').toList(), <String>[
      'epub|BookA',
      'srt|srt-1',
      'epub|BookB',
    ]);
    expect(members.map((m) => m.sortIndex).toList(), <int>[0, 1, 2]);

    // 旧 Series 表清空、shelf_entries.series_id 全 NULL、散书 sortOrder 保留。
    expect((await db.getAllSeries()).isEmpty, isTrue);
    final entries = await db
        .customSelect(
            'SELECT entry_key, sort_order, series_id FROM shelf_entries')
        .get();
    for (final e in entries) {
      expect(e.read<int?>('series_id'), isNull);
    }
    final bookC =
        entries.firstWhere((e) => e.read<String>('entry_key') == 'BookC');
    expect(bookC.read<int>('sort_order'), 9);
    // 父 playlist 视频的 shelf_entry 已删（下面 split 断言复核）。
    expect(
      entries
          .any((e) => e.read<String>('entry_key') == 'video/playlist/MyShow'),
      isFalse,
    );
  });

  test('v38: 多集 playlist 拆成 N 条独立集行，每集进度迁入 last_position_ms', () async {
    final HibikiDatabase db = await _openV37Db();
    await db.getAllMediaCollections(); // 触发迁移

    final uids =
        (await db.customSelect('SELECT book_uid FROM video_books').get())
            .map((r) => r.read<String>('book_uid'))
            .toSet();
    // 父行消失，3 集独立行 + 单视频存在。
    expect(uids, <String>{_e1, _e2, _e3, 'video/single1'});
    expect(uids.contains('video/playlist/MyShow'), isFalse);

    final e1 = await _videoRow(db, _e1);
    expect(e1['title'], 'E1');
    expect(e1['video_path'], '/v/MyShow E01.mkv');
    expect(e1['last_position_ms'], 1000);
    expect(e1['playlist_json'], isNull);
    expect(e1['current_episode'], 0);
    // 共享列照抄。
    expect(e1['subtitle_source'], 'embedded:0');
    expect(e1['subtitle_format'], 'srt');
    expect(e1['audio_track_id'], '2');
    expect(e1['delay_ms'], 50);

    final e2 = await _videoRow(db, _e2);
    expect(e2['last_position_ms'], 2000);
    final e3 = await _videoRow(db, _e3);
    expect(e3['last_position_ms'], 0);

    // completed_at：父的整本完成标记(9999)不照抄，每集 NULL。
    expect(e1['completed_at'], isNull);
    expect(e2['completed_at'], isNull);
    expect(e3['completed_at'], isNull);
    // cover_path：整本封面只由第 0 集承接，其余 NULL。
    expect(e1['cover_path'], '/covers/myshow.jpg');
    expect(e2['cover_path'], isNull);
    expect(e3['cover_path'], isNull);

    // 单视频不受影响。
    final single = await _videoRow(db, 'video/single1');
    expect(single['title'], 'Single');
    expect(single['playlist_json'], isNull);
    expect(single['video_path'], '/v/single.mkv');
  });

  test('v38: playlist 合集建立，成员有序，排序权重取父 shelf sortOrder', () async {
    final HibikiDatabase db = await _openV37Db();
    final collections = await db.getAllMediaCollections();

    final playlist =
        collections.firstWhere((c) => c.collectionType == 'playlist');
    expect(playlist.name, 'MyShow');
    expect(playlist.sortOrder, 7); // 父 shelf_entry sort_order
    // created_at 契约是毫秒；父 imported_at 是 drift 秒(5000) → ×1000。
    expect(playlist.createdAt, 5000000);

    final members = await db.getCollectionItems(playlist.id);
    expect(members.map((m) => m.entryKey).toList(), <String>[_e1, _e2, _e3]);
    expect(members.map((m) => m.sortIndex).toList(), <int>[0, 1, 2]);
    expect(members.every((m) => m.mediaType == 'video'), isTrue);
  });

  test('v38: mined_sentences 集坐标改写（section i / NULL / 真越界 / 负数）', () async {
    final HibikiDatabase db = await _openV37Db();
    await db.getAllMediaCollections();

    final rows = await db
        .customSelect(
            'SELECT expression, book_key, section_index FROM mined_sentences')
        .get();
    final Map<String, ({String? key, int? section})> byExpr = {
      for (final r in rows)
        r.read<String>('expression'): (
          key: r.read<String?>('book_key'),
          section: r.read<int?>('section_index'),
        ),
    };
    expect(byExpr['sent-e1']!.key, _e1);
    expect(byExpr['sent-e1']!.section, 0);
    expect(byExpr['sent-e3']!.key, _e3);
    expect(byExpr['sent-e3']!.section, 0);
    // section NULL → 归 current_episode=1 → E02。
    expect(byExpr['sent-null']!.key, _e2);
    expect(byExpr['sent-null']!.section, 0);
    // 真越界(5) / 负数(-1) → 第三步 catch-all → 末集 E03。
    expect(byExpr['sent-oob']!.key, _e3);
    expect(byExpr['sent-oob']!.section, 0);
    expect(byExpr['sent-neg']!.key, _e3);
    expect(byExpr['sent-neg']!.section, 0);
    // 非视频对照不动。
    expect(byExpr['sent-book']!.key, 'BookA');
    expect(byExpr['sent-book']!.section, 0);
  });

  test('v38: 父标签复制到每集，收藏句集坐标改写', () async {
    final HibikiDatabase db = await _openV37Db();
    await db.getAllMediaCollections();

    // 标签：3 集各有 tag 1，父映射已随父行 cascade 删。
    // （断言跑在整条阶梯之后，v57 已把 video_book_uid 更名 book_uid。）
    final tagRows = await db
        .customSelect('SELECT book_uid, tag_id FROM video_book_tag_mappings')
        .get();
    final tagged = tagRows
        .where((r) => r.read<int>('tag_id') == 1)
        .map((r) => r.read<String>('book_uid'))
        .toSet();
    expect(tagged, <String>{_e1, _e2, _e3});

    // 收藏句 pref：视频条(section=1) → E02/section0；书籍条不变。
    final prefRow = await db
        .customSelect(
            "SELECT value FROM preferences WHERE key = 'favorite_sentences'")
        .getSingle();
    final List<dynamic> favs =
        jsonDecode(prefRow.read<String>('value')) as List<dynamic>;
    final Map<String, dynamic> a =
        favs.firstWhere((e) => e['id'] == 'a') as Map<String, dynamic>;
    expect(a['bookKey'], _e2);
    expect(a['sectionIndex'], 0);
    final Map<String, dynamic> b =
        favs.firstWhere((e) => e['id'] == 'b') as Map<String, dynamic>;
    expect(b['bookKey'], 'BookA');
    expect(b['sectionIndex'], 0);
    expect(b['source'], 'book');
    // 旧格式无 source 的视频收藏(section=0) 仍须改写 → E01/section0（不靠 source 判定）。
    final Map<String, dynamic> c =
        favs.firstWhere((e) => e['id'] == 'c') as Map<String, dynamic>;
    expect(c['bookKey'], _e1);
    expect(c['sectionIndex'], 0);
  });

  test('v38: 迁移幂等——再次调用两个迁移助手无副作用', () async {
    final HibikiDatabase db = await _openV37Db();
    final before = await db.getAllMediaCollections();
    final int beforeCount = before.length;
    final int beforeVideoCount = (await db
            .customSelect('SELECT COUNT(*) AS c FROM video_books')
            .getSingle())
        .read<int>('c');

    // 直接再跑一次两个助手（series 空 + 无 playlist_json 行 → 全 no-op）。
    await db.migrateSeriesToCollectionsV38();
    await db.splitPlaylistVideoBooksV38();

    expect((await db.getAllMediaCollections()).length, beforeCount);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS c FROM video_books')
              .getSingle())
          .read<int>('c'),
      beforeVideoCount,
    );
  });

  test('v38: 旧版 playlist（各集无 positionMs）当前集续播点从 parent.last_position_ms 兜底',
      () async {
    // 2 集 legacy playlist：各 entry 无 positionMs（回退 0），当前集续播点只存在于
    // 父行 last_position_ms=777；current_episode=0 → 第 0 集应承接 777，其余为 0。
    final db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys = OFF');
          rawDb.execute('''
CREATE TABLE video_books (
  book_uid TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  video_path TEXT NOT NULL,
  subtitle_source TEXT,
  secondary_subtitle_source TEXT,
  subtitle_format TEXT,
  embedded_subtitle_track INTEGER,
  cover_path TEXT,
  last_position_ms INTEGER NOT NULL DEFAULT 0,
  imported_at INTEGER,
  playlist_json TEXT,
  current_episode INTEGER NOT NULL DEFAULT 0,
  audio_track_id TEXT,
  delay_ms INTEGER NOT NULL DEFAULT 0,
  completed_at INTEGER,
  source_id INTEGER,
  stream_spec_json TEXT
)
''');
          final String legacyJson = jsonEncode(<Map<String, dynamic>>[
            {'title': 'L1', 'path': '/v/Legacy E01.mkv'}, // 无 positionMs
            {'title': 'L2', 'path': '/v/Legacy E02.mkv'},
          ]);
          rawDb.execute(
            'INSERT INTO video_books '
            '(book_uid, title, video_path, last_position_ms, playlist_json, '
            'current_episode) VALUES (?, ?, ?, ?, ?, ?)',
            <Object?>[
              'video/playlist/Legacy',
              'Legacy',
              '/v/Legacy E01.mkv',
              777,
              legacyJson,
              0,
            ],
          );
          rawDb.execute('PRAGMA user_version = 37');
        },
      ),
    );
    addTearDown(db.close);
    await db.getAllMediaCollections(); // 触发迁移

    final l1 = await _videoRow(db, 'video/Legacy E01');
    final l2 = await _videoRow(db, 'video/Legacy E02');
    expect(l1['last_position_ms'], 777); // 当前集(0) 从 parent 兜底
    expect(l2['last_position_ms'], 0);
  });
}
