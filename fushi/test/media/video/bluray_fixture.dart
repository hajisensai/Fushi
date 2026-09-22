// 字节级合成 MPLS / CLPI，给蓝光解析器的测试当输入。
//
// 手工拼字节而不是塞一份真盘文件进仓：MPLS 里没有任何可公开分发的样本，而且合成的
// 好处是每个字段都能单独拨动——「IN 不从零起跳」「多角度」「章节落在第二段上」这些
// 情形在随便一张真盘上不一定同时出现。

import 'dart:typed_data';

/// 一个 PlayItem 的描述。
class FixturePlayItem {
  const FixturePlayItem({
    required this.clipId,
    required this.inTimeTicks,
    required this.outTimeTicks,
    this.angleCount = 1,
    this.codecId = 'M2TS',
  });

  final String clipId;
  final int inTimeTicks;
  final int outTimeTicks;

  /// `clip_codec_identifier`。真盘上除 `M2TS` 外还见过 `FMTS`。
  final String codecId;

  /// >1 时写出多角度块，用来验证解析器跳过它之后仍能找到 STN table。
  final int angleCount;
}

/// STN table 里的一条流。
class FixtureStream {
  const FixtureStream.video({
    required this.codingType,
    required this.videoFormat,
    required this.frameRate,
    this.pid = 0x1011,
  }) : language = null,
       kind = 0;

  const FixtureStream.audio({
    required this.codingType,
    required this.language,
    this.pid = 0x1100,
  }) : videoFormat = 0,
       frameRate = 0,
       kind = 1;

  const FixtureStream.subtitle({
    required this.codingType,
    required this.language,
    this.pid = 0x1200,
  }) : videoFormat = 0,
       frameRate = 0,
       kind = 2;

  final int kind; // 0=video 1=audio 2=pg/textst
  final int codingType;
  final int pid;
  final String? language;
  final int videoFormat;
  final int frameRate;
}

/// 一个章节标记。
class FixtureMark {
  const FixtureMark({
    required this.playItemIndex,
    required this.timestampTicks,
    this.markType = 0x01,
  });

  final int playItemIndex;
  final int timestampTicks;
  final int markType;
}

/// 拼一份 MPLS。
Uint8List buildMplsFixture({
  required List<FixturePlayItem> playItems,
  List<FixtureStream> streams = const <FixtureStream>[
    FixtureStream.video(codingType: 0x1B, videoFormat: 6, frameRate: 1),
  ],
  List<FixtureMark> marks = const <FixtureMark>[],
  int playbackType = 1,
  String magic = 'MPLS',
}) {
  final BytesBuilder appInfo = BytesBuilder();
  appInfo.addByte(0); // reserved
  appInfo.addByte(playbackType);
  appInfo.add(_u16(1)); // playback_count
  appInfo.add(Uint8List(8)); // UO_mask_table
  appInfo.add(_u16(0)); // flags
  final Uint8List appInfoBlock = _withUint32Length(appInfo.toBytes());

  final Uint8List playListBlock = _buildPlayListBlock(playItems, streams);
  final Uint8List markBlock = _buildMarkBlock(marks);

  const int headerSize = 0x28;
  final int playListStart = headerSize + appInfoBlock.length;
  final int markStart = playListStart + playListBlock.length;

  final BytesBuilder out = BytesBuilder();
  out.add(Uint8List.fromList(magic.codeUnits));
  out.add(Uint8List.fromList('0200'.codeUnits));
  out.add(_u32(playListStart));
  out.add(_u32(markStart));
  out.add(_u32(0)); // ExtensionData
  out.add(Uint8List(20)); // reserved → 到 0x28
  out.add(appInfoBlock);
  out.add(playListBlock);
  out.add(markBlock);
  return out.toBytes();
}

Uint8List _buildPlayListBlock(
  List<FixturePlayItem> playItems,
  List<FixtureStream> streams,
) {
  final BytesBuilder body = BytesBuilder();
  body.add(_u16(0)); // reserved
  body.add(_u16(playItems.length));
  body.add(_u16(0)); // number_of_SubPaths
  for (int i = 0; i < playItems.length; i++) {
    // STN table 只在第一个 PlayItem 上有意义（解析器也只读它），但真盘每段都写，
    // 这里照写，顺便验证解析器不会把后面几段的流重复堆进结果。
    body.add(_buildPlayItem(playItems[i], streams));
  }
  return _withUint32Length(body.toBytes());
}

Uint8List _buildPlayItem(FixturePlayItem item, List<FixtureStream> streams) {
  final BytesBuilder body = BytesBuilder();
  body.add(Uint8List.fromList(item.clipId.codeUnits));
  body.add(Uint8List.fromList(item.codecId.codeUnits));
  // 11 位保留 | 1 位 is_multi_angle | 4 位 connection_condition
  final int multiAngle = item.angleCount > 1 ? 1 : 0;
  body.add(_u16((multiAngle << 4) | 0x1));
  body.addByte(0); // ref_to_STC_id
  body.add(_u32(item.inTimeTicks));
  body.add(_u32(item.outTimeTicks));
  body.add(Uint8List(8)); // UO_mask_table
  body.addByte(0); // random_access_flag
  body.addByte(0); // still_mode
  body.add(_u16(0)); // still_time
  if (multiAngle == 1) {
    body.addByte(item.angleCount);
    body.addByte(0); // flags
    for (int a = 1; a < item.angleCount; a++) {
      body.add(Uint8List.fromList('9999${a % 10}'.codeUnits));
      body.add(Uint8List.fromList('M2TS'.codeUnits));
      body.addByte(0);
    }
  }
  body.add(_buildStnTable(streams));
  return _withUint16Length(body.toBytes());
}

Uint8List _buildStnTable(List<FixtureStream> streams) {
  final List<FixtureStream> video = streams
      .where((FixtureStream s) => s.kind == 0)
      .toList();
  final List<FixtureStream> audio = streams
      .where((FixtureStream s) => s.kind == 1)
      .toList();
  final List<FixtureStream> subtitle = streams
      .where((FixtureStream s) => s.kind == 2)
      .toList();

  final BytesBuilder body = BytesBuilder();
  body.add(_u16(0)); // reserved
  body.addByte(video.length);
  body.addByte(audio.length);
  body.addByte(subtitle.length);
  body.addByte(0); // IG
  body.addByte(0); // secondary audio
  body.addByte(0); // secondary video
  body.addByte(0); // PiP PG
  body.add(Uint8List(5)); // reserved
  for (final FixtureStream stream in <FixtureStream>[
    ...video,
    ...audio,
    ...subtitle,
  ]) {
    body.add(_buildStreamEntry(stream));
    body.add(_buildStreamAttributes(stream));
  }
  return _withUint16Length(body.toBytes());
}

Uint8List _buildStreamEntry(FixtureStream stream) {
  final BytesBuilder content = BytesBuilder();
  content.addByte(1); // stream_type: 本 PlayItem 的片段
  content.add(_u16(stream.pid));
  content.addByte(0); // 真盘在这里有填充，写上以验证解析器按 length 前进
  return _withUint8Length(content.toBytes());
}

Uint8List _buildStreamAttributes(FixtureStream stream) {
  final BytesBuilder content = BytesBuilder();
  content.addByte(stream.codingType);
  switch (stream.kind) {
    case 0:
      content.addByte((stream.videoFormat << 4) | stream.frameRate);
      content.add(Uint8List(2)); // 填充
    case 1:
      content.addByte(0x13); // audio_format/sample_rate
      content.add(Uint8List.fromList(stream.language!.codeUnits));
      content.addByte(0); // 填充
    default:
      if (stream.codingType == 0x92) {
        content.addByte(0); // character_code
      }
      content.add(Uint8List.fromList(stream.language!.codeUnits));
      content.addByte(0); // 填充
  }
  return _withUint8Length(content.toBytes());
}

Uint8List _buildMarkBlock(List<FixtureMark> marks) {
  final BytesBuilder body = BytesBuilder();
  body.add(_u16(marks.length));
  for (final FixtureMark mark in marks) {
    body.addByte(0); // reserved
    body.addByte(mark.markType);
    body.add(_u16(mark.playItemIndex));
    body.add(_u32(mark.timestampTicks));
    body.add(_u16(0x1011)); // entry_ES_PID
    body.add(_u32(0)); // duration
  }
  return _withUint32Length(body.toBytes());
}

/// 拼一份 CLPI，只有 SequenceInfo 是真的。
Uint8List buildClpiFixture({
  required int presentationStartTicks,
  required int presentationEndTicks,
  String magic = 'HDMV',
  int atcSequences = 1,
  int stcSequences = 1,
}) {
  final BytesBuilder sequence = BytesBuilder();
  sequence.addByte(0); // reserved
  sequence.addByte(atcSequences);
  for (int atc = 0; atc < atcSequences; atc++) {
    sequence.add(_u32(0)); // SPN_ATC_start
    sequence.addByte(stcSequences);
    sequence.addByte(0); // offset_STC_id
    for (int stc = 0; stc < stcSequences; stc++) {
      sequence.add(_u16(0x1001)); // PCR_PID
      sequence.add(_u32(0)); // SPN_STC_start
      // 只有第一个序列描述真正的零点，后面的写别的值以证明解析器不看它们。
      final bool first = atc == 0 && stc == 0;
      sequence.add(_u32(first ? presentationStartTicks : 0xFFFF));
      sequence.add(_u32(first ? presentationEndTicks : 0xFFFFFF));
    }
  }
  final Uint8List sequenceBlock = _withUint32Length(sequence.toBytes());

  const int sequenceStart = 0x28;
  final BytesBuilder out = BytesBuilder();
  out.add(Uint8List.fromList(magic.codeUnits));
  out.add(Uint8List.fromList('0200'.codeUnits));
  out.add(_u32(sequenceStart));
  out.add(_u32(0)); // ProgramInfo
  out.add(_u32(0)); // CPI
  out.add(_u32(0)); // ClipMark
  out.add(_u32(0)); // ExtensionData
  out.add(Uint8List(12)); // reserved → 到 0x28
  out.add(sequenceBlock);
  return out.toBytes();
}

Uint8List _withUint8Length(Uint8List content) {
  final BytesBuilder out = BytesBuilder();
  out.addByte(content.length);
  out.add(content);
  return out.toBytes();
}

Uint8List _withUint16Length(Uint8List content) {
  final BytesBuilder out = BytesBuilder();
  out.add(_u16(content.length));
  out.add(content);
  return out.toBytes();
}

Uint8List _withUint32Length(Uint8List content) {
  final BytesBuilder out = BytesBuilder();
  out.add(_u32(content.length));
  out.add(content);
  return out.toBytes();
}

Uint8List _u16(int value) {
  final ByteData data = ByteData(2);
  data.setUint16(0, value);
  return data.buffer.asUint8List();
}

Uint8List _u32(int value) {
  final ByteData data = ByteData(4);
  data.setUint32(0, value);
  return data.buffer.asUint8List();
}
