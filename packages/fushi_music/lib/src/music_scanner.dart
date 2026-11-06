import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'fushi_music_library.dart';
import 'scan_wire.dart';

typedef _OpenC =
    Int32 Function(Pointer<Uint8>, Size, Uint8, Pointer<Pointer<Void>>);
typedef _OpenDart =
    int Function(Pointer<Uint8>, int, int, Pointer<Pointer<Void>>);
typedef _SetKnownC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _SetKnownDart = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _NextC =
    Int32 Function(
      Pointer<Void>,
      Uint32,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _NextDart =
    int Function(Pointer<Void>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);
typedef _CoverC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _CoverDart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);

/// 扫描根打不开（不存在 / 不是目录 / 参数非法）。业务层失败：来源库被挪走、U 盘没插。
final class MusicScanRootError implements Exception {
  const MusicScanRootError(this.root, this.status);

  final String root;
  final int status;

  @override
  String toString() => status == FfmStatus.notFound
      ? 'MusicScanRootError: $root is not a directory'
      : 'MusicScanRootError: cannot scan $root (status $status)';
}

class _ScanBindings {
  _ScanBindings(FushiMusic lib) : _lib = lib {
    try {
      open = lib.library.lookupFunction<_OpenC, _OpenDart>('ffm_scan_open');
      setKnown = lib.library.lookupFunction<_SetKnownC, _SetKnownDart>(
        'ffm_scan_set_known',
      );
      next = lib.library.lookupFunction<_NextC, _NextDart>('ffm_scan_next');
      close = lib.library.lookupFunction<_CloseC, _CloseDart>('ffm_scan_close');
      cover = lib.library.lookupFunction<_CoverC, _CoverDart>(
        'ffm_tags_embedded_cover',
      );
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('scan', e);
    }
  }

  final FushiMusic _lib;
  late final _OpenDart open;
  late final _SetKnownDart setKnown;
  late final _NextDart next;
  late final _CloseDart close;
  late final _CoverDart cover;

  static _ScanBindings? _instance;
  static _ScanBindings get instance =>
      _instance ??= _ScanBindings(FushiMusic.instance);
}

Pointer<Uint8> _copyIn(Uint8List bytes, Allocator alloc) {
  final Pointer<Uint8> p = alloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  p.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
  return p;
}

/// 同步扫描会话（**阻塞调用线程**：目录遍历与标签解析都在 [next] 里）。UI isolate 一律用
/// [scanMusicRoot]，它把会话放进后台 isolate。
final class MusicScanSession {
  MusicScanSession._(this._b, this._handle);

  /// 打开 [root]（UTF-8 路径）。[known] 是库里已有文件的（修改时刻, 大小）：没变的
  /// 文件只回 [MusicScanUnchanged]，不再解析标签。根不可扫抛 [MusicScanRootError]。
  factory MusicScanSession.open(
    String root, {
    bool recursive = true,
    Map<String, ({int mtimeMs, int size})> known =
        const <String, ({int mtimeMs, int size})>{},
  }) {
    final _ScanBindings b = _ScanBindings.instance;
    return using((Arena arena) {
      final Uint8List rootBytes = utf8.encode(root);
      final Pointer<Pointer<Void>> out = arena<Pointer<Void>>();
      final int rc = b.open(
        _copyIn(rootBytes, arena),
        rootBytes.length,
        recursive ? 1 : 0,
        out,
      );
      if (rc != FfmStatus.ok) throw MusicScanRootError(root, rc);
      final MusicScanSession session = MusicScanSession._(b, out.value);
      if (known.isNotEmpty) {
        final Uint8List knownBytes = encodeMusicKnownFiles(known);
        final int krc = b.setKnown(
          session._handle,
          _copyIn(knownBytes, arena),
          knownBytes.length,
        );
        if (krc != FfmStatus.ok) {
          session.close();
          throw StateError('ffm_scan_set_known failed with status $krc');
        }
      }
      return session;
    });
  }

  final _ScanBindings _b;
  Pointer<Void> _handle;

  /// 取下一批原始字节（至多 [maxRecords] 条，0 = 原生上限 256）。
  Uint8List nextBytes({int maxRecords = 0}) {
    if (_handle == nullptr) throw StateError('MusicScanSession is closed');
    return using((Arena arena) {
      final Pointer<Pointer<Uint8>> outPtr = arena<Pointer<Uint8>>();
      final Pointer<Size> outLen = arena<Size>();
      final int rc = _b.next(_handle, maxRecords, outPtr, outLen);
      if (rc != FfmStatus.ok) {
        throw StateError('ffm_scan_next failed with status $rc');
      }
      final int len = outLen.value;
      final Uint8List copy = Uint8List.fromList(
        outPtr.value.asTypedListOutOfLine(len),
      );
      _b._lib.freeBytes(outPtr.value, len);
      return copy;
    });
  }

  MusicScanBatch next({int maxRecords = 0}) =>
      decodeMusicScanBatch(nextBytes(maxRecords: maxRecords));

  void close() {
    if (_handle == nullptr) return;
    _b.close(_handle);
    _handle = nullptr;
  }
}

/// 读一个音频文件的内嵌封面字节（阻塞；放后台 isolate 调）。没有封面返回 null。
Uint8List? readMusicEmbeddedCover(String path) {
  final _ScanBindings b = _ScanBindings.instance;
  return using((Arena arena) {
    final Uint8List pathBytes = utf8.encode(path);
    final Pointer<Pointer<Uint8>> outPtr = arena<Pointer<Uint8>>();
    final Pointer<Size> outLen = arena<Size>();
    final int rc = b.cover(
      _copyIn(pathBytes, arena),
      pathBytes.length,
      outPtr,
      outLen,
    );
    if (rc != FfmStatus.ok) return null;
    final int len = outLen.value;
    if (len == 0) return null;
    final Uint8List copy = Uint8List.fromList(
      outPtr.value.asTypedListOutOfLine(len),
    );
    b._lib.freeBytes(outPtr.value, len);
    return copy;
  });
}

/// 在后台 isolate 里跑一整次扫描，按批交回结果。根不可扫时流以 [MusicScanRootError]
/// 结束；原生库缺失以 [FushiMusicUnavailableError] 结束（硬依赖，不吞）。取消订阅即停扫。
Stream<MusicScanBatch> scanMusicRoot(
  String root, {
  bool recursive = true,
  Map<String, ({int mtimeMs, int size})> known =
      const <String, ({int mtimeMs, int size})>{},
  int maxRecords = 0,
}) {
  late final StreamController<MusicScanBatch> controller;
  ReceivePort? port;
  Isolate? isolate;
  SendPort? control;

  Future<void> start() async {
    final ReceivePort rp = port = ReceivePort();
    final ReceivePort errors = ReceivePort();
    rp.listen((Object? message) {
      if (message is SendPort) {
        control = message;
        message.send(true); // 要第一批
        return;
      }
      if (message is TransferableTypedData) {
        final MusicScanBatch batch = decodeMusicScanBatch(
          message.materialize().asUint8List(),
        );
        controller.add(batch);
        if (batch.done) {
          controller.close();
          rp.close();
          errors.close();
        } else if (!controller.isPaused) {
          control?.send(true);
        }
        return;
      }
      if (message is List && message.length == 2) {
        // 原样转发后台 isolate 的异常（类型化的部署 / 根错误在那边已转成字符串 + 类别）。
        final String kind = message[0] as String;
        final String text = message[1] as String;
        controller.addError(switch (kind) {
          'unavailable' => FushiMusicUnavailableError(text),
          'root' => MusicScanRootError(root, int.parse(text)),
          _ => StateError(text),
        });
        controller.close();
        rp.close();
        errors.close();
      }
    });
    errors.listen((Object? e) {
      if (controller.isClosed) return;
      controller.addError(StateError('music scan isolate crashed: $e'));
      controller.close();
      rp.close();
      errors.close();
    });
    isolate = await Isolate.spawn<_ScanRequest>(
      _scanIsolateMain,
      _ScanRequest(rp.sendPort, root, recursive, known, maxRecords),
      onError: errors.sendPort,
    );
  }

  controller = StreamController<MusicScanBatch>(
    onListen: () => unawaited(start()),
    onResume: () => control?.send(true),
    onCancel: () {
      control?.send(false);
      port?.close();
      isolate?.kill(priority: Isolate.beforeNextEvent);
    },
  );
  return controller.stream;
}

final class _ScanRequest {
  const _ScanRequest(
    this.reply,
    this.root,
    this.recursive,
    this.known,
    this.maxRecords,
  );

  final SendPort reply;
  final String root;
  final bool recursive;
  final Map<String, ({int mtimeMs, int size})> known;
  final int maxRecords;
}

Future<void> _scanIsolateMain(_ScanRequest req) async {
  final ReceivePort control = ReceivePort();
  MusicScanSession? session;
  try {
    session = MusicScanSession.open(
      req.root,
      recursive: req.recursive,
      known: req.known,
    );
  } on FushiMusicUnavailableError catch (e) {
    req.reply.send(<String>['unavailable', e.toString()]);
    control.close();
    return;
  } on MusicScanRootError catch (e) {
    req.reply.send(<String>['root', '${e.status}']);
    control.close();
    return;
  }
  req.reply.send(control.sendPort);
  // 按需拉：主 isolate 每消费一批要下一批，暂停的订阅不会被灌满。
  await for (final Object? msg in control) {
    if (msg != true) break;
    final Uint8List bytes = session.nextBytes(maxRecords: req.maxRecords);
    final bool done = decodeMusicScanBatchDone(bytes);
    req.reply.send(TransferableTypedData.fromList(<TypedData>[bytes]));
    if (done) break;
  }
  session.close();
  control.close();
}

/// 只读批头的 done 标志（后台 isolate 不必整批解码）。
bool decodeMusicScanBatchDone(Uint8List bytes) {
  if (bytes.length < 5) throw const MusicScanWireError('truncated batch head');
  return bytes[4] != 0;
}

typedef _RemoteOpenC =
    Int32 Function(Pointer<Uint8>, Size, Pointer<Pointer<Void>>);
typedef _RemoteOpenDart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Void>>);
typedef _RemoteFeedC =
    Int32 Function(Pointer<Void>, Int64, Pointer<Uint8>, Size);
typedef _RemoteFeedDart = int Function(Pointer<Void>, int, Pointer<Uint8>, int);

class _RemoteBindings {
  _RemoteBindings(FushiMusic lib) : _lib = lib {
    try {
      open = lib.library.lookupFunction<_RemoteOpenC, _RemoteOpenDart>(
        'ffm_remote_scan_open',
      );
      setKnown = lib.library.lookupFunction<_SetKnownC, _SetKnownDart>(
        'ffm_remote_scan_set_known',
      );
      step = lib.library.lookupFunction<_NextC, _NextDart>(
        'ffm_remote_scan_step',
      );
      feed = lib.library.lookupFunction<_RemoteFeedC, _RemoteFeedDart>(
        'ffm_remote_scan_feed',
      );
      close = lib.library.lookupFunction<_CloseC, _CloseDart>(
        'ffm_remote_scan_close',
      );
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('remote scan', e);
    }
  }

  final FushiMusic _lib;
  late final _RemoteOpenDart open;
  late final _SetKnownDart setKnown;
  late final _NextDart step;
  late final _RemoteFeedDart feed;
  late final _CloseDart close;

  static _RemoteBindings? _instance;
  static _RemoteBindings get instance =>
      _instance ??= _RemoteBindings(FushiMusic.instance);
}

/// 远程曲库扫描的同步会话（native/fushi_music `remote.rs`）：输入 Dart 列好的文件清单，
/// [step] 要么交回一批记录、要么交回「当前文件缺这几段字节」，调用方取回后 [feed] 再
/// [step]。**阻塞调用线程**（标签解析在 step 里）；UI isolate 一律用 [scanMusicListing]。
final class MusicRemoteScanSession {
  MusicRemoteScanSession._(this._b, this._handle);

  factory MusicRemoteScanSession.open(
    Uint8List listing, {
    Map<String, ({int mtimeMs, int size})> known =
        const <String, ({int mtimeMs, int size})>{},
  }) {
    final _RemoteBindings b = _RemoteBindings.instance;
    return using((Arena arena) {
      final Pointer<Pointer<Void>> out = arena<Pointer<Void>>();
      final int rc = b.open(_copyIn(listing, arena), listing.length, out);
      if (rc != FfmStatus.ok) {
        throw StateError('ffm_remote_scan_open failed with status $rc');
      }
      final MusicRemoteScanSession session = MusicRemoteScanSession._(
        b,
        out.value,
      );
      if (known.isNotEmpty) {
        final Uint8List knownBytes = encodeMusicKnownFiles(known);
        final int krc = b.setKnown(
          session._handle,
          _copyIn(knownBytes, arena),
          knownBytes.length,
        );
        if (krc != FfmStatus.ok) {
          session.close();
          throw StateError('ffm_remote_scan_set_known failed with status $krc');
        }
      }
      return session;
    });
  }

  final _RemoteBindings _b;
  Pointer<Void> _handle;

  Uint8List stepBytes({int maxRecords = 0}) {
    if (_handle == nullptr) {
      throw StateError('MusicRemoteScanSession is closed');
    }
    return using((Arena arena) {
      final Pointer<Pointer<Uint8>> outPtr = arena<Pointer<Uint8>>();
      final Pointer<Size> outLen = arena<Size>();
      final int rc = _b.step(_handle, maxRecords, outPtr, outLen);
      if (rc != FfmStatus.ok) {
        throw StateError('ffm_remote_scan_step failed with status $rc');
      }
      final int len = outLen.value;
      final Uint8List copy = Uint8List.fromList(
        outPtr.value.asTypedListOutOfLine(len),
      );
      _b._lib.freeBytes(outPtr.value, len);
      return copy;
    });
  }

  MusicRemoteStep step({int maxRecords = 0}) =>
      decodeMusicRemoteStep(stepBytes(maxRecords: maxRecords));

  /// 喂当前 NEED 文件从 [offset] 起的字节（交回空 = 取不到，下一步该文件记错误跳过）。
  void feed(int offset, Uint8List bytes) {
    if (_handle == nullptr) {
      throw StateError('MusicRemoteScanSession is closed');
    }
    using((Arena arena) {
      final int rc = _b.feed(
        _handle,
        offset,
        _copyIn(bytes, arena),
        bytes.length,
      );
      if (rc != FfmStatus.ok) {
        throw StateError('ffm_remote_scan_feed failed with status $rc');
      }
    });
  }

  void close() {
    if (_handle == nullptr) return;
    _b.close(_handle);
    _handle = nullptr;
  }
}

/// 远程扫描按区间取字节（真 app = 来源访问层的 HTTP Range / SFTP 偏移读）。交回的字节
/// 可以比 [length] 短（到了文件尾）；取不到就抛——整次扫描以该异常结束，调用方不据此
/// 对账删除（断网时不把整个来源的曲目当成「消失」软删）。
typedef MusicRangeFetcher =
    Future<Uint8List> Function(String path, int offset, int length);

/// 在后台 isolate 里跑一整次远程扫描（标签解析不占 UI isolate），按批交回结果。原生库
/// 缺失以 [FushiMusicUnavailableError] 结束；[fetch] 抛错以该错误结束。取消订阅即停扫。
Stream<MusicScanBatch> scanMusicListing({
  required String root,
  required List<MusicListedFile> files,
  required Map<String, Uint8List> cueBytes,
  required MusicRangeFetcher fetch,
  Map<String, ({int mtimeMs, int size})> known =
      const <String, ({int mtimeMs, int size})>{},
  int maxRecords = 0,
}) {
  late final StreamController<MusicScanBatch> controller;
  ReceivePort? port;
  ReceivePort? errors;
  Isolate? isolate;
  SendPort? control;
  bool closed = false;

  void finish() {
    if (closed) return;
    closed = true;
    port?.close();
    errors?.close();
    controller.close();
  }

  Future<void> serveNeed(
    String path,
    List<int> offsets,
    List<int> lengths,
  ) async {
    final List<int> outOffsets = <int>[];
    final List<TransferableTypedData> datas = <TransferableTypedData>[];
    try {
      for (int i = 0; i < offsets.length; i++) {
        final Uint8List data = await fetch(path, offsets[i], lengths[i]);
        outOffsets.add(offsets[i]);
        datas.add(TransferableTypedData.fromList(<TypedData>[data]));
      }
    } catch (e, st) {
      if (closed) return;
      controller.addError(e, st);
      control?.send(false);
      isolate?.kill(priority: Isolate.beforeNextEvent);
      finish();
      return;
    }
    if (closed) return;
    control?.send(<Object>[outOffsets, datas]);
  }

  Future<void> start() async {
    final ReceivePort rp = port = ReceivePort();
    final ReceivePort errs = errors = ReceivePort();
    rp.listen((Object? message) {
      if (message is SendPort) {
        control = message;
        message.send(true);
        return;
      }
      if (message is TransferableTypedData) {
        final MusicScanBatch batch = decodeMusicScanBatch(
          message.materialize().asUint8List(),
        );
        controller.add(batch);
        if (batch.done) {
          finish();
        } else if (!controller.isPaused) {
          control?.send(true);
        }
        return;
      }
      if (message is List && message.length == 4 && message[0] == 'need') {
        unawaited(
          serveNeed(
            message[1] as String,
            (message[2] as List<Object?>).cast<int>(),
            (message[3] as List<Object?>).cast<int>(),
          ),
        );
        return;
      }
      if (message is List && message.length == 2) {
        final String kind = message[0] as String;
        final String text = message[1] as String;
        controller.addError(switch (kind) {
          'unavailable' => FushiMusicUnavailableError(text),
          _ => StateError(text),
        });
        finish();
      }
    });
    errs.listen((Object? e) {
      if (closed) return;
      controller.addError(StateError('music remote scan isolate crashed: $e'));
      finish();
    });
    isolate = await Isolate.spawn<_RemoteScanRequest>(
      _remoteScanIsolateMain,
      _RemoteScanRequest(
        rp.sendPort,
        TransferableTypedData.fromList(<TypedData>[
          encodeMusicListing(root: root, files: files, cueBytes: cueBytes),
        ]),
        known,
        maxRecords,
      ),
      onError: errs.sendPort,
    );
  }

  controller = StreamController<MusicScanBatch>(
    onListen: () => unawaited(start()),
    onResume: () => control?.send(true),
    onCancel: () {
      control?.send(false);
      closed = true;
      port?.close();
      errors?.close();
      isolate?.kill(priority: Isolate.beforeNextEvent);
    },
  );
  return controller.stream;
}

final class _RemoteScanRequest {
  const _RemoteScanRequest(
    this.reply,
    this.listing,
    this.known,
    this.maxRecords,
  );

  final SendPort reply;
  final TransferableTypedData listing;
  final Map<String, ({int mtimeMs, int size})> known;
  final int maxRecords;
}

Future<void> _remoteScanIsolateMain(_RemoteScanRequest req) async {
  final ReceivePort control = ReceivePort();
  MusicRemoteScanSession? session;
  try {
    session = MusicRemoteScanSession.open(
      req.listing.materialize().asUint8List(),
      known: req.known,
    );
  } on FushiMusicUnavailableError catch (e) {
    req.reply.send(<String>['unavailable', e.toString()]);
    control.close();
    return;
  } on Object catch (e) {
    req.reply.send(<String>['error', e.toString()]);
    control.close();
    return;
  }
  req.reply.send(control.sendPort);
  // 主 isolate 发 true = 往下走一步；发 [offsets, datas] = 喂完 NEED 的字节再走一步。
  await for (final Object? msg in control) {
    if (msg is List && msg.length == 2) {
      final List<Object?> offsets = msg[0] as List<Object?>;
      final List<Object?> datas = msg[1] as List<Object?>;
      for (int i = 0; i < offsets.length; i++) {
        session.feed(
          offsets[i]! as int,
          (datas[i]! as TransferableTypedData).materialize().asUint8List(),
        );
      }
    } else if (msg != true) {
      break;
    }
    final MusicRemoteStep step = session.step(maxRecords: req.maxRecords);
    switch (step) {
      case MusicRemoteNeed(:final String path, :final ranges):
        req.reply.send(<Object>[
          'need',
          path,
          <int>[for (final ({int offset, int length}) r in ranges) r.offset],
          <int>[for (final ({int offset, int length}) r in ranges) r.length],
        ]);
      case MusicRemoteBatch(:final Uint8List bytes):
        final bool done = decodeMusicScanBatchDone(bytes);
        req.reply.send(TransferableTypedData.fromList(<TypedData>[bytes]));
        if (done) {
          session.close();
          control.close();
          return;
        }
    }
  }
  session.close();
  control.close();
}
