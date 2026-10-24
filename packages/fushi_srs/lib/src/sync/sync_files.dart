/// 同步文件格式（第三期「传输」）：批次、快照、cursor 文件一律自校验。
///
/// 文件 = 一行 UTF-8 JSON 头 + '\n' + 正文。头含魔数、格式版本、writerId、编号、正文长度与 SHA-256。
/// 长度不足、哈希不符（写到一半、传输截断）一律视为「这个文件还不存在」，下一轮再读（[SrsFileIncomplete]）。
/// 校验通过、内容却解不出来（某台设备的 bug、版本不兼容的写入者）是另一回事：等多少轮都不会变好，
/// 解码返回 [SrsFileMalformed] 而不是抛异常，同步引擎跳过它、记进报告（[SrsSyncReport.skippedFiles]），
/// 不让一个坏文件拖垮整轮同步（BUG-3566 的 host 一侧：host 读的是所有已配对设备写进来的文件）。
/// 全部走字节接口，开启「防扫盘混淆」时正文也会被 ObfuscatingSyncBackend 混淆。
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

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
    'sha256': ffcSha256Bytes(body),
  };
  final BytesBuilder b = BytesBuilder(copy: false)
    ..add(utf8.encode(srsCanonicalJson(h)))
    ..addByte(0x0a)
    ..add(body);
  return b.takeBytes();
}

/// 解码结果：成功 / 还不完整（下一轮再读）/ 校验通过但内容坏了（跳过，别等）。
sealed class SrsFileDecode<T> {
  const SrsFileDecode();

  /// 成功时的值，否则 null。
  T? get valueOrNull => switch (this) {
    SrsFileOk<T>(:final T value) => value,
    _ => null,
  };
}

final class SrsFileOk<T> extends SrsFileDecode<T> {
  const SrsFileOk(this.value);
  final T value;
}

/// 写到一半 / 传输截断 / 不是这种文件：视为「还不存在」。
final class SrsFileIncomplete<T> extends SrsFileDecode<T> {
  const SrsFileIncomplete();
}

/// 自校验通过，但头部字段或正文解不出来。[reason] 只用于日志。
final class SrsFileMalformed<T> extends SrsFileDecode<T> {
  const SrsFileMalformed(this.reason);
  final String reason;
}

/// 自校验通过之后再解析：解析里任何类型 / 格式错误都收成 [SrsFileMalformed]。
SrsFileDecode<T> _parseChecked<T>(
  Uint8List bytes,
  String magic,
  T Function(Map<String, Object?> header, Uint8List body) parse,
) {
  final (Map<String, Object?>, Uint8List)? d = _decode(bytes, magic);
  if (d == null) return SrsFileIncomplete<T>();
  try {
    return SrsFileOk<T>(parse(d.$1, d.$2));
  } on Object catch (e) {
    // TypeError / FormatException / RangeError / 事件 JSON 结构不对……都是内容坏了。
    return SrsFileMalformed<T>('$magic: ${e.runtimeType}: $e');
  }
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
  if (ffcSha256Bytes(body) != header['sha256']) return null;
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

/// 解析正文里的事件。只在 [_parseChecked] 里调：结构不对的事件在这里就抛出、被收成
/// [SrsFileMalformed]——各 fromJson 里的 `cast` 是惰性的，类型错误要到第一次读字段才暴露，
/// 所以每条事件当场规范编码一遍（与落库时同一操作），把错误留在解码这一层，不带进应用阶段。
List<SrsEvent> _parseEvents(String text) => <SrsEvent>[
  for (final String line in const LineSplitter().convert(text))
    if (line.isNotEmpty) _validated(_eventFromLine(line)),
];

SrsEvent _eventFromLine(String line) =>
    SrsEvent.fromJson((jsonDecode(line) as Map).cast<String, Object?>());

SrsEvent _validated(SrsEvent e) {
  e.canonical();
  return e;
}

/// 一个批次：写入者的本机改动，冻结后不再改变。
class SrsBatch {
  const SrsBatch({
    required this.writerId,
    required this.no,
    required this.serverTimeMs,
    required this.events,
    this.knownServerTimes = const <String, int>{},
  });

  final String writerId;
  final int no;

  /// 发布时的服务器时间 S（带外元数据，只在信封里，不改任何事件）。只作用于**首次发布**的事件。
  final int serverTimeMs;
  final List<SrsEvent> events;

  /// 批次里早已发布过、写入者冻结时已知 S 的事件（转发、重新发布）→ 那个 S。
  /// 这些事件不取信封的 S：转发的那份可能是某些设备唯一能看到的一份，信封 S 是转发时刻，
  /// 用它会让只看得到转发的设备算出与别人不同的 S(e)（排序键随之不同，不收敛）。
  final Map<String, int> knownServerTimes;

  /// 事件 [eventId] 在本批次里的 S。
  int serverTimeOf(String eventId) => knownServerTimes[eventId] ?? serverTimeMs;

  Uint8List encode() => _encode(<String, Object?>{
    'magic': srsBatchMagic,
    'writer': writerId,
    'no': no,
    's': serverTimeMs,
    if (knownServerTimes.isNotEmpty) 'fs': knownServerTimes,
  }, _eventsBody(events));

  /// 解码；不完整或内容坏了都返回 null（要区分两者用 [tryDecode]）。
  static SrsBatch? decode(Uint8List bytes) => tryDecode(bytes).valueOrNull;

  static SrsFileDecode<SrsBatch> tryDecode(Uint8List bytes) =>
      _parseChecked(bytes, srsBatchMagic, _parse);

  static SrsBatch _parse(Map<String, Object?> h, Uint8List body) {
    return SrsBatch(
      writerId: h['writer']! as String,
      no: h['no']! as int,
      serverTimeMs: h['s']! as int,
      events: _parseEvents(utf8.decode(body)),
      knownServerTimes: <String, int>{
        for (final MapEntry<String, Object?> e
            in ((h['fs'] as Map?) ?? const <String, Object?>{})
                .cast<String, Object?>()
                .entries)
          e.key: e.value! as int,
      },
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

  Uint8List encode() => encodeParts(
    writerId: writerId,
    maxOwnBatch: maxOwnBatch,
    vv: vv,
    serverTimesJson: utf8.encode(srsCanonicalJson(serverTimes)),
    eventsBody: _eventsBody(events),
  );

  /// 由已拼好的两段正文组成快照文件（与 [encode] 同格式）：[serverTimesJson] 是「事件 ID → S」的
  /// JSON 对象，[eventsBody] 是每行一条事件规范 JSON（每行以换行结尾）。纯函数，只做拼接与 SHA-256：
  /// 同步引擎按页从副本读出两段后在后台 isolate 里调它（整份快照几十 MB，不能在调用方 isolate 上算）。
  static Uint8List encodeParts({
    required String writerId,
    required int maxOwnBatch,
    required Map<String, int> vv,
    required List<int> serverTimesJson,
    required List<int> eventsBody,
  }) {
    final BytesBuilder body = BytesBuilder(copy: false)
      ..add(utf8.encode('${serverTimesJson.length}\n'))
      ..add(serverTimesJson)
      ..add(eventsBody);
    return _encode(<String, Object?>{
      'magic': srsSnapshotMagic,
      'writer': writerId,
      'no': maxOwnBatch,
      'vv': vv,
    }, body.takeBytes());
  }

  /// 解码；不完整或内容坏了都返回 null（要区分两者用 [tryDecode]）。
  static SrsSnapshot? decode(Uint8List bytes) => tryDecode(bytes).valueOrNull;

  static SrsFileDecode<SrsSnapshot> tryDecode(Uint8List bytes) =>
      _parseChecked(bytes, srsSnapshotMagic, _parse);

  static SrsSnapshot _parse(Map<String, Object?> h, Uint8List body) {
    final int nl = body.indexOf(0x0a);
    final int timesLen = int.parse(utf8.decode(body.sublist(0, nl)));
    final Map<String, Object?> times =
        (jsonDecode(utf8.decode(body.sublist(nl + 1, nl + 1 + timesLen)))
                as Map)
            .cast<String, Object?>();
    return SrsSnapshot(
      writerId: h['writer']! as String,
      maxOwnBatch: h['no']! as int,
      vv: <String, int>{
        for (final MapEntry<Object?, Object?> e in (h['vv']! as Map).entries)
          e.key! as String: e.value! as int,
      },
      serverTimes: <String, int>{
        for (final MapEntry<String, Object?> e in times.entries)
          e.key: e.value! as int,
      },
      events: _parseEvents(utf8.decode(body.sublist(nl + 1 + timesLen))),
    );
  }
}

/// 快照的头部（只要 vv / 编号时用，不带几十 MB 的事件正文）。
class SrsSnapshotHeader {
  const SrsSnapshotHeader({
    required this.writerId,
    required this.maxOwnBatch,
    required this.vv,
  });

  SrsSnapshotHeader.of(SrsSnapshot s)
    : writerId = s.writerId,
      maxOwnBatch = s.maxOwnBatch,
      vv = s.vv;

  final String writerId;
  final int maxOwnBatch;
  final Map<String, int> vv;
}

/// 小于它的文件就在调用方 isolate 上编解码：起一个 isolate 的固定开销比解它本身还贵，
/// 也不会长时间占住事件循环。更大的（整份快照、几千条事件的批次）一律放后台 isolate——
/// 自校验（SHA-256）、逐条事件解析 / 规范编码都是 O(正文) 的 CPU 活，大库上一次就是秒级，
/// 在 UI isolate 上做会让整个 app 卡死（反馈 OMWOurRQKb）。
const int kSrsOffThreadMinBytes = 256 * 1024;

/// 少于这么多条事件的批次就地编码（同 [kSrsOffThreadMinBytes] 的理由）。
const int kSrsOffThreadMinEvents = 500;

/// 解码快照（大文件在后台 isolate）。
Future<SrsFileDecode<SrsSnapshot>> srsDecodeSnapshot(Uint8List bytes) =>
    bytes.length < kSrsOffThreadMinBytes
    ? Future<SrsFileDecode<SrsSnapshot>>.value(SrsSnapshot.tryDecode(bytes))
    : Isolate.run(() => SrsSnapshot.tryDecode(bytes));

/// 只要快照头部（vv）时：照样整份校验（坏了的快照不能算覆盖），但只把头部带回调用方，
/// 不把几万条事件对象搬回来。
Future<SrsFileDecode<SrsSnapshotHeader>> srsDecodeSnapshotHeader(
  Uint8List bytes,
) => bytes.length < kSrsOffThreadMinBytes
    ? Future<SrsFileDecode<SrsSnapshotHeader>>.value(_snapshotHeaderOf(bytes))
    : Isolate.run(() => _snapshotHeaderOf(bytes));

SrsFileDecode<SrsSnapshotHeader> _snapshotHeaderOf(Uint8List bytes) =>
    switch (SrsSnapshot.tryDecode(bytes)) {
      SrsFileOk<SrsSnapshot>(:final SrsSnapshot value) =>
        SrsFileOk<SrsSnapshotHeader>(SrsSnapshotHeader.of(value)),
      SrsFileMalformed<SrsSnapshot>(:final String reason) =>
        SrsFileMalformed<SrsSnapshotHeader>(reason),
      SrsFileIncomplete<SrsSnapshot>() =>
        const SrsFileIncomplete<SrsSnapshotHeader>(),
    };

/// 按页拼好的两段正文组成快照文件（[SrsSnapshot.encodeParts]；大的在后台 isolate 拼接、求摘要）。
Future<Uint8List> srsEncodeSnapshotParts({
  required String writerId,
  required int maxOwnBatch,
  required Map<String, int> vv,
  required Uint8List serverTimesJson,
  required Uint8List eventsBody,
}) {
  Uint8List run() => SrsSnapshot.encodeParts(
    writerId: writerId,
    maxOwnBatch: maxOwnBatch,
    vv: vv,
    serverTimesJson: serverTimesJson,
    eventsBody: eventsBody,
  );
  return serverTimesJson.length + eventsBody.length < kSrsOffThreadMinBytes
      ? Future<Uint8List>.value(run())
      : Isolate.run(run);
}

/// 解码批次（同 [srsDecodeSnapshot]）。
Future<SrsFileDecode<SrsBatch>> srsDecodeBatch(Uint8List bytes) =>
    bytes.length < kSrsOffThreadMinBytes
    ? Future<SrsFileDecode<SrsBatch>>.value(SrsBatch.tryDecode(bytes))
    : Isolate.run(() => SrsBatch.tryDecode(bytes));

/// 编码批次：几千条事件逐条规范编码 + SHA-256，大批次在后台 isolate 做。
Future<Uint8List> srsEncodeBatch(SrsBatch batch) =>
    batch.events.length < kSrsOffThreadMinEvents
    ? Future<Uint8List>.value(batch.encode())
    : Isolate.run(batch.encode);

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

  /// 解码；不完整或内容坏了都返回 null（要区分两者用 [tryDecode]）。
  static SrsCursorFile? decode(Uint8List bytes) => tryDecode(bytes).valueOrNull;

  static SrsFileDecode<SrsCursorFile> tryDecode(Uint8List bytes) =>
      _parseChecked(bytes, srsCursorMagic, _parse);

  static SrsCursorFile _parse(Map<String, Object?> h, Uint8List body) {
    return SrsCursorFile(
      writerId: h['writer']! as String,
      cursors: <String, int>{
        for (final MapEntry<Object?, Object?> e
            in (jsonDecode(utf8.decode(body)) as Map).entries)
          e.key! as String: e.value! as int,
      },
      updatedAtMs: h['at']! as int,
    );
  }
}
