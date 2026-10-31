import 'dart:convert';
import 'dart:typed_data';

/// 统一歌词时间轴（设计 §5.2），与 native/fushi_music/src/lyrics/model.rs 一一对应。
/// 线格式见 `src/lyrics/wire.rs`；本文件的 [decodeLyricTimeline] / [encodeLyricTimeline]
/// 逐字段对应（双向：用户编辑后 Dart 写回 `timeline_cache`）。
const int kLyricTimelineWireVersion = 1;

/// 音节擦色语义（ASS `\k` / `\kf` / `\ko`）。
enum LyricFill { instant, sweep, outline }

/// 行角色：主唱 / `x-bg` 和声（紧跟在所属主行后面）。
enum LyricRole { main, background }

/// 时间粒度。[unsynced] = 没有时间，只做静态显示。
enum LyricTimingQuality {
  unsynced('unsynced'),
  line('line'),
  word('word'),
  syllable('syllable'),
  syllablePitch('syllable_pitch');

  const LyricTimingQuality(this.dbName);

  /// `music_lyrics.timing_quality` 的取值。
  final String dbName;

  /// 有逐字（词 / 音节）时间。
  bool get isPerSyllable => index >= LyricTimingQuality.word.index;
}

enum LyricAgentKind { person, group, other }

/// 对唱声部。
class LyricAgent {
  const LyricAgent({
    required this.id,
    this.name = '',
    this.kind = LyricAgentKind.person,
  });

  final String id;
  final String name;
  final LyricAgentKind kind;

  @override
  bool operator ==(Object other) =>
      other is LyricAgent &&
      other.id == id &&
      other.name == name &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, name, kind);
}

class LyricSyllable {
  const LyricSyllable({
    required this.text,
    required this.startMs,
    required this.endMs,
    this.fill = LyricFill.sweep,
    this.ruby,
  });

  final String text;
  final int startMs;
  final int endMs;
  final LyricFill fill;

  /// 源文件自带的注音（解析器读出；不自动生成）。
  final String? ruby;

  int get durationMs => endMs - startMs;

  LyricSyllable copyWith({
    String? text,
    int? startMs,
    int? endMs,
    String? ruby,
    bool clearRuby = false,
  }) => LyricSyllable(
    text: text ?? this.text,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    fill: fill,
    ruby: clearRuby ? null : (ruby ?? this.ruby),
  );

  @override
  bool operator ==(Object other) =>
      other is LyricSyllable &&
      other.text == text &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.fill == fill &&
      other.ruby == ruby;

  @override
  int get hashCode => Object.hash(text, startMs, endMs, fill, ruby);
}

/// 一行的一条翻译。
class LyricTranslation {
  const LyricTranslation(this.lang, this.text);

  /// 语言标签；未知为 `und`。
  final String lang;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is LyricTranslation && other.lang == lang && other.text == text;

  @override
  int get hashCode => Object.hash(lang, text);
}

class LyricLine {
  const LyricLine({
    required this.startMs,
    required this.endMs,
    required this.syllables,
    this.agent,
    this.role = LyricRole.main,
    this.translations = const <LyricTranslation>[],
    this.romanization,
    this.style,
  });

  final int startMs;
  final int endMs;

  /// [LyricTimeline.agents] 下标。
  final int? agent;
  final LyricRole role;
  final List<LyricSyllable> syllables;
  final List<LyricTranslation> translations;
  final String? romanization;

  /// 来自 ASS 时的样式名。
  final String? style;

  /// 整行文本（音节拼接）。
  String get text => syllables.map((LyricSyllable s) => s.text).join();

  bool get isBackground => role == LyricRole.background;

  /// 第一条翻译（没有为 null）。
  String? get primaryTranslation =>
      translations.isEmpty ? null : translations.first.text;

  LyricLine copyWith({
    int? startMs,
    int? endMs,
    List<LyricSyllable>? syllables,
    List<LyricTranslation>? translations,
    String? romanization,
    bool clearRomanization = false,
  }) => LyricLine(
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    syllables: syllables ?? this.syllables,
    agent: agent,
    role: role,
    translations: translations ?? this.translations,
    romanization: clearRomanization
        ? null
        : (romanization ?? this.romanization),
    style: style,
  );

  @override
  bool operator ==(Object other) =>
      other is LyricLine &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.agent == agent &&
      other.role == role &&
      _listEq(other.syllables, syllables) &&
      _listEq(other.translations, translations) &&
      other.romanization == romanization &&
      other.style == style;

  @override
  int get hashCode => Object.hash(
    startMs,
    endMs,
    agent,
    role,
    Object.hashAll(syllables),
    Object.hashAll(translations),
    romanization,
    style,
  );
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class LyricTimeline {
  const LyricTimeline({
    required this.format,
    required this.lines,
    this.source = '',
    this.offsetMs = 0,
    this.language,
    this.isUserEdited = false,
    this.hasEffects = false,
    this.title,
    this.artist,
    this.agents = const <LyricAgent>[],
    this.timingQuality = LyricTimingQuality.line,
  });

  /// 来源（`sidecar` / `embedded` / `provider:lrclib` / `user` …）。
  final String source;

  /// 原格式（`lrc` / `ttml` / `ass` …）。
  final String format;

  /// 整首偏移（正 = 歌词提前）。
  final int offsetMs;
  final String? language;
  final bool isUserEdited;

  /// ASS 特效 / templater 产物：推荐原样渲染（§6.3，P3）。
  final bool hasEffects;
  final String? title;
  final String? artist;
  final List<LyricAgent> agents;
  final List<LyricLine> lines;
  final LyricTimingQuality timingQuality;

  bool get isSynced => timingQuality != LyricTimingQuality.unsynced;

  LyricTimeline copyWith({
    String? source,
    int? offsetMs,
    bool? isUserEdited,
    List<LyricLine>? lines,
  }) => LyricTimeline(
    format: format,
    lines: lines ?? this.lines,
    source: source ?? this.source,
    offsetMs: offsetMs ?? this.offsetMs,
    language: language,
    isUserEdited: isUserEdited ?? this.isUserEdited,
    hasEffects: hasEffects,
    title: title,
    artist: artist,
    agents: agents,
    timingQuality: timingQuality,
  );

  /// 声部在对唱布局里的位置：第一个「个人」声部靠左、第二个靠右，组合 / 合唱居中。
  LyricAgentSide sideOf(LyricLine line) {
    final int? a = line.agent;
    if (a == null || a < 0 || a >= agents.length) return LyricAgentSide.start;
    final LyricAgent agent = agents[a];
    if (agent.kind == LyricAgentKind.group) return LyricAgentSide.center;
    final List<int> persons = <int>[
      for (int i = 0; i < agents.length; i++)
        if (agents[i].kind != LyricAgentKind.group) i,
    ];
    final int rank = persons.indexOf(a);
    return rank <= 0 ? LyricAgentSide.start : LyricAgentSide.end;
  }

  @override
  bool operator ==(Object other) =>
      other is LyricTimeline &&
      other.source == source &&
      other.format == format &&
      other.offsetMs == offsetMs &&
      other.language == language &&
      other.isUserEdited == isUserEdited &&
      other.hasEffects == hasEffects &&
      other.title == title &&
      other.artist == artist &&
      _listEq(other.agents, agents) &&
      _listEq(other.lines, lines) &&
      other.timingQuality == timingQuality;

  @override
  int get hashCode => Object.hash(
    source,
    format,
    offsetMs,
    language,
    isUserEdited,
    hasEffects,
    title,
    artist,
    Object.hashAll(agents),
    Object.hashAll(lines),
    timingQuality,
  );
}

/// 对唱布局里的一侧（`v1` 左、`v2` 右、合唱居中）。
enum LyricAgentSide { start, center, end }

const int _kNull = 0xFFFFFFFF;

class _R {
  _R(this.b) : v = ByteData.sublistView(b);
  final Uint8List b;
  final ByteData v;
  int p = 0;

  int u8() => b[p++];
  int u32() {
    final int x = v.getUint32(p, Endian.little);
    p += 4;
    return x;
  }

  int i32() {
    final int x = v.getInt32(p, Endian.little);
    p += 4;
    return x;
  }

  int i64() {
    final int x = v.getInt64(p, Endian.little);
    p += 8;
    return x;
  }

  String str() {
    final int n = u32();
    final String s = utf8.decode(Uint8List.sublistView(b, p, p + n));
    p += n;
    return s;
  }

  String? optStr() {
    final int n = u32();
    if (n == _kNull) return null;
    final String s = utf8.decode(Uint8List.sublistView(b, p, p + n));
    p += n;
    return s;
  }
}

/// 线格式解码。格式不对抛 [FormatException]。
LyricTimeline decodeLyricTimeline(Uint8List bytes) {
  try {
    final _R r = _R(bytes);
    if (bytes.length < 8 ||
        bytes[0] != 0x46 || // F
        bytes[1] != 0x4D || // M
        bytes[2] != 0x4C || // L
        bytes[3] != 0x54) {
      throw const FormatException('not a lyric timeline (bad magic)');
    }
    r.p = 4;
    final int version = r.u32();
    if (version != kLyricTimelineWireVersion) {
      throw FormatException('lyric timeline wire version $version');
    }
    final String source = r.str();
    final String format = r.str();
    final int offsetMs = r.i64();
    final String? language = r.optStr();
    final LyricTimingQuality quality =
        LyricTimingQuality.values[r.u8().clamp(0, 4)];
    final int flags = r.u8();
    final String? title = r.optStr();
    final String? artist = r.optStr();
    final int agentCount = r.u32();
    final List<LyricAgent> agents = <LyricAgent>[
      for (int i = 0; i < agentCount; i++)
        LyricAgent(
          id: r.str(),
          name: r.str(),
          kind: LyricAgentKind.values[r.u8().clamp(0, 2)],
        ),
    ];
    final int lineCount = r.u32();
    final List<LyricLine> lines = <LyricLine>[];
    for (int i = 0; i < lineCount; i++) {
      final int start = r.i64();
      final int end = r.i64();
      final int agent = r.i32();
      final LyricRole role = r.u8() == 1
          ? LyricRole.background
          : LyricRole.main;
      final int sc = r.u32();
      final List<LyricSyllable> syl = <LyricSyllable>[
        for (int k = 0; k < sc; k++)
          LyricSyllable(
            text: r.str(),
            startMs: r.i64(),
            endMs: r.i64(),
            fill: LyricFill.values[r.u8().clamp(0, 2)],
            ruby: r.optStr(),
          ),
      ];
      final int tc = r.u32();
      final List<LyricTranslation> tr = <LyricTranslation>[
        for (int k = 0; k < tc; k++) LyricTranslation(r.str(), r.str()),
      ];
      lines.add(
        LyricLine(
          startMs: start,
          endMs: end,
          agent: agent >= 0 && agent < agents.length ? agent : null,
          role: role,
          syllables: syl,
          translations: tr,
          romanization: r.optStr(),
          style: r.optStr(),
        ),
      );
    }
    if (r.p != bytes.length) {
      throw const FormatException('trailing bytes after lyric timeline');
    }
    return LyricTimeline(
      source: source,
      format: format,
      offsetMs: offsetMs,
      language: language,
      timingQuality: quality,
      isUserEdited: flags & 1 != 0,
      hasEffects: flags & 2 != 0,
      title: title,
      artist: artist,
      agents: agents,
      lines: lines,
    );
  } on RangeError {
    throw const FormatException('truncated lyric timeline');
  }
}

/// 线格式编码（与 Rust `wire::encode` 字节一致）。
Uint8List encodeLyricTimeline(LyricTimeline t) {
  final BytesBuilder b = BytesBuilder(copy: false);
  final ByteData scratch = ByteData(8);
  void u8(int v) => b.addByte(v);
  void u32(int v) {
    scratch.setUint32(0, v, Endian.little);
    b.add(scratch.buffer.asUint8List(0, 4).toList());
  }

  void i32(int v) {
    scratch.setInt32(0, v, Endian.little);
    b.add(scratch.buffer.asUint8List(0, 4).toList());
  }

  void i64(int v) {
    scratch.setInt64(0, v, Endian.little);
    b.add(scratch.buffer.asUint8List(0, 8).toList());
  }

  void str(String s) {
    final Uint8List e = utf8.encode(s);
    u32(e.length);
    b.add(e);
  }

  void optStr(String? s) => s == null ? u32(_kNull) : str(s);

  b.add(const <int>[0x46, 0x4D, 0x4C, 0x54]);
  u32(kLyricTimelineWireVersion);
  str(t.source);
  str(t.format);
  i64(t.offsetMs);
  optStr(t.language);
  u8(t.timingQuality.index);
  u8((t.isUserEdited ? 1 : 0) | (t.hasEffects ? 2 : 0));
  optStr(t.title);
  optStr(t.artist);
  u32(t.agents.length);
  for (final LyricAgent a in t.agents) {
    str(a.id);
    str(a.name);
    u8(a.kind.index);
  }
  u32(t.lines.length);
  for (final LyricLine l in t.lines) {
    i64(l.startMs);
    i64(l.endMs);
    i32(l.agent ?? -1);
    u8(l.role == LyricRole.background ? 1 : 0);
    u32(l.syllables.length);
    for (final LyricSyllable s in l.syllables) {
      str(s.text);
      i64(s.startMs);
      i64(s.endMs);
      u8(s.fill.index);
      optStr(s.ruby);
    }
    u32(l.translations.length);
    for (final LyricTranslation tr in l.translations) {
      str(tr.lang);
      str(tr.text);
    }
    optStr(l.romanization);
    optStr(l.style);
  }
  return b.takeBytes();
}
