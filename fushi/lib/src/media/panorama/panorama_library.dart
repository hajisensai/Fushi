/// 媒体库全景的数据层：把本机库里的作品（一部作品一张封面）与复习库全部制卡归成
/// [PanoramaLibrary]，交给图集 / Rust 布局核心。
///
/// 归并规则（需求 2026-10-29）：
/// - 视频按播放列表归并（`media_collections.collection_type = 'playlist'`，成员在
///   `media_collection_items`）；没进播放列表的，去掉集号后同名的归成一部
///   （[parseVideoFilename] 的 `series`）。
/// - 书、漫画、游戏、音乐一条记录一部。
/// - 制卡：复习库全部未删除笔记。词取 `sort_field`；是内部编号时从笔记字段里取第一个像
///   日语单词的值。归属：书优先按出处（`source`）里的 bookKey，其余按标签匹配作品名
///   （标签里空格写成 `_`）。
/// - 展示：每部作品最多 [kPanoramaWordsPerWork] 个词（均匀抽取），没挂作品的最多
///   [kPanoramaLooseWords] 个。
///
/// 只有 IO 与编排：布局 / 轨道 / 每帧投影全在 Rust（`ffc_pano_*`）。
library;

import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 每部作品最多展示的词数。
const int kPanoramaWordsPerWork = 40;

/// 没挂作品的词最多展示的个数。
const int kPanoramaLooseWords = 1800;

/// 作品种类（决定边框色与打开方式）。
enum PanoramaWorkKind { book, manga, video, game, music }

/// 一部作品（一张封面）。
class PanoramaWork {
  const PanoramaWork({
    required this.kind,
    required this.key,
    required this.title,
    required this.coverPath,
    this.memberKeys = const <String>[],
    this.matchTitles = const <String>[],
    this.playlistCollectionId,
    this.extractDir,
    this.bookUid,
    this.lastOpenedAt = 0,
  });

  final PanoramaWorkKind kind;

  /// 打开用的身份：书 / 漫画 = bookKey，视频 = 代表集 bookUid，游戏 = galgames.id，
  /// 音乐 = albumUid。
  final String key;
  final String title;
  final String? coverPath;

  /// 归进这部作品的全部条目身份（视频各集 bookUid、书的 bookKey 与 uid），按出处挂词用。
  final List<String> memberKeys;

  /// 标签匹配用的名字（作品名 + 各集名）。
  final List<String> matchTitles;

  /// 视频播放列表 id（打开时从合集续播）。
  final int? playlistCollectionId;

  /// 书的解包目录（翻开时取当前进度正文）。
  final String? extractDir;

  /// 书的本机 uid（取阅读位置）。
  final String? bookUid;

  /// 最近打开时刻（毫秒；选「最近在读」用），0 = 未知。
  final int lastOpenedAt;

  bool get isBook => kind == PanoramaWorkKind.book;
}

/// 一个展示的词。
class PanoramaWord {
  const PanoramaWord(this.text, this.work);

  final String text;

  /// 所属作品下标；-1 = 没挂作品。
  final int work;
}

/// 全景数据。
class PanoramaLibrary {
  const PanoramaLibrary({
    required this.works,
    required this.words,
    required this.minedTotal,
  });

  static const PanoramaLibrary empty = PanoramaLibrary(
    works: <PanoramaWork>[],
    words: <PanoramaWord>[],
    minedTotal: 0,
  );

  final List<PanoramaWork> works;
  final List<PanoramaWord> words;

  /// 复习库未删除笔记总数（说明文字同时写出总数与展示数）。
  final int minedTotal;

  int get shownWords => words.length;
  bool get isEmpty => works.isEmpty;
}

/// 一条笔记的展示要素（纯数据，便于测试）。
class PanoramaNoteInput {
  const PanoramaNoteInput({
    required this.sortField,
    required this.tags,
    this.fields = const <String>[],
    this.sourceKeys = const <String>[],
  });

  final String sortField;
  final List<String> tags;

  /// 字段值（按字段顺序；sort_field 是内部编号时才需要）。
  final List<String> fields;

  /// 出处里的身份（bookKey / mangaKey / mediaKey）。
  final List<String> sourceKeys;
}

final RegExp _kana = RegExp(r'[぀-ヿㇰ-ㇿｦ-ﾟ]');
final RegExp _cjk = RegExp(r'[㐀-䶿一-鿿豈-﫿々〆ヵヶ]');
final RegExp _japaneseWord = RegExp(r'^[぀-ヿㇰ-ㇿ㐀-䶿一-鿿豈-﫿ｦ-ﾟ々〆ヵヶー・〜]+$');
final RegExp _htmlTag = RegExp(r'<[^>]*>');
final RegExp _sound = RegExp(r'\[sound:[^\]]*\]');

/// 去 HTML / 声音标记 / 首尾空白。
String panoramaPlainText(String raw) => raw
    .replaceAll(_sound, '')
    .replaceAll(_htmlTag, '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .trim();

/// 是不是「内部编号」（导入词库常见：纯数字、十六进制串、带连字符的 id，里面没有假名 / 汉字）。
bool panoramaLooksLikeInternalId(String value) {
  final String v = value.trim();
  if (v.isEmpty) return true;
  if (_kana.hasMatch(v) || _cjk.hasMatch(v)) return false;
  return RegExp(r'^[0-9A-Za-z_:\-#.]+$').hasMatch(v) &&
      RegExp(r'[0-9]').hasMatch(v);
}

/// 是不是像一个日语单词（假名 / 汉字组成，1–12 字，至少一个假名或汉字）。
bool panoramaLooksLikeJapaneseWord(String value) {
  final String v = value.trim();
  if (v.isEmpty || v.runes.length > 12) return false;
  return _japaneseWord.hasMatch(v);
}

/// 一条笔记展示的词：sort_field 正常就用它；是内部编号时取第一个像日语单词的字段值。
/// 取不到返回 null（不展示）。
String? panoramaNoteWord(String sortField, List<String> fields) {
  final String sort = panoramaPlainText(sortField);
  if (!panoramaLooksLikeInternalId(sort)) {
    return sort.runes.length > 16
        ? String.fromCharCodes(sort.runes.take(16))
        : sort;
  }
  for (final String raw in fields) {
    final String v = panoramaPlainText(raw);
    if (panoramaLooksLikeJapaneseWord(v)) return v;
  }
  return null;
}

/// 作品名 → 标签形（空格写成 `_`，大小写不敏感）。
String panoramaTagForm(String title) =>
    title.trim().replaceAll(RegExp(r'\s+'), '_').toLowerCase();

/// 从 [items] 里均匀抽 [max] 个（保序）；不足时全取。
List<T> panoramaSampleEvenly<T>(List<T> items, int max) {
  if (items.length <= max) return List<T>.of(items);
  if (max <= 0) return <T>[];
  return <T>[for (int i = 0; i < max; i++) items[(i * items.length) ~/ max]];
}

/// 视频去集号后的作品名。
String panoramaVideoSeriesTitle(String title) {
  final String series = parseVideoFilename(title).series.trim();
  return series.isEmpty ? title.trim() : series;
}

/// 视频条目（归并输入）。
class PanoramaVideoInput {
  const PanoramaVideoInput({
    required this.bookUid,
    required this.title,
    required this.coverPath,
    this.lastPlayedAt = 0,
  });

  final String bookUid;
  final String title;
  final String? coverPath;
  final int lastPlayedAt;
}

/// 播放列表（归并输入）。
class PanoramaPlaylistInput {
  const PanoramaPlaylistInput({
    required this.id,
    required this.name,
    required this.coverPath,
    required this.memberUids,
  });

  final int id;
  final String name;
  final String? coverPath;

  /// 按 sortIndex 排好的成员 bookUid。
  final List<String> memberUids;
}

/// 视频归并：播放列表一部；其余去集号同名一部。保持首次出现顺序。
List<PanoramaWork> panoramaGroupVideos(
  List<PanoramaVideoInput> videos,
  List<PanoramaPlaylistInput> playlists,
) {
  final Map<String, PanoramaVideoInput> byUid = <String, PanoramaVideoInput>{
    for (final PanoramaVideoInput v in videos) v.bookUid: v,
  };
  final Set<String> claimed = <String>{};
  final List<PanoramaWork> out = <PanoramaWork>[];
  for (final PanoramaPlaylistInput pl in playlists) {
    final List<PanoramaVideoInput> members = <PanoramaVideoInput>[
      for (final String uid in pl.memberUids)
        if (byUid[uid] case final PanoramaVideoInput v)
          if (claimed.add(uid)) v,
    ];
    if (members.isEmpty) continue;
    String? cover = pl.coverPath;
    if (cover == null || cover.isEmpty) {
      cover = members
          .map((PanoramaVideoInput v) => v.coverPath)
          .firstWhere(
            (String? c) => c != null && c.isNotEmpty,
            orElse: () => null,
          );
    }
    final PanoramaVideoInput latest = members.reduce(
      (PanoramaVideoInput a, PanoramaVideoInput b) =>
          b.lastPlayedAt > a.lastPlayedAt ? b : a,
    );
    out.add(
      PanoramaWork(
        kind: PanoramaWorkKind.video,
        key: latest.bookUid,
        title: pl.name,
        coverPath: cover,
        memberKeys: <String>[
          for (final PanoramaVideoInput v in members) v.bookUid,
        ],
        matchTitles: <String>[
          pl.name,
          for (final PanoramaVideoInput v in members)
            panoramaVideoSeriesTitle(v.title),
        ],
        playlistCollectionId: pl.id,
        lastOpenedAt: latest.lastPlayedAt,
      ),
    );
  }
  final Map<String, List<PanoramaVideoInput>> bySeries =
      <String, List<PanoramaVideoInput>>{};
  final List<String> order = <String>[];
  for (final PanoramaVideoInput v in videos) {
    if (claimed.contains(v.bookUid)) continue;
    final String series = panoramaVideoSeriesTitle(v.title);
    final String k = series.toLowerCase();
    (bySeries[k] ??= <PanoramaVideoInput>[]).add(v);
    if (bySeries[k]!.length == 1) order.add(k);
  }
  for (final String k in order) {
    final List<PanoramaVideoInput> members = bySeries[k]!;
    final PanoramaVideoInput latest = members.reduce(
      (PanoramaVideoInput a, PanoramaVideoInput b) =>
          b.lastPlayedAt > a.lastPlayedAt ? b : a,
    );
    final String title = panoramaVideoSeriesTitle(members.first.title);
    out.add(
      PanoramaWork(
        kind: PanoramaWorkKind.video,
        key: latest.bookUid,
        title: title,
        coverPath: members
            .map((PanoramaVideoInput v) => v.coverPath)
            .firstWhere(
              (String? c) => c != null && c.isNotEmpty,
              orElse: () => null,
            ),
        memberKeys: <String>[
          for (final PanoramaVideoInput v in members) v.bookUid,
        ],
        matchTitles: <String>[
          title,
          for (final PanoramaVideoInput v in members) v.title,
        ],
        lastOpenedAt: latest.lastPlayedAt,
      ),
    );
  }
  return out;
}

/// 把笔记挂到作品上并抽样，得到展示词表。
List<PanoramaWord> panoramaAssignWords(
  List<PanoramaWork> works,
  List<PanoramaNoteInput> notes, {
  int perWork = kPanoramaWordsPerWork,
  int loose = kPanoramaLooseWords,
}) {
  final Map<String, int> byKey = <String, int>{};
  final Map<String, int> byTag = <String, int>{};
  for (int i = 0; i < works.length; i++) {
    final PanoramaWork w = works[i];
    byKey.putIfAbsent(w.key, () => i);
    for (final String k in w.memberKeys) {
      byKey.putIfAbsent(k, () => i);
    }
    byTag.putIfAbsent(panoramaTagForm(w.title), () => i);
    for (final String t in w.matchTitles) {
      final String form = panoramaTagForm(t);
      if (form.isNotEmpty) byTag.putIfAbsent(form, () => i);
    }
  }
  final List<List<String>> perWorkWords = <List<String>>[
    for (int i = 0; i < works.length; i++) <String>[],
  ];
  final List<String> looseWords = <String>[];
  for (final PanoramaNoteInput n in notes) {
    final String? word = panoramaNoteWord(n.sortField, n.fields);
    if (word == null || word.isEmpty) continue;
    int? owner;
    for (final String k in n.sourceKeys) {
      owner = byKey[k];
      if (owner != null) break;
    }
    if (owner == null) {
      for (final String tag in n.tags) {
        owner = byTag[tag.toLowerCase()];
        if (owner != null) break;
      }
    }
    if (owner == null) {
      looseWords.add(word);
    } else {
      perWorkWords[owner].add(word);
    }
  }
  return <PanoramaWord>[
    for (int i = 0; i < works.length; i++)
      for (final String w in panoramaSampleEvenly(perWorkWords[i], perWork))
        PanoramaWord(w, i),
    for (final String w in panoramaSampleEvenly(looseWords, loose))
      PanoramaWord(w, -1),
  ];
}

/// 出处里能挂作品的身份。
List<String> panoramaSourceKeys(SrsSourceRef? source) {
  if (source == null) return const <String>[];
  final Map<String, Object?> d = source.data;
  return <String>[
    for (final String k in const <String>['bookKey', 'mangaKey', 'mediaKey'])
      if (d[k] case final String v when v.isNotEmpty) v,
  ];
}

/// 从本机库与复习库读出全景数据。
///
/// [srs] 为 null（复习库未就绪）时没有词。读笔记字段 / 出处走 [SrsDbStore.notes]
/// 的批量物化（每块几次往返）。
Future<PanoramaLibrary> loadPanoramaLibrary({
  required FushiDatabase db,
  required SrsDbStore? srs,
}) async {
  final List<PanoramaWork> works = <PanoramaWork>[];

  final Map<String, int> positionAt = <String, int>{
    for (final ReaderPositionRow r in await db.select(db.readerPositions).get())
      r.bookUid: r.updatedAt,
  };
  for (final EpubBookRow b in await db.select(db.epubBooks).get()) {
    final BookFormat format = BookFormat.parseOrEpub(b.format);
    final bool manga = format == BookFormat.manga;
    works.add(
      PanoramaWork(
        kind: manga ? PanoramaWorkKind.manga : PanoramaWorkKind.book,
        key: b.bookKey,
        title: b.title,
        coverPath: b.coverPath,
        memberKeys: <String>[b.bookKey, if (b.uid.isNotEmpty) b.uid],
        matchTitles: <String>[b.title],
        extractDir: format == BookFormat.epub ? b.extractDir : null,
        bookUid: b.uid.isEmpty ? null : b.uid,
        lastOpenedAt: positionAt[b.uid] ?? positionAt[b.bookKey] ?? 0,
      ),
    );
  }

  final List<PanoramaVideoInput> videos = <PanoramaVideoInput>[
    for (final VideoBookRow v in await db.select(db.videoBooks).get())
      PanoramaVideoInput(
        bookUid: v.bookUid,
        title: v.title,
        coverPath: v.coverPath,
        lastPlayedAt: v.lastPlayedAt ?? 0,
      ),
  ];
  final List<MediaCollectionRow> collections = await (db.select(
    db.mediaCollections,
  )..where((c) => c.collectionType.equals('playlist'))).get();
  final List<MediaCollectionItemRow> items =
      await (db.select(db.mediaCollectionItems)
            ..where((i) => i.mediaType.equals('video'))
            ..orderBy(<OrderClauseGenerator<$MediaCollectionItemsTable>>[
              (i) => OrderingTerm.asc(i.sortIndex),
            ]))
          .get();
  final Map<int, List<String>> members = <int, List<String>>{};
  for (final MediaCollectionItemRow it in items) {
    (members[it.collectionId] ??= <String>[]).add(it.entryKey);
  }
  works.addAll(
    panoramaGroupVideos(videos, <PanoramaPlaylistInput>[
      for (final MediaCollectionRow c in collections)
        PanoramaPlaylistInput(
          id: c.id,
          name: c.name,
          coverPath: c.coverPath,
          memberUids: members[c.id] ?? const <String>[],
        ),
    ]),
  );

  for (final GalgameRow g in await db.select(db.galgames).get()) {
    works.add(
      PanoramaWork(
        kind: PanoramaWorkKind.game,
        key: g.id,
        title: g.name,
        coverPath: g.coverPath,
        matchTitles: <String>[g.name],
      ),
    );
  }
  for (final MusicAlbumRow a in await db.select(db.musicAlbums).get()) {
    works.add(
      PanoramaWork(
        kind: PanoramaWorkKind.music,
        key: a.albumUid,
        title: a.title,
        coverPath: a.coverPath,
        matchTitles: <String>[a.title],
      ),
    );
  }

  if (srs == null) {
    return PanoramaLibrary(
      works: works,
      words: const <PanoramaWord>[],
      minedTotal: 0,
    );
  }
  final List<SrsNoteCacheRow> rows =
      await (srs.db.select(srs.db.srsNotesCache)
            ..where(
              (n) => n.profileUid.equals(srs.profileUid) & n.deletedAt.isNull(),
            )
            ..orderBy(<OrderClauseGenerator<$SrsNotesCacheTable>>[
              (n) => OrderingTerm.asc(n.createdAt),
            ]))
          .get();
  // 出处只有物化后的笔记才有：全部物化（分块批量），字段顺便给内部编号的词兜底。
  final Map<String, SrsNoteView?> views = await srs.notes(
    rows.map((SrsNoteCacheRow r) => r.id),
  );
  final List<PanoramaNoteInput> notes = <PanoramaNoteInput>[
    for (final SrsNoteCacheRow r in rows)
      PanoramaNoteInput(
        sortField: r.sortField,
        tags: _decodeTags(r.tagsJson),
        fields: views[r.id]?.fields.values.toList() ?? const <String>[],
        sourceKeys: panoramaSourceKeys(views[r.id]?.source),
      ),
  ];
  return PanoramaLibrary(
    works: works,
    words: panoramaAssignWords(works, notes),
    minedTotal: rows.length,
  );
}

List<String> _decodeTags(String json) {
  try {
    final Object? v = jsonDecode(json);
    if (v is List) {
      return <String>[
        for (final Object? t in v)
          if (t is String) t,
      ];
    }
  } on FormatException {
    // 坏 JSON 当没标签。
  }
  return const <String>[];
}

/// 书当前进度处的正文片段（翻开时竖排显示）；取不到返回 null。在后台 isolate 解析。
Future<String?> loadPanoramaBookExcerpt({
  required FushiDatabase db,
  required PanoramaWork work,
  int maxChars = 420,
}) async {
  final String? extractDir = work.extractDir;
  if (extractDir == null) return null;
  final ReaderPositionRow? pos = work.bookUid == null
      ? null
      : await db.getReaderPosition(work.bookUid!);
  final int section = pos?.sectionIndex ?? 0;
  // charOffset 是章内绝对字符偏移（-1 = 旧行没有）；normCharOffset 是章内 0–10000 的比例。
  final int charOffset = pos?.charOffset ?? -1;
  final int normOffset = pos?.normCharOffset ?? 0;
  return Isolate.run<String?>(() {
    final EpubBook book;
    try {
      book = EpubParser.parseFromExtracted(extractDir);
    } on FormatException {
      return null;
    }
    if (book.chapters.isEmpty) return null;
    final int s = section.clamp(0, book.chapters.length - 1);
    final String text = book.chapterPlainText(s).replaceAll(RegExp(r'\s+'), '');
    if (text.isEmpty) return null;
    final int start =
        (charOffset >= 0 ? charOffset : text.length * normOffset ~/ 10000)
            .clamp(0, text.length - 1);
    final int end = (start + maxChars).clamp(0, text.length);
    return text.substring(start, end);
  });
}
