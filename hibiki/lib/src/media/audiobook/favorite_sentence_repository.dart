import 'dart:convert';

import 'package:hibiki/src/database/database.dart';

class FavoriteSentence {
  FavoriteSentence({
    required this.text,
    required this.bookTitle,
    this.chapterLabel,
    required this.createdAt,
    this.ttuBookId,
    this.sectionIndex,
    this.normCharOffset,
    this.normCharLength,
    this.color,
    String? id,
  }) : id = id ?? 'hl_${DateTime.now().microsecondsSinceEpoch}';

  final String id;
  final String text;
  final String bookTitle;
  final String? chapterLabel;
  final DateTime createdAt;
  final int? ttuBookId;
  final int? sectionIndex;
  final int? normCharOffset;
  final int? normCharLength;
  final String? color;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'bookTitle': bookTitle,
        if (chapterLabel != null) 'chapterLabel': chapterLabel,
        'createdAt': createdAt.toIso8601String(),
        if (ttuBookId != null) 'ttuBookId': ttuBookId,
        if (sectionIndex != null) 'sectionIndex': sectionIndex,
        if (normCharOffset != null) 'normCharOffset': normCharOffset,
        if (normCharLength != null) 'normCharLength': normCharLength,
        if (color != null) 'color': color,
      };

  factory FavoriteSentence.fromJson(Map<String, dynamic> json) =>
      FavoriteSentence(
        id: json['id'] as String?,
        text: json['text'] as String,
        bookTitle: json['bookTitle'] as String,
        chapterLabel: json['chapterLabel'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
        ttuBookId: json['ttuBookId'] as int?,
        sectionIndex: json['sectionIndex'] as int?,
        normCharOffset: json['normCharOffset'] as int?,
        normCharLength: json['normCharLength'] as int?,
        color: json['color'] as String?,
      );
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
    if (sentences.any((FavoriteSentence s) => s.id == sentence.id)) return;
    sentences.insert(0, sentence);
    await _db.setPref(
      _key,
      jsonEncode(sentences.map((s) => s.toJson()).toList()),
    );
  }

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
    sentences.removeWhere((FavoriteSentence s) => s.id == id);
    await _db.setPref(
      _key,
      jsonEncode(sentences.map((FavoriteSentence s) => s.toJson()).toList()),
    );
  }
}
