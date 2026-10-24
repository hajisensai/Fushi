/// 「我库里的例句」语料的数据形态（与 native/fushi_corpus 的线格式一一对应）。
library;

/// 语料里一份文档来自哪个模块。值就是线格式里的 `u8 kind`，也是查询 `kindMask` 的位号，
/// 与 native/fushi_corpus 共用，**不得改值**（磁盘上的旧文档按它解释）。
///
/// 这是语料域自己的枚举（命名术语表：各域独立枚举）；与制卡来源 `SentenceSourceKind`
/// 的换算在 app 的 `media_kind_mappings.dart`。
enum CorpusSourceKind {
  /// 书正文：key = `EpubBooks.bookKey`，part = -1，section = 章下标，pos / len = 章内学习单位。
  book(1),

  /// 视频字幕：key = `bookUid`，part = section = 集下标（单视频 0），pos / len = 毫秒。
  video(2),

  /// 音乐歌词：key = `music_tracks.track_uid`，part = -1，section = 0，pos / len = 毫秒（曲内）。
  music(3),

  /// 游戏台词（文本钩子）：key = `galgames.id`，part = 落盘批次序号，section = 0，
  /// pos = 收到台词的时刻（毫秒时间戳），len = 0。
  game(4);

  const CorpusSourceKind(this.code);

  final int code;

  /// 查询 kindMask 里本 kind 的位。
  int get bit => 1 << code;

  static CorpusSourceKind? fromCode(int code) {
    for (final CorpusSourceKind kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }

  static int maskOf(Iterable<CorpusSourceKind> kinds) {
    int mask = 0;
    for (final CorpusSourceKind kind in kinds) {
      mask |= kind.bit;
    }
    return mask;
  }
}

/// 喂进语料的一个句子。定位字段的语义随 [CorpusSourceKind] 定（见各值的注释）。
class CorpusSentence {
  const CorpusSentence({
    required this.section,
    required this.pos,
    required this.len,
    required this.text,
  });

  final int section;
  final int pos;
  final int len;
  final String text;
}

/// 喂进语料的一份文档：同一 (kind, key, part) 再次写入即整份替换。
class CorpusDocument {
  const CorpusDocument({
    required this.kind,
    required this.key,
    required this.part,
    required this.title,
    required this.fingerprint,
    required this.normalizer,
    required this.updatedAt,
    required this.sentences,
  });

  final CorpusSourceKind kind;
  final String key;
  final int part;

  /// 展示用标题（书名 / 视频名 / 曲名 / 游戏名）。
  final String title;

  /// 内容指纹：与来源当前状态比对，不同就重新喂入。
  final String fingerprint;

  /// 词元归一的口径（已加载词典集合的签名）：词典换了，旧文档的词元就过期了。
  final String normalizer;

  final int updatedAt;
  final List<CorpusSentence> sentences;
}

/// 语料里已有的一份文档（`fcorp_docs`）。
class CorpusDocInfo {
  const CorpusDocInfo({
    required this.kind,
    required this.key,
    required this.part,
    required this.title,
    required this.fingerprint,
    required this.normalizer,
    required this.updatedAt,
    required this.sentences,
  });

  factory CorpusDocInfo.fromJson(Map<String, Object?> json) => CorpusDocInfo(
    kind: CorpusSourceKind.fromCode(json['kind']! as int),
    key: json['key']! as String,
    part: json['part']! as int,
    title: json['title']! as String,
    fingerprint: json['fingerprint']! as String,
    normalizer: json['normalizer']! as String,
    updatedAt: json['updatedAt']! as int,
    sentences: json['sentences']! as int,
  );

  /// 未知 kind（更新的库写的）为 null。
  final CorpusSourceKind? kind;
  final String key;
  final int part;
  final String title;
  final String fingerprint;
  final String normalizer;
  final int updatedAt;
  final int sentences;
}

/// 一条例句命中。
class CorpusHit {
  const CorpusHit({
    required this.kind,
    required this.key,
    required this.part,
    required this.title,
    required this.section,
    required this.pos,
    required this.len,
    required this.text,
    required this.highlights,
  });

  final CorpusSourceKind kind;
  final String key;
  final int part;
  final String title;
  final int section;
  final int pos;
  final int len;
  final String text;

  /// 句内命中词元的 UTF-16 区间。
  final List<({int start, int length})> highlights;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.code,
    'key': key,
    'part': part,
    'title': title,
    'section': section,
    'pos': pos,
    'len': len,
    'text': text,
    'hl': <List<int>>[
      for (final ({int start, int length}) h in highlights)
        <int>[h.start, h.length],
    ],
  };
}

/// 一个模块的命中：[total] 是该模块全部命中句数（[items] 只是排好序的前几条）。
class CorpusGroup {
  const CorpusGroup({
    required this.kind,
    required this.total,
    required this.items,
  });

  final CorpusSourceKind kind;
  final int total;
  final List<CorpusHit> items;
}

class CorpusQueryResult {
  const CorpusQueryResult({required this.total, required this.groups});

  static const CorpusQueryResult empty = CorpusQueryResult(
    total: 0,
    groups: <CorpusGroup>[],
  );

  /// 解析 `fcorp_query` 的 JSON；未知 kind 的组跳过。
  factory CorpusQueryResult.fromJson(Map<String, Object?> json) {
    final List<CorpusGroup> groups = <CorpusGroup>[];
    for (final Object? raw in json['groups']! as List<Object?>) {
      final Map<String, Object?> g = raw! as Map<String, Object?>;
      final CorpusSourceKind? kind = CorpusSourceKind.fromCode(
        g['kind']! as int,
      );
      if (kind == null) continue;
      groups.add(
        CorpusGroup(
          kind: kind,
          total: g['total']! as int,
          items: <CorpusHit>[
            for (final Object? item in g['items']! as List<Object?>)
              _hitFromJson(kind, item! as Map<String, Object?>),
          ],
        ),
      );
    }
    return CorpusQueryResult(total: json['total']! as int, groups: groups);
  }

  final int total;
  final List<CorpusGroup> groups;

  bool get isEmpty => groups.every((CorpusGroup g) => g.items.isEmpty);
}

CorpusHit _hitFromJson(CorpusSourceKind kind, Map<String, Object?> json) =>
    CorpusHit(
      kind: kind,
      key: json['key']! as String,
      part: json['part']! as int,
      title: json['title']! as String,
      section: json['section']! as int,
      pos: json['pos']! as int,
      len: json['len']! as int,
      text: json['text']! as String,
      highlights: <({int start, int length})>[
        for (final Object? h in json['hl']! as List<Object?>) _span(h),
      ],
    );

({int start, int length}) _span(Object? raw) {
  final List<Object?> pair = raw! as List<Object?>;
  return (start: pair[0]! as int, length: pair[1]! as int);
}

class CorpusStats {
  const CorpusStats({
    required this.docs,
    required this.sentences,
    required this.terms,
    required this.postings,
    required this.droppedOnOpen,
  });

  factory CorpusStats.fromJson(Map<String, Object?> json) => CorpusStats(
    docs: json['docs']! as int,
    sentences: json['sentences']! as int,
    terms: json['terms']! as int,
    postings: json['postings']! as int,
    droppedOnOpen: json['droppedOnOpen']! as int,
  );

  final int docs;
  final int sentences;
  final int terms;
  final int postings;

  /// 打开时丢弃的损坏 / 过期副本文件数。
  final int droppedOnOpen;
}
