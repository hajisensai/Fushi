import 'dart:async';
import 'dart:io';

import 'package:fushi/src/media/manga/manga_panel_detector.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/manga/panel_detection.dart';
import 'package:fushi_engine/media/manga/panel_model_manifest.dart';
import 'package:fushi_engine/ocr/ocr_host_bindings.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

class MangaPanelModelStatus {
  const MangaPanelModelStatus({
    required this.available,
    required this.bytes,
    this.error,
  });

  final bool available;
  final int bytes;
  final String? error;
}

const String kMangaPanelModelDirectory = 'manga_panel_detector';

/// 模型文件修订号：每次下载并校验通过后 +1。阅读页缓存「模型不可用」时记下当时的
/// 修订号，号变了就重试建检测器——这样无论从设置页还是制卡对话框下载，开着的书都能
/// 立刻用上，又不必每次检测都对整份模型重算 sha256。
int mangaPanelModelRevision = 0;

Future<Directory> mangaPanelModelDirectory() async {
  final Directory root = await enginePaths.supportRootDirectory();
  return Directory(
    '${root.path}${Platform.pathSeparator}$kMangaPanelModelDirectory',
  );
}

Future<File> mangaPanelModelFile() async {
  final Directory dir = await mangaPanelModelDirectory();
  return File(
    '${dir.path}${Platform.pathSeparator}${kMangaPanelModelManifest.fileName}',
  );
}

Future<MangaPanelModelStatus> mangaPanelModelStatus() async {
  if (!kMangaPanelModelManifest.isVerified) {
    return const MangaPanelModelStatus(
      available: false,
      bytes: 0,
      error: 'panel model release asset is not verified',
    );
  }
  final File file = await mangaPanelModelFile();
  if (!await file.exists()) {
    return const MangaPanelModelStatus(available: false, bytes: 0);
  }
  final int bytes = await file.length();
  if (bytes != kMangaPanelModelManifest.bytes) {
    return MangaPanelModelStatus(
      available: false,
      bytes: bytes,
      error: 'model size mismatch',
    );
  }
  final String digest = await _sha256(file);
  return MangaPanelModelStatus(
    available: digest == kMangaPanelModelManifest.sha256,
    bytes: bytes,
    error: digest == kMangaPanelModelManifest.sha256
        ? null
        : 'model checksum mismatch',
  );
}

/// 模型下载时等响应头、以及两个数据块之间允许的最长停顿（整体不设限）。
const Duration kMangaPanelModelStallTimeout = Duration(seconds: 30);

/// 下载分镜模型，逐块产出已收字节数。
///
/// 连接卡住（[stallTimeout] 内一个字节都没来）以 [TimeoutException] 结束并断开
/// 连接，不让设置页永远停在「下载中」。任何失败都删掉 `.part`。
///
/// **进程内同时只有一次下载**：设置页、阅读页的高级制卡、制卡对话框三个入口都调
/// 这里，写的是同一个 `<模型>.part`。下载进行中再调用不另起一次，而是接到正在跑的
/// 那一次上（先补一条当前进度，之后同步收进度、完成与失败）。旧实现各起各的：
/// 两路往同一个暂存文件交错写，一路失败时把另一路正在写的 `.part` 删掉，校验必挂。
/// 全部订阅者都取消时才中止下载（只有一个入口时与旧语义相同）。
/// [clientFactory] / [stallTimeout] 只对发起那一次生效。
///
/// 取消立刻停（拍板台 design-nmv-fyi-tail ⑤）：最后一个订阅者取消时先强关这次下载
/// 的连接，卡在等响应头 / 等数据的下载体当场以连接错误醒来、走 finally 删 `.part`，
/// 不必再等下一块或一个 [stallTimeout]（以前取消后马上重下，新那次最多要等 30 秒）。
/// 新发起的那一次仍先等上一次的下载体真正退出（[_panelModelStopped]）再碰 `.part`，
/// 否则旧那次的清理会删掉新那次正在写的暂存文件。
Stream<int> downloadMangaPanelModel({
  HttpClient Function()? clientFactory,
  Duration stallTimeout = kMangaPanelModelStallTimeout,
}) {
  _PanelModelDownload? download = _panelModelDownload;
  if (download == null) {
    final HttpClient client = (clientFactory ?? createAppHttpClient)();
    download = _panelModelDownload = _PanelModelDownload(
      _downloadMangaPanelModelOnce(
        after: _panelModelStopped,
        client: client,
        stallTimeout: stallTimeout,
      ),
      abort: () => client.close(force: true),
    );
  }
  return download.subscribe();
}

_PanelModelDownload? _panelModelDownload;

/// 最近发起的那一次下载的下载体退出（含 finally 的 `.part` 清理）时完成；只当次序
/// 信号，从不带错误。
Future<void> _panelModelStopped = Future<void>.value();

/// 正在进行的那一次下载与它的订阅者。下载结束（成功或失败）时先摘掉
/// [_panelModelDownload] 再通知订阅者：之后的调用会重新发起，不会接到已结束的这一次。
class _PanelModelDownload {
  _PanelModelDownload(Stream<int> source, {required void Function() abort})
    : _abort = abort {
    _panelModelStopped = _stopped.future;
    _source = source.listen(
      (int received) {
        _received = received;
        for (final StreamController<int> sub in _subscribers.toList()) {
          sub.add(received);
        }
      },
      onError: (Object error, StackTrace stack) {
        _detach();
        for (final StreamController<int> sub in _subscribers.toList()) {
          sub.addError(error, stack);
        }
      },
      onDone: () {
        _detach();
        for (final StreamController<int> sub in _subscribers.toList()) {
          unawaited(sub.close());
        }
        _subscribers.clear();
        _markStopped();
      },
      cancelOnError: false,
    );
  }

  late final StreamSubscription<int> _source;
  final void Function() _abort;
  final Completer<void> _stopped = Completer<void>();

  void _markStopped() {
    if (!_stopped.isCompleted) _stopped.complete();
  }

  final List<StreamController<int>> _subscribers = <StreamController<int>>[];
  int? _received;

  void _detach() {
    if (identical(_panelModelDownload, this)) _panelModelDownload = null;
  }

  Stream<int> subscribe() {
    late final StreamController<int> sub;
    sub = StreamController<int>(
      onCancel: () async {
        _subscribers.remove(sub);
        if (_subscribers.isEmpty && identical(_panelModelDownload, this)) {
          // 最后一个订阅者走了：先强关连接让卡在 await 上的下载体当场醒来，再等它
          // 跑完 finally（删 `.part`）。async* 的取消只在下一次 yield 时生效，单靠
          // cancel 要等到下一块数据或停顿超时。
          _detach();
          _abort();
          try {
            await _source.cancel();
          } finally {
            _markStopped();
          }
        }
      },
    );
    final int? received = _received;
    if (received != null) sub.add(received);
    _subscribers.add(sub);
    return sub.stream;
  }
}

Stream<int> _downloadMangaPanelModelOnce({
  required Future<void> after,
  required HttpClient client,
  Duration stallTimeout = kMangaPanelModelStallTimeout,
}) async* {
  // 连接从头到尾归这一次下载体所有：任何一步抛出都在最外层 finally 里关掉。
  try {
    await after;
    if (!kMangaPanelModelManifest.isVerified) {
      throw StateError('panel model manifest has no verified release digest');
    }
    final Directory dir = await mangaPanelModelDirectory();
    await dir.create(recursive: true);
    final File target = File(
      '${dir.path}${Platform.pathSeparator}${kMangaPanelModelManifest.fileName}',
    );
    final File part = File('${target.path}.part');
    final HttpClientRequest request = await client.getUrl(
      Uri.parse(kMangaPanelModelManifest.assetUrl),
    );
    request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
    final HttpClientResponse response = await request.close().timeout(
      stallTimeout,
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('model download HTTP ${response.statusCode}');
    }
    IOSink? sink = part.openWrite();
    bool verified = false;
    try {
      int received = 0;
      await for (final List<int> chunk in response.timeout(stallTimeout)) {
        received += chunk.length;
        if (received > kMangaPanelModelManifest.bytes!) {
          throw StateError('model exceeds manifest size');
        }
        sink.add(chunk);
        yield received;
      }
      await sink.close();
      sink = null;
      if (received != kMangaPanelModelManifest.bytes ||
          await _sha256(part) != kMangaPanelModelManifest.sha256) {
        throw StateError('downloaded panel model failed manifest validation');
      }
      verified = true;
    } finally {
      await sink?.close();
      if (!verified && await part.exists()) await part.delete();
    }
    // A retry may be replacing a corrupt file. Windows rename does not replace
    // an existing target, so remove only this verified-path target immediately
    // before the atomic move.
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
    mangaPanelModelRevision++;
  } finally {
    client.close(force: true);
  }
}

Future<PanelDetector?> createMangaPanelDetector() async {
  final MangaPanelModelStatus status = await mangaPanelModelStatus();
  if (!status.available) return null;
  final OcrSessionFactory Function()? builder = ocrSessionFactoryBuilder;
  if (builder == null) return null;
  final OcrSessionFactory factory = builder();
  final File model = await mangaPanelModelFile();
  final OcrSession session = await factory.createSession(
    model.path,
    providers: <OcrExecutionProvider>[OcrExecutionProvider.cpu],
  );
  return OnnxPanelDetector(
    session,
    modelRevision: kMangaPanelModelManifest.revision,
  );
}

Future<String> _sha256(File file) => ffcSha256File(file.path);

void installMangaPanelDetectorFactory() {
  mangaPanelDetectorFactory = createMangaPanelDetector;
}
