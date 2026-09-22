// 蓝光盘播放列表（`BDMV/PLAYLIST/*.mpls`）的字节层解析。
//
// 为什么要自己解：一张 BD 上的「正片」不是某个 `.m2ts` 文件，而是一条 MPLS 播放列
// 表——它按顺序引用若干 `STREAM/*.m2ts` 片段、给出每段的 IN/OUT 时间、章节点，以及
// 音轨/字幕轨的语言表。把 `STREAM/` 下的 m2ts 当独立视频逐个导入，拿到的是被切碎的
// 片段（正片常被切成 2~20 段）外加一堆菜单/预告/警告片，顺序和时长全错。
//
// 也不能指望播放器代劳：随包 libmpv 只有 Windows 版编进了 libbluray（meson 配置行
// `-Dlibbluray=enabled` 原样留在 DLL 里），macOS / iOS / Android 三个 vendored 包由
// 另外两个 fork 仓各自构建，上游默认不编 libbluray——靠 `bluray://` 会做成「只有
// Windows 能看」。MPLS 是定长大端结构，纯 Dart 解析在五端行为完全一致，还顺带把分
// 辨率、帧率、编码、音轨与字幕语言一次拿全：这些信息用 ffprobe 反而要逐段探测，而
// BD 的 m2ts 实测 18~75 秒一条（BUG-1867）。
//
// 解析失败一律返回 null，不抛：输入是用户随手拖进来的目录，半张盘、`BACKUP/` 里的
// 截断文件、非 BD 的同名文件都是常态，不是异常。
//
// 结构参照 Blu-ray Disc Read-Only Format part 3 的公开描述，逐字段与 libbluray 的
// `bdnav/mpls_parse.c` 交叉核对过。

import 'dart:typed_data';

/// MPLS 时间戳的时钟频率：45kHz（90kHz PTS 的一半）。
const int kBlurayTimeScale = 45000;

/// 把 45kHz ticks 换成 [Duration]，不丢精度到毫秒以下。
Duration blurayTicksToDuration(int ticks) =>
    Duration(microseconds: ticks * 1000000 ~/ kBlurayTimeScale);

/// 一条 MPLS 里单个 PlayItem 引用的片段。
class BlurayClipRef {
  const BlurayClipRef({
    required this.clipId,
    required this.inTimeTicks,
    required this.outTimeTicks,
  });

  /// `CLIPINF`/`STREAM` 下的五位片段号，如 `00001`。
  final String clipId;

  /// 该段在**片段自己的**时间轴上的起止（45kHz ticks）。
  ///
  /// 注意这不是「从 0 开始」：m2ts 的首个 PTS 通常不为零，真正的零点要去同名 CLPI
  /// 的 `presentation_start_time` 里取（见 `bluray_clip_info.dart`）。
  final int inTimeTicks;
  final int outTimeTicks;

  int get durationTicks => outTimeTicks - inTimeTicks;

  /// 该段在 `STREAM/` 下的文件名。
  String get streamFileName => '$clipId.m2ts';

  /// 该段在 `CLIPINF/` 下的文件名。
  String get clipInfoFileName => '$clipId.clpi';
}

/// 章节点（PlayListMark 里 `mark_type == 0x01` 的 entry mark）。
class BlurayChapter {
  const BlurayChapter({required this.startTicks, required this.playItemIndex});

  /// 相对**播放列表**时间轴起点的位置（前面 PlayItem 的时长已累加进去）。
  final int startTicks;

  /// 这个章节点落在第几个 PlayItem 上。
  final int playItemIndex;

  Duration get start => blurayTicksToDuration(startTicks);
}

/// STN table 里一条流的种类。只区分消费端真正用得上的三类。
enum BlurayStreamKind { video, audio, subtitle }

/// STN table 里的一条流。
class BlurayStream {
  const BlurayStream({
    required this.kind,
    required this.codingType,
    required this.pid,
    this.languageCode,
    this.videoFormat = 0,
    this.frameRate = 0,
  });

  final BlurayStreamKind kind;

  /// 原始 `stream_coding_type` 字节；未识别的值也原样保留，不归一成「未知」。
  final int codingType;

  /// 该流在 m2ts 传输流里的 PID。
  final int pid;

  /// ISO 639-2 三字母码（小写）；视频轨为 null。
  final String? languageCode;

  /// 仅视频轨有意义：`video_format` / `frame_rate` 两个 nibble 的原始值。
  final int videoFormat;
  final int frameRate;

  /// 人读编码名；未识别时给 `0x` 十六进制原值，不猜。
  String get codecName => switch (codingType) {
    0x01 => 'MPEG-1 Video',
    0x02 => 'MPEG-2 Video',
    0x1B => 'H.264',
    0x20 => 'H.264 MVC',
    0x24 => 'HEVC',
    0xEA => 'VC-1',
    0x03 => 'MPEG-1 Audio',
    0x04 => 'MPEG-2 Audio',
    0x80 => 'LPCM',
    0x81 => 'AC-3',
    0x82 => 'DTS',
    0x83 => 'TrueHD',
    0x84 => 'E-AC-3',
    0x85 => 'DTS-HD',
    0x86 => 'DTS-HD MA',
    0xA1 => 'E-AC-3',
    0xA2 => 'DTS-HD',
    0x90 => 'PGS',
    0x91 => 'IGS',
    0x92 => 'Text',
    _ => '0x${codingType.toRadixString(16).padLeft(2, '0')}',
  };

  /// 视频高度（行数）；未识别返回 null。
  ///
  /// `video_format` 只编码扫描格式，宽度推不出真值（同为 1080 的 16:9 与 4:3 编码
  /// 一致），所以这里只给高度与是否隔行，不编造宽度。
  int? get videoHeight => switch (videoFormat) {
    1 || 3 => 480,
    2 || 7 => 576,
    4 || 6 => 1080,
    5 => 720,
    8 => 2160,
    _ => null,
  };

  bool get isInterlaced =>
      videoFormat == 1 || videoFormat == 2 || videoFormat == 4;

  /// 帧率；未识别返回 null。
  double? get framesPerSecond => switch (frameRate) {
    1 => 24000 / 1001,
    2 => 24,
    3 => 25,
    4 => 30000 / 1001,
    6 => 50,
    7 => 60000 / 1001,
    _ => null,
  };
}

/// 一条解析完成的 MPLS。
class BlurayPlaylist {
  const BlurayPlaylist({
    required this.id,
    required this.clips,
    required this.chapters,
    required this.streams,
    required this.playbackType,
  });

  /// 文件名去扩展名，如 `00001`。
  final String id;

  final List<BlurayClipRef> clips;
  final List<BlurayChapter> chapters;
  final List<BlurayStream> streams;

  /// AppInfoPlayList 的 `playback_type`：1=顺序播放，2=随机，3=洗牌。
  final int playbackType;

  String get fileName => '$id.mpls';

  /// 所有 PlayItem 时长之和。
  int get durationTicks {
    int total = 0;
    for (final BlurayClipRef clip in clips) {
      total += clip.durationTicks;
    }
    return total;
  }

  Duration get duration => blurayTicksToDuration(durationTicks);

  List<BlurayStream> get videoStreams => streams
      .where((BlurayStream s) => s.kind == BlurayStreamKind.video)
      .toList(growable: false);

  List<BlurayStream> get audioStreams => streams
      .where((BlurayStream s) => s.kind == BlurayStreamKind.audio)
      .toList(growable: false);

  List<BlurayStream> get subtitleStreams => streams
      .where((BlurayStream s) => s.kind == BlurayStreamKind.subtitle)
      .toList(growable: false);

  /// 片段号序列——用来判「两条播放列表是不是同一份内容」。
  List<String> get clipIds =>
      clips.map((BlurayClipRef c) => c.clipId).toList(growable: false);
}

/// 解析一份 MPLS 的字节内容。[id] 是文件名去扩展名（`00001.mpls` → `00001`）。
///
/// 任何越界、幻数不符、字段自相矛盾都返回 null。
BlurayPlaylist? parseBlurayPlaylist(Uint8List bytes, {required String id}) {
  if (bytes.length < 0x2E) return null;
  if (String.fromCharCodes(bytes, 0, 4) != 'MPLS') return null;

  final ByteData view = ByteData.sublistView(bytes);
  final int playListStart = view.getUint32(8);
  final int playListMarkStart = view.getUint32(12);

  // AppInfoPlayList 固定在 0x28：uint32 length、1 字节保留位、1 字节 playback_type。
  final int playbackType = bytes[0x2D];

  final List<BlurayClipRef> clips = <BlurayClipRef>[];
  final List<BlurayStream> streams = <BlurayStream>[];
  if (!_parsePlayList(view, bytes, playListStart, clips, streams)) return null;
  if (clips.isEmpty) return null;

  final List<BlurayChapter> chapters = <BlurayChapter>[];
  _parsePlayListMarks(view, playListMarkStart, clips, chapters);

  return BlurayPlaylist(
    id: id,
    clips: List<BlurayClipRef>.unmodifiable(clips),
    chapters: List<BlurayChapter>.unmodifiable(chapters),
    streams: List<BlurayStream>.unmodifiable(streams),
    playbackType: playbackType,
  );
}

/// PlayList 段：`uint32 length | uint16 reserved | uint16 播放项数 | uint16 子路径数`
/// 之后是依次排列的 PlayItem。
bool _parsePlayList(
  ByteData view,
  Uint8List bytes,
  int start,
  List<BlurayClipRef> clips,
  List<BlurayStream> streams,
) {
  if (start <= 0 || start + 10 > bytes.length) return false;
  final int length = view.getUint32(start);
  final int end = start + 4 + length;
  if (length <= 0 || end > bytes.length) return false;

  final int playItemCount = view.getUint16(start + 6);
  if (playItemCount == 0) return false;

  int offset = start + 10;
  for (int i = 0; i < playItemCount; i++) {
    if (offset + 2 > end) return false;
    final int itemLength = view.getUint16(offset);
    final int itemEnd = offset + 2 + itemLength;
    // PlayItem 的固定头就要 32 字节，短于此的必然是坏数据而不是紧凑编码。
    if (itemLength < 32 || itemEnd > end) return false;

    final BlurayClipRef? clip = _parsePlayItem(view, bytes, offset, itemEnd);
    if (clip == null) return false;
    clips.add(clip);

    // STN table 只读第一个 PlayItem 的：同一条播放列表各段的轨道布局按规范必须一
    // 致，读后面的段只会在多角度盘上重复堆出同样的轨。
    if (i == 0) {
      _parsePlayItemStreams(view, bytes, offset, itemEnd, streams);
    }

    offset = itemEnd;
  }
  return true;
}

BlurayClipRef? _parsePlayItem(
  ByteData view,
  Uint8List bytes,
  int offset,
  int end,
) {
  // 固定头（自 length 之后起算）：
  //   5B clip_id | 4B codec_id | 2B flags | 1B stc_id | 4B IN | 4B OUT
  //   | 8B UO_mask | 1B flags | 1B still_mode | 2B still_time  = 32B
  final int base = offset + 2;
  if (base + 32 > end) return null;
  final String clipId = String.fromCharCodes(bytes, base, base + 5);
  // `clip_codec_identifier` 是 `M2TS`（也见过 `FMTS`）。上游 libbluray 对不认识的值
  // 只告警不中止，这里照办：这个字段不参与我们的任何判断，拿它当幻数会让一条本可
  // 正常播放的播放列表整条作废。真正的结构性把关在 length 与 IN/OUT 的自洽上。
  final int inTime = view.getUint32(base + 12);
  final int outTime = view.getUint32(base + 16);
  if (outTime <= inTime) return null;
  return BlurayClipRef(
    clipId: clipId,
    inTimeTicks: inTime,
    outTimeTicks: outTime,
  );
}

/// 跳过可选的多角度块，定位并解析该 PlayItem 的 STN table。
void _parsePlayItemStreams(
  ByteData view,
  Uint8List bytes,
  int offset,
  int end,
  List<BlurayStream> out,
) {
  final int base = offset + 2;
  int p = base + 32;
  // 16 位标志位：11 位保留 | 1 位 is_multi_angle | 4 位 connection_condition。
  final int flags = view.getUint16(base + 9);
  final bool isMultiAngle = ((flags >> 4) & 0x1) == 1;
  if (isMultiAngle) {
    if (p + 2 > end) return;
    final int angles = bytes[p];
    p += 2;
    // 第一个角度就是 PlayItem 自己的片段，只跳过其余角度的 10 字节引用。
    p += (angles > 1 ? angles - 1 : 0) * 10;
  }
  _parseStnTable(view, bytes, p, end, out);
}

void _parseStnTable(
  ByteData view,
  Uint8List bytes,
  int offset,
  int end,
  List<BlurayStream> out,
) {
  if (offset + 16 > end) return;
  final int length = view.getUint16(offset);
  final int tableEnd = offset + 2 + length;
  if (length < 14 || tableEnd > end) return;

  // 计数字节依次是：video(+4) audio(+5) PG/textST(+6) IG(+7) 次要音频(+8)
  // 次要视频(+9) PiP PG(+10) Dolby Vision(+11)，之后 4 字节保留，条目从 +16 起。
  final int videoCount = bytes[offset + 4];
  final int audioCount = bytes[offset + 5];
  final int pgCount = bytes[offset + 6];

  int p = offset + 16;
  p = _parseStreamEntries(
    view,
    bytes,
    p,
    tableEnd,
    videoCount,
    BlurayStreamKind.video,
    out,
  );
  p = _parseStreamEntries(
    view,
    bytes,
    p,
    tableEnd,
    audioCount,
    BlurayStreamKind.audio,
    out,
  );
  // PG 与 textST 共用一个计数字段。IG（菜单图形）及其后的次要流不读：它们对「选哪条
  // 音轨/字幕」没有意义，而且次要流后面还跟着变长的引用表，跳错一字节会污染全表。
  //
  // ⚠️ 上游 libbluray 这一段的循环条数是 `PG/textST + PiP PG`（两类条目连着排），我
  // 们读完 PG 就收手，所以不受影响；但将来要往后读 IG 或次要流，必须先把这里改成
  // 两者之和，否则从 IG 开始整表偏移。
  _parseStreamEntries(
    view,
    bytes,
    p,
    tableEnd,
    pgCount,
    BlurayStreamKind.subtitle,
    out,
  );
}

/// 读 [count] 条「StreamEntry + StreamAttributes」对，返回读完后的偏移。
///
/// 中途越界就停在当前位置并返回——调用方据此不会再往后读，已经读出来的流保留。
int _parseStreamEntries(
  ByteData view,
  Uint8List bytes,
  int offset,
  int end,
  int count,
  BlurayStreamKind kind,
  List<BlurayStream> out,
) {
  int p = offset;
  for (int i = 0; i < count; i++) {
    if (p + 2 > end) return p;
    final int entryLength = bytes[p];
    final int entryEnd = p + 1 + entryLength;
    if (entryLength < 1 || entryEnd + 2 > end) return p;

    final int entryType = bytes[p + 1];
    int pid = 0;
    switch (entryType) {
      case 1: // 本 PlayItem 的片段
        if (p + 4 <= entryEnd) pid = view.getUint16(p + 2);
      case 2: // 子路径里的子片段
        if (p + 6 <= entryEnd) pid = view.getUint16(p + 4);
      case 3:
      case 4:
        if (p + 5 <= entryEnd) pid = view.getUint16(p + 3);
    }

    p = entryEnd;
    final int attrLength = bytes[p];
    final int attrEnd = p + 1 + attrLength;
    if (attrLength < 1 || attrEnd > end) return p;

    final int coding = bytes[p + 1];
    String? language;
    int videoFormat = 0;
    int frameRate = 0;
    switch (kind) {
      case BlurayStreamKind.video:
        if (p + 3 <= attrEnd) {
          videoFormat = (bytes[p + 2] >> 4) & 0xF;
          frameRate = bytes[p + 2] & 0xF;
        }
      case BlurayStreamKind.audio:
        // 1 字节 audio_format/sample_rate，然后才是语言码。
        if (p + 6 <= attrEnd) language = _languageAt(bytes, p + 3);
      case BlurayStreamKind.subtitle:
        // PGS/IGS 的语言码紧跟编码类型；textST 前面多一个 character_code 字节。
        final int langOffset = coding == 0x92 ? p + 3 : p + 2;
        if (langOffset + 3 <= attrEnd)
          language = _languageAt(bytes, langOffset);
    }

    out.add(
      BlurayStream(
        kind: kind,
        codingType: coding,
        pid: pid,
        languageCode: language,
        videoFormat: videoFormat,
        frameRate: frameRate,
      ),
    );
    p = attrEnd;
  }
  return p;
}

/// 读 3 字节 ISO 639-2 码；出现非 ASCII 可见字符就判定这不是语言码，返回 null。
String? _languageAt(Uint8List bytes, int offset) {
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < 3; i++) {
    final int c = bytes[offset + i];
    if (c < 0x20 || c > 0x7E) return null;
    buffer.writeCharCode(c);
  }
  final String code = buffer.toString().trim().toLowerCase();
  return code.isEmpty ? null : code;
}

/// PlayListMark 段：`uint32 length | uint16 标记数`，之后每条标记 14 字节。
void _parsePlayListMarks(
  ByteData view,
  int start,
  List<BlurayClipRef> clips,
  List<BlurayChapter> out,
) {
  if (start <= 0 || start + 6 > view.lengthInBytes) return;
  final int length = view.getUint32(start);
  final int end = start + 4 + length;
  if (length < 2 || end > view.lengthInBytes) return;
  final int markCount = view.getUint16(start + 4);

  // PlayItem i 在播放列表时间轴上的起点。
  final List<int> itemStart = <int>[];
  int acc = 0;
  for (final BlurayClipRef clip in clips) {
    itemStart.add(acc);
    acc += clip.durationTicks;
  }

  int p = start + 6;
  for (int i = 0; i < markCount; i++) {
    if (p + 14 > end) return;
    final int markType = view.getUint8(p + 1);
    final int itemIndex = view.getUint16(p + 2);
    final int timestamp = view.getUint32(p + 4);
    p += 14;
    if (markType != 0x01) continue; // 0x02 是 link point，不是章节
    if (itemIndex >= clips.length) continue;
    final int relative = timestamp - clips[itemIndex].inTimeTicks;
    // 标记落在本段 IN 之前或 OUT 之后的盘是存在的（多为制作残留），直接丢弃：宁可
    // 少一个章节，也不要一个会把进度条拖到别处的坐标。
    if (relative < 0 || relative > clips[itemIndex].durationTicks) continue;
    out.add(
      BlurayChapter(
        startTicks: itemStart[itemIndex] + relative,
        playItemIndex: itemIndex,
      ),
    );
  }
  out.sort(
    (BlurayChapter a, BlurayChapter b) => a.startTicks.compareTo(b.startTicks),
  );
}
