/// `--json` 模式的 stdout 隔离：进程级 stdout 只留给最终那一个 JSON 文档。
///
/// 为什么不能只靠「诊断都写 stderr」：引擎里大量计算跑在 `Isolate.run` 起的后台
/// isolate 里（有声书对齐的 `EpubSrtMatcher.matchInIsolate` / `probeInIsolate`、
/// OCR、字幕对时间轴 …），**根 isolate 的全局装配点一个都带不过 isolate 边界**——
/// 后台 isolate 里的 `fushiDebugPrint` 是 fushi_core 的缺省实现 `print`，直接写
/// fd 1。`audiobook align … --json` 的 stdout 因此混进几行 `[sentenceAudioHighlight]
/// matcher …`，`jq` 解析失败。原生库（词典导入器等）自己 `printf` 也是同一个 fd。
///
/// 所以在 CLI 这一层整体处理，而不是逐个静音：
/// - 把 fd 1 `dup2` 到 fd 2：任何 isolate 的 `print`、原生 `printf`、根 isolate 的
///   `print` 都落到 stderr；
/// - 根 isolate 的 `stdout`（`dart:io` 的 getter）经 [IOOverrides] 换成写在**原 fd 1
///   副本**上的 [Stdout]：命令模块照旧 `stdout.writeln(jsonEncode(…))` /
///   `CommandIo.json`，结果仍进真正的 stdout。
///
/// 仅 Linux / macOS 生效（libc `dup` / `dup2` / `write`）。Windows 的 Dart VM 静态
/// 链接 CRT，外部 `_dup2` 改不到它的 fd 1，这里退化为不隔离（与改动前同行为）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';

typedef _DupNative = Int32 Function(Int32 fd);
typedef _DupDart = int Function(int fd);
typedef _Dup2Native = Int32 Function(Int32 from, Int32 to);
typedef _Dup2Dart = int Function(int from, int to);
typedef _CloseNative = Int32 Function(Int32 fd);
typedef _CloseDart = int Function(int fd);

/// libc `write(2)`。用 `@Native` 叶子调用是为了直接传 `Uint8List.address`（免一次
/// 堆拷贝，也不用拉 package:ffi 的 malloc）；符号回落到进程里查找，只在 POSIX 上调。
@Native<IntPtr Function(Int32, Pointer<Uint8>, IntPtr)>(symbol: 'write', isLeaf: true)
external int _posixWrite(int fd, Pointer<Uint8> buf, int count);

/// 这次调用的命令链（`audiobook` → `align` …）里有没有哪一层要了 `--json`。
bool commandChainWantsJson(ArgResults results) {
  ArgResults? level = results;
  while (level != null) {
    if (level.options.contains('json') && level['json'] == true) return true;
    level = level.command;
  }
  return false;
}

class _Libc {
  _Libc._(this.dup, this.dup2, this.close);

  final _DupDart dup;
  final _Dup2Dart dup2;
  final _CloseDart close;

  static _Libc? open() {
    if (!Platform.isLinux && !Platform.isMacOS) return null;
    try {
      final DynamicLibrary lib = DynamicLibrary.process();
      return _Libc._(
        lib.lookupFunction<_DupNative, _DupDart>('dup'),
        lib.lookupFunction<_Dup2Native, _Dup2Dart>('dup2'),
        lib.lookupFunction<_CloseNative, _CloseDart>('close'),
      );
    } on ArgumentError {
      return null;
    }
  }
}

/// 在 stdout 隔离下跑 [body]（见库注释）。平台不支持或 `dup` 失败时直接跑 [body]。
///
/// 结束时把 fd 1 还原（进程内多次调用 CLI——测试——不能把 stdout 永久改道）。
Future<T> runWithJsonStdoutIsolation<T>(Future<T> Function() body) async {
  final _Libc? libc = _Libc.open();
  if (libc == null) return body();
  final int saved = libc.dup(1);
  if (saved < 0) return body();
  if (libc.dup2(2, 1) < 0) {
    libc.close(saved);
    return body();
  }
  // 调用方已经用 IOOverrides 接管了 stdout（测试捕获输出）：结果照旧写给它；
  // 否则写到原 fd 1 的副本。根 zone 里取到的才是进程真正的 stdout。
  final Stdout current = stdout;
  final Stdout sink = identical(current, Zone.root.run(() => stdout)) ? _FdStdout(saved, current) : current;
  try {
    return await IOOverrides.runZoned<Future<T>>(body, stdout: () => sink);
  } finally {
    libc.dup2(saved, 1);
    libc.close(saved);
  }
}

/// 同步写在 [_fd] 上的 [Stdout]：每次 write 立刻落到 fd（无缓冲、无异步排队），
/// 进程退出前不存在「JSON 还没刷出去」的窗口。
class _FdStdout implements Stdout {
  _FdStdout(this._fd, this._original);

  final int _fd;
  final Stdout _original;

  @override
  Encoding encoding = utf8;

  @override
  String lineTerminator = '\n';

  @override
  bool get hasTerminal => _original.hasTerminal;

  @override
  int get terminalColumns => _original.terminalColumns;

  @override
  int get terminalLines => _original.terminalLines;

  @override
  bool get supportsAnsiEscapes => _original.supportsAnsiEscapes;

  @override
  IOSink get nonBlocking => this;

  @override
  void add(List<int> data) {
    final Uint8List bytes = data is Uint8List ? data : Uint8List.fromList(data);
    int offset = 0;
    while (offset < bytes.length) {
      final Uint8List rest = Uint8List.sublistView(bytes, offset);
      final int n = _posixWrite(_fd, rest.address, rest.length);
      if (n < 0) throw const StdoutException('写 stdout 失败');
      offset += n;
    }
  }

  @override
  void write(Object? object) {
    final String text = object.toString();
    if (text.isNotEmpty) add(encoding.encode(text));
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write(lineTerminator);
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      Error.throwWithStackTrace(error, stackTrace ?? StackTrace.current);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final List<int> chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}
}
