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
