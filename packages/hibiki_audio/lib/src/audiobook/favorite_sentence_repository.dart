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

/// 收藏句来源的**内存态**枚举（BUG-1120）。持久化 JSON 的 `source` 字段仍存
/// 上面四个原字符串常量（wire 契约字节不变），本枚举只在读取后解析使用，
/// 供 UI 层穷尽 switch——消除「video vs 其它」的 bool 降维把 audiobook/lyrics
/// 静默展示成书的问题。
enum SentenceSourceKind {
  book(kFavoriteSentenceSourceBook),
  video(kFavoriteSentenceSourceVideo),
  audiobook(kFavoriteSentenceSourceAudiobook),
  lyrics(kFavoriteSentenceSourceLyrics);

  const SentenceSourceKind(this.dbValue);

  /// 落库字符串（与 `kFavoriteSentenceSource*` 常量逐字节一致）。
  final String dbValue;

  /// 严格解析：精确匹配四个落库值之一，未知/null → null（由调用方决定回退）。
  static SentenceSourceKind? tryParse(String? raw) {
    for (final SentenceSourceKind kind in SentenceSourceKind.values) {
      if (kind.dbValue == raw) return kind;
    }
    return null;
  }
}

/// 宽松解析：未知串/null/空串一律回退 [SentenceSourceKind.book]，与
/// [FavoriteSentence.fromJson] 对旧条目缺 `source` 字段的向后兼容默认一致。
SentenceSourceKind sentenceSourceKindOf(String? raw) =>
    SentenceSourceKind.tryParse(raw) ?? SentenceSourceKind.book;

/// 收藏句删除传播墓碑的 mediaType（与收藏词 `'favoriteword'` 并列）。存进统一表
/// [HibikiDatabase.writeSyncDeletionTombstone]，供 aggregate 并集抑制复活 + orchestrator
/// 逐条确认删对端两条通道共用。
const String kFavoriteSentenceTombstoneType = 'favoritesentence';

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
  })  : id = id ?? _generateFavoriteId(),
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

  // BUG-494 (TODO-1053 Bug C)：id 生成必须无碰撞。旧 'hl_<microsecondsSinceEpoch>' 在同一
  // 微秒内连续 new 两条（快速连续收藏 / 测试）会撞出相同 id → id 身份键坍缩（add 按 id 去重
  // 误判重复丢第二条、removeById 连坐）。加进程内单调计数器后缀，保证同微秒也唯一。
  static int _idCounter = 0;
  static String _generateFavoriteId() =>
      'hl_${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

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

  /// 跨设备稳定的内容身份键（**唯一真源**：aggregate 去重、删除墓碑 itemKey、接收端删除
  /// 三处共用同一函数，杜绝键分叉）。`收藏句无稳定 id`（本机随机），只能靠内容四元组。
  /// text 长度前缀防分隔符伪造字段边界；可空字段用显式 `<null>` 哨兵，避免 null 与空串/0
  /// 撞键。与 `AggregateMergeService._favoriteSentenceContentKey`（已改为委托本函数）一致。
  static String itemKey({
    required String text,
    required String? bookKey,
    required int? sectionIndex,
    required int? normCharOffset,
  }) {
    const String nul = '<null>';
    final String bk = bookKey ?? nul;
    final String section = sectionIndex == null ? nul : sectionIndex.toString();
    final String offset =
        normCharOffset == null ? nul : normCharOffset.toString();
    return '${text.length}:$text|$bk|$section|$offset';
  }

  /// [itemKey] 的便捷重载：直接从一条收藏句取内容键。
  static String itemKeyOf(FavoriteSentence s) => itemKey(
        text: s.text,
        bookKey: s.bookKey,
        sectionIndex: s.sectionIndex,
        normCharOffset: s.normCharOffset,
      );

  /// 写删除墓碑（取消收藏 → 传播删除）。
  Future<void> _writeTombstone(FavoriteSentence s) =>
      _db.writeSyncDeletionTombstone(kFavoriteSentenceTombstoneType,
          itemKeyOf(s), DateTime.now().millisecondsSinceEpoch);

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
    // BUG-494 (TODO-1053 Bug C)：去重**只按 id**（每条 add 的 FavoriteSentence 自带唯一 id）。
    // 不再按内容键（text+bookKey+section+normCharOffset）去重——那会在 normCharOffset 均 null
    // 时把同章重复短句 collapse 成一条（身份键坍缩，Bug C 的幻影收藏根因）。重复收藏同一句
    // 由调用方（reader 的 _currentSentenceIsFavorited 门控）拦在 add 之前，不靠这里内容去重。
    if (sentences.any((s) => s.id == sentence.id)) {
      return;
    }
    sentences.insert(0, sentence);
    await _db.setPref(
      _key,
      jsonEncode(sentences.map((s) => s.toJson()).toList()),
    );
    // 重新收藏 → 清除该内容键的删除墓碑；否则墓碑会在 aggregate 并集里把这条刚收藏的句
    // 再次抑制掉（与收藏词 addFavoriteWord 清墓碑同律）。
    await _db.clearSyncDeletionTombstone(
        kFavoriteSentenceTombstoneType, itemKeyOf(sentence));
  }

  /// 查已收藏项：返回**匹配到的条目 id**（未收藏 → null）。id-first——先按内容键（含
  /// normCharOffset）精确匹配，命中即返回该条 id 供 [removeById] 精确删除，杜绝 Bug C
  /// 的身份键坍缩误删/误点亮（同章重复短句 offset 均 null 时，内容键相同也只会命中「某一
  /// 条」，但因 removeById 按返回 id 删，不会连坐删掉另一条同内容记录）。
  Future<String?> matchedFavoriteId({
    required String text,
    required String? bookKey,
    required int? sectionIndex,
    required int? normCharOffset,
  }) async {
    final sentences = await getAll();
    for (final FavoriteSentence s in sentences) {
      if (s.text == text &&
          s.bookKey == bookKey &&
          s.sectionIndex == sectionIndex &&
          s.normCharOffset == normCharOffset) {
        return s.id;
      }
    }
    return null;
  }

  Future<bool> isFavorited({
    required String text,
    required String? bookKey,
    required int? sectionIndex,
    required int? normCharOffset,
  }) async {
    return (await matchedFavoriteId(
          text: text,
          bookKey: bookKey,
          sectionIndex: sectionIndex,
          normCharOffset: normCharOffset,
        )) !=
        null;
  }

  Future<void> removeByContent({
    required String text,
    required String? bookKey,
    required int? sectionIndex,
    required int? normCharOffset,
    bool propagateDeletion = true,
  }) async {
    final sentences = await getAll();
    // BUG-494：只删**第一条**匹配内容键的记录（非 removeWhere 全删），避免同章重复短句
    // （offset 均 null → 内容键相同）取消收藏时把另一条同内容记录连坐删掉。
    final int idx = sentences.indexWhere((s) =>
        s.text == text &&
        s.bookKey == bookKey &&
        s.sectionIndex == sectionIndex &&
        s.normCharOffset == normCharOffset);
    if (idx < 0) return;
    final FavoriteSentence removed = sentences[idx];
    sentences.removeAt(idx);
    await _db.setPref(
      _key,
      jsonEncode(sentences.map((s) => s.toJson()).toList()),
    );
    if (propagateDeletion) await _writeTombstone(removed);
  }

  Future<void> removeAt(int index, {bool propagateDeletion = true}) async {
    final sentences = await getAll();
    if (index < 0 || index >= sentences.length) return;
    final FavoriteSentence removed = sentences[index];
    sentences.removeAt(index);
    await _db.setPref(
      _key,
      jsonEncode(sentences.map((s) => s.toJson()).toList()),
    );
    if (propagateDeletion) await _writeTombstone(removed);
  }

  Future<void> removeById(String id, {bool propagateDeletion = true}) async {
    final sentences = await getAll();
    // id 理论唯一，但 BUG-494 前的旧数据可能撞 id；捕获全部被删条目各写一次墓碑（同内容
    // 键幂等）。
    final List<FavoriteSentence> removed =
        sentences.where((s) => s.id == id).toList();
    if (removed.isEmpty) return;
    sentences.removeWhere((s) => s.id == id);
    await _db.setPref(
      _key,
      jsonEncode(sentences.map((s) => s.toJson()).toList()),
    );
    if (propagateDeletion) {
      for (final FavoriteSentence s in removed) {
        await _writeTombstone(s);
      }
    }
  }

  /// 按内容键取消收藏（删除传播**接收端**确认后调用）。默认写墓碑：本设备也需墓碑抑制
  /// 第三设备 aggregate 快照的并集复活（与收藏词 `_applyConfirmedDeletions` 同律）。本地
  /// 已无此句时仍写墓碑（幂等，防复活）。
  Future<void> removeByItemKey(String key,
      {bool propagateDeletion = true}) async {
    final sentences = await getAll();
    final int idx = sentences.indexWhere((s) => itemKeyOf(s) == key);
    if (idx < 0) {
      if (propagateDeletion) {
        await _db.writeSyncDeletionTombstone(kFavoriteSentenceTombstoneType,
            key, DateTime.now().millisecondsSinceEpoch);
      }
      return;
    }
    final FavoriteSentence removed = sentences[idx];
    sentences.removeAt(idx);
    await _db.setPref(
      _key,
      jsonEncode(sentences.map((s) => s.toJson()).toList()),
    );
    if (propagateDeletion) await _writeTombstone(removed);
  }

  /// 清空全部收藏句。收藏夹「清空」面板的收藏句范围走这里，直接删掉承载偏好键。
  /// [propagateDeletion] 时为清空前的每条各写一个删除墓碑（传播到其它设备）。
  Future<void> clear({bool propagateDeletion = true}) async {
    if (propagateDeletion) {
      for (final FavoriteSentence s in await getAll()) {
        await _writeTombstone(s);
      }
    }
    await _db.deletePref(_key);
  }
}
