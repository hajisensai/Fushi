import 'dart:convert';

import 'package:hibiki_core/hibiki_core.dart';

/// 收藏句子的来源标识。与制卡/收藏单词统计的 `kStatSourceBook`/`kStatSourceVideo`
/// 口径对齐：统计分桶时只分「书籍 vs 视频」两桶——[kFavoriteSentenceSourceVideo]
/// 归视频统计，其余（书内 / 有声书 / 歌词）都归阅读（书籍）统计。收藏夹页展示时
/// 仍可按这四个细分值各自标注来源。
const String kFavoriteSentenceSourceBook = 'book';
const String kFavoriteSentenceSourceVideo = 'video';
const String kFavoriteSentenceSourceAudiobook = 'audiobook';
const String kFavoriteSentenceSourceLyrics = 'lyrics';

class FavoriteSentence {
  factory FavoriteSentence.fromJson(Map<String, dynamic> json) =>
      FavoriteSentence(
        id: json['id'] as String?,
        text: json['text'] as String,
        bookTitle: json['bookTitle'] as String,
        chapterLabel: json['chapterLabel'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
        bookKey: json['bookKey'] as String?,
        sectionIndex: json['sectionIndex'] as int?,
        normCharOffset: json['normCharOffset'] as int?,
        normCharLength: json['normCharLength'] as int?,
        color: json['color'] as String?,
        // 向后兼容：旧条目无 source → 默认书籍；无 dateKey → 留空（不计入按日统计）。
        source: (json['source'] as String?) ?? kFavoriteSentenceSourceBook,
        dateKey: json['dateKey'] as String?,
      );
  FavoriteSentence({
    required this.text,
    required this.bookTitle,
    required this.createdAt,
    this.chapterLabel,
    this.bookKey,
    this.sectionIndex,
    this.normCharOffset,
    this.normCharLength,
    this.color,
    String? id,
    String? source,
    this.dateKey,
  })  : id = id ?? 'hl_${DateTime.now().microsecondsSinceEpoch}',
        source = source ?? kFavoriteSentenceSourceBook;

  final String id;
  final String text;
  final String bookTitle;
  final String? chapterLabel;
  final DateTime createdAt;
  final String? bookKey;
  final int? sectionIndex;
  final int? normCharOffset;
  final int? normCharLength;
  final String? color;

  /// 收藏来源（[kFavoriteSentenceSourceBook]/`Video`/`Audiobook`/`Lyrics`）。旧条目
  /// 反序列化时默认 [kFavoriteSentenceSourceBook]，保证既有书内收藏行为不变。
  final String source;

  /// 收藏日期键（形如 `2026-06-10`，与制卡/收藏单词统计的 `statDateKey` 同格式）。
  /// 旧条目无此字段 → null，按日统计时归为「未分类」，不参与分桶（不会崩）。
  final String? dateKey;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'bookTitle': bookTitle,
        if (chapterLabel != null) 'chapterLabel': chapterLabel,
        'createdAt': createdAt.toIso8601String(),
        if (bookKey != null) 'bookKey': bookKey,
        if (sectionIndex != null) 'sectionIndex': sectionIndex,
        if (normCharOffset != null) 'normCharOffset': normCharOffset,
        if (normCharLength != null) 'normCharLength': normCharLength,
        if (color != null) 'color': color,
        'source': source,
        if (dateKey != null) 'dateKey': dateKey,
      };
}

class FavoriteSentenceRepository {
  FavoriteSentenceRepository(this._db);

  final HibikiDatabase _db;

  static const String _key = 'favorite_sentences';

  Future<List<FavoriteSentence>> getAll() async {
    final raw = await _db.getPref(_key);
    if (raw == null || raw.isEmpty) return [];
    final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => FavoriteSentence.fromJson(e as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> add(FavoriteSentence sentence) async {
    final sentences = await getAll();
    if (sentences.any((s) => _contentMatch(s, sentence))) {
      return;
    }
    sentences.insert(0, sentence);
    await _db.setPref(
      _key,
      jsonEncode(sentences.map((s) => s.toJson()).toList()),
    );
  }

  Future<bool> isFavorited({
    required String text,
    required String? bookKey,
    required int? sectionIndex,
    required int? normCharOffset,
  }) async {
    final sentences = await getAll();
    return sentences.any((s) =>
        s.text == text &&
        s.bookKey == bookKey &&
        s.sectionIndex == sectionIndex &&
        s.normCharOffset == normCharOffset);
  }

  Future<void> removeByContent({
    required String text,
    required String? bookKey,
    required int? sectionIndex,
    required int? normCharOffset,
  }) async {
    final sentences = await getAll();
    sentences.removeWhere((s) =>
        s.text == text &&
        s.bookKey == bookKey &&
        s.sectionIndex == sectionIndex &&
        s.normCharOffset == normCharOffset);
    await _db.setPref(
      _key,
      jsonEncode(sentences.map((s) => s.toJson()).toList()),
    );
  }

  static bool _contentMatch(FavoriteSentence a, FavoriteSentence b) =>
      a.text == b.text &&
      a.bookKey == b.bookKey &&
      a.sectionIndex == b.sectionIndex &&
      a.normCharOffset == b.normCharOffset;

  Future<void> removeAt(int index) async {
    final sentences = await getAll();
    if (index < 0 || index >= sentences.length) return;
    sentences.removeAt(index);
    await _db.setPref(
      _key,
      jsonEncode(sentences.map((s) => s.toJson()).toList()),
    );
  }

  Future<void> removeById(String id) async {
    final sentences = await getAll();
    sentences.removeWhere((s) => s.id == id);
    await _db.setPref(
      _key,
      jsonEncode(sentences.map((s) => s.toJson()).toList()),
    );
  }
}
