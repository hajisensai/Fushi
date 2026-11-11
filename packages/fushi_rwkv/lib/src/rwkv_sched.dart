import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'fushi_rwkv_library.dart';
import 'rwkv_native.dart';

/// 排程内核（native/fushi_rwkv 的 `sched` 模块）消息通道上的编号。布局的唯一说明在
/// `native/fushi_rwkv/src/sched/mod.rs` 的模块注释；这里只是同一组数字。
abstract final class RwkvSchedWire {
  // 输入消息的种类。
  static const int inCommand = 1;
  static const int inReply = 2;
  static const int inProgress = 3;
  static const int inTimer = 4;

  // 命令。
  static const int cmdStart = 1;
  static const int cmdRebuild = 2;
  static const int cmdRefresh = 3;
  static const int cmdInstant = 4;
  static const int cmdCurrent = 5;
  static const int cmdAnswered = 6;
  static const int cmdPurged = 7;
  static const int cmdClose = 8;

  // 输出记录。
  static const int outStatus = 1;
  static const int outDone = 2;
  static const int outEffect = 3;
  static const int outLog = 4;
  static const int outOpBegin = 5;
  static const int outOpEnd = 6;
  static const int outTimer = 7;
  static const int outCancel = 8;

  // effect（内核让宿主取的数 / 办的事）。
  static const int fxRevision = 1;
  static const int fxTail = 2;
  static const int fxReplay = 3;
  static const int fxAppendRows = 4;
  static const int fxScoreInputs = 5;
  static const int fxQueryRows = 6;
  static const int fxIngesting = 7;
  static const int fxIngestSettled = 8;
  static const int fxDayIndex = 9;
  static const int fxModelReady = 10;
  static const int fxDownload = 11;
  static const int fxDeleteRetired = 12;
  static const int fxRebuildHook = 13;
  static const int fxOpenBackend = 14;
  static const int fxBackend = 15;

  // 宿主后端模式下的后端调用。
  static const int bkReplay = 1;
  static const int bkAppend = 2;
  static const int bkUnappend = 3;
  static const int bkRewind = 4;
  static const int bkQuery = 5;
  static const int bkClearScores = 6;
  static const int bkLookupScores = 7;
  static const int bkUpdateScores = 8;
  static const int bkRequeryScores = 9;
  static const int bkRemoveScores = 10;
  static const int bkSnapshotToFile = 11;
  static const int bkRestoreFromFile = 12;
  static const int bkReset = 13;
  static const int bkClose = 14;

  // 日志尾巴里一条日志的种类。
  static const int logOther = 0;
  static const int logReview = 1;
  static const int logUndo = 2;
}

/// 写一条消息（小端；`str` / `bytes` = u32 长度 + 内容，`T[]` = u32 个数 + 元素，`opt T` = u8 有无 + T）。
final class RwkvSchedWriter {
  RwkvSchedWriter([int capacity = 64])
    : _bytes = Uint8List(capacity < 16 ? 16 : capacity) {
    _data = ByteData.sublistView(_bytes);
  }

  Uint8List _bytes;
  late ByteData _data;
  int _length = 0;

  int get length => _length;

  void _reserve(int more) {
    final int need = _length + more;
    if (need <= _bytes.length) return;
    int capacity = _bytes.length * 2;
    while (capacity < need) {
      capacity *= 2;
    }
    final Uint8List grown = Uint8List(capacity)..setRange(0, _length, _bytes);
    _bytes = grown;
    _data = ByteData.sublistView(grown);
  }

  void u8(int value) {
    _reserve(1);
    _bytes[_length++] = value;
  }

  void boolean(bool value) => u8(value ? 1 : 0);

  void u32(int value) {
    _reserve(4);
    _data.setUint32(_length, value, Endian.little);
    _length += 4;
  }

  void i64(int value) {
    _reserve(8);
    _data.setInt64(_length, value, Endian.little);
    _length += 8;
  }

  /// 无符号 64 位，按位写（Dart 的 int 只有有符号 64 位）。
  void u64(int value) => i64(value);

  void f32(double value) {
    _reserve(4);
    _data.setFloat32(_length, value, Endian.little);
    _length += 4;
  }

  void optI64(int? value) {
    boolean(value != null);
    if (value != null) i64(value);
  }

  void raw(Uint8List value) {
    _reserve(value.length);
    _bytes.setRange(_length, _length + value.length, value);
    _length += value.length;
  }

  void bytes(Uint8List value) {
    u32(value.length);
    raw(value);
  }

  void str(String value) => bytes(utf8.encode(value));

  void optStr(String? value) {
    boolean(value != null);
    if (value != null) str(value);
  }

  void i64s(List<int> values) {
    u32(values.length);
    _reserve(8 * values.length);
    for (final int value in values) {
      _data.setInt64(_length, value, Endian.little);
      _length += 8;
    }
  }

  void u64s(List<int> values) => i64s(values);

  void f32s(List<double> values) {
    u32(values.length);
    _reserve(4 * values.length);
    for (final double value in values) {
      _data.setFloat32(_length, value, Endian.little);
      _length += 4;
    }
  }

  /// 写好的字节（视图，不复制；之后别再往这个 writer 里写）。
  Uint8List take() => Uint8List.sublistView(_bytes, 0, _length);
}

/// 读一段消息；越界抛 [FormatException]。
final class RwkvSchedReader {
  RwkvSchedReader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int _at = 0;

  bool get isDone => _at >= _bytes.length;

  int _advance(int size) {
    final int at = _at;
    if (size < 0 || at + size > _bytes.length) {
      throw FormatException(
        'RWKV sched message truncated at $at (+$size of ${_bytes.length})',
      );
    }
    _at = at + size;
    return at;
  }

  int u8() => _bytes[_advance(1)];

  bool boolean() => u8() != 0;

  int u32() => _data.getUint32(_advance(4), Endian.little);

  int i64() => _data.getInt64(_advance(8), Endian.little);

  /// 无符号 64 位的位模式（Dart 的 int 只有有符号 64 位）。
  int u64() => i64();

  double f32() => _data.getFloat32(_advance(4), Endian.little);

  int? optI64() => boolean() ? i64() : null;

  /// 一段带长度的字节（原缓冲上的视图）。
  Uint8List bytes() {
    final int length = u32();
    final int at = _advance(length);
    return Uint8List.sublistView(_bytes, at, at + length);
  }

  /// 之后固定 [length] 个字节（原缓冲上的视图）。
  Uint8List raw(int length) {
    final int at = _advance(length);
    return Uint8List.sublistView(_bytes, at, at + length);
  }

  String str() => utf8.decode(bytes());

  String? optStr() => boolean() ? str() : null;

  Int64List i64s() {
    final int n = u32();
    final int at = _advance(8 * n);
    final Int64List out = Int64List(n);
    for (int i = 0; i < n; i++) {
      out[i] = _data.getInt64(at + 8 * i, Endian.little);
    }
    return out;
  }

  Uint64List u64s() {
    final int n = u32();
    final int at = _advance(8 * n);
    final Uint64List out = Uint64List(n);
    for (int i = 0; i < n; i++) {
      out[i] = _data.getUint64(at + 8 * i, Endian.little);
    }
    return out;
  }

  Uint32List u32s() {
    final int n = u32();
    final int at = _advance(4 * n);
    final Uint32List out = Uint32List(n);
    for (int i = 0; i < n; i++) {
      out[i] = _data.getUint32(at + 4 * i, Endian.little);
    }
    return out;
  }

  Float32List f32s() {
    final int n = u32();
    final int at = _advance(4 * n);
    final Float32List out = Float32List(n);
    for (int i = 0; i < n; i++) {
      out[i] = _data.getFloat32(at + 4 * i, Endian.little);
    }
    return out;
  }
}

/// 内核一段输出里的一条记录。
typedef RwkvSchedRecord = ({int tag, Uint8List body});

/// 把一段输出（[RwkvSchedWorker.outputs] 的一个元素）拆成记录。
Iterable<RwkvSchedRecord> rwkvSchedRecords(Uint8List output) sync* {
  final RwkvSchedReader reader = RwkvSchedReader(output);
  while (!reader.isDone) {
    final int tag = reader.u8();
    yield (tag: tag, body: reader.bytes());
  }
}

/// 排程内核的配置（`frwkv_sched_new` 的入参）。
Uint8List rwkvSchedConfig({
  required String profile,
  required String snapshotDir,
  required int threads,
  required int journalSeed,
  required Duration requeryAfter,
  required bool hostBackend,
  required Duration snapshotIdle,
  required Duration retryAfter,
}) {
  final RwkvSchedWriter w = RwkvSchedWriter()
    ..str(profile)
    ..str(snapshotDir)
    ..u32(threads)
    ..i64(journalSeed)
    ..i64(requeryAfter.inMilliseconds)
    ..boolean(hostBackend)
    ..i64(snapshotIdle.inMilliseconds)
    ..i64(retryAfter.inMilliseconds);
  return w.take();
}

typedef _AllocC = Pointer<Uint8> Function(Size);
typedef _AllocDart = Pointer<Uint8> Function(int);
typedef _NewC = Pointer<Void> Function(Pointer<Uint8>, Size);
typedef _NewDart = Pointer<Void> Function(Pointer<Uint8>, int);
typedef _StepC =
    Pointer<Uint8> Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Size>);
typedef _StepDart =
    Pointer<Uint8> Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Size>);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _FreeBytesC = Void Function(Pointer<Uint8>, Size);
typedef _FreeBytesDart = void Function(Pointer<Uint8>, int);
typedef _LastErrorC = Pointer<Utf8> Function();
typedef _FreeStringC = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);

class _Bindings {
  _Bindings(DynamicLibrary lib)
    : alloc = lib.lookupFunction<_AllocC, _AllocDart>('frwkv_sched_alloc'),
      create = lib.lookupFunction<_NewC, _NewDart>('frwkv_sched_new'),
      step = lib.lookupFunction<_StepC, _StepDart>('frwkv_sched_step'),
      free = lib.lookupFunction<_FreeC, _FreeDart>('frwkv_sched_free'),
      freeBytes = lib.lookupFunction<_FreeBytesC, _FreeBytesDart>(
        'frwkv_free_bytes',
      ),
      lastError = lib.lookupFunction<_LastErrorC, _LastErrorC>(
        'frwkv_last_error',
      ),
      freeString = lib.lookupFunction<_FreeStringC, _FreeStringDart>(
        'frwkv_free_string',
      );

  final _AllocDart alloc;
  final _NewDart create;
  final _StepDart step;
  final _FreeDart free;
  final _FreeBytesDart freeBytes;
  final Pointer<Utf8> Function() lastError;
  final _FreeStringDart freeString;

  /// 调用失败后**紧接着**（同一段同步代码）取线程局部的错误文本。
  String error(String fallback) {
    final Pointer<Utf8> text = lastError();
    if (text == nullptr) return fallback;
    final String message = text.toDartString();
    freeString(text);
    return message;
  }
}

/// 常驻后台 isolate，独占一个排程内核（`frwkv_sched_*`）。
///
/// 内核里的回放要几秒到几十秒，又不是线程安全的，所以它只活在这个 isolate 里。主 isolate 把一条条
/// 输入消息写进原生内存（[send]，内核接管那块内存——大块的回放行因此只复制一次），后台 isolate 逐条
/// 喂给内核、把每段输出发回来（[outputs]）。消息的含义见 [RwkvSchedWire]。
class RwkvSchedWorker {
  RwkvSchedWorker._(this._isolate, this._inputs, this._bindings);

  /// 启动 worker 并建内核。[config] 来自 [rwkvSchedConfig]；[libraryPath] 为 null 走默认定位规则。
  /// 库加载失败抛 [FushiRwkvUnavailableError]，内核建不起来抛 [RwkvNativeException]。
  static Future<RwkvSchedWorker> spawn({
    required Uint8List config,
    String? libraryPath,
  }) async {
    final FushiRwkv library = libraryPath == null
        ? FushiRwkv.instance
        : FushiRwkv.load(libraryPath: libraryPath);
    final _Bindings bindings = _Bindings(library.library);
    final ReceivePort responses = ReceivePort('fushi-rwkv-sched');
    final Isolate isolate = await Isolate.spawn<_Boot>(
      _main,
      _Boot(responses.sendPort, library.libraryPath, config),
      debugName: 'fushi-rwkv-sched',
      errorsAreFatal: false,
    );
    final StreamIterator<Object?> first = StreamIterator<Object?>(responses);
    await first.moveNext();
    final Object? hello = first.current;
    if (hello is! SendPort) {
      responses.close();
      isolate.kill(priority: Isolate.immediate);
      throw (hello! as _Failure).rebuild();
    }
    final RwkvSchedWorker worker = RwkvSchedWorker._(isolate, hello, bindings);
    unawaited(worker._pump(first, responses));
    return worker;
  }

  final Isolate _isolate;
  final SendPort _inputs;
  final _Bindings _bindings;
  final StreamController<Uint8List> _outputs = StreamController<Uint8List>();
  final Completer<void> _stopped = Completer<void>();
  bool _closed = false;

  /// 内核的输出，一段一个元素（若干条记录，用 [rwkvSchedRecords] 拆）。内核报错（消息不合布局 /
  /// panic 过）时出一个 [RwkvNativeException] 错误；worker 停下后流结束。
  Stream<Uint8List> get outputs => _outputs.stream;

  Future<void> _pump(
    StreamIterator<Object?> responses,
    ReceivePort port,
  ) async {
    while (await responses.moveNext()) {
      final Object? message = responses.current;
      if (message == null) break;
      if (message is _Failure) {
        _outputs.addError(message.rebuild());
        continue;
      }
      final Uint8List output = (message as TransferableTypedData)
          .materialize()
          .asUint8List();
      // 第一个字节（还要不要立刻再调）后台 isolate 已经处理了。
      if (output.length > 1) _outputs.add(Uint8List.sublistView(output, 1));
    }
    port.close();
    _closed = true;
    if (!_stopped.isCompleted) _stopped.complete();
    await _outputs.close();
  }

  /// 递一条输入消息：[parts] 依次拼成一条（分段传是为了大块正文不必先在 Dart 里拼一遍）。
  /// worker 已停时什么都不做。
  void send(List<Uint8List> parts) {
    if (_closed) return;
    int length = 0;
    for (final Uint8List part in parts) {
      length += part.length;
    }
    if (length == 0) return;
    final Pointer<Uint8> memory = _bindings.alloc(length);
    if (memory == nullptr) {
      throw RwkvNativeException(
        -4,
        _bindings.error('frwkv_sched_alloc($length) failed'),
      );
    }
    final Uint8List view = memory.asTypedListOutOfLine(length);
    int at = 0;
    for (final Uint8List part in parts) {
      view.setRange(at, at + part.length, part);
      at += part.length;
    }
    _inputs.send((memory.address, length));
  }

  /// 停掉 worker 并释放内核（先让内核处理完已递进去的消息）。之后 [outputs] 结束。
  Future<void> dispose() async {
    if (!_closed) {
      _closed = true;
      _inputs.send(null);
    }
    await _stopped.future;
    _isolate.kill(priority: Isolate.immediate);
  }
}

class _Boot {
  const _Boot(this.reply, this.libraryPath, this.config);
  final SendPort reply;
  final String? libraryPath;
  final Uint8List config;
}

/// 跨 isolate 传回的错误（异常对象本身不一定能发送）。
class _Failure {
  const _Failure(this.unavailable, this.message);

  factory _Failure.of(Object error) => _Failure(
    error is FushiRwkvUnavailableError,
    error is RwkvNativeException ? error.message : error.toString(),
  );

  final bool unavailable;
  final String message;

  Object rebuild() => unavailable
      ? FushiRwkvUnavailableError(message)
      : RwkvNativeException(-4, message);
}

Future<void> _main(_Boot boot) async {
  final _Bindings bindings;
  final Pointer<Void> sched;
  try {
    final FushiRwkv library = boot.libraryPath == null
        ? FushiRwkv.instance
        : FushiRwkv.load(libraryPath: boot.libraryPath);
    bindings = _Bindings(library.library);
    final int length = boot.config.length;
    final Pointer<Uint8> config = malloc<Uint8>(length == 0 ? 1 : length);
    try {
      config.asTypedListOutOfLine(length).setAll(0, boot.config);
      sched = bindings.create(config, length);
      if (sched == nullptr) {
        throw RwkvNativeException(-1, bindings.error('frwkv_sched_new failed'));
      }
    } finally {
      malloc.free(config);
    }
  } catch (error) {
    boot.reply.send(_Failure.of(error));
    return;
  }
  final ReceivePort inputs = ReceivePort();
  boot.reply.send(inputs.sendPort);
  final Pointer<Size> outLength = malloc<Size>();
  await for (final Object? message in inputs) {
    if (message == null) break;
    final (int address, int length) = message as (int, int);
    Pointer<Uint8> input = Pointer<Uint8>.fromAddress(address);
    int inputLength = length;
    // 输出第一个字节非 0 = 内核刚把「开始」之类的记录交出来、还有活要干：先把这段发走，再用空消息接着跑。
    while (true) {
      final Pointer<Uint8> out = bindings.step(
        sched,
        input,
        inputLength,
        outLength,
      );
      if (out == nullptr) {
        boot.reply.send(
          _Failure(false, bindings.error('frwkv_sched_step failed')),
        );
        break;
      }
      final int n = outLength.value;
      final bool more = n > 0 && out[0] != 0;
      final TransferableTypedData output = TransferableTypedData.fromList(
        <Uint8List>[out.asTypedListOutOfLine(n)],
      );
      bindings.freeBytes(out, n);
      boot.reply.send(output);
      if (!more) break;
      input = nullptr;
      inputLength = 0;
    }
  }
  inputs.close();
  bindings.free(sched);
  malloc.free(outLength);
  boot.reply.send(null);
}
