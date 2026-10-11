/// 从 ffmpeg `-c copy -f mpegts` 抽出的单轨 TS 里取回字幕包（PES）。
///
/// 为什么经 TS：VobSub / DVB 的 `-f sup` 封装器直接拒收（实测 `Invalid data`），而捆绑的
/// 精简 ffmpeg 只编入了 mpegts / mov / webm / sup / null 等少数封装器；TS 是其中唯一一个
/// 对**任意**字幕编码都按「私有数据流」原样承载、逐包带 90 kHz PTS、且边写边可读（定长
/// 188 字节包，没有尾部索引）的。payload 不被改写，只有 DVB 字幕按 EN 300 743 多一层
/// `data_identifier 0x20 / stream_id 0x00 … 0xFF` 包装（解码器自己剥）。
///
/// 只做抽轨产物需要的那部分：PAT → PMT → 第一条基本流 PID → 按 `payload_unit_start`
/// 拼 PES。抽轨仍在写时文件尾可能是半个 TS 包 / 半个 PES：PES 头里的长度没收满的不交出，
/// 长度为 0（不定长）的 PES 只在下一个 PES 开始或 [complete] 时交出。
library;

import 'dart:typed_data';

/// 一个字幕包：90 kHz 的显示时间戳 + 原始 payload。
class BitmapSubtitlePacket {
  const BitmapSubtitlePacket({
    required this.pts90k,
    required this.data,
    this.duration90k,
  });

  final int pts90k;

  /// 容器给的包时长（TS 不带，恒为 null；保留给其它来源）。
  final int? duration90k;
  final Uint8List data;

  int get ptsMs => pts90k ~/ 90;
}

const int _kTsPacketSize = 188;
const int _kTsSync = 0x47;

/// 解析 TS 字节，返回第一条基本流的全部完整 PES（按出现顺序，时间戳已折回 33 位环绕）。
///
/// [complete] 为假（文件还在增长）时不交出可能没收完的尾 PES。损坏的 TS 包（同步字节
/// 不对）按 188 字节步长跳过并重新找同步。
List<BitmapSubtitlePacket> demuxMpegTsSubtitlePackets(
  Uint8List data, {
  bool complete = true,
}) {
  final _TsDemuxer demuxer = _TsDemuxer();
  int offset = 0;
  while (offset + _kTsPacketSize <= data.length) {
    if (data[offset] != _kTsSync) {
      offset = _resync(data, offset + 1);
      if (offset < 0) break;
      continue;
    }
    demuxer.feed(Uint8List.sublistView(data, offset, offset + _kTsPacketSize));
    offset += _kTsPacketSize;
  }
  demuxer.finish(complete: complete);
  return demuxer.packets;
}

/// 从 [from] 起找下一个「连续两个包都以 0x47 开头」的位置；找不到返回 -1。
int _resync(Uint8List data, int from) {
  for (int i = from; i + _kTsPacketSize < data.length; i++) {
    if (data[i] == _kTsSync && data[i + _kTsPacketSize] == _kTsSync) return i;
  }
  return -1;
}

class _TsDemuxer {
  final List<BitmapSubtitlePacket> packets = <BitmapSubtitlePacket>[];
  int? _pmtPid;
  int? _esPid;
  BytesBuilder? _pes;
  int _pesExpected = 0;
  int? _lastPts;
  int _ptsWrap = 0;

  void feed(Uint8List ts) {
    final bool unitStart = ts[1] & 0x40 != 0;
    final int pid = ((ts[1] & 0x1F) << 8) | ts[2];
    final int afc = (ts[3] >> 4) & 0x3;
    int o = 4;
    if (afc == 0 || afc == 2) return; // 无 payload。
    if (afc == 3) {
      o += 1 + ts[4];
      if (o >= _kTsPacketSize) return;
    }
    final Uint8List payload = Uint8List.sublistView(ts, o);
    if (pid == 0) {
      if (unitStart) _readPat(payload);
      return;
    }
    if (pid == _pmtPid) {
      if (unitStart) _readPmt(payload);
      return;
    }
    if (pid != _esPid) return;
    if (unitStart) {
      _flush(force: true);
      _pes = BytesBuilder(copy: true)..add(payload);
      _pesExpected = payload.length >= 6 ? ((payload[4] << 8) | payload[5]) : 0;
    } else {
      _pes?.add(payload);
    }
    if (_pesExpected > 0 && (_pes?.length ?? 0) >= _pesExpected + 6) {
      _flush(force: true);
    }
  }

  void finish({required bool complete}) {
    if (complete || _pesExpected > 0) _flush(force: complete);
  }

  void _readPat(Uint8List p) {
    final Uint8List? section = _section(p);
    if (section == null) return;
    // section: table_id .. 8 字节表头，之后每 4 字节一项，末尾 4 字节 CRC。
    for (int i = 8; i + 4 <= section.length - 4; i += 4) {
      final int program = (section[i] << 8) | section[i + 1];
      final int pid = ((section[i + 2] & 0x1F) << 8) | section[i + 3];
      if (program != 0) {
        _pmtPid = pid;
        return;
      }
    }
  }

  void _readPmt(Uint8List p) {
    final Uint8List? section = _section(p);
    if (section == null || section.length < 12) return;
    final int programInfoLength = ((section[10] & 0x0F) << 8) | section[11];
    int i = 12 + programInfoLength;
    while (i + 5 <= section.length - 4) {
      final int pid = ((section[i + 1] & 0x1F) << 8) | section[i + 2];
      final int esInfoLength = ((section[i + 3] & 0x0F) << 8) | section[i + 4];
      _esPid ??= pid;
      i += 5 + esInfoLength;
    }
  }

  /// PSI：pointer_field 后的一整节（只看首个 TS 包里的部分，PAT/PMT 远小于一个包）。
  Uint8List? _section(Uint8List p) {
    if (p.isEmpty) return null;
    final int start = 1 + p[0];
    if (start + 3 > p.length) return null;
    final int length = ((p[start + 1] & 0x0F) << 8) | p[start + 2];
    final int end = start + 3 + length;
    if (end > p.length) return null;
    return Uint8List.sublistView(p, start, end);
  }

  /// 交出在拼的 PES。[force] 为假时只交长度已收满的。
  void _flush({required bool force}) {
    final BytesBuilder? builder = _pes;
    if (builder == null) return;
    final Uint8List pes = builder.toBytes();
    final bool sized = _pesExpected > 0;
    if (sized && pes.length < _pesExpected + 6) {
      // 没收满：文件还在增长（或尾部截断），丢弃，下次重读再拼。
      if (!force) return;
      _pes = null;
      return;
    }
    _pes = null;
    final Uint8List body = sized
        ? Uint8List.sublistView(pes, 0, _pesExpected + 6)
        : pes;
    final BitmapSubtitlePacket? packet = _readPes(body);
    if (packet != null) packets.add(packet);
  }

  BitmapSubtitlePacket? _readPes(Uint8List pes) {
    if (pes.length < 9 || pes[0] != 0 || pes[1] != 0 || pes[2] != 1) {
      return null;
    }
    final int headerLength = pes[8];
    final int payloadStart = 9 + headerLength;
    if (payloadStart > pes.length) return null;
    final int flags = pes[7];
    if (flags & 0x80 == 0 || headerLength < 5) return null; // 没有 PTS 的包无法定时。
    final int raw =
        ((pes[9] >> 1) & 0x07) << 30 |
        pes[10] << 22 |
        (pes[11] >> 1) << 15 |
        pes[12] << 7 |
        (pes[13] >> 1);
    return BitmapSubtitlePacket(
      pts90k: _unwrap(raw),
      data: Uint8List.fromList(Uint8List.sublistView(pes, payloadStart)),
    );
  }

  /// 33 位 PTS 环绕：比上一个小了超过半圈就算绕回。
  int _unwrap(int raw) {
    const int period = 1 << 33;
    int pts = raw + _ptsWrap;
    final int? last = _lastPts;
    if (last != null && last - pts > period ~/ 2) {
      _ptsWrap += period;
      pts += period;
    }
    _lastPts = pts;
    return pts;
  }
}
