/// 视频字幕 AI 校对的作品级专名表（spec `2026-10-19-video-asr-llm-subtitle-pipeline`
/// 第 3 节 S0）：数据形状、作品上下文与存储契约。
///
/// 表以「作品键」为单位（[SubtitleWorkContext.workKey]），一部作品生成一次、各集
/// 共用；用户可增删改，用户动过的条目（[SubtitleGlossaryEntry.userEdited]）在重新
/// 生成时保留。存储有两个实现：app / 服务端走 Drift 表 `video_subtitle_glossaries`，
/// 不入库的独立 CLI 走任务目录里的 JSON 文件。
library;

import 'dart:convert';

/// 专名表的一条：正式写法、读音、类别与 ASR 常见误写。
class SubtitleGlossaryEntry {
  const SubtitleGlossaryEntry({
    required this.ja,
    this.reading = '',
    this.kind = '',
    this.misrecognitions = const <String>[],
    this.note = '',
    this.userEdited = false,
  });

  factory SubtitleGlossaryEntry.fromJson(Map<String, Object?> json) =>
      SubtitleGlossaryEntry(
        ja: (json['ja'] as String? ?? '').trim(),
        reading: (json['reading'] as String? ?? '').trim(),
        kind: (json['kind'] as String? ?? '').trim(),
        misrecognitions: <String>[
          for (final Object? m
              in (json['misrecognitions'] as List<Object?>? ?? const <Object?>[]))
            if (m is String && m.trim().isNotEmpty) m.trim(),
        ],
        note: (json['note'] as String? ?? '').trim(),
        userEdited: json['userEdited'] == true,
      );

  /// 正式写法（字幕里要统一成的样子）。
  final String ja;

  /// 平假名读音；可空。
  final String reading;

  /// 类别：以「人名」开头的条目参与身份校验（如 `人名(平沢唯の名)`）。
  final String kind;

  /// 音声认识常见的误写。
  final List<String> misrecognitions;

  /// 自由备注（用户的说明）。
  final String note;

  /// 用户手动增改过：重新生成专名表时原样保留。
  final bool userEdited;

  /// 是不是人名条目（身份校验只数人名）。
  bool get isPersonName => kind.startsWith('人名');

  SubtitleGlossaryEntry copyWith({
    String? ja,
    String? reading,
    String? kind,
    List<String>? misrecognitions,
    String? note,
    bool? userEdited,
  }) => SubtitleGlossaryEntry(
    ja: ja ?? this.ja,
    reading: reading ?? this.reading,
    kind: kind ?? this.kind,
    misrecognitions: misrecognitions ?? this.misrecognitions,
    note: note ?? this.note,
    userEdited: userEdited ?? this.userEdited,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'ja': ja,
    if (reading.isNotEmpty) 'reading': reading,
    if (kind.isNotEmpty) 'kind': kind,
    if (misrecognitions.isNotEmpty) 'misrecognitions': misrecognitions,
    if (note.isNotEmpty) 'note': note,
    if (userEdited) 'userEdited': true,
  };
}

/// 一部作品的专名表。
class SubtitleGlossary {
  const SubtitleGlossary({
    required this.entries,
    this.sourceFingerprint = '',
    this.generatedAt,
    this.userEditedAt,
  });

  factory SubtitleGlossary.fromJson(Map<String, Object?> json) =>
      SubtitleGlossary(
        entries: <SubtitleGlossaryEntry>[
          for (final Object? e
              in (json['entries'] as List<Object?>? ?? const <Object?>[]))
            if (e is Map)
              SubtitleGlossaryEntry.fromJson(e.cast<String, Object?>()),
        ].where((SubtitleGlossaryEntry e) => e.ja.isNotEmpty).toList(),
        sourceFingerprint: json['sourceFingerprint'] as String? ?? '',
        generatedAt: json['generatedAt'] as int?,
        userEditedAt: json['userEditedAt'] as int?,
      );

  factory SubtitleGlossary.decode(String text) =>
      SubtitleGlossary.fromJson(jsonDecode(text) as Map<String, Object?>);

  static const SubtitleGlossary empty = SubtitleGlossary(
    entries: <SubtitleGlossaryEntry>[],
  );

  final List<SubtitleGlossaryEntry> entries;

  /// 生成时所用资料（刮削身份 + 角色表 + 百科页）的指纹；资料变了才需要重新生成。
  final String sourceFingerprint;

  /// 最近一次 AI 生成的时刻（毫秒）；null = 从未生成（纯手填）。
  final int? generatedAt;

  /// 用户最近一次编辑的时刻（毫秒）；null = 没编辑过。
  final int? userEditedAt;

  bool get isEmpty => entries.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'entries': <Map<String, Object?>>[
      for (final SubtitleGlossaryEntry e in entries) e.toJson(),
    ],
    if (sourceFingerprint.isNotEmpty) 'sourceFingerprint': sourceFingerprint,
    if (generatedAt != null) 'generatedAt': generatedAt,
    if (userEditedAt != null) 'userEditedAt': userEditedAt,
  };

  String encode() => const JsonEncoder.withIndent(' ').convert(toJson());
}

/// 刮削得到的一个角色（声优可空）。
class SubtitleWorkCharacter {
  const SubtitleWorkCharacter({
    required this.name,
    this.originalName,
    this.voiceActor,
  });

  /// 刮削源的显示名（AniDB / MAL 多为罗马音）。
  final String name;

  /// 日文原名（MAL `name_kanji`）；没有就 null。
  final String? originalName;
  final String? voiceActor;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    if (originalName != null) 'originalName': originalName,
    if (voiceActor != null) 'voiceActor': voiceActor,
  };
}

/// 生成专名表与校对时用到的作品身份。
///
/// 刮削数据是权威来源（免查）；没有刮削数据时只有 [title]（文件夹 / 用户输入），
/// 这时 S0 退回「标题 + ASR 抽样确认作品身份」，UI 提示建议先刮削。
class SubtitleWorkContext {
  const SubtitleWorkContext({
    required this.workKey,
    required this.title,
    this.originalTitle,
    this.kanjiTitle,
    this.characters = const <SubtitleWorkCharacter>[],
  });

  /// 专名表的存储键：`collection:<id>` / `work:<metadata work id>` /
  /// `folder:<sha1(目录)>` / `title:<sha1(标题)>`。
  final String workKey;

  /// 显示用标题（提示词里的作品名）。
  final String title;

  /// 刮削的日文原名（`video_metadata_works.originalTitle`）。
  final String? originalTitle;

  /// AniDB 汉字标题（`anidb_file_identities.kanjiTitle`）。
  final String? kanjiTitle;
  final List<SubtitleWorkCharacter> characters;

  /// 有没有可当权威的刮削数据。
  bool get hasScrapedData =>
      (originalTitle?.isNotEmpty ?? false) ||
      (kanjiTitle?.isNotEmpty ?? false) ||
      characters.isNotEmpty;

  /// 提示词里优先用的作品名：日文原名 → 汉字标题 → 显示标题。
  String get japaneseTitle => (originalTitle?.isNotEmpty ?? false)
      ? originalTitle!
      : (kanjiTitle?.isNotEmpty ?? false)
      ? kanjiTitle!
      : title;
}

/// 专名表存储。
abstract interface class SubtitleGlossaryStore {
  Future<SubtitleGlossary?> load(String workKey);

  Future<void> save(String workKey, SubtitleGlossary glossary);
}
