import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:fushi/src/utils/misc/download_plan.dart';
import 'package:fushi/src/utils/misc/resumable_downloader.dart';

/// 打开一次请求。与 [ResumableDownloadOpen] 同形（复用 [ResumableDownloadResponse]），
/// 让单流与分片两条路共享同一套注入点和测试替身。
typedef SegmentedDownloadOpen = ResumableDownloadOpen;

/// 已收字节 / 总字节。
typedef SegmentedDownloadProgress = void Function(int received, int total);

/// 用户主动取消。与真实失败区分开：取消不重试、不删半截（下次可续）。
class SegmentedDownloadCancelledException implements Exception {
  const SegmentedDownloadCancelledException();
  @override
  String toString() => 'SegmentedDownloadCancelledException';
}

/// 某一片把所有来源都试完仍拿不到。
class SegmentedDownloadPartException implements Exception {
  const SegmentedDownloadPartException(this.partIndex, this.cause);
  final int partIndex;
  final Object cause;
  @override
  String toString() =>
      'SegmentedDownloadPartException(片 #$partIndex 全部来源失败: $cause)';
}

/// 分片并发下载器：把 [DownloadPlan] 的每一片并发取回，按各自偏移写进**同一个**
/// 预分配的 `.part` 文件，全部完成并校验后原子改名为 [destination]。
///
/// ## 为什么不是「分卷压缩」
///
/// 分卷（`.zip.001`）下完必须再解出一个完整包才能导入，落地要 2× 磁盘——9.5 GB 的包
/// 在手机上就是 19 GB。按**字节**分片则是并发写进同一个目标文件，下完即是原封不动的
/// 原文件，消费端（备份导入）一行不用改，磁盘只要 1×。
///
/// ## 断点与换包
///
/// 每片的已收字节记在 [progressFile]，跨进程可续。服务端换包由两道闸拦住：进度文件
/// 记了计划的 `version`/`totalBytes`/`sha256`，对不上直接清空重来；续传请求还带
/// `If-Range`，服务器自己会把过期断点降级成 200（本类据此丢弃该片重下），不会拼出
/// 一个下完 9.5 GB 才在 sha256 上发现是坏的包。
///
/// ## 取够就断
///
/// 一片取到 [DownloadPart.length] 字节就跳出 `await for`（取消订阅断连），绝不把整包
/// 读完——否则一个忽略 Range 的服务器会让每一片都去下整个 9.5 GB。
class SegmentedDownloader {
  SegmentedDownloader({
    required this.plan,
    required this.destination,
    required this.partFile,
    required this.progressFile,
    required this.open,
    this.concurrency = kDefaultDownloadConcurrency,
    this.maxAttemptsPerPart = 3,
    this.onProgress,
    this.bodyTimeout,
    this.firstByteTimeout,
    this.isCancelled,
    this.flushInterval = kDefaultFlushInterval,
    this.retryBackoff,
  })  : assert(concurrency > 0, 'concurrency 必须为正'),
        assert(maxAttemptsPerPart > 0, 'maxAttemptsPerPart 必须为正');

  /// 并发段数默认值：国内下 CF 单连接常被限速，多连接叠加是主要提速手段；再大对
  /// 移动端内存/CDN 都不友好。
  static const int kDefaultDownloadConcurrency = 4;

  /// 每写满这么多字节就 flush 一次并落一次进度（崩溃最多丢这么多）。
  static const int kDefaultFlushInterval = 8 * 1024 * 1024;

  final DownloadPlan plan;
  final File destination;
  final File partFile;
  final File progressFile;
  final SegmentedDownloadOpen open;
  final int concurrency;
  final int maxAttemptsPerPart;
  final SegmentedDownloadProgress? onProgress;

  /// 两个数据块之间的最大间隔（不是整片总时长）。
  final Duration? bodyTimeout;

  /// 首字节（连接 + 响应头）预算。
  final Duration? firstByteTimeout;

  /// 取消判定；返回 true 时正在跑的片尽快退出，半截保留供下次续传。
  final bool Function()? isCancelled;

  final int flushInterval;

  /// 第 [attempt] 次失败后等多久再试下一个来源。默认指数退避（1s / 2s / 4s…，
  /// 上限 30s）：移动网络抖动时背靠背重试三次基本是三次一起失败，退避才有意义。
  /// 单测注入 [Duration.zero] 免得空等。
  final Duration Function(int attempt)? retryBackoff;

  static Duration _defaultBackoff(int attempt) {
    final int seconds = 1 << (attempt > 4 ? 4 : attempt);
    return Duration(seconds: seconds > 30 ? 30 : seconds);
  }

  late RandomAccessFile _raf;
  final _AsyncLock _ioLock = _AsyncLock();
  late _ProgressStore _store;
  int _receivedTotal = 0;

  /// 服务端校验子（ETag / Last-Modified），首个成功响应捕获，之后续传带 `If-Range`。
  String? _validator;

  Future<File> download() async {
    if (await destination.exists()) return destination;
    await partFile.parent.create(recursive: true);

    _store = await _ProgressStore.load(progressFile, plan);
    _validator = _store.validator;
    await _preparePartFile();
    _receivedTotal = _store.receivedTotal(plan);
    onProgress?.call(_receivedTotal, plan.totalBytes);

    final List<DownloadPart> pending = plan.parts
        .where((DownloadPart p) => _store.receivedOf(p.index) < p.length)
        .toList();

    if (pending.isNotEmpty) {
      _raf = await _openPartFile();
      try {
        await _runWorkers(pending);
      } finally {
        try {
          await _raf.flush();
        } catch (_) {
          // flush 失败不能盖住上面真正的错误；下面 close 仍要跑。
        }
        await _raf.close();
      }
    }

    await _verifyOrThrow();
    return _promote();
  }

  // ── 文件准备 ────────────────────────────────────────────────────────

  /// 确保 `.part` 存在且长度**恰好**是 totalBytes（预分配）。空间不够就在这里当场
  /// 失败，而不是下到 90% 才写不进去。
  Future<void> _preparePartFile() async {
    final bool exists = await partFile.exists();
    if (!exists) {
      final RandomAccessFile raf = await partFile.open(mode: FileMode.write);
      try {
        await raf.truncate(plan.totalBytes);
      } finally {
        await raf.close();
      }
      return;
    }
    final int length = await partFile.length();
    if (length == plan.totalBytes) return;
    final RandomAccessFile raf = await partFile.open(mode: FileMode.append);
    try {
      await raf.truncate(plan.totalBytes);
    } finally {
      await raf.close();
    }
  }

  /// 以 append 模式打开做随机写：`write` 会截断已下内容，只有 `append` 既不截断又能
  /// `setPosition` 随机写。该语义由 `segmented_downloader_test.dart` 的平台守卫钉住
  /// （某平台若按 `O_APPEND` 强制追加，测试当场红，而不是把 9.5 GB 写成乱序垃圾）。
  Future<RandomAccessFile> _openPartFile() =>
      partFile.open(mode: FileMode.append);

  // ── 并发调度 ────────────────────────────────────────────────────────

  Future<void> _runWorkers(List<DownloadPart> pending) async {
    final Queue<DownloadPart> queue = Queue<DownloadPart>.of(pending);
    Object? failure;
    StackTrace? failureStack;

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (failure != null) return;
        _throwIfCancelled();
        final DownloadPart part = queue.removeFirst();
        try {
          await _fetchPart(part);
        } catch (e, st) {
          // 先到的错误胜出；其余 worker 看到 failure 后收工（快速失败：一片彻底
          // 拿不到，整包就不可能完成，没必要让别的片继续烧流量）。
          failure ??= e;
          failureStack ??= st;
          queue.clear();
          return;
        }
      }
    }

    final int workerCount = math.min(concurrency, pending.length);
    await Future.wait<void>(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );
    if (failure != null) {
      Error.throwWithStackTrace(failure!, failureStack!);
    }
  }

  /// 取一片：按序轮换来源，直到取到或试满 [maxAttemptsPerPart] 次。
  Future<void> _fetchPart(DownloadPart part) async {
    Object? lastError;
    StackTrace? lastStack;
    for (int attempt = 0; attempt < maxAttemptsPerPart; attempt++) {
      _throwIfCancelled();
      // 源轮换把**分片序号**也算进去：只按 attempt 取模的话，第一轮所有并发分片
      // 全打 sources[0]，第二个源只有失败重试才用得上——那是故障转移，不是双源并拉。
      // 加上 part.index 后，片 0→源 0、片 1→源 1……天然摊到所有来源；而 attempt+1
      // 仍然换到下一个源，重试换源的性质原样保留。
      final DownloadSource source =
          part.sources[(part.index + attempt) % part.sources.length];
      try {
        await _fetchPartFrom(part, source);
        return;
      } on SegmentedDownloadCancelledException {
        rethrow;
      } catch (e, st) {
        lastError = e;
        lastStack = st;
        if (attempt + 1 < maxAttemptsPerPart) {
          final Duration wait = (retryBackoff ?? _defaultBackoff)(attempt);
          if (wait > Duration.zero) {
            await Future<void>.delayed(wait);
            _throwIfCancelled();
          }
        }
      }
    }
    Error.throwWithStackTrace(
      SegmentedDownloadPartException(part.index, lastError!),
      lastStack!,
    );
  }

  Future<void> _fetchPartFrom(DownloadPart part, DownloadSource source) async {
    int done = _store.receivedOf(part.index);
    if (done >= part.length) return;

    final int start = source.remoteOffset + done;
    final int end = source.remoteOffset + part.length - 1;
    final Map<String, String> headers = <String, String>{
      HttpHeaders.rangeHeader: 'bytes=$start-$end',
    };
    final String? validator = _validator;
    if (done > 0 && validator != null && validator.isNotEmpty) {
      headers[HttpHeaders.ifRangeHeader] = validator;
    }

    Future<ResumableDownloadResponse> opened =
        open(Uri.parse(source.url), headers);
    if (firstByteTimeout != null) {
      opened = opened.timeout(firstByteTimeout!);
    }
    final ResumableDownloadResponse response = await opened;

    if (response.statusCode == HttpStatus.partialContent) {
      // 206 必须带可解析的 Content-Range（RFC 9110）。缺了或看不懂就**不猜**——
      // 猜错就是把别处的字节写进本片偏移，最后只体现为一个 sha256 不符的坏包。
      final int? gotStart =
          _contentRangeStart(response.header(HttpHeaders.contentRangeHeader));
      if (gotStart != start) {
        await _abort(response);
        throw HttpException(
          'content-range 起点不符：要 $start 实到 $gotStart',
          uri: Uri.parse(source.url),
        );
      }
    } else if (response.statusCode == HttpStatus.ok) {
      // 服务器忽略了 Range，body 从**资源第 0 字节**开始。
      if (source.remoteOffset != 0) {
        // 整包来源：这条 body 是整个包，不是本片。绝不能消费（会下满 9.5 GB），
        // 直接断连换下一个来源。
        await _abort(response);
        throw HttpException(
          '来源忽略 Range，整包来源无法定位片 #${part.index}',
          uri: Uri.parse(source.url),
        );
      }
      // 切片来源：body 就是本片，从头重写（旧的半截作废）。
      done = 0;
      await _ioLock.run(() async {
        _receivedTotal -= _store.receivedOf(part.index);
        _store.setReceived(part.index, 0);
      });
    } else {
      await _abort(response);
      throw HttpException(
        'download failed (${response.statusCode})',
        uri: Uri.parse(source.url),
      );
    }

    _validator ??= response.header(HttpHeaders.etagHeader) ??
        response.header(HttpHeaders.lastModifiedHeader);

    await _consumePart(part: part, response: response, alreadyDone: done);
  }

  /// 消费一片的 body：边写盘边算摘要，取够 [DownloadPart.length] 立刻跳出。
  Future<void> _consumePart({
    required DownloadPart part,
    required ResumableDownloadResponse response,
    required int alreadyDone,
  }) async {
    final String? expected = part.sha256;
    ByteConversionSink? hasher;
    _DigestSink? digestSink;
    if (expected != null) {
      digestSink = _DigestSink();
      hasher = sha256.startChunkedConversion(digestSink);
      if (alreadyDone > 0) {
        await _seedHasher(hasher, part, alreadyDone);
      }
    }

    int written = alreadyDone;
    int sinceFlush = 0;

    Stream<List<int>> body = response.stream;
    if (bodyTimeout != null) body = body.timeout(bodyTimeout!);

    await for (final List<int> chunk in body) {
      if (isCancelled?.call() ?? false) {
        await _flushAndPersist(part.index, written);
        throw const SegmentedDownloadCancelledException();
      }
      if (chunk.isEmpty) continue;
      // 服务器多给了就只取够（忽略 Range 的 200 会一路送到文件末尾）。
      final int take = math.min(chunk.length, part.length - written);
      if (take <= 0) break;

      final int writeAt = part.offset + written;
      await _ioLock.run(() async {
        await _raf.setPosition(writeAt);
        await _raf.writeFrom(chunk, 0, take);
      });
      hasher?.addSlice(chunk, 0, take, false);

      written += take;
      sinceFlush += take;
      _receivedTotal += take;
      onProgress?.call(_receivedTotal, plan.totalBytes);

      if (sinceFlush >= flushInterval) {
        await _flushAndPersist(part.index, written);
        sinceFlush = 0;
      }
      if (written >= part.length) break; // 取够就断连，不读整包
    }

    if (written < part.length) {
      await _flushAndPersist(part.index, written);
      throw HttpException(
        '片 #${part.index} 提前结束：$written / ${part.length}',
      );
    }

    if (expected != null) {
      hasher!.close();
      final String actual = digestSink!.value.toString();
      if (actual != expected) {
        // 坏片不留：已收清零，下次重下这一片（整包其余片不受影响）。
        await _ioLock.run(() async {
          _receivedTotal -= _store.receivedOf(part.index);
          _store.setReceived(part.index, 0);
        });
        await _store.persist(progressFile, plan, _validator);
        throw ResumableDownloadIntegrityException(
          '片 #${part.index} sha256 不符：得 $actual 期望 $expected',
        );
      }
    }

    await _flushAndPersist(part.index, written);
  }

  /// 续传时把已落盘的前缀喂给摘要器，免得为了校验再整片重读一遍。
  Future<void> _seedHasher(
    ByteConversionSink hasher,
    DownloadPart part,
    int prefixLength,
  ) async {
    final RandomAccessFile reader = await partFile.open(mode: FileMode.read);
    try {
      await reader.setPosition(part.offset);
      int remaining = prefixLength;
      const int bufferSize = 1 << 20;
      while (remaining > 0) {
        final int want = math.min(bufferSize, remaining);
        final List<int> bytes = await reader.read(want);
        if (bytes.isEmpty) {
          throw ResumableDownloadIntegrityException(
            '片 #${part.index} 前缀读取提前结束',
          );
        }
        hasher.addSlice(bytes, 0, bytes.length, false);
        remaining -= bytes.length;
      }
    } finally {
      await reader.close();
    }
  }

  Future<void> _flushAndPersist(int partIndex, int received) async {
    await _ioLock.run(() async {
      await _raf.flush();
      _store.setReceived(partIndex, received);
    });
    await _store.persist(progressFile, plan, _validator);
  }

  /// 断开一条不要的响应流：**不能**用 `drain`——整包来源的 body 是 9.5 GB。
  Future<void> _abort(ResumableDownloadResponse response) async {
    try {
      final StreamSubscription<List<int>> sub =
          response.stream.listen(null, cancelOnError: true);
      await sub.cancel();
    } catch (_) {
      // best-effort：断连失败不该盖住真正的失败原因。
    }
  }

  void _throwIfCancelled() {
    if (isCancelled?.call() ?? false) {
      throw const SegmentedDownloadCancelledException();
    }
  }

  // ── 收尾 ────────────────────────────────────────────────────────────

  Future<void> _verifyOrThrow() async {
    final int length = await partFile.length();
    if (length != plan.totalBytes) {
      throw ResumableDownloadIntegrityException(
        '大小不符：得 $length 期望 ${plan.totalBytes}',
      );
    }
    final String? expected = plan.sha256;
    // 每片都验过摘要时，逐片校验已严格强于整包校验，省掉一次 9.5 GB 重读。
    if (expected == null || plan.hasPerPartDigests) return;
    final Digest digest = await sha256.bind(partFile.openRead()).first;
    if (digest.toString() != expected) {
      await _deleteQuietly(partFile);
      await _deleteQuietly(progressFile);
      throw ResumableDownloadIntegrityException(
        '整包 sha256 不符：得 $digest 期望 $expected',
      );
    }
  }

  Future<File> _promote() async {
    await destination.parent.create(recursive: true);
    if (await destination.exists()) await _deleteQuietly(destination);
    final File promoted = await partFile.rename(destination.path);
    await _deleteQuietly(progressFile);
    return promoted;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // best-effort
    }
  }

  static int? _contentRangeStart(String? value) {
    if (value == null) return null;
    final RegExpMatch? match =
        RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$').firstMatch(value.trim());
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }
}

/// 串行化写盘：多个片并发到达，但只有一个 [RandomAccessFile]，`setPosition` +
/// `writeFrom` 必须成对地不被打断，否则两片会写到彼此的偏移上。
///
/// 用锁而不是「每片开一个 fd」是有意的：瓶颈在网络不在盘，一把锁最笨也最不会错。
class _AsyncLock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() body) {
    final Completer<void> gate = Completer<void>();
    final Future<void> previous = _tail;
    _tail = gate.future;
    return previous.then((_) => body()).whenComplete(gate.complete);
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 各片已收字节的持久化。与计划的 `version` / `totalBytes` / `sha256` 绑定：任何一项
/// 对不上说明服务端换包了，整份进度作废（而不是把新旧两个包的字节拼在一起）。
class _ProgressStore {
  _ProgressStore._(this._received, this.validator);

  static const int _formatVersion = 1;

  final Map<int, int> _received;
  String? validator;

  static Future<_ProgressStore> load(File file, DownloadPlan plan) async {
    try {
      if (!await file.exists()) return _ProgressStore._(<int, int>{}, null);
      final Object? decoded = json.decode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return _ProgressStore._(<int, int>{}, null);
      }
      if (decoded['version'] != _formatVersion ||
          decoded['totalBytes'] != plan.totalBytes ||
          decoded['planVersion'] != plan.version ||
          decoded['sha256'] != plan.sha256) {
        return _ProgressStore._(<int, int>{}, null);
      }
      final Object? parts = decoded['parts'];
      final Map<int, int> received = <int, int>{};
      if (parts is Map<String, dynamic>) {
        for (final MapEntry<String, dynamic> entry in parts.entries) {
          final int? index = int.tryParse(entry.key);
          final Object? value = entry.value;
          if (index == null || value is! int || value < 0) continue;
          received[index] = value;
        }
      }
      // 越界的记录（片表变了）一律丢弃，避免把已收字节记到不存在的偏移上。
      final Map<int, int> clamped = <int, int>{};
      for (final DownloadPart part in plan.parts) {
        final int? got = received[part.index];
        if (got == null || got <= 0) continue;
        clamped[part.index] = math.min(got, part.length);
      }
      final Object? validator = decoded['validator'];
      return _ProgressStore._(
        clamped,
        validator is String && validator.isNotEmpty ? validator : null,
      );
    } catch (_) {
      return _ProgressStore._(<int, int>{}, null);
    }
  }

  int receivedOf(int index) => _received[index] ?? 0;

  void setReceived(int index, int value) => _received[index] = value;

  int receivedTotal(DownloadPlan plan) {
    int sum = 0;
    for (final DownloadPart part in plan.parts) {
      sum += math.min(receivedOf(part.index), part.length);
    }
    return sum;
  }

  Future<void> persist(File file, DownloadPlan plan, String? validator) async {
    this.validator = validator;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(json.encode(<String, Object?>{
        'version': _formatVersion,
        'totalBytes': plan.totalBytes,
        'planVersion': plan.version,
        'sha256': plan.sha256,
        'validator': validator,
        'parts': <String, int>{
          for (final MapEntry<int, int> e in _received.entries)
            if (e.value > 0) '${e.key}': e.value,
        },
      }));
    } catch (_) {
      // 进度落盘失败只影响续传效率，不该中断正在进行的下载。
    }
  }
}
