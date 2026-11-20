import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';

/// 收藏句子 / 制卡句（`mined_sentences.source`）的来源标识。与制卡/收藏单词统计的
/// `kStatSource*` 口径对齐：统计分桶分「书籍 / 视频 / 游戏 / 音乐」四桶——
/// [kFavoriteSentenceSourceVideo] 归视频、[kFavoriteSentenceSourceGame] 归游戏、
/// [kFavoriteSentenceSourceMusic] 归音乐，其余（书内 / 有声书 / 歌词模式 / 漫画）都归
/// 阅读（书籍）。收藏夹页展示时仍按细分值各自标注来源。
const String kFavoriteSentenceSourceBook = 'book';
const String kFavoriteSentenceSourceVideo = 'video';
const String kFavoriteSentenceSourceAudiobook = 'audiobook';

/// 有声书阅读器的「歌词模式」（书域，身份是 bookKey）。与音乐模块的
/// [kFavoriteSentenceSourceMusic] 是两回事：后者身份是 track uid、跳回音乐播放器。
const String kFavoriteSentenceSourceLyrics = 'lyrics';

/// galgame hook 会话期间的收藏句 / 制卡句。与 `kStatSourceGame` 逐字节同值，故统计
/// 分桶可直接对照。出处身份 = `galgames.id`。
const String kFavoriteSentenceSourceGame = 'game';

/// 漫画阅读器（本地卷 / 在线下载）的制卡句。出处身份 = bookKey + 页码。
const String kFavoriteSentenceSourceManga = 'manga';

/// 音乐模块歌词（v130 起）的制卡句。与 `kStatSourceMusic` 逐字节同值；出处身份 =
/// `music_tracks.track_uid` + 时间轴位置。
const String kFavoriteSentenceSourceMusic = 'music';

/// 浏览器扩展看网页视频（YouTube / niconico / Netflix / 任意 `<video>` 站）时收藏的句子
/// 或视频本身（反馈 KGC1ifR1a3）。出处身份 [FavoriteSentence.bookKey] = 规范化后的网页
/// 地址（去掉时间参数），[FavoriteSentence.chapterLabel] = 站点名，锚点同视频口径
/// （[FavoriteSentence.normCharOffset] / [FavoriteSentence.normCharLength] = cue 起点 /
/// 时长毫秒）；[FavoriteSentence.text] 为空串 = 收藏的是视频本身（无锚点）。统计归视频桶。
const String kFavoriteSentenceSourceWeb = 'web';

/// 收藏句来源的**内存态**枚举（BUG-1120）。持久化 JSON 的 `source` 字段仍存
/// 上面的原字符串常量（wire 契约字节不变），本枚举只在读取后解析使用，
/// 供 UI 层穷尽 switch——消除「video vs 其它」的 bool 降维把 audiobook/lyrics
/// 静默展示成书的问题。
enum SentenceSourceKind {
  book(kFavoriteSentenceSourceBook),
  video(kFavoriteSentenceSourceVideo),
  audiobook(kFavoriteSentenceSourceAudiobook),
  lyrics(kFavoriteSentenceSourceLyrics),
  game(kFavoriteSentenceSourceGame),
  manga(kFavoriteSentenceSourceManga),
  music(kFavoriteSentenceSourceMusic),
  web(kFavoriteSentenceSourceWeb);

  const SentenceSourceKind(this.dbValue);

  /// 落库字符串（与 `kFavoriteSentenceSource*` 常量逐字节一致）。
  final String dbValue;

  /// 严格解析：精确匹配任一落库值，未知/null → null（由调用方决定回退）。
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
/// [FushiDatabase.writeSyncDeletionTombstone]，供 aggregate 并集抑制复活 + orchestrator
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
        expression: json['expression'] as String?,
        reading: json['reading'] as String?,
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
    this.expression,
    this.reading,
  }) : id = id ?? _generateFavoriteId(),
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

  /// 从查词弹窗顶栏 ★ 收藏这句时，当时查的那个词（顶层结果的首个词头）与读音。
  /// 收藏夹在句子旁显示它、批量制卡时以它为词条。划选 / 右键菜单收藏的句子没有
  /// 查词对象，为 null；旧条目无此字段同为 null。
  final String? expression;
  final String? reading;

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
    if (expression != null) 'expression': expression,
    if (reading != null) 'reading': reading,
  };
}

class FavoriteSentenceRepository {
  FavoriteSentenceRepository(this._db);

  final FushiDatabase _db;

  /// 表行 → 模型（v165 起收藏句存 `favorite_sentences` 表）。
  static FavoriteSentence fromRow(FavoriteSentenceRow r) => FavoriteSentence(
    id: r.id,
    text: r.sentence,
    bookTitle: r.bookTitle,
    chapterLabel: r.chapterLabel,
    createdAt: DateTime.fromMicrosecondsSinceEpoch(r.createdAtUs),
    bookKey: r.bookKey,
    sectionIndex: r.sectionIndex,
    normCharOffset: r.normCharOffset,
    normCharLength: r.normCharLength,
    color: r.color,
    source: r.source,
    dateKey: r.dateKey,
    expression: r.expression,
    reading: r.reading,
  );

  /// 模型 → 表行。
  static FavoriteSentencesCompanion toCompanion(FavoriteSentence s) =>
      FavoriteSentencesCompanion.insert(
        id: s.id,
        sentence: s.text,
        bookTitle: Value<String>(s.bookTitle),
        chapterLabel: Value<String?>(s.chapterLabel),
        createdAtUs: s.createdAt.microsecondsSinceEpoch,
        bookKey: Value<String?>(s.bookKey),
        sectionIndex: Value<int?>(s.sectionIndex),
        normCharOffset: Value<int?>(s.normCharOffset),
        normCharLength: Value<int?>(s.normCharLength),
        color: Value<String?>(s.color),
        source: Value<String>(s.source),
        dateKey: Value<String?>(s.dateKey),
        expression: Value<String?>(s.expression),
        reading: Value<String?>(s.reading),
      );

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
    final String offset = normCharOffset == null
        ? nul
        : normCharOffset.toString();
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
      _db.writeSyncDeletionTombstone(
        kFavoriteSentenceTombstoneType,
        itemKeyOf(s),
        DateTime.now().millisecondsSinceEpoch,
      );

  /// 收藏句表有写入就发一次（任何来源：本仓库的增删、收藏夹页、同步合并、备份合并、
  /// 音乐别名改写——它们都写同一张表）。持有页内镜像的页面（视频播放页的收藏星标、
  /// 手机遥控）据此重读，不必等下次打开面板。
  Stream<void> watchChanges() => _db.watchFavoriteSentencesChanged();

  /// 全部收藏句，新收藏在前。
  Future<List<FavoriteSentence>> getAll() async => <FavoriteSentence>[
    for (final FavoriteSentenceRow r in await _db.getAllFavoriteSentenceRows())
      fromRow(r),
  ];

  Future<void> add(FavoriteSentence sentence) async {
    // BUG-494 (TODO-1053 Bug C)：去重**只按 id**（每条 add 的 FavoriteSentence 自带唯一 id）。
    // 不按内容键（text+bookKey+section+normCharOffset）去重——那会在 normCharOffset 均 null
    // 时把同章重复短句 collapse 成一条（身份键坍缩，Bug C 的幻影收藏根因）。重复收藏同一句
    // 由调用方（reader 的 _currentSentenceIsFavorited 门控）拦在 add 之前，不靠这里内容去重。
    if (!await _db.insertFavoriteSentenceRow(toCompanion(sentence))) return;
    // 重新收藏 → 清除该内容键的删除墓碑；否则墓碑会在 aggregate 并集里把这条刚收藏的句
    // 再次抑制掉（与收藏词 addFavoriteWord 清墓碑同律）。
    await _db.clearSyncDeletionTombstone(
      kFavoriteSentenceTombstoneType,
      itemKeyOf(sentence),
    );
  }

  /// 查已收藏项：返回**匹配到的条目 id**（未收藏 → null）。按内容键（含 normCharOffset）
  /// 精确匹配，命中即返回该条 id 供 [removeById] 精确删除，杜绝 Bug C 的身份键坍缩误删 /
  /// 误点亮（同章重复短句 offset 均 null 时内容键相同，也只命中最新的那一条，removeById
  /// 按返回 id 删，不会连坐删掉另一条同内容记录）。
  Future<String?> matchedFavoriteId({
    required String text,
    required String? bookKey,
    required int? sectionIndex,
    required int? normCharOffset,
  }) async => (await _db.findFavoriteSentenceByContent(
    text: text,
    bookKey: bookKey,
    sectionIndex: sectionIndex,
    normCharOffset: normCharOffset,
  ))?.id;

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
    // BUG-494：只删**一条**匹配内容键的记录（最新的那条），避免同章重复短句（offset 均
    // null → 内容键相同）取消收藏时把另一条同内容记录连坐删掉。
    final FavoriteSentenceRow? row = await _db.findFavoriteSentenceByContent(
      text: text,
      bookKey: bookKey,
      sectionIndex: sectionIndex,
      normCharOffset: normCharOffset,
    );
    if (row == null) return;
    await _removeRow(row, propagateDeletion: propagateDeletion);
  }

  /// 删 [getAll] 列表里第 [index] 条（越界不动）。
  Future<void> removeAt(int index, {bool propagateDeletion = true}) async {
    final List<FavoriteSentenceRow> rows = await _db
        .getAllFavoriteSentenceRows();
    if (index < 0 || index >= rows.length) return;
    await _removeRow(rows[index], propagateDeletion: propagateDeletion);
  }

  Future<void> removeById(String id, {bool propagateDeletion = true}) async {
    final FavoriteSentenceRow? row = await _db.getFavoriteSentenceRowById(id);
    if (row == null) return;
    await _removeRow(row, propagateDeletion: propagateDeletion);
  }

  /// 按内容键取消收藏（删除传播**接收端**确认后调用）。默认写墓碑：本设备也需墓碑抑制
  /// 第三设备 aggregate 快照的并集复活（与收藏词 `_applyConfirmedDeletions` 同律）。本地
  /// 已无此句时仍写墓碑（幂等，防复活）。
  Future<void> removeByItemKey(
    String key, {
    bool propagateDeletion = true,
  }) async {
    for (final FavoriteSentenceRow row
        in await _db.getAllFavoriteSentenceRows()) {
      if (itemKeyOf(fromRow(row)) == key) {
        await _removeRow(row, propagateDeletion: propagateDeletion);
        return;
      }
    }
    if (propagateDeletion) {
      await _db.writeSyncDeletionTombstone(
        kFavoriteSentenceTombstoneType,
        key,
        DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  /// 清空全部收藏句（收藏夹「清空」面板的收藏句范围走这里）。[propagateDeletion] 时为
  /// 清空前的每条各写一个删除墓碑（传播到其它设备）。
  Future<void> clear({bool propagateDeletion = true}) async {
    if (propagateDeletion) {
      for (final FavoriteSentence s in await getAll()) {
        await _writeTombstone(s);
      }
    }
    await _db.deleteAllFavoriteSentences();
  }

  /// 整表换成 [sentences]（同步合并 / 备份合并的结果）。与现有内容逐字段相同时不写，
  /// 免得一次空合并唤醒 [watchChanges] 的全部订阅方。
  Future<void> replaceAll(List<FavoriteSentence> sentences) async {
    final List<FavoriteSentence> current = await getAll();
    if (_sameContent(current, sentences)) return;
    await _db.replaceAllFavoriteSentenceRows(<FavoriteSentencesCompanion>[
      for (final FavoriteSentence s in sentences) toCompanion(s),
    ]);
  }

  Future<void> _removeRow(
    FavoriteSentenceRow row, {
    required bool propagateDeletion,
  }) async {
    await _db.deleteFavoriteSentenceById(row.id);
    if (propagateDeletion) await _writeTombstone(fromRow(row));
  }

  static bool _sameContent(List<FavoriteSentence> a, List<FavoriteSentence> b) {
    if (a.length != b.length) return false;
    String sig(FavoriteSentence s) => jsonEncode(s.toJson());
    final List<String> sa = a.map(sig).toList()..sort();
    final List<String> sb = b.map(sig).toList()..sort();
    for (int i = 0; i < sa.length; i++) {
      if (sa[i] != sb[i]) return false;
    }
    return true;
  }
}
