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

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

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

/// 解析 TS 字节，返回第一条基本流的全部完整 PES（按出现顺序，时间戳已折回 33 位环绕）。
///
/// [complete] 为假（文件还在增长）时不交出可能没收完的尾 PES。损坏的 TS 包（同步字节
/// 不对）按「连续两个包都以 0x47 开头」重新找同步。解析在原生内核（`ffc_ts_demux_*`，与旧
/// Dart 实现逐包相同）。
List<BitmapSubtitlePacket> demuxMpegTsSubtitlePackets(
  Uint8List data, {
  bool complete = true,
}) => <BitmapSubtitlePacket>[
  for (final FfcTsPacket p in FushiComputeTs.instance.demuxAll(
    data,
    complete: complete,
  ))
    BitmapSubtitlePacket(pts90k: p.pts90k, data: p.data),
];

/// 增长中的 TS 文件的增量解复用：每次只读、只解析上次之后新写出的字节，交出的包与
/// 「每次从头重解整个文件」（[demuxMpegTsSubtitlePackets]）逐包相同。
///
/// 解复用状态在原生句柄里（[handle] 是地址，可以带进 `Isolate.run`；同一时刻只许一个
/// isolate 用它）。文件被截短（抽轨重来）时调用方应 [close] 后换新会话。
class MpegTsSubtitleDemuxSession implements Finalizable {
  MpegTsSubtitleDemuxSession() : handle = FushiComputeTs.instance.open() {
    _finalizer.attach(this, Pointer<Void>.fromAddress(handle), detach: this);
  }

  static final NativeFinalizer _finalizer = NativeFinalizer(
    FushiComputeTs.instance.finalizer,
  );

  /// 原生解复用器地址。
  final int handle;

  /// 到目前为止交出的全部包（按出现顺序）。
  final List<BitmapSubtitlePacket> packets = <BitmapSubtitlePacket>[];

  /// 已按「文件写完」收尾：之后 [packets] 就是整个文件的结果，不再读。
  bool completed = false;

  bool _closed = false;

  /// 下次要从文件的哪个偏移读起。
  int get needOffset => FushiComputeTs.instance.needOffset(handle);

  /// 把 [path] 从 [needOffset] 起到文件尾的新字节喂进去（在后台 isolate 读文件 + 解析），
  /// 返回本次新交出的包。文件比已解析的位置还短时抛 [StateError]（调用方换新会话）。
  Future<List<BitmapSubtitlePacket>> readMore(
    String path, {
    required bool complete,
  }) async {
    if (_closed) throw StateError('demux session closed');
    if (completed) return const <BitmapSubtitlePacket>[];
    final int address = handle;
    final List<BitmapSubtitlePacket> fresh = await Isolate.run(
      () => _readAndFeed(address, path, complete),
    );
    packets.addAll(fresh);
    if (complete) completed = true;
    return fresh;
  }

  /// 释放原生句柄（幂等）。
  void close() {
    if (_closed) return;
    _closed = true;
    _finalizer.detach(this);
    FushiComputeTs.instance.close(handle);
  }
}

List<BitmapSubtitlePacket> _readAndFeed(
  int handle,
  String path,
  bool complete,
) {
  final FushiComputeTs ts = FushiComputeTs.instance;
  final int from = ts.needOffset(handle);
  final RandomAccessFile file = File(path).openSync();
  final Uint8List chunk;
  try {
    final int length = file.lengthSync();
    if (length < from) {
      throw StateError('TS payload shrank below the parsed offset');
    }
    file.setPositionSync(from);
    chunk = file.readSync(length - from);
  } finally {
    file.closeSync();
  }
  return <BitmapSubtitlePacket>[
    for (final FfcTsPacket p in ts.feed(
      handle,
      chunk,
      base: from,
      complete: complete,
    ))
      BitmapSubtitlePacket(pts90k: p.pts90k, data: p.data),
  ];
}
