/// 同步文件格式（第三期「传输」）：批次、快照、cursor 文件一律自校验。
///
/// 文件 = 一行 UTF-8 JSON 头 + '\n' + 正文。头含魔数、格式版本、writerId、编号、正文长度与 SHA-256。
/// 长度不足、哈希不符（写到一半、传输截断）一律视为「这个文件还不存在」，下一轮再读。
/// 全部走字节接口，开启「防扫盘混淆」时正文也会被 ObfuscatingSyncBackend 混淆。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../event_store.dart';
import '../field_edit.dart' show srsCanonicalJson;

const String srsBatchMagic = 'FSRS-BATCH';
const String srsSnapshotMagic = 'FSRS-SNAP';
const String srsCursorMagic = 'FSRS-CURSOR';
const int srsSyncFormatVersion = 1;

String srsBatchName(int no) => 'batch-${no.toString().padLeft(10, '0')}';
String srsSnapshotName(int maxBatch) =>
    'snapshot-${maxBatch.toString().padLeft(10, '0')}';
const String srsCursorName = 'cursor';
const String srsProbeName = 'probe';

int? srsParseBatchName(String name) =>
    name.startsWith('batch-') ? int.tryParse(name.substring(6)) : null;
int? srsParseSnapshotName(String name) =>
    name.startsWith('snapshot-') ? int.tryParse(name.substring(9)) : null;

Uint8List _encode(Map<String, Object?> header, List<int> body) {
  final Map<String, Object?> h = <String, Object?>{
    ...header,
    'fv': srsSyncFormatVersion,
    'len': body.length,
    'sha256': sha256.convert(body).toString(),
  };
  final BytesBuilder b = BytesBuilder(copy: false)
    ..add(utf8.encode(srsCanonicalJson(h)))
    ..addByte(0x0a)
    ..add(body);
  return b.takeBytes();
}

/// 解出 (头, 正文)；校验不过返回 null。
(Map<String, Object?>, Uint8List)? _decode(Uint8List bytes, String magic) {
  final int nl = bytes.indexOf(0x0a);
  if (nl <= 0) return null;
  final Object? header;
  try {
    header = jsonDecode(utf8.decode(bytes.sublist(0, nl)));
  } on FormatException {
    return null;
  }
  if (header is! Map || header['magic'] != magic) return null;
  final Object? len = header['len'];
  final Uint8List body = Uint8List.sublistView(bytes, nl + 1);
  if (len is! int || body.length != len) return null;
  if (sha256.convert(body).toString() != header['sha256']) return null;
  return (header.cast<String, Object?>(), body);
}

List<int> _eventsBody(Iterable<SrsEvent> events) {
  final StringBuffer sb = StringBuffer();
  for (final SrsEvent e in events) {
    sb
      ..write(e.canonical())
      ..write('\n');
  }
  return utf8.encode(sb.toString());
}

List<SrsEvent> _parseEvents(String text) => <SrsEvent>[
  for (final String line in const LineSplitter().convert(text))
    if (line.isNotEmpty)
      SrsEvent.fromJson((jsonDecode(line) as Map).cast<String, Object?>()),
];

/// 一个批次：写入者的本机改动，冻结后不再改变。
class SrsBatch {
  const SrsBatch({
    required this.writerId,
    required this.no,
    required this.serverTimeMs,
    required this.events,
  });

  final String writerId;
  final int no;

  /// 发布时的服务器时间 S（带外元数据，只在信封里，不改任何事件）。
  final int serverTimeMs;
  final List<SrsEvent> events;

  Uint8List encode() => _encode(<String, Object?>{
    'magic': srsBatchMagic,
    'writer': writerId,
    'no': no,
    's': serverTimeMs,
  }, _eventsBody(events));

  static SrsBatch? decode(Uint8List bytes) {
    final (Map<String, Object?>, Uint8List)? d = _decode(bytes, srsBatchMagic);
    if (d == null) return null;
    final (Map<String, Object?> h, Uint8List body) = d;
    return SrsBatch(
      writerId: h['writer']! as String,
      no: h['no']! as int,
      serverTimeMs: h['s']! as int,
      events: _parseEvents(utf8.decode(body)),
    );
  }
}

/// 快照：写入者此刻的**完整合并状态**（不只是本机改动）+ 版本向量 + 「事件 ID → S」映射。
class SrsSnapshot {
  const SrsSnapshot({
    required this.writerId,
    required this.maxOwnBatch,
    required this.vv,
    required this.serverTimes,
    required this.events,
  });

  final String writerId;

  /// 快照覆盖的本写入者批次前缀（= vv[writerId]）。
  final int maxOwnBatch;

  /// 每个写入者 → 本快照已包含的无缺口批次前缀（含自己，含目录已删除的写入者；只增不减）。
  final Map<String, int> vv;
  final Map<String, int> serverTimes;
  final List<SrsEvent> events;

  Uint8List encode() {
    final List<int> events = _eventsBody(this.events);
    final List<int> times = utf8.encode(srsCanonicalJson(serverTimes));
    final BytesBuilder body = BytesBuilder(copy: false)
      ..add(utf8.encode('${times.length}\n'))
      ..add(times)
      ..add(events);
    return _encode(<String, Object?>{
      'magic': srsSnapshotMagic,
      'writer': writerId,
      'no': maxOwnBatch,
      'vv': vv,
    }, body.takeBytes());
  }

  static SrsSnapshot? decode(Uint8List bytes) {
    final (Map<String, Object?>, Uint8List)? d = _decode(
      bytes,
      srsSnapshotMagic,
    );
    if (d == null) return null;
    final (Map<String, Object?> h, Uint8List body) = d;
    final int nl = body.indexOf(0x0a);
    final int timesLen = int.parse(utf8.decode(body.sublist(0, nl)));
    final Map<String, Object?> times =
        (jsonDecode(utf8.decode(body.sublist(nl + 1, nl + 1 + timesLen)))
                as Map)
            .cast<String, Object?>();
    return SrsSnapshot(
      writerId: h['writer']! as String,
      maxOwnBatch: h['no']! as int,
      vv: (h['vv']! as Map).cast<String, int>(),
      serverTimes: <String, int>{
        for (final MapEntry<String, Object?> e in times.entries)
          e.key: e.value! as int,
      },
      events: _parseEvents(utf8.decode(body.sublist(nl + 1 + timesLen))),
    );
  }
}

/// cursor 文件：本写入者对每个对端的读取进度（只表示无缺口前缀）与更新时刻（判退役）。
class SrsCursorFile {
  const SrsCursorFile({
    required this.writerId,
    required this.cursors,
    required this.updatedAtMs,
  });

  final String writerId;
  final Map<String, int> cursors;
  final int updatedAtMs;

  Uint8List encode() => _encode(<String, Object?>{
    'magic': srsCursorMagic,
    'writer': writerId,
    'at': updatedAtMs,
  }, utf8.encode(srsCanonicalJson(cursors)));

  static SrsCursorFile? decode(Uint8List bytes) {
    final (Map<String, Object?>, Uint8List)? d = _decode(bytes, srsCursorMagic);
    if (d == null) return null;
    final (Map<String, Object?> h, Uint8List body) = d;
    return SrsCursorFile(
      writerId: h['writer']! as String,
      cursors: (jsonDecode(utf8.decode(body)) as Map).cast<String, int>(),
      updatedAtMs: h['at']! as int,
    );
  }
}
