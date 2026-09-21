// fragmented MP4 的字节层改写：把「每段一个独立 ffmpeg」的产物拼成一条**时间轴连续**
// 的 HLS fMP4 流。
//
// 为什么非改不可：ffmpeg 的 mp4 muxer 在 fragmented 模式下，总把第一个 fragment 的
// `tfdt`（baseMediaDecodeTime）写成 0——`-copyts`、`-output_ts_offset`、
// `-avoid_negative_ts disabled` 三种组合实测都改不了它（2026-09-21 用随包
// ffmpeg-min 逐一验证）。于是每段独立转码出来的分段，时间戳全都落在 `0..段长`
// 上互相重叠：播放器按 playlist 把它们首尾相接时，540 个包里只有 300 个能进解码器，
// 后面的段因为时间戳回退被整片丢掉。
//
// 修法是在段发出去之前，把每个 `moof/traf/tfdt` 的 baseMediaDecodeTime 加上该段在
// 片中的绝对偏移（按各 track 自己的 timescale 换算）。改完实测：时长正确、包一个不
// 丢、pts 连续覆盖全片、seek 落点正确。
//
// 这里只动 `tfdt` 这一个字段，其余字节原样透传——不重写 box 大小，不重排结构，所以
// 一次解析失败的最坏后果是「这段没被改写」而不是「产出一段坏 MP4」。

import 'dart:typed_data';

/// MP4 box 头：`size(4) + type(4)`，size==1 时后面再跟 8 字节的 64 位 largesize。
class _Box {
  const _Box(this.offset, this.size, this.type, this.headerSize);

  final int offset;
  final int size;
  final String type;
  final int headerSize;

  int get contentOffset => offset + headerSize;
  int get end => offset + size;
}

/// 顺序扫 [data] 的 `[start, end)` 区间里的顶层 box。
///
/// 任何一步越界都停止迭代而不是抛——输入是子进程的输出，截断（进程被 kill）是常态，
/// 不是异常。
Iterable<_Box> _boxes(Uint8List data, int start, int end) sync* {
  final ByteData view = ByteData.sublistView(data);
  int offset = start;
  while (offset + 8 <= end) {
    int size = view.getUint32(offset);
    int headerSize = 8;
    if (size == 1) {
      if (offset + 16 > end) return;
      size = view.getUint64(offset + 8);
      headerSize = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < headerSize || offset + size > end) return;
    final String type = String.fromCharCodes(data, offset + 4, offset + 8);
    yield _Box(offset, size, type, headerSize);
    offset += size;
  }
}

/// 初始化段（`ftyp` + `moov`）在 [data] 里的结束位置；找不到 `moov` 返回 null。
int? initSegmentLength(Uint8List data) {
  for (final _Box box in _boxes(data, 0, data.length)) {
    if (box.type == 'moov') return box.end;
  }
  return null;
}

/// 切出初始化段（HLS 的 `EXT-X-MAP` 指向它）。
///
/// 所有分段共用这一份 track 定义，所以它必须与分段出自**同一套编码参数**——host 侧
/// 的做法是拿第 0 段的转码产物来生成它。
Uint8List? extractInitSegment(Uint8List data) {
  final int? length = initSegmentLength(data);
  if (length == null) return null;
  return Uint8List.sublistView(data, 0, length);
}

/// 丢掉 `ftyp`+`moov`，只留 `moof`+`mdat`——这是 HLS fMP4 分段该有的形状。
///
/// 段里重复带 `moov` 时播放器会报 "Found duplicated MOOV Atom"，并可能把后续分段
/// 拆成另一组流（实测 ffprobe 会列出两套 h264+aac），所以这一步不是洁癖。
Uint8List stripInitSegment(Uint8List data) {
  final int? length = initSegmentLength(data);
  if (length == null || length >= data.length) return data;
  return Uint8List.sublistView(data, length);
}

/// 从初始化段读出每条 track 的 `trackId -> timescale`（`trak/tkhd` + `trak/mdia/mdhd`）。
///
/// 视频与音频的 timescale 通常不同（实测 15360 / 44100），所以偏移必须**按 track 各
/// 自换算**，不能共用一个数。
Map<int, int> parseTrackTimescales(Uint8List init) {
  final Map<int, int> result = <int, int>{};
  final ByteData view = ByteData.sublistView(init);
  for (final _Box moov in _boxes(init, 0, init.length)) {
    if (moov.type != 'moov') continue;
    for (final _Box trak in _boxes(init, moov.contentOffset, moov.end)) {
      if (trak.type != 'trak') continue;
      int? trackId;
      int? timescale;
      for (final _Box child in _boxes(init, trak.contentOffset, trak.end)) {
        if (child.type == 'tkhd') {
          final int version = init[child.contentOffset];
          // version 1 的 creation/modification 是 64 位，track_id 因此后移 8 字节。
          final int idOffset = child.contentOffset + (version == 1 ? 20 : 12);
          if (idOffset + 4 > child.end) continue;
          trackId = view.getUint32(idOffset);
        } else if (child.type == 'mdia') {
          for (final _Box mdhd in _boxes(
            init,
            child.contentOffset,
            child.end,
          )) {
            if (mdhd.type != 'mdhd') continue;
            final int version = init[mdhd.contentOffset];
            final int scaleOffset =
                mdhd.contentOffset + (version == 1 ? 20 : 12);
            if (scaleOffset + 4 > mdhd.end) continue;
            timescale = view.getUint32(scaleOffset);
          }
        }
      }
      if (trackId != null && timescale != null && timescale > 0) {
        result[trackId] = timescale;
      }
    }
  }
  return result;
}

/// 给 [segment] 里每个 `traf` 的 `tfdt` 加上 [offset] 的绝对偏移。
///
/// [timescales] 来自 [parseTrackTimescales]。返回**新的字节**（不原地改调用方的
/// buffer）。解析不出 track / timescale 的 `traf` 原样放过：宁可这一处不平移，也不
/// 要写出一个大小对不上的 box。
///
/// version 0 的 `tfdt` 是 32 位，加上偏移后可能溢出（timescale 90000 时约 13 小时
/// 封顶）。真溢出就跳过该 traf 而不是截断成一个错得离谱的时间戳——一段不同步远好过
/// 整条时间轴错乱。
Uint8List shiftFragmentDecodeTimes(
  Uint8List segment, {
  required Map<int, int> timescales,
  required Duration offset,
}) {
  if (offset == Duration.zero || timescales.isEmpty) return segment;
  final Uint8List out = Uint8List.fromList(segment);
  final ByteData view = ByteData.sublistView(out);
  final double offsetSeconds =
      offset.inMicroseconds / Duration.microsecondsPerSecond;

  for (final _Box moof in _boxes(out, 0, out.length)) {
    if (moof.type != 'moof') continue;
    for (final _Box traf in _boxes(out, moof.contentOffset, moof.end)) {
      if (traf.type != 'traf') continue;
      int? trackId;
      _Box? tfdt;
      for (final _Box child in _boxes(out, traf.contentOffset, traf.end)) {
        if (child.type == 'tfhd') {
          // tfhd: version(1) + flags(3) + track_ID(4)
          if (child.contentOffset + 8 > child.end) continue;
          trackId = view.getUint32(child.contentOffset + 4);
        } else if (child.type == 'tfdt') {
          tfdt = child;
        }
      }
      if (trackId == null || tfdt == null) continue;
      final int? timescale = timescales[trackId];
      if (timescale == null) continue;
      final int delta = (offsetSeconds * timescale).round();
      if (delta == 0) continue;

      final int version = out[tfdt.contentOffset];
      // tfdt: version(1) + flags(3) + baseMediaDecodeTime(4 或 8)
      final int valueOffset = tfdt.contentOffset + 4;
      if (version == 1) {
        if (valueOffset + 8 > tfdt.end) continue;
        view.setUint64(valueOffset, view.getUint64(valueOffset) + delta);
      } else {
        if (valueOffset + 4 > tfdt.end) continue;
        final int shifted = view.getUint32(valueOffset) + delta;
        if (shifted >= 0x100000000) continue;
        view.setUint32(valueOffset, shifted);
      }
    }
  }
  return out;
}
